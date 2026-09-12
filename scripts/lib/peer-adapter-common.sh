# shellcheck shell=bash
# peer-adapter-common.sh — shared preamble helpers for <vendor>-peer-adapter.sh
# (DP.SC.154, §0в.1 contract). Sourced, not executed: declares functions only,
# no side effects on source. Deliberately does not set its own `set -e/-u/-o
# pipefail` — callers differ (claude-peer-adapter.sh runs -euo pipefail,
# kimi-peer-adapter.sh runs -uo pipefail without -e) and a sourced file must
# not change the caller's shell options.
# see peer-session 2026-08-16-01-wp524-preamble-dedup (WP-524, consensus with
# Codex) — extracted from claude-peer-adapter.sh + kimi-peer-adapter.sh, which
# had carried these blocks byte-identical since the 15.08 sandbox-network fix.

# peer_adapter_check_sandbox_network <cli-label> <exit-code>
# Codex's Linux sandbox disables network for non-escalated commands; the
# vendor CLI then dies on its API call with little to no diagnostic output
# (WP-524, verified live 15.08 on codex-cli 0.147). Fail fast with an
# actionable message instead of leaking that opaque failure downstream.
# <exit-code> is the caller's, not this helper's: claude-peer-adapter.sh
# passes 69, kimi-peer-adapter.sh passes 1 — unifying that divergence is a
# separate decision, not bundled into this refactor (Codex review, WP-524).
peer_adapter_check_sandbox_network() {
  local cli_label="$1" exit_code="${2:?peer_adapter_check_sandbox_network: exit code required}"
  if [ "${CODEX_SANDBOX_NETWORK_DISABLED:-}" = "1" ]; then
    echo "ERROR: network is disabled in this sandbox (CODEX_SANDBOX_NETWORK_DISABLED=1) — the $cli_label cannot reach its API. Re-run through the approved escalated route." >&2
    exit "$exit_code"
  fi
}

# run_with_deadline <seconds> [--pgid-file <path> --lineage-nonce <hex>]
#                   [--exec-gate-file <path>]
#                   [--pre-exec-barrier <path>]
#                   [--pre-setsid-barrier <path>] <cmd> [args...]
# Runs cmd in its own process group and kills the whole group (TERM then
# KILL) on timeout, so a supervised CLI can't leave an orphaned child behind
# a plain `timeout` (WP-516: the previous `perl alarm; exec` signalled only
# the launcher, not a forked CLI child). `--pgid-file` publishes the group id
# after setsid and before exec so an external lifetime/lock helper can stop the
# group even after SIGKILL of the top adapter. The barrier options are
# deterministic test seams for the fork/setsid/exec hand-off boundaries.
run_with_deadline() {
  local deadline_seconds="$1"
  shift
  perl -MPOSIX=setsid,WNOHANG -MFcntl=O_RDONLY,O_WRONLY,O_CREAT,O_EXCL -MIO::Handle -e '
    use strict;
    use warnings;
    use Errno qw(EPERM ESRCH);
    use Time::HiRes qw(time);

    my $seconds = shift @ARGV;
    my ($pgid_file, $lineage_nonce, $exec_gate_file, $pre_exec_barrier, $pre_setsid_barrier);
    while (@ARGV >= 2) {
      if ($ARGV[0] eq "--pgid-file") {
        shift @ARGV;
        $pgid_file = shift @ARGV;
        next;
      }
      if ($ARGV[0] eq "--lineage-nonce") {
        shift @ARGV;
        $lineage_nonce = shift @ARGV;
        next;
      }
      if ($ARGV[0] eq "--exec-gate-file") {
        shift @ARGV;
        $exec_gate_file = shift @ARGV;
        next;
      }
      if ($ARGV[0] eq "--pre-exec-barrier") {
        shift @ARGV;
        $pre_exec_barrier = shift @ARGV;
        next;
      }
      if ($ARGV[0] eq "--pre-setsid-barrier") {
        shift @ARGV;
        $pre_setsid_barrier = shift @ARGV;
        next;
      }
      last;
    }
    die "ERROR: peer CLI command is empty\n" unless @ARGV;
    my $child = fork();
    die "ERROR: cannot fork peer CLI supervisor: $!\n" unless defined $child;
    if ($child == 0) {
      if (defined $pre_setsid_barrier) {
        sysopen(my $ready_out, "$pre_setsid_barrier.ready", O_WRONLY | O_CREAT | O_EXCL, 0600)
          or die "ERROR: cannot publish pre-setsid barrier: $!\n";
        print {$ready_out} "$$\n";
        close $ready_out;
        select undef, undef, undef, 0.01 until -e "$pre_setsid_barrier.release";
      }
      setsid() or die "ERROR: cannot isolate peer CLI process group: $!\n";
      if (defined $pgid_file) {
        die "ERROR: lineage nonce required with pgid file\n"
          unless defined $lineage_nonce && $lineage_nonce =~ /\A[0-9a-f]{32}\z/;
        die "ERROR: setsid did not establish pid=pgid\n" unless getpgrp() == $$;
        my $pgid_tmp = "$pgid_file.$$.tmp";
        sysopen(my $pgid_out, $pgid_tmp, O_WRONLY | O_CREAT | O_EXCL, 0600)
          or die "ERROR: cannot publish peer CLI process group: $!\n";
        print {$pgid_out} "{\"nonce\":\"$lineage_nonce\",\"pid\":$$,\"pgid\":$$}\n";
        $pgid_out->sync or die "ERROR: cannot sync peer CLI process-group marker: $!\n";
        close $pgid_out or die "ERROR: cannot close peer CLI process-group marker: $!\n";
        rename $pgid_tmp, $pgid_file
          or die "ERROR: cannot publish peer CLI process-group marker atomically: $!\n";
      }
      if (defined $exec_gate_file) {
        die "ERROR: lineage nonce required with exec gate\n"
          unless defined $lineage_nonce && $lineage_nonce =~ /\A[0-9a-f]{32}\z/;
        my $expected_gate = "$lineage_nonce $$\n";
        my $gate_deadline = time + 10;
        while (1) {
          if (sysopen(my $gate_in, $exec_gate_file, O_RDONLY)) {
            local $/;
            my $gate = <$gate_in>;
            close $gate_in;
            die "ERROR: invalid peer CLI exec gate\n"
              unless defined $gate && $gate eq $expected_gate;
            last;
          }
          die "ERROR: peer CLI exec gate timed out\n" if time >= $gate_deadline;
          select undef, undef, undef, 0.01;
        }
      }
      if (defined $pre_exec_barrier) {
        sysopen(my $ready_out, "$pre_exec_barrier.ready", O_WRONLY | O_CREAT | O_EXCL, 0600)
          or die "ERROR: cannot publish pre-exec barrier: $!\n";
        print {$ready_out} "$$\n";
        close $ready_out;
        select undef, undef, undef, 0.01 until -e "$pre_exec_barrier.release";
      }
      exec @ARGV or die "ERROR: cannot exec peer CLI: $!\n";
    }

    sub child_group_alive {
      local $! = 0;
      return 1 if kill 0, -$child;
      return 1 if $! == EPERM;
      return 0 if $! == ESRCH;
      return 1; # unknown kernel result is not proof that the group is gone
    }

    sub stop_child_group {
      my $reaped = 0;
      kill "TERM", -$child if child_group_alive();
      for (1 .. 20) {
        if (!$reaped) {
          my $done = waitpid($child, WNOHANG);
          $reaped = 1 if $done == $child;
        }
        if (!child_group_alive()) {
          waitpid($child, 0) unless $reaped;
          return;
        }
        select undef, undef, undef, 0.1;
      }
      # A TERM-resistant grandchild keeps the original group observable even
      # after its leader exits. Re-check immediately before KILL so a vanished
      # group is never signalled later after that numeric PGID is reused.
      kill "KILL", -$child if child_group_alive();
      waitpid($child, 0) unless $reaped;
    }

    my $deadline = time + $seconds;
    my $status;
    while (1) {
      my $done = waitpid($child, WNOHANG);
      if ($done == $child) {
        $status = $?;
        last;
      }
      if (time >= $deadline) {
        stop_child_group();
        exit 142;
      }
      select undef, undef, undef, 0.05;
    }
    exit 128 + ($status & 127) if $status & 127;
    exit $status >> 8;
  ' "$deadline_seconds" "$@"
}

# peer_adapter_check_frontmatter <output-text>
# §0в.1: a peer reply's stdout must open with a `---` frontmatter fence on
# its first non-empty line and close with a second `---`; violation is a
# format error, not "no answer". Callers gate the call itself on
# IWE_PEER_PLAIN (service calls like review/verify/synth aren't peer replies
# and opt out at the call site) — this helper only checks, it never reads
# that env var, so a caller can't accidentally skip the check through it.
# Argument is passed by value (Codex review: nameref was considered and
# rejected — no measured cost on adapter-sized replies, and by-value avoids
# nameref's bash-version and `set -u` footguns in a file every adapter sources).
peer_adapter_check_frontmatter() {
  local output="${1-}"
  local first_line fm_fences
  # awk in one process: a `sed | head` pipeline hit SIGPIPE under `pipefail`
  # on a long valid reply and killed the adapter without diagnostics
  # (review-02, WP-516 Ф5) — kept from the original inline check.
  first_line=$(printf '%s\n' "$output" | awk 'length { print; exit }')
  fm_fences=$(printf '%s\n' "$output" | grep -c '^---$' || true)
  if [ "$first_line" != "---" ] || [ "${fm_fences:-0}" -lt 2 ]; then
    echo "ERROR: peer response missing frontmatter (first non-empty line must be '---' with a closing '---')." >&2
    exit 1
  fi
}

# peer_adapter_check_language <output-text>
# WP-484 Ф89/Ф92: alert-only self-check — доля кириллицы в ответе после
# вычитания кода/путей/A2-глосс. Никогда не блокирует вывод, только
# предупреждает в stderr (не видна peer-реплике, IWE_PEER_PLAIN=1 её не
# печатает). Уже жила инлайн-копией в codex-/hermes-peer-adapter.sh
# (Ф89, 11.08) — здесь единственное определение для новых вызывающих
# (kimi/claude), чтобы не плодить третью копию (P2). language-check.py
# лежит рядом с этим файлом (scripts/lib/), путь резолвится через
# BASH_SOURCE этого файла — не зависит от cwd вызывающего адаптера.
peer_adapter_check_language() {
  local output="${1-}"
  local lib_dir lang_check python_resolver resolved_python lang_result
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  lang_check="$lib_dir/language-check.py"
  python_resolver="$lib_dir/find-python3.sh"
  if [ -f "$lang_check" ] && [ -x "$python_resolver" ]; then
    resolved_python=$("$python_resolver" --stdlib-only 2>/dev/null || true)
  else
    resolved_python=""
  fi
  if [ -n "$resolved_python" ]; then
    lang_result=$(printf '%s' "$output" | "$resolved_python" "$lang_check" 2>/dev/null || true)
    if printf '%s' "$lang_result" | grep -q '"alert": true'; then
      echo "WARNING: peer response may not be in Russian (language-check alert) — $lang_result" >&2
    fi
  fi
}
