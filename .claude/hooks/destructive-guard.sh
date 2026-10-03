#!/usr/bin/env bash
# PreToolUse:Bash guard — blocks irreversible operations: git (staging, history,
# push/reset/clean), filesystem (recursive forced rm — only through
# .claude/bin/guarded-rm), prod DB (psql DROP/TRUNCATE/DELETE without WHERE),
# GitHub repo deletion. Exit 2 = block.
set -euo pipefail

block() {
  echo "BLOCKED: $1" >&2
  exit 2
}

# Outcomes of this hook: 0 = allowed, 2 = forbidden OR the check itself failed.
# Claude Code treats only exit code 2 as a block, so any other non-zero exit (a
# missing perl or jq, a command failing under `set -e`) would let the call through.
# Every unexpected exit is turned into a block instead (issue #940).
fail_check() {
  block "ошибка проверки destructive-guard ($1) — команда не пропущена. Разовая необходимость: CC_ALLOW_DESTRUCTIVE_INPUT=1 из реального шелла пилота."
}
on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then
    fail_check "неожиданный выход, код $rc"
  fi
}
trap on_exit EXIT

# matches TEXT <grep options and pattern...> — 0 = match, 1 = no match. A grep or printf that
# FAILS (exit code 2 or more: a broken binary, a bad pattern) is a failed check and blocks;
# inside `if cmd | grep -q ...` it used to read as "no match" and let the call through.
# `grep -c` reads all its input, so an early exit of grep cannot raise SIGPIPE in printf.
matches() {
  local text=$1 feed=0 found=0
  shift
  { printf '%s\n' "$text" | grep -c "$@" >/dev/null; feed=${PIPESTATUS[0]} found=${PIPESTATUS[1]}; } || true
  [ "$feed" -eq 0 ] || fail_check "printf, код $feed"
  case "$found" in
    0|1) return "$found" ;;
    *) fail_check "grep, код $found" ;;
  esac
}

# Bypass: только из реального шелла пилота (тот же контракт, что secret-leak-block.sh —
# хук читает свой процессный env, не текст команды, агент не может выставить это сам себе).
# Строгое сравнение с "1" (не -n) — та же несогласованность в secret-leak-block.sh
# (там -n) допустима для существующего кода, но не стоит копировать её в новый
# (пир-ревью Codex, WP-544 Ф1, 20.08): -n пропустил бы CC_ALLOW_DESTRUCTIVE_INPUT=0 как bypass.
# Первым делом, до разбора входа: обход пилота должен работать и при сломанном jq.
[ "${CC_ALLOW_DESTRUCTIVE_INPUT:-}" = "1" ] && exit 0

# Portable timeout (same helper as rule-engine.sh:_safe_timeout — kept local,
# not sourced, since this hook has no other dependency on rule-engine.sh).
# Plain `timeout` is a GNU coreutils binary, not part of base macOS: on a
# clean Mac install (no Homebrew coreutils) it is simply absent, `command not
# found` exits 127, and the `if !` below treats that identically to a real jq
# failure — every Bash call gets fail-closed blocked (issue #754).
_safe_timeout() {
  local t="$1"; shift
  if command -v gtimeout &>/dev/null; then
    gtimeout "$t" "$@"
  elif command -v timeout &>/dev/null; then
    timeout "$t" "$@"
  else
    perl -e "alarm $t; exec @ARGV" -- "$@"
  fi
}

# Read stdin once: a pipe/redirected fd is fully drained by the first jq call,
# so a second `jq` reading raw stdin always sees EOF and returns empty — this
# silently zeroed out $CWD on every invocation (found WP-547, 03.09, while
# verifying the stash-pop/apply check below, which depends on the real cwd).
HOOK_INPUT=$(cat 2>/dev/null || true)

# Fail-closed on a malformed/schema-invalid envelope (WP-544 Д22, peer session
# 2026-09-08-25-wp544-continue-f7, Codex). The old `jq ... // empty || true`
# swallowed any jq parse error into an empty $CMD, and the next line read
# that as "no command, nothing to check" and exited 0 — a truncated payload
# with a real `rm -rf /x` inside it passed silently (reproduced live). `jq -e`
# on the whole envelope fails (non-zero exit) on a parse error, a non-object
# root, a missing/null/non-string/empty `tool_input.command`, or `jq` itself
# missing — none of those can be told apart from an actually-dangerous
# command with certainty, so all of them block rather than pass through.
# Never echo the raw payload here: it can carry command text with secrets.
# `timeout 5` on every jq call over $HOOK_INPUT (defense-in-depth, cold review
# WP-544 Д22, 08.09): jq reads over a pipe so it isn't hit by the ARG_MAX bug
# above, but nothing bounded how long it could run on a pathological payload
# either — a hang here would hang the hook, and by the same fail-closed logic
# as the rest of this block, a hung/killed jq (exit 124) blocks too.
if ! printf '%s' "$HOOK_INPUT" | _safe_timeout 5 jq -e \
  'type == "object" and (.tool_input | type) == "object" and (.tool_input.command | type) == "string" and (.tool_input.command | length) > 0' \
  >/dev/null 2>&1; then
  block "не удалось разобрать вход хука, либо tool_input.command отсутствует/пустой/неверного типа — блокирую как неопределённо опасный запрос."
fi
# `|| block ...`, not a bare assignment: under `set -e` a failing command
# substitution assigned straight to a variable kills the script with jq's own
# raw exit code, bypassing block()'s deliberate exit 2 — the same "crash
# instead of a decision" class as the ARG_MAX bug above. This jq call should
# never actually fail here (the identical content just parsed successfully
# one line up), but "should never fail" is exactly the assumption Д22 exists
# to not make.
CMD=$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_input.command') || block "jq отказал при извлечении команды после успешной валидации — блокирую."
CWD=$(printf '%s' "$HOOK_INPUT" | jq -r '.cwd // .tool_input.cwd // empty' 2>/dev/null || true)
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
WORKSPACE_ROOT="$(cd "$HOOK_DIR/../.." && pwd -P)"
GUARDED_RM="$WORKSPACE_ROOT/.claude/bin/guarded-rm"

# --- what this hook is allowed to look at (WP-545, 06.09) -------------------
#
# Every check below used to match against the raw Bash call text. Two live
# false positives in one session showed what that costs:
#   * writing a document through `cat > file <<'EOF' ... EOF` was refused as
#     `rm -rf`, because the check greps `rm`, a `-r`-ish flag and a `-f`-ish
#     flag ANYWHERE in the call: `rm -f "$PROMPT_FILE"` (a temp-file cleanup)
#     supplied two of them and the unrelated `--add-dir` of another command
#     supplied the "recursive" one;
#   * a session-close call was refused as `git add .`, because the standalone
#     `.` of `. "$HOME/.../publish-gate.sh"` (shell `source`) sat on a LATER
#     LINE of the same call, and the segment splitter did not treat a newline
#     as a command separator, so it landed inside the `git add` segment.
#
# So the text scanned is narrowed twice, before any check runs: heredoc bodies
# sent to data commands are removed, while bodies sent to literal shell/SQL
# interpreters remain; a newline separates commands the same way `;` does.
CMD_EXEC=$(printf '%s' "$CMD" | perl -e '
  # Read via stdin, not $ENV{CMD_SCAN}: a command text passed through the
  # process environment is subject to the same execve ARG_MAX as argv (found
  # by cold review, WP-544 Д22, 08.09 — a ~1.1MB command crashed this call
  # with "Argument list too long" (exit 126) instead of reaching block() or
  # exit 0, bypassing every check below it). Stdin has no such limit.
  my $text = do { local $/; <STDIN> };
  my @lines = split(/\n/, $text, -1);
  my (@out, @pending);
  sub continued_header {
    my ($line, $initial_quote) = @_;
    my ($slashes) = $line =~ /(\\+)$/;
    return 0 unless defined $slashes && length($slashes) % 2;
    my $quote = $initial_quote;
    for (my $i = 0; $i < length($line); $i++) {
      my $char = substr($line, $i, 1);
      if (defined $quote) {
        if ($quote ne chr(39) && $char eq "\\" && $i + 1 < length($line)) { $i++; next; }
        undef $quote if $char eq $quote;
      } elsif ($char eq "\\" && $i + 1 < length($line)) {
        $i++;
      } elsif ($char eq chr(39) || $char eq q{"}) {
        $quote = $char;
      }
    }
    return !defined $quote || $quote eq q{"};
  }

  sub is_data_command {
    my ($first, $next) = @_;
    return 1 if lc($first) =~ /^(?:cat|echo|printf|test|\[|type|which|python[0-9.]*|perl|jq|sed|awk|grep|rg|tee|head|tail|wc|sort|uniq|cut|ls)$/;
    return 1 if lc($first) eq q{command} && ($next // q{}) =~ /^-[vV]$/;
    return 0;
  }

  sub heredoc_recipient {
    my ($fragment) = @_;
    my @words = grep { length } split(/\s+/, $fragment);
    # Data commands may mention an interpreter as a filename or argument.
    # Their heredoc is still data; aliases/functions changing the command
    # meaning are dynamic and outside this static check.
    my $first = $words[0] // q{};
    $first =~ s/<<-?.*$//;
    $first =~ s/^[!({]+//;
    $first =~ s{^.*[/\\]}{};
    $first =~ s/[;)}]+$//;
    $first =~ s/^[\x27"]+|[\x27"]+$//g;
    $first =~ s/\.exe$//i;
    return 0 if is_data_command($first, $words[1]);
    # A wrapper or remote shell may carry the interpreter. For other commands,
    # scanning later words errs toward keeping data, not discarding runnable code.
    for my $word (@words) {
      $word =~ s/<<-?.*$//;
      $word =~ s/^[!({]+//;
      $word =~ s{^.*[/\\]}{};
      $word =~ s/[;)}]+$//;
      $word =~ s/^[\x27"]+|[\x27"]+$//g;
      $word =~ s/\.exe$//i;
      return 1 if lc($word) =~ /^(?:(?:ba|z|k|da)?sh|ssh|psql|mysql|sqlite3)$/;
    }
    return 0;
  }

  sub data_command_before_heredoc {
    my ($fragment) = @_;
    $fragment =~ s/^\s+//;
    # Assignments and output redirects can precede a command, including one
    # placed to the right of the heredoc operator.
    while ($fragment =~ s/^(?:[A-Za-z_][A-Za-z0-9_]*=\S+|\d*(?:>>|<>|<&|>&|>\||>|<)\s*\S+)\s*//) {}
    $fragment =~ s/^\s*(?:(?:if|then|else|do)\b\s*)+//;
    my @words = grep { length } split(/\s+/, $fragment);
    while (@words) {
      if (lc($words[0]) eq q{env}) {
        shift @words;
        shift @words while @words && $words[0] =~ /^[A-Za-z_][A-Za-z0-9_]*=/;
      } elsif (lc($words[0]) eq q{sudo}) {
        shift @words;
        while (@words && $words[0] =~ /^-/) {
          my $option = shift @words;
          shift @words if @words && $option =~ /^(?:-u|--user)$/;
        }
      } else { last; }
    }
    my $first = $words[0] // q{};
    $first =~ s/^[!({]+//;
    $first =~ s{^.*[/\\]}{};
    $first =~ s/[;)}]+$//;
    $first =~ s/^[\x27"]+|[\x27"]+$//g;
    $first =~ s/\.exe$//i;
    return is_data_command($first, $words[1]);
  }

  sub right_command_stages {
    my ($tail) = @_;
    my @stages;
    my $stage = q{};
    my $quote;
    for (my $i = 0; $i < length($tail); $i++) {
      my $char = substr($tail, $i, 1);
      my $next = substr($tail, $i + 1, 1);
      my $prev = $i ? substr($tail, $i - 1, 1) : q{};
      if (defined $quote) {
        $stage .= $char;
        if ($quote ne chr(39) && $char eq "\\" && $i + 1 < length($tail)) {
          $stage .= $next; $i++; next;
        }
        undef $quote if $char eq $quote;
        next;
      }
      if ($char eq "\\" && $i + 1 < length($tail)) { $stage .= $char . $next; $i++; next; }
      if ($char eq chr(39) || $char eq q{"}) { $quote = $char; $stage .= $char; next; }
      last if $char eq q{;};
      if ($char eq q{|} && $prev ne q{>}) {
        last if $next eq q{|};
        push @stages, $stage;
        $stage = q{};
        $i++ if $next eq q{&}; # |& forwards both streams into the next stage.
        next;
      }
      last if $char eq q{&} && $prev !~ /[<>]/ && $next ne q{>};
      $stage .= $char;
    }
    push @stages, $stage;
    return @stages;
  }

  sub compound_end {
    my ($fragment) = @_;
    return q{fi} if $fragment =~ /^\s*if\b/;
    return q{done} if $fragment =~ /^\s*(?:for|while|until|select)\b/;
    return q{esac} if $fragment =~ /^\s*case\b/;
    return q{};
  }

  sub compound_recipient {
    my ($source, $end) = @_;
    # Loop lists and case labels are data. Scan command fragments in the
    # construct, conservatively including every possible branch.
    if ($end eq q{done} && $source =~ /^\s*(?:for|select)\b/) {
      $source =~ s/^.*?(?:;|\n)\s*do\b//s;
    } elsif ($end eq q{esac}) {
      $source =~ s/^\s*case\b.*?\bin\b//s;
      $source =~ s/(?:^|;;|;&|;;&)\s*[^)\n]*\)/;/g;
    }
    for my $fragment (split(/[;\n]/, $source)) {
      $fragment =~ s/^\s*(?:(?:if|then|elif|else|do|while|until)\b\s*)+//;
      return 1 if heredoc_recipient($fragment);
    }
    return 0;
  }

  sub line_heredocs {
    my ($line, $initial_quote, $initial_depth, $prior_group_source, $compound_frames) = @_;
    my (@specs, $start, $group_depth, $closed_prior_group, $last_heredoc_end);
    my $quote = $initial_quote;
    $start = 0;
    $group_depth = $initial_depth;
    $closed_prior_group = 0;
    $last_heredoc_end = -1;
    for (my $i = 0; $i < length($line); $i++) {
      my $char = substr($line, $i, 1);
      if (defined $quote) {
        if ($quote ne chr(39) && $char eq "\\" && $i + 1 < length($line)) { $i++; next; }
        undef $quote if $char eq $quote;
        next;
      }
      if ($char eq "\\" && $i + 1 < length($line)) { $i++; next; }
      if ($char eq chr(39) || $char eq q{"}) { $quote = $char; next; }
      if ($char eq "(" || $char eq "{") { $group_depth++; next; }
      if ($char eq ")" || $char eq "}") {
        $group_depth-- if $group_depth;
        $closed_prior_group = 1 if $initial_depth && !$group_depth;
        next;
      }
      my $prev = $i ? substr($line, $i - 1, 1) : q{};
      my $next = substr($line, $i + 1, 1);
      # These are redirection operators, not shell command separators.
      next if ($char eq q{&} && ($prev =~ /[<>|]/ || $next eq q{>}))
           || ($char eq q{|} && $prev eq q{>});
      if (!$group_depth && $char =~ /[;&|]/) {
        my $fragment = substr($line, $start, $i - $start);
        if ($start >= $last_heredoc_end) {
          my $end = compound_end($fragment);
          if (length $end) { push @$compound_frames, { source => q{}, line_start => $start, end => $end }; }
          elsif ($fragment =~ /^\s*(fi|done|esac)\b/ && @$compound_frames && $compound_frames->[-1]{end} eq $1) {
            pop @$compound_frames;
          }
        }
        $start = $i + 1;
        if ($char eq q{|} && $next eq q{&}) { $start++; $i++; }
        $closed_prior_group = 0;
        next;
      }
      next unless substr($line, $i, 2) eq "<<";
      next if substr($line, $i, 3) eq "<<<";
      my $tail = substr($line, $i);
      next unless $tail =~ /^<<(-?)\s*(?!<)(?:([\x27"])([A-Za-z_][A-Za-z0-9_]*)\2|([A-Za-z_][A-Za-z0-9_]*))/;
      my $match_length = length($&);
      my ($indent, $delim) = ($1 eq q{-}, defined $3 ? $3 : $4);
      my $recipient = substr($line, $start, $i - $start);
      my $prefix_is_data = data_command_before_heredoc($recipient);
      my @right_stages = right_command_stages(substr($line, $i + $match_length));
      my $right_recipient = $right_stages[0];
      if ($recipient =~ /^\s*0?\s*$/) {
        # A redirect may precede its command: `<<EOF bash`, `0<<EOF psql`.
        # Only an empty/FD prefix is commandless; `cat <<EOF bash` still feeds
        # cat, with bash merely an argument. Stop at the next shell separator.
        $recipient = $right_recipient;
      }
      my $compound_end = $recipient =~ /^\s*(fi|done|esac)\s*$/ ? $1 : q{};
      my $frame;
      if (length $compound_end && @$compound_frames && $compound_frames->[-1]{end} eq $compound_end) {
        # A redirect on fi/done/esac belongs to the entire compound command.
        $frame = pop @$compound_frames;
        $recipient = $frame->{source} . substr($line, $frame->{line_start}, $i - $frame->{line_start});
      }
      $recipient = $prior_group_source . $recipient if $closed_prior_group;
      # Keep any body addressed to a literal interpreter, regardless of the
      # heredoc FD. It may be read through /dev/fd/N or a later FD chain;
      # `bash 2<<EOF` can therefore be rejected conservatively.
      my $keep = $frame ? compound_recipient($recipient, $frame->{end}) : heredoc_recipient($recipient);
      $keep ||= heredoc_recipient($right_recipient) unless $prefix_is_data;
      # A data command can forward the body over a pipe to a literal shell or
      # SQL client. A later `;`/`&&` command does not receive that body.
      for my $stage (@right_stages[1 .. $#right_stages]) {
        $keep ||= heredoc_recipient($stage);
      }
      push @specs, { indent => $indent, delim => $delim, keep => $keep };
      $last_heredoc_end = $i + $match_length;
      $i += $match_length - 1;
    }
    if (!$group_depth && $start >= $last_heredoc_end) {
      my $fragment = substr($line, $start);
      my $end = compound_end($fragment);
      if (length $end) { push @$compound_frames, { source => q{}, line_start => $start, end => $end }; }
      elsif ($fragment =~ /^\s*(fi|done|esac)\b/ && @$compound_frames && $compound_frames->[-1]{end} eq $1) {
        pop @$compound_frames;
      }
    }
    for my $frame (@$compound_frames) {
      $frame->{source} .= substr($line, $frame->{line_start}) . "\n";
      $frame->{line_start} = 0;
    }
    return (\@specs, $quote, $group_depth);
  }

  my ($header_quote, $header_group_depth, $group_source, @compound_frames) = (undef, 0, q{});
  for (my $line_no = 0; $line_no < @lines; $line_no++) {
    my $line = $lines[$line_no];
    if (@pending) {
      my $body = $pending[0];
      my $probe = $line;
      $probe =~ s/^\t+// if $body->{indent};
      if ($probe eq $body->{delim}) { shift @pending; push @out, q{}; next; }
      push @out, $line if $body->{keep};
      next;
    }
    while ($line_no + 1 < @lines && continued_header($line, $header_quote)) {
      $line =~ s/\\$//;
      $line .= $lines[++$line_no];
    }
    push @out, $line;
    my ($specs, $after_quote, $after_depth) = line_heredocs($line, $header_quote, $header_group_depth, $group_source, \@compound_frames);
    push @pending, @$specs;
    $header_quote = $after_quote;
    $group_source = $after_depth ? $group_source . $line . "\n" : q{};
    $header_group_depth = $after_depth;
  }
  # An unterminated body means this was not a heredoc at all (an arithmetic
  # shift, a quoted "<<" in prose): stripping there would hide real commands,
  # so the whole reduction is discarded rather than trusted.
  if (@pending) { print "UNTERMINATED"; exit 0; }
  print "OK", join("\n", @out);
')
if [ "$CMD_EXEC" = "UNTERMINATED" ]; then
  CMD_EXEC="$CMD"
else
  CMD_EXEC="${CMD_EXEC#OK}"
fi

# #362: a top-level `cd` persists between Bash calls in Claude Code. Strip
# quoted spans before detecting command segments; `(cd ... && ...)` remains
# allowed because the opening parenthesis is not a top-level separator.
CD_RC=0
printf '%s' "$CMD_EXEC" | perl -e '
  my $s = do { local $/; <STDIN> };
  $s =~ s/'"'"'[^'"'"']*'"'"'/ Q /g;
  $s =~ s/"(?:\\.|[^"\\])*"/ Q /g;
  exit($s =~ /(?:^\s*|[;&|\n]\s*)cd\s+/ ? 0 : 1);
' || CD_RC=$?
case "$CD_RC" in
  0) block "верхнеуровневый cd запрещён: используй git -C <path>, абсолютный путь или (cd <path> && ...)." ;;
  1) ;;
  *) fail_check "perl, проверка cd, код $CD_RC" ;;
esac

if [ -n "$CWD" ]; then
  CWD_PHYSICAL=$(cd "$CWD" 2>/dev/null && pwd -P || printf '%s' "$CWD")
  if [ "$CWD_PHYSICAL" != "$WORKSPACE_ROOT" ] && \
     matches "$CMD_EXEC" -E "(^|[[:space:]\"'])(\\.claude/|scripts/|memory/)"; then
    block "root-relative path вызван из cwd=$CWD_PHYSICAL; используй абсолютный путь от $WORKSPACE_ROOT."
  fi
fi

# One shell splitter, three readers (WP-545, 06.09). This file used to carry
# two near-identical copies of the same perl segment scanner and a third
# whole-command grep pass; each copy learned about `>&` redirects, newlines
# and command positions separately, or not at all. MODE=match answers "which
# invocations of <name> does this call actually run", MODE=count answers "how
# many commands are in this call, and how many are <pattern>".
SEGMENTER_PL='
  sub words {
    my ($text) = @_;
    my (@out, $word, $quote) = ();
    for (my $i = 0; $i < length($text); $i++) {
      my $char = substr($text, $i, 1);
      if (defined $quote) {
        if ($char eq "\\" && $quote eq "ansi" && $i + 1 < length($text)) {
          # Decode what bash decodes inside dollar-single-quote: the flag -rf can be written -r\x66.
          my $esc = substr($text, $i + 1, 1);
          my $tail = substr($text, $i + 1);
          my %simple = (a => "\a", b => "\b", e => chr(27), E => chr(27), f => "\f", n => "\n", r => "\r", t => "\t", v => chr(11));
          if ($esc eq "x" && $tail =~ /^x([0-9A-Fa-f]{1,2})/) {
            $word .= chr(hex $1);
            $i += length($1) + 1;
          } elsif ($tail =~ /^([0-7]{1,3})/) {
            $word .= chr(oct($1) & 255);
            $i += length($1);
          } elsif (($esc eq "u" && $tail =~ /^u([0-9A-Fa-f]{1,4})/) || ($esc eq "U" && $tail =~ /^U([0-9A-Fa-f]{1,8})/)) {
            $word .= chr(hex $1);
            $i += length($1) + 1;
          } elsif (exists $simple{$esc}) {
            $word .= $simple{$esc};
            $i++;
          } elsif ($esc eq "c" && $i + 2 < length($text)) {
            $word .= chr(ord(substr($text, $i + 2, 1)) & 31);
            $i += 2;
          } elsif ($esc eq chr(92) || $esc eq chr(39) || $esc eq q{"} || $esc eq q{?}) {
            $word .= $esc;
            $i++;
          } else {
            $word .= $char;               # an unknown escape keeps its backslash
          }
        } elsif ($char eq "\\" && $quote eq q{"} && $i + 1 < length($text) && substr($text, $i + 1, 1) =~ /[\$`"\\\n]/) {
          # In double quotes a backslash escapes only $ ` " \ and a newline; in "C:\Git\usr" it stays.
          $word .= substr($text, ++$i, 1);
        } elsif ($char eq ($quote eq "ansi" ? chr(39) : $quote)) {
          undef $quote;
        } else {
          $word .= $char;
        }
      } elsif ($char eq q{$} && $i + 1 < length($text) && substr($text, $i + 1, 1) eq chr(39)) {
        # ANSI-C quoting (dollar + single quote): a backslash escapes the next char.
        $quote = "ansi";
        $i++;
      } elsif ($char eq q{$} && $i + 1 < length($text) && substr($text, $i + 1, 1) eq q{"}) {
        # dollar-double-quote (locale translation) is an ordinary double-quoted string: drop the dollar.
        next;
      } elsif ($char eq q{"} || $char eq chr(39)) {
        $quote = $char;
      } elsif ($char eq "\\" && $i + 1 < length($text)) {
        $word .= substr($text, ++$i, 1);
      } elsif ($char =~ /\s/) {
        push @out, $word if length $word;
        $word = q{};
      } else {
        $word .= $char;
      }
    }
    push @out, $word if length $word;
    return @out;
  }

  sub segments {
    my ($text) = @_;
    my (@out, $segment, $quote) = ((), q{}, undef);
    my $n = length($text);
    my $escaped_at = -1;
    for (my $i = 0; $i < $n; $i++) {
      my $char = substr($text, $i, 1);
      my $next = $i + 1 < $n ? substr($text, $i + 1, 1) : q{};
      if (defined $quote) {
        $segment .= $char;
        if ($char eq "\\" && ($quote eq q{"} || $quote eq "ansi") && $i + 1 < $n) {
          $segment .= substr($text, ++$i, 1);
        } elsif ($char eq ($quote eq "ansi" ? chr(39) : $quote)) {
          undef $quote;
        }
      } elsif ($char eq q{$} && $next eq chr(39)) {
        $quote = "ansi";
        $segment .= $char . $next;
        $i++;
      } elsif ($char eq "\\" && $next eq "\n") {
        # A backslash before a newline joins the lines and both vanish: r-backslash-newline-m is rm.
        $i++;
      } elsif ($char eq "\\" && $i + 1 < $n && $next !~ /[;&|(){}\n`]/) {
        # An escaped character is literal: an escaped quote opens no quote. An escaped separator
        # still splits (conservative: the next iteration sees it as the separator it looks like).
        $segment .= $char . $next;
        $escaped_at = length $segment;
        $i++;
      } elsif ($char eq q{"} || $char eq chr(39)) {
        $quote = $char;
        $segment .= $char;
      } elsif ($char eq q{#} && $escaped_at != length($segment) && ($segment eq q{} || $segment =~ /[ \t]$/)) {
        # A comment runs to the end of the line; an apostrophe in it must not open a quote
        # that swallows the next lines (and a command hidden behind them).
        my $end = index($text, "\n", $i);
        $i = ($end < 0 ? $n : $end) - 1;
      } elsif ($char eq chr(123) && $next eq chr(125)) {
        # `{}` — the placeholder of `find -exec` / `xargs -I {}`, not a brace group.
        $segment .= $char . $next;
        $i++;
      } elsif ($char eq q{&} && length($segment) && substr($segment, -1, 1) eq q{>}) {
        # `>&` fd-dup (`2>&1`, `>&2`) — part of the CURRENT command redirect,
        # not a separator (WP-544, 04.09: without this, a lone command ending
        # in `2>&1` was mis-split into two).
        $segment .= $char;
      } elsif ($char eq q{&} && $next eq q{>}) {
        $segment .= $char;
      } elsif ($char eq q{|} && length($segment) && substr($segment, -1, 1) eq q{>}) {
        $segment .= $char;                       # `>|` noclobber redirect
      } elsif ($char =~ /[;&|(){}\n]/ || $char eq q{`}) {
        # A newline ends a command exactly like `;` does. Without it, every
        # later line of a multi-line call was glued onto the first command
        # of the call — how a `source` dot two lines below a `git add <path>`
        # was read as `git add .` (WP-545).
        push @out, $segment;
        $segment = q{};
        $escaped_at = -1;
      } else {
        $segment .= $char;
      }
    }
    push @out, $segment;
    return @out;
  }

  # Basename of a command word: /bin/rm, /usr/bin/rm, C:\Git\usr\bin\rm.exe all name `rm`.
  # macOS and Windows can resolve /BIN/RM or GIT to the same executable; normalise
  # every command name, including data commands such as ECHO, before classification.
  sub command_base {
    my ($word) = @_;
    $word =~ s/[<>].*$//;                # rm>/dev/null names rm
    $word =~ s{^.*[/\\]}{};
    $word =~ s/\.exe$//i;
    return lc($word);
  }

  sub git_clean_would_delete {
    my @options = @_;
    # clean.requireForce=false makes even bare `git clean` destructive. Only an
    # effective dry-run proves that the invocation cannot remove files.
    my $dry_run = 0;
    for (my $i = 0; $i < @options; $i++) {
      my $token = $options[$i];
      last if $token eq "--";
      my ($long, $value) = split(/=/, $token, 2);
      if (length($long) >= 3 && index("--exclude", $long) == 0) {
        $i++ unless defined $value;
        next;
      }
      if (length($long) >= 4 && index("--dry-run", $long) == 0) { $dry_run = 1; next; }
      if (length($long) >= 5 && index("--no-dry-run", $long) == 0) { $dry_run = 0; next; }
      next unless $token =~ /^-[A-Za-z]/;
      my $flags = substr($token, 1);
      for (my $j = 0; $j < length($flags); $j++) {
        my $flag = substr($flags, $j, 1);
        # -e, also at the end of -fde, consumes the next token. In -fen the
        # attached n is its pattern, not a dry-run flag.
        if ($flag eq "e") { $i++ if $j == length($flags) - 1; last; }
        $dry_run = 1 if $flag eq "n";
      }
    }
    return !$dry_run;
  }

  sub rm_has_recursive_force {
    my @args = @_;
    my ($recursive, $force) = (0, 0);
    for my $token (@args) {
      last if $token eq "--";
      $token =~ s/\d*[<>].*$// if $token =~ /^-/;
      if ($token =~ /^-([A-Za-z]+)$/) {
        my $flags = $1;
        $recursive = 1 if $flags =~ /[rR]/;
        $force = 1 if $flags =~ /f/;
      } elsif ($token =~ /^(--[A-Za-z]+)$/) {
        my $option = lc($1);
        $recursive = 1 if length($option) >= 3 && index("--recursive", $option) == 0;
        $force = 1 if length($option) >= 3 && index("--force", $option) == 0;
      }
    }
    return $recursive && $force;
  }

  sub is_redirection {
    my ($word, $alone) = @_;
    return $alone ? ($word =~ /^(?:\d*|&)(?:>>?|<<?|>&|<&|>\|)$/) : ($word =~ /^(?:\d*|&)(?:>>?|<<?|>&|<&|>\|)./);
  }

  sub command_indices {
    # Token positions where a command NAME is expected — the executable of the
    # segment, plus the standard "run this command" carriers. Anything else (a
    # word inside a quoted argument, prose in an echo) is an argument, never a
    # command, and must not arm a check.
    #
    # Wrappers are skipped WITH their own options: cold review 06.09 found
    # `timeout 5 rm -rf …`, `nice rm -rf …`, `sudo -u nobody rm -rf …`,
    # `env -i rm -rf …` and `xargs -n 1 rm -rf …` all passing, because the
    # first option (or a bare duration) took the command position and the real
    # command behind it was never looked at. The list is deliberately generous:
    # a wrapper skipped in error only means one more position is examined.
    my %option_with_argument = (
      sudo    => qr/^(?:-u|-g|-h|-p|-C|-r|-t|--user|--group|--host|--prompt|--close-from|--role|--type)$/,
      doas    => qr/^(?:-u|-C)$/,
      env     => qr/^(?:-u|--unset|-C|--chdir)$/,
      timeout => qr/^(?:-s|-k|--signal|--kill-after)$/,
      nice    => qr/^(?:-n|--adjustment)$/,
      ionice  => qr/^(?:-c|-n|-p|-P|-u)$/,
      stdbuf  => qr/^(?:-i|-o|-e|--input|--output|--error)$/,
      time    => qr/^(?:-o|-f|--output|--format)$/,
      xargs   => qr/^(?:-n|-P|-I|-L|-s|-E|-d|-a|--max-args|--max-procs|--max-chars|--delimiter|--arg-file)$/,
    );
    my %keyword = map { $_ => 1 } qw(! then do else elif if while until);
    my (@tokens) = @_;
    my @indices;
    my $i = 0;
    while ($i < @tokens) {
      if ($tokens[$i] =~ /^[A-Za-z_][A-Za-z0-9_]*=/ || $keyword{$tokens[$i]}) { $i++; next; }
      # A redirection in front of the command (`> log cmd`, `2>&1 cmd`) is not the command.
      if (is_redirection($tokens[$i], 1)) { $i += 2; next; }
      if (is_redirection($tokens[$i], 0)) { $i++; next; }
      my $name = command_base($tokens[$i]);
      last unless $name =~ /^(?:command|builtin|exec|env|nohup|time|sudo|doas|timeout|nice|ionice|stdbuf|setsid|xargs)$/;
      my $pattern = $option_with_argument{$name};
      $i++;
      # `timeout 5 cmd`: the duration is not an option and not the command.
      $i++ if $name eq "timeout" && $i < @tokens && $tokens[$i] =~ /^[0-9]+(?:\.[0-9]+)?[smhd]?$/;
      while ($i < @tokens && $tokens[$i] =~ /^-/) {
        my $option = $tokens[$i];
        $i++;
        $i++ if defined $pattern && $option =~ $pattern && $i < @tokens;
      }
    }
    return () unless $i < @tokens;
    push @indices, $i;
    if (command_base($tokens[$i]) eq "find") {
      for (my $j = $i + 1; $j < $#tokens; $j++) {
        push @indices, $j + 1 if $tokens[$j] =~ /^-(?:exec|execdir)$/;
      }
    }
    return @indices;
  }

  my $cmd_scan = do { local $/; <STDIN> };
  my @found = grep { /\S/ } segments($cmd_scan);
  if ($ENV{"MODE"} eq "count") {
    # A hit is the pattern standing where a COMMAND name stands: the segment
    # executable, a command carried by find/xargs, or the script argument of a
    # shell interpreter (`bash /path/wrapper.sh`). The same name inside an
    # argument of another program (`find -name wrapper.sh`, `sed -n 1,60p
    # /path/wrapper.sh`) is data about the file, not a run of it.
    my $pattern = $ENV{"PATTERN"};
    my $hits = 0;
    for my $segment (@found) {
      my @tokens = words($segment);
      next unless @tokens;
      my $hit = 0;
      for my $index (command_indices(@tokens)) {
        next unless $index <= $#tokens;
        $hit = 1 if $tokens[$index] =~ /$pattern/;
        next unless $tokens[$index] =~ /^(?:.*\/)?(?:ba|z|k|da)?sh$/;
        for (my $j = $index + 1; $j <= $#tokens; $j++) {
          next if $tokens[$j] =~ /^-/;
          $hit = 1 if $tokens[$j] =~ /$pattern/;
          last;
        }
      }
      $hits += 1 if $hit;
    }
    print scalar(@found), " ", $hits, "\n";
    exit 0;
  }
  my $name = $ENV{"NAME"};
  my $subcmd = $ENV{"SUBCMD"};
  my %data = map { $_ => 1 } qw(echo printf : true false test [ which type man help grep egrep fgrep rg cat ls head tail wc sort uniq cut);
  my %global_option_with_argument = map { $_ => 1 } qw(-C -c --git-dir --work-tree --namespace --super-prefix --config-env);
  # A string handed to a shell (`bash -c "..."`, `eval "..."`) is commands too; it goes back
  # into the queue, a few levels deep.
  my @queue = map { [$_, 0] } @found;
  while (my $item = shift @queue) {
    my ($segment, $depth) = @$item;
    my @tokens = words($segment);
    next unless @tokens;
    for my $index (command_indices(@tokens)) {
      next unless $index <= $#tokens;
      my $base = command_base($tokens[$index]);
      if ($depth < 3 && $tokens[$index] =~ /\s/) {
        push @queue, map { [$_, $depth + 1] } grep { /\S/ } segments($tokens[$index]);
      }
      # Candidate command positions: the executable itself and, after a command that is not
      # known to only print its arguments, every later word (ssh host rm -rf x, docker exec c
      # sh -c "rm -rf x", strace git push --force). A data command (echo, grep, cat ...) ends
      # the search, and so does git: its later words are its arguments (git grep -e rm -e -rf).
      # A parse mistake here errs toward a block, never a pass.
      my @candidates = ($index);
      push @candidates, $index + 1 .. $#tokens unless $data{$base} || $base eq "git";
      for my $cand (@candidates) {
      my $cbase = command_base($tokens[$cand]);
      if ($depth < 3) {
        if ($cbase =~ /^(?:ba|z|k|da|a)?sh$/) {
          for (my $j = $cand + 1; $j <= $#tokens; $j++) {
            if ($tokens[$j] =~ /^-[A-Za-z]*c[A-Za-z]*$/ && $j < $#tokens) {
              my $script = $j + 1;
              $script++ if $tokens[$script] eq "--" && $script < $#tokens;
              push @queue, map { [$_, $depth + 1] } grep { /\S/ } segments($tokens[$script]);
              last;
            }
            if ($tokens[$j] =~ /^-[oO]$/ && $j < $#tokens) { $j++; next; }
            last unless $tokens[$j] =~ /^-/;
          }
        } elsif ($cand == $index && $cbase =~ /^(?:ssh|su)$/) {
          # ssh host "rm -rf /x": a word with blanks after ssh/su is a command line for the far side.
          for (my $j = $cand + 1; $j <= $#tokens; $j++) {
            push @queue, map { [$_, $depth + 1] } grep { /\S/ } segments($tokens[$j]) if $tokens[$j] =~ /\s/;
          }
        } elsif ($cbase eq "eval" && $cand < $#tokens) {
          push @queue, map { [$_, $depth + 1] } grep { /\S/ } segments(join(" ", @tokens[$cand + 1 .. $#tokens]));
        }
      }
      next unless $cbase eq $name;
      my $start = $cand;
      if (length $subcmd) {
        # Global git options (--no-pager, -C dir, -Cdir, -c k=v, a redirection) sit between
        # git and the subcommand.
        my $i = $start + 1;
        while ($i < @tokens) {
          if (is_redirection($tokens[$i], 1)) { $i += 2; }
          elsif (is_redirection($tokens[$i], 0)) { $i++; }
          elsif ($tokens[$i] =~ /^-/) { $i += $global_option_with_argument{$tokens[$i]} ? 2 : 1; }
          else { last; }
        }
        next unless $i < @tokens && $tokens[$i] eq $subcmd;
        # Keep only dangerous clean calls. The original token boundaries are
        # still available here, before printing merges quoted arguments.
        next if $name eq "git" && $subcmd eq "clean" && !git_clean_would_delete(@tokens[$i + 1 .. $#tokens]);
        next if $name eq "git" && $subcmd eq "rm" && !rm_has_recursive_force(@tokens[$i + 1 .. $#tokens]);
      }
      next if $name eq "rm" && !rm_has_recursive_force(@tokens[$cand + 1 .. $#tokens]);
      # Print and keep scanning — one call can chain several invocations of
      # the same command (`git push origin main && git push origin +:refs/x`),
      # and every check below reads all of them, one per line. The command word is printed
      # as its basename, so `/usr/bin/git reset` reads like `git reset` downstream. A second
      # line without redirections is printed when they change the text (`git add -A>/dev/null`
      # reads as `-A`); the raw line stays, because a quoted ">" looks like a redirection.
      my @raw = @tokens[$start .. $#tokens];
      $raw[0] = $name;
      print join(" ", @raw), "\n";
      my @clean = ($name);
      for (my $k = 1; $k < @raw; $k++) {
        if (is_redirection($raw[$k], 1)) { $k++; next; }
        next if is_redirection($raw[$k], 0);
        my $word = $raw[$k];
        $word =~ s/\d*[<>].*$// if $word =~ /^-/;
        push @clean, $word;
      }
      print join(" ", @clean), "\n" if join(" ", @clean) ne join(" ", @raw);
      }
    }
  }
'

shell_invocations() {
  # shell_invocations <command-name> [<git-style subcommand>]
  # One line per invocation actually run by this call, tokens normalised.
  # $CMD_EXEC goes over stdin, not as CMD_SCAN in the environment — an
  # execve-sized command text in the env hits the same ARG_MAX crash as the
  # perl calls above (found by cold review, WP-544 Д22, 08.09).
  local name="$1" subcmd="${2:-}"
  printf '%s' "$CMD_EXEC" | MODE=match NAME="$name" SUBCMD="$subcmd" perl -e "$SEGMENTER_PL"
}

shell_segment_stats() {
  # shell_segment_stats <perl-regex> -> "<total segments> <segments matching>"
  printf '%s' "$CMD_EXEC" | MODE=count PATTERN="$1" perl -e "$SEGMENTER_PL"
}

git_segment() {
  # Invocations where `git <global-opts> <subcmd>` is the command being run.
  # A regex over the raw command saw `git reset` inside a quoted argument of
  # another program as an actual Git command.
  shell_invocations git "$1"
}

is_git_subcmd() {
  [ -n "$(git_segment "$1")" ]
}

# git push --force / -f (allow the safe --force-with-lease)
PUSH_SEGMENT=$(git_segment push)
if [ -n "$PUSH_SEGMENT" ]; then
  PUSH_FORCE_SCAN=$(echo "$PUSH_SEGMENT" | sed -E 's/--force-with-lease(=[^[:space:]]*)?//g')
  if matches "$PUSH_FORCE_SCAN" -E -- '(^|[[:space:]])(--force([[:space:]]|=|$)|-[a-zA-Z]*f[a-zA-Z]*([[:space:]]|$))'; then
    block "git push --force запрещён. Используй --force-with-lease или согласуй с владельцем (CLAUDE.md §2)."
  fi

  # git push --delete / -d and refspec deletion (:<ref>, or +:<ref> force-form)
  # — same irreversible class as --force (WP-544 Д28). `-d` really is git's
  # short form of --delete (verified: `git push --help` lists `[-f | --force]
  # [-d | --delete]`; short form for --dry-run is `-n`, unrelated letter).
  # `--del`/`--delet`/... also match: git's own prefix matching accepts any
  # unambiguous abbreviation of a long option, and confirmed live that
  # `--delet` executes as `--delete` (no other push option starts with "de").
  # Matched only inside $PUSH_SEGMENT, never the raw $CMD — a same-day live
  # incident in this session
  # (bug-2026-09-04-destructive-guard-rm-rf-false-positive-cross-command.md)
  # showed whole-command matching false-triggers on unrelated flags in other
  # commands of the same compound Bash call. Known residual: variable
  # obfuscation (REF=":main"; git push origin $REF) is not caught — the hook
  # only sees literal command text, the same limit already documented for the
  # neighbouring secret hooks (Д6.3).
  if matches "$PUSH_SEGMENT" -E -- '(^|[[:space:]])(--de[a-zA-Z]*([[:space:]]|=|$)|-[a-zA-Z]*d[a-zA-Z]*([[:space:]]|$))'; then
    block "git push --delete запрещён — удаление удалённой ветки/тега необратимо. Согласуй с владельцем (CLAUDE.md §2)."
  fi
  if matches "$PUSH_SEGMENT" -E -- '(^|[[:space:]])\+?:[^[:space:]]+'; then
    block "git push с refspec-удалением (:<ref> или +:<ref>) запрещён — удаление удалённой ветки/тега необратимо. Согласуй с владельцем (CLAUDE.md §2)."
  fi

  # git push --mirror — same class again (found in peer review, WP-544 Ф8,
  # 04.09): syncs the remote to exactly the local ref set, silently deleting
  # any remote branch/tag that doesn't exist locally. Not named in the
  # original Д28 report but closed alongside it — same failure mode, cheap
  # to cover while already here. `--mi`/`--mir`/... also match — confirmed
  # live that `--mir` executes as `--mirror` (no other push option starts
  # with "mi").
  if matches "$PUSH_SEGMENT" -E -- '(^|[[:space:]])--mi[a-zA-Z]*([[:space:]]|=|$)'; then
    block "git push --mirror запрещён — синхронизирует remote с локальными ссылками, удаляя отсутствующие локально ветки/теги. Согласуй с владельцем (CLAUDE.md §2)."
  fi
fi

# A hard reset is safe only when it cannot discard tracked work or local history:
# the tree must be clean and the target must contain the current HEAD. This still
# blocks resets that rewind a branch or erase uncommitted changes, while allowing
# a no-loss fast-forward reset used to repair a stale mirror.
reset_is_non_destructive() {
  local segment="$1" repo="${CWD:-$PWD}" target="" hard=false
  set -- $segment
  [ "${1:-}" = "git" ] || return 1
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      -C) repo="${2:-}"; shift 2 ;;
      --git-dir|--work-tree|-c) shift 2 ;;
      --git-dir=*|--work-tree=*|-c*) shift ;;
      *) break ;;
    esac
  done
  [ "${1:-}" = "reset" ] || return 1
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --hard) hard=true ;;
      --) shift; [ $# -eq 1 ] || return 1; target="$1"; break ;;
      -*) ;;
      *) [ -z "$target" ] || return 1; target="$1" ;;
    esac
    shift
  done
  [ "$hard" = true ] && [ -n "$target" ] || return 1
  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  git -C "$repo" diff --quiet || return 1
  git -C "$repo" diff --cached --quiet || return 1
  git -C "$repo" merge-base --is-ancestor HEAD "$target" 2>/dev/null
}

# git reset --hard — one $RESET_SEGMENT line per chained `git reset` in the
# command (WP-544 Ф8, 04.09: git_segment now returns every match, not just
# the first — a compound `git reset --hard a && git reset --hard b` used to
# hide the second call from this same check). reset_is_non_destructive()
# parses token positions for exactly one invocation, so each line is checked
# on its own, not concatenated.
RESET_SEGMENT=$(git_segment reset)
if [ -n "$RESET_SEGMENT" ]; then
  # With a cd anywhere in the call, reset_is_non_destructive would inspect the wrong
  # repository (the hook's cwd, not the one the reset runs in), so the exception is off.
  RESET_CD=$(shell_invocations cd)
  while IFS= read -r one_reset; do
    [ -n "$one_reset" ] || continue
    if matches "$one_reset" -E -- '(^|[[:space:]])--hard([[:space:]]|$)' && { [ -n "$RESET_CD" ] || ! reset_is_non_destructive "$one_reset"; }; then
      block "git reset --hard запрещён (теряет незакоммиченное). Используй git stash."
    fi
  done <<< "$RESET_SEGMENT"
fi

# git_segment clean returns only calls with delete flags and no effective
# dry-run. Its parser knows that `-e` consumes the next argument, unlike a
# regex over the flattened command text.
CLEAN_SEGMENT=$(git_segment clean)
if [ -n "$CLEAN_SEGMENT" ]; then
  block "git clean с удалением запрещён (удаляет неотслеживаемые файлы). Согласуй с владельцем."
fi

# git add -A/--all/-u/--update/bare-dot (I7, WP-458: AR.216 жил только в rule-engine.sh
# check_git_staged_only(), которая никогда не диспатчилась ни на одно живое событие —
# реальная защита срабатывала только на commit (install-hooks.sh Check 8), уже после
# стейджа. Здесь — фактический PreToolUse барьер, до того как чужие файлы попадут в индекс.
# WP-544 Ф1 Д5, 21.08: перенесено из личной установки, где было с 17.07 — устраняет
# расхождение версий хука между личной установкой и этим шаблоном.)
ADD_SEGMENT=$(git_segment add)
if [ -n "$ADD_SEGMENT" ]; then
  if matches "$ADD_SEGMENT" -E -- '(^|[[:space:]])(-A|--all|-u|--update)([[:space:]]|$)'; then
    block "git add -A/--all/-u/--update запрещён — подхватывает файлы других агентов (CLAUDE.md §Git Staging). Стейдж конкретные пути: git add <path>."
  fi
  if matches "$ADD_SEGMENT" -E -- '(^|[[:space:]])\.([[:space:]]|$)'; then
    block "git add . запрещён — подхватывает файлы других агентов (CLAUDE.md §Git Staging). Стейдж конкретные пути: git add <path>."
  fi
fi

# git stash pop/apply возвращает содержимое чужой заначки целиком, без разбора по
# файлам — слепой pop/apply молча теряет уже закоммиченные/задеплоенные артефакты,
# если заначка содержит удаления (WP-547, 03.09: именно так был утерян файл уже
# применённой к проду миграции — агент увидел "deleted: ..." в списке файлов чужого
# автостэша вперемешку с легитимной работой и вернул всё разом). Non-pop/apply
# stash-подкоманды (show/list/drop/...) короткозамыкаются на "безопасно" — функция
# только решает судьбу pop/apply. При неопределённости (не распарсили, не смогли
# посмотреть содержимое) — тоже "небезопасно", как reset_is_non_destructive.
stash_pop_apply_is_safe() {
  local segment="$1" repo="${CWD:-$PWD}" ref=""
  set -- $segment
  [ "${1:-}" = "git" ] || return 1
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      -C) repo="${2:-}"; shift 2 ;;
      --git-dir|--work-tree|-c) shift 2 ;;
      --git-dir=*|--work-tree=*|-c*) shift ;;
      *) break ;;
    esac
  done
  [ "${1:-}" = "stash" ] || return 0
  shift
  case "${1:-}" in
    pop|apply) shift ;;
    *) return 0 ;;
  esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --index|--quiet|-q) shift ;;
      --) shift; [ $# -eq 1 ] || return 1; ref="$1"; break ;;
      -*) return 1 ;;
      *) [ -z "$ref" ] || return 1; ref="$1" ;;
    esac
    shift
  done
  [ -n "$ref" ] || ref="stash@{0}"
  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  local status
  status=$(git -C "$repo" stash show --name-status -- "$ref" 2>/dev/null) || return 1
  ! matches "$status" -E '^D[[:space:]]'
}

# Same one-line-per-invocation reasoning as the reset check above — each
# chained `git stash ...` gets its own token-position parse.
STASH_SEGMENT=$(git_segment stash)
if [ -n "$STASH_SEGMENT" ]; then
  while IFS= read -r one_stash; do
    [ -n "$one_stash" ] || continue
    if ! stash_pop_apply_is_safe "$one_stash"; then
      block "git stash pop/apply запрещён: заначка содержит удаления файлов (или их не удалось проверить). Слепой возврат может стереть уже закоммиченные/задеплоенные артефакты (прецедент WP-547, 03.09). Сначала 'git stash show --name-status <ref>' и разбери каждое удаление вручную; разовая необходимость — CC_ALLOW_DESTRUCTIVE_INPUT=1 из реального шелла пилота."
    fi
  done <<< "$STASH_SEGMENT"
fi

# rm с одновременным recursive (-r/-R/--recursive) и force (-f/--force), в любом сочетании
# флагов (слитных или раздельных), включая /bin/rm, /usr/bin/rm, \rm, find -exec rm, xargs rm,
# обёртки sudo/env/time и строки для sh -c/eval, распознаётся и блокируется (issue #940).
# Код через stdin оболочки и подстановки внутри кавычек или некавыченного heredoc
# остаются за границей текстового анализа; см. docs/DESTRUCTIVE-GUARD.md (#1002).
# Удалять — через .claude/bin/guarded-rm: он при выполнении, когда оболочка уже раскрыла
# переменные и шаблоны, вычисляет настоящий путь каждой цели и удаляет только внутри корней
# из .claude/config/guarded-rm-roots.txt.
#
# Прежнее исключение «/tmp/, /scratchpad/ или .claude/worktrees/ где угодно в тексте вызова»
# освобождало и удаление вне временных каталогов: `rm -rf /important; ls /tmp/` и
# `echo /tmp/ > /dev/null && rm -rf "$HOME/project/data"` проходили. Сузить исключение по
# тексту нельзя: цель удаления зависит от переменных, cd, ссылок и подстановок, известных
# только при выполнении, поэтому проверка перенесена с текста на выполнение.
#
# Ключи проверяются по исходным токенам: `--` в имени цели не является
# разделителем ключей. Короткие кластеры (-rf, -vrf) и сокращения GNU
# --recursive/--force признаются; --verbose/--preserve-root — нет.

# git rm с -r и -f: -f теряет незакоммиченные правки удаляемых файлов (`git rm -r --cached`
# без -f остаётся разрешённым).
GIT_RM_INVOCATIONS=$(git_segment rm)
if [ -n "$GIT_RM_INVOCATIONS" ]; then
  block "git rm с -r и -f запрещён — -f теряет незакоммиченные правки. Убери -f или согласуй с владельцем."
fi

RM_INVOCATIONS=$(shell_invocations rm)
if [ -n "$RM_INVOCATIONS" ]; then
  block "rm с -r и -f запрещён — удаление необратимо. Удаляй той же командой через $GUARDED_RM (те же ключи и цели): он при выполнении проверит настоящие пути и удалит только внутри временных каталогов из реестра $WORKSPACE_ROOT/.claude/config/guarded-rm-roots.txt. Разовая необходимость: CC_ALLOW_DESTRUCTIVE_INPUT=1 из реального шелла пилота."
fi

# SQL-клиенты: DROP/TRUNCATE — необратимая потеря структуры/данных.
if matches "$CMD_EXEC" -iE '\b(psql|mysql|sqlite3)\b' && matches "$CMD_EXEC" -iE '\b(DROP[[:space:]]+(TABLE|SCHEMA|DATABASE)|TRUNCATE)\b'; then
  block "DROP/TRUNCATE через SQL-клиент запрещён — необратимая потеря данных. Разовая необходимость: CC_ALLOW_DESTRUCTIVE_INPUT=1 из реального шелла пилота."
fi

# SQL-клиенты: DELETE FROM без WHERE в том же операторе (эвристика: сегмент до ближайшего
# ';' или конца строки — не защищает от WHERE в другом statement той же команды).
if matches "$CMD_EXEC" -iE '\b(psql|mysql|sqlite3)\b' \
  && matches "$CMD_EXEC" -iE 'DELETE[[:space:]]+FROM' \
  && ! matches "$CMD_EXEC" -iE 'DELETE[[:space:]]+FROM[^;]*[[:space:]]WHERE([[:space:]]|$)'; then
  block "DELETE FROM без WHERE через SQL-клиент запрещён — удалит всю таблицу. Разовая необходимость: CC_ALLOW_DESTRUCTIVE_INPUT=1 из реального шелла пилота."
fi

# удаление репозитория на GitHub — необратимо.
if matches "$CMD_EXEC" -E '\bgh[[:space:]]+repo[[:space:]]+delete\b'; then
  block "gh repo delete запрещён — необратимо. Разовая необходимость: CC_ALLOW_DESTRUCTIVE_INPUT=1 из реального шелла пилота."
fi

# gh repo deploy-key add с правом записи (-w/--allow-write) — расширяет ACL
# репозитория на внешнем сервисе без второго слоя проверки (WP-544, пир-сессия
# 2026-09-04-16-wp544-permission-type-auto-approve, Claude + Kimi). По умолчанию
# (без флага) ключ read-only — эта ветка не трогает `gh repo deploy-key add`
# без -w/--allow-write, тот случай остаётся обычным interactive-approve.
# Тот же residual, что у push --delete выше: whole-command grep, не
# git_segment-изолированный per-invocation — variable-obfuscation не ловит.
if matches "$CMD_EXEC" -E '\bgh[[:space:]]+repo[[:space:]]+deploy-key[[:space:]]+add\b' \
  && matches "$CMD_EXEC" -E -- '(^|[[:space:]"'"'"'])(-w|--allow-write)([[:space:]"'"'"'=]|$)'; then
  block "gh repo deploy-key add с -w/--allow-write запрещён — добавляет ключ с правом записи в репозиторий (необратимое расширение доступа). Разовая необходимость: CC_ALLOW_DESTRUCTIVE_INPUT=1 из реального шелла пилота."
fi

# iwe-commit-isolated.sh обязан быть единственной командой в Bash-вызове.
# Разрешающее правило в settings.json матчит по префиксу пути к этому скрипту
# с завершающим `:*` — без такого хвоста правило не переиспользуешь (разные
# WP, разные пути worktree на каждый вызов), но с ним оно так же охотно
# матчит и `&& что-угодно-ещё`, потому что permission-matcher — текстовый
# префикс, не парсер shell-грамматики (WP-544, пир-сессия
# 2026-09-04-16-wp544-permission-type-auto-approve, Claude + Kimi).
#
# Проверка повторяет условие, при котором это правило вообще срабатывает:
# вызов НАЧИНАЕТСЯ с пути к обёртке. Прежний вариант считал попаданием любое
# упоминание имени в тексте сегмента, поэтому `find ... -name
# iwe-commit-isolated.sh | head` блокировался как «обёртка плюс лишние
# команды» — имя в аргументе чужой команды не запускает обёртку и не матчит
# разрешающее правило (WP-545, 06.09: третий случай того же типа в этом
# файле, найден живьём этим же хуком).
ISOLATED_COMMIT_ANALYSIS=$(shell_segment_stats "iwe-commit-isolated\.sh")
ISOLATED_COMMIT_TOTAL_SEGMENTS=$(echo "$ISOLATED_COMMIT_ANALYSIS" | awk '{print $1}')
ISOLATED_COMMIT_WRAPPER_HITS=$(echo "$ISOLATED_COMMIT_ANALYSIS" | awk '{print $2}')
if [ "${ISOLATED_COMMIT_WRAPPER_HITS:-0}" -gt 0 ] && [ "${ISOLATED_COMMIT_TOTAL_SEGMENTS:-0}" -gt 1 ]; then
  block "iwe-commit-isolated.sh обязан быть единственной командой в вызове — обнаружены другие сегменты той же compound-команды (после ; & | или в скобках/backtick). Раздели на отдельные Bash-вызовы."
fi

exit 0
