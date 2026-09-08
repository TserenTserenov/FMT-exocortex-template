#!/usr/bin/env bash
# PreToolUse:Bash guard — blocks irreversible operations: git (staging, history,
# push/reset/clean), filesystem (rm -rf outside temp paths), prod DB (psql
# DROP/TRUNCATE/DELETE without WHERE), GitHub repo deletion. Exit 2 = block.
set -euo pipefail

block() {
  echo "BLOCKED: $1" >&2
  exit 2
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
if ! printf '%s' "$HOOK_INPUT" | timeout 5 jq -e \
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
# are removed (they are data being written, not commands being run), and a
# newline separates commands the same way `;` does.
CMD_EXEC=$(printf '%s' "$CMD" | perl -e '
  # Read via stdin, not $ENV{CMD_SCAN}: a command text passed through the
  # process environment is subject to the same execve ARG_MAX as argv (found
  # by cold review, WP-544 Д22, 08.09 — a ~1.1MB command crashed this call
  # with "Argument list too long" (exit 126) instead of reaching block() or
  # exit 0, bypassing every check below it). Stdin has no such limit.
  my $text = do { local $/; <STDIN> };
  my @lines = split(/\n/, $text, -1);
  my (@out, @pending);
  for my $line (@lines) {
    if (@pending) {
      my $body = $pending[0];
      my $probe = $line;
      $probe =~ s/^\t+// if $body->{indent};
      if ($probe eq $body->{delim}) { shift @pending; push @out, q{}; next; }
      push @out, $line if $body->{keep};
      next;
    }
    push @out, $line;
    # A body fed to something that EXECUTES it stays in the scanned text; a
    # body written to a file or fed to a non-shell interpreter is content.
    # Cold review 06.09 broke the first version of this test twice: it was
    # anchored to the start of a line and to a bare name, so `/bin/bash <<EOF`
    # and `ssh host bash <<EOF` slipped through, and `psql <<SQL ... DROP
    # TABLE ... SQL` - executable SQL by any measure - was dropped as data.
    # Matching a basename anywhere on the line covers all three; the cost of
    # a false keep is a stricter scan, the cost of a false drop is a bypass.
    my $keep = 0;
    for my $word (split(/\s+/, $line)) {
      $word =~ s/^.*\///;
      $keep = 1 if $word =~ /^(?:ba|z|k|da)?sh$|^ssh$|^psql$|^mysql$|^sqlite3$/;
    }
    while ($line =~ /<<(-?)\s*(?!<)(?:([\x27"])([A-Za-z_][A-Za-z0-9_]*)\2|([A-Za-z_][A-Za-z0-9_]*))/g) {
      push @pending, { indent => ($1 eq q{-}), delim => (defined $3 ? $3 : $4), keep => $keep };
    }
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

# Bypass: только из реального шелла пилота (тот же контракт, что secret-leak-block.sh —
# хук читает свой процессный env, не текст команды, агент не может выставить это сам себе).
# Строгое сравнение с "1" (не -n) — та же несогласованность в secret-leak-block.sh
# (там -n) допустима для существующего кода, но не стоит копировать её в новый
# (пир-ревью Codex, WP-544 Ф1, 20.08): -n пропустил бы CC_ALLOW_DESTRUCTIVE_INPUT=0 как bypass.
[ "${CC_ALLOW_DESTRUCTIVE_INPUT:-}" = "1" ] && exit 0

# #362: a top-level `cd` persists between Bash calls in Claude Code. Strip
# quoted spans before detecting command segments; `(cd ... && ...)` remains
# allowed because the opening parenthesis is not a top-level separator.
if printf '%s' "$CMD_EXEC" | perl -e '
  my $s = do { local $/; <STDIN> };
  $s =~ s/'"'"'[^'"'"']*'"'"'/ Q /g;
  $s =~ s/"(?:\\.|[^"\\])*"/ Q /g;
  exit($s =~ /(?:^|[;&|\n]\s*)cd\s+/ ? 0 : 1);
'; then
  block "верхнеуровневый cd запрещён: используй git -C <path>, абсолютный путь или (cd <path> && ...)."
fi

if [ -n "$CWD" ]; then
  CWD_PHYSICAL=$(cd "$CWD" 2>/dev/null && pwd -P || printf '%s' "$CWD")
  if [ "$CWD_PHYSICAL" != "$WORKSPACE_ROOT" ] && \
     echo "$CMD_EXEC" | grep -qE "(^|[[:space:]\"'])(\\.claude/|scripts/|memory/)"; then
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
        if ($char eq "\\" && $quote eq q{"} && $i + 1 < length($text)) {
          $word .= substr($text, ++$i, 1);
        } elsif ($char eq $quote) {
          undef $quote;
        } else {
          $word .= $char;
        }
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
    for (my $i = 0; $i < length($text); $i++) {
      my $char = substr($text, $i, 1);
      if (defined $quote) {
        $segment .= $char;
        if ($char eq "\\" && $quote eq q{"} && $i + 1 < length($text)) {
          $segment .= substr($text, ++$i, 1);
        } elsif ($char eq $quote) {
          undef $quote;
        }
      } elsif ($char eq q{"} || $char eq chr(39)) {
        $quote = $char;
        $segment .= $char;
      } elsif ($char eq q{&} && length($segment) && substr($segment, -1, 1) eq q{>}) {
        # `>&` fd-dup (`2>&1`, `>&2`) — part of the CURRENT command redirect,
        # not a separator (WP-544, 04.09: without this, a lone command ending
        # in `2>&1` was mis-split into two).
        $segment .= $char;
      } elsif ($char eq q{&} && $i + 1 < length($text) && substr($text, $i + 1, 1) eq q{>}) {
        $segment .= $char;
      } elsif ($char =~ /[;&|(){}\n]/ || $char eq q{`}) {
        # A newline ends a command exactly like `;` does. Without it, every
        # later line of a multi-line call was glued onto the first command
        # of the call — how a `source` dot two lines below a `git add <path>`
        # was read as `git add .` (WP-545).
        push @out, $segment;
        $segment = q{};
      } else {
        $segment .= $char;
      }
    }
    push @out, $segment;
    return @out;
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
      env     => qr/^(?:-u|--unset|-C|--chdir|-S|--split-string)$/,
      timeout => qr/^(?:-s|-k|--signal|--kill-after)$/,
      nice    => qr/^(?:-n|--adjustment)$/,
      ionice  => qr/^(?:-c|-n|-p|-P|-u)$/,
      stdbuf  => qr/^(?:-i|-o|-e|--input|--output|--error)$/,
      xargs   => qr/^(?:-n|-P|-I|-i|-L|-s|-E|-d|-a|--max-args|--max-procs|--replace|--max-lines|--max-chars|--eof|--delimiter|--arg-file)$/,
    );
    my (@tokens) = @_;
    my @indices;
    my $i = 0;
    while ($i < @tokens) {
      if ($tokens[$i] =~ /^[A-Za-z_][A-Za-z0-9_]*=/) { $i++; next; }
      my $name = $tokens[$i];
      $name =~ s/^.*\///;
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
    if ($tokens[$i] eq "find") {
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
  for my $segment (@found) {
    my @tokens = words($segment);
    next unless @tokens;
    for my $index (command_indices(@tokens)) {
      next unless $index <= $#tokens && $tokens[$index] eq $name;
      my $start = $index;
      if (length $subcmd) {
        my $i = $index + 1;
        while ($i < @tokens) {
          if ($tokens[$i] =~ /^-C$/ || $tokens[$i] =~ /^--(?:git-dir|work-tree)$/ || $tokens[$i] =~ /^-c$/) {
            $i += 2;
          } elsif ($tokens[$i] =~ /^--(?:git-dir|work-tree)=/ || $tokens[$i] =~ /^-c/) {
            $i++;
          } else {
            last;
          }
        }
        next unless $i < @tokens && $tokens[$i] eq $subcmd;
      }
      # Print and keep scanning — one call can chain several invocations of
      # the same command (`git push origin main && git push origin +:refs/x`),
      # and every check below reads all of them, one per line.
      print join(" ", @tokens[$start .. $#tokens]), "\n";
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
  if echo "$PUSH_FORCE_SCAN" | grep -qE -- '(^|[[:space:]])(--force([[:space:]]|=|$)|-[a-zA-Z]*f[a-zA-Z]*([[:space:]]|$))'; then
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
  if echo "$PUSH_SEGMENT" | grep -qE -- '(^|[[:space:]])(--de[a-zA-Z]*([[:space:]]|=|$)|-[a-zA-Z]*d[a-zA-Z]*([[:space:]]|$))'; then
    block "git push --delete запрещён — удаление удалённой ветки/тега необратимо. Согласуй с владельцем (CLAUDE.md §2)."
  fi
  if echo "$PUSH_SEGMENT" | grep -qE -- '(^|[[:space:]])\+?:[^[:space:]]+'; then
    block "git push с refspec-удалением (:<ref> или +:<ref>) запрещён — удаление удалённой ветки/тега необратимо. Согласуй с владельцем (CLAUDE.md §2)."
  fi

  # git push --mirror — same class again (found in peer review, WP-544 Ф8,
  # 04.09): syncs the remote to exactly the local ref set, silently deleting
  # any remote branch/tag that doesn't exist locally. Not named in the
  # original Д28 report but closed alongside it — same failure mode, cheap
  # to cover while already here. `--mi`/`--mir`/... also match — confirmed
  # live that `--mir` executes as `--mirror` (no other push option starts
  # with "mi").
  if echo "$PUSH_SEGMENT" | grep -qE -- '(^|[[:space:]])--mi[a-zA-Z]*([[:space:]]|=|$)'; then
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
  while IFS= read -r one_reset; do
    [ -n "$one_reset" ] || continue
    if echo "$one_reset" | grep -qE -- '(^|[[:space:]])--hard([[:space:]]|$)' && ! reset_is_non_destructive "$one_reset"; then
      block "git reset --hard запрещён (теряет незакоммиченное). Используй git stash."
    fi
  done <<< "$RESET_SEGMENT"
fi

# git clean with delete flags (-f/-d/-x)
CLEAN_SEGMENT=$(git_segment clean)
if [ -n "$CLEAN_SEGMENT" ] && echo "$CLEAN_SEGMENT" | grep -qE -- '(^|[[:space:]])-[a-zA-Z]*[dfx]'; then
  block "git clean -fdx запрещён (удаляет неотслеживаемые файлы). Согласуй с владельцем."
fi

# git add -A/--all/-u/--update/bare-dot (I7, WP-458: AR.216 жил только в rule-engine.sh
# check_git_staged_only(), которая никогда не диспатчилась ни на одно живое событие —
# реальная защита срабатывала только на commit (install-hooks.sh Check 8), уже после
# стейджа. Здесь — фактический PreToolUse барьер, до того как чужие файлы попадут в индекс.
# WP-544 Ф1 Д5, 21.08: перенесено из личной установки, где было с 17.07 — устраняет
# расхождение версий хука между личной установкой и этим шаблоном.)
ADD_SEGMENT=$(git_segment add)
if [ -n "$ADD_SEGMENT" ]; then
  if echo "$ADD_SEGMENT" | grep -qE -- '(^|[[:space:]])(-A|--all|-u|--update)([[:space:]]|$)'; then
    block "git add -A/--all/-u/--update запрещён — подхватывает файлы других агентов (CLAUDE.md §Git Staging). Стейдж конкретные пути: git add <path>."
  fi
  if echo "$ADD_SEGMENT" | grep -qE -- '(^|[[:space:]])\.([[:space:]]|$)'; then
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
  ! echo "$status" | grep -qE '^D[[:space:]]'
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

# rm с одновременным recursive (-r/-R/--recursive) и force (-f/--force) — но
# только когда оба флага принадлежат ОДНОМУ вызову rm. Три отдельных grep по
# всему тексту вызова давали ложный отказ на записи документа: `rm -f
# "$PROMPT_FILE"` (уборка временного файла) давал слово rm и флаг -f, а
# несвязанный `--add-dir` другой команды прочитывался как «рекурсивно»
# (живой случай 06.09, тот же класс, что зафиксирован 04.09 в
# bug-2026-09-04-destructive-guard-rm-rf-false-positive-cross-command.md).
#
# Исключение (временные пути) намеренно осталось широким — оно смотрит и на
# сам вызов, и на весь текст: сужение срабатывания убирает ложные ОТКАЗЫ,
# сужение исключения добавило бы новые (`S=/tmp/x; rm -rf "$S/y"` — путь
# виден только в присваивании выше).
RM_INVOCATIONS=$(shell_invocations rm)
if [ -n "$RM_INVOCATIONS" ]; then
  while IFS= read -r one_rm; do
    [ -n "$one_rm" ] || continue
    if ! echo "$one_rm" | grep -qE -- '(^|[[:space:]])(-[^[:space:]]*[rR][^[:space:]]*|--recursive)([[:space:]]|$)'; then
      continue
    fi
    if ! echo "$one_rm" | grep -qE -- '(^|[[:space:]])(-[^[:space:]]*f[^[:space:]]*|--force)([[:space:]]|$)'; then
      continue
    fi
    if echo "$one_rm" | grep -qE '(/tmp/|/scratchpad/|\.claude/worktrees/)'; then
      continue
    fi
    if echo "$CMD_EXEC" | grep -qE '(/tmp/|/scratchpad/|\.claude/worktrees/)'; then
      continue
    fi
    block "rm -r -f (в любом сочетании флагов) вне /tmp, scratchpad или worktree запрещён — удаление необратимо. Разовая необходимость: CC_ALLOW_DESTRUCTIVE_INPUT=1 из реального шелла пилота."
  done <<< "$RM_INVOCATIONS"
fi

# psql: DROP/TRUNCATE — необратимая потеря структуры/данных.
if echo "$CMD_EXEC" | grep -qiE '\bpsql\b' && echo "$CMD_EXEC" | grep -qiE '\b(DROP[[:space:]]+(TABLE|SCHEMA|DATABASE)|TRUNCATE)\b'; then
  block "DROP/TRUNCATE через psql запрещён — необратимая потеря данных. Разовая необходимость: CC_ALLOW_DESTRUCTIVE_INPUT=1 из реального шелла пилота."
fi

# psql: DELETE FROM без WHERE в том же операторе (эвристика: сегмент до ближайшего
# ';' или конца строки — не защищает от WHERE в другом statement той же команды).
if echo "$CMD_EXEC" | grep -qiE '\bpsql\b' \
  && echo "$CMD_EXEC" | grep -qiE 'DELETE[[:space:]]+FROM' \
  && ! echo "$CMD_EXEC" | grep -qiE 'DELETE[[:space:]]+FROM[^;]*[[:space:]]WHERE([[:space:]]|$)'; then
  block "DELETE FROM без WHERE через psql запрещён — удалит всю таблицу. Разовая необходимость: CC_ALLOW_DESTRUCTIVE_INPUT=1 из реального шелла пилота."
fi

# удаление репозитория на GitHub — необратимо.
if echo "$CMD_EXEC" | grep -qE '\bgh[[:space:]]+repo[[:space:]]+delete\b'; then
  block "gh repo delete запрещён — необратимо. Разовая необходимость: CC_ALLOW_DESTRUCTIVE_INPUT=1 из реального шелла пилота."
fi

# gh repo deploy-key add с правом записи (-w/--allow-write) — расширяет ACL
# репозитория на внешнем сервисе без второго слоя проверки (WP-544, пир-сессия
# 2026-09-04-16-wp544-permission-type-auto-approve, Claude + Kimi). По умолчанию
# (без флага) ключ read-only — эта ветка не трогает `gh repo deploy-key add`
# без -w/--allow-write, тот случай остаётся обычным interactive-approve.
# Тот же residual, что у push --delete выше: whole-command grep, не
# git_segment-изолированный per-invocation — variable-obfuscation не ловит.
if echo "$CMD_EXEC" | grep -qE '\bgh[[:space:]]+repo[[:space:]]+deploy-key[[:space:]]+add\b' \
  && echo "$CMD_EXEC" | grep -qE -- '(^|[[:space:]"'"'"'])(-w|--allow-write)([[:space:]"'"'"'=]|$)'; then
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
