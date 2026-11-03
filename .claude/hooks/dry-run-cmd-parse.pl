#!/usr/bin/env perl
# dry-run-cmd-parse.pl — shell command reader for dry-run-gate.sh (issue #1434).
#
# The gate classifies a Bash command by text. Line-based sed normalisation
# cannot tell code from data: heredoc bodies and comments look like commands,
# and a quoted or path-invoked program hides from the first-word rules. This
# reader walks the raw command once, quote-aware, and serves two modes:
#
#   strip        stdout: the command with heredoc bodies and comments removed
#                (what the shell actually executes as commands)
#   run-by-path  stdout: "OK", or "BLOCK <program>" when a command runs a
#                program by its own path (./x, ../x, $DIR/x.sh) or a script
#                name through PATH (x.sh), after assignments, redirections,
#                keywords and wrappers with their options are skipped
#
# Input: the command on stdin. Exit code 0 means the answer is valid; any other
# exit or output is a parse failure, and the gate then fails closed.
# Whitelist (run-by-path only), from the environment: WL_ROOT (absolute
# scripts dir of the template), WL_IWE_SCRIPTS_OK, WL_RELATIVE_OK (1/0).
use strict;
use warnings;

my $mode = shift // '';
die "usage: dry-run-cmd-parse.pl strip|run-by-path\n" unless $mode eq 'strip' || $mode eq 'run-by-path';

local $/;
my $text = <STDIN>;
$text = '' unless defined $text;
my $n = length $text;

my (@cmds, @words, @drop, @heredocs, @stack, @qnl);
my ($word, $has, $quote, $suspicious) = ('', 0, undef, 0);

sub flush_word { push @words, $word if $has; $word = ''; $has = 0; }
# Each command keeps the character that ended it: case patterns end with ')'.
sub flush_cmd  { my ($term) = @_; flush_word(); push @cmds, [[@words], $term // ''] if @words; @words = (); }
# A substitution starts a command of its own. One in the command-word position
# runs whatever it prints: not readable by text, a documented boundary.
sub subst_start { flush_cmd('('); }
sub at { my ($i, $len) = @_; return substr($text, $i, $len // 1); }

# Scan ${...}: quote-aware brace matching. A command substitution inside makes
# the word unreadable by text, so it is marked suspicious (the gate blocks).
sub scan_param {
    my ($i) = @_;
    my ($depth, $q) = (0, undef);
    for (; $i < $n; $i++) {
        my $c = at($i);
        $word .= $c;
        if (defined $q) { $q = undef if $c eq $q; next; }
        if ($c eq "'" || $c eq '"') { $q = $c; next; }
        if ($c eq '`' || ($c eq '$' && at($i + 1) eq '(')) { $suspicious = 1; next; }
        if ($c eq '\\') { $word .= at(++$i); next; }
        $depth++ if $c eq '{';
        if ($c eq '}') { $depth--; return $i if $depth == 0; }
    }
    $suspicious = 1;    # unterminated
    return $n - 1;
}

# Scan $(( ... )) / (( ... )): arithmetic, where << is a shift, not a heredoc.
# For (( )) the closing pair must be adjacent: `$((./x) )` is a command
# substitution of a subshell for bash, so such a word is suspicious.
sub scan_arith {
    my ($i, $open, $close) = @_;
    ($open, $close) = ('(', ')') unless defined $open;
    my $depth = 0;
    for (; $i < $n; $i++) {
        my $c = at($i);
        $word .= $c;
        $depth++ if $c eq $open;
        if ($c eq $close) {
            $depth--;
            if ($depth == 0) {
                $suspicious = 1 if $open eq '(' && at($i - 1) ne ')';
                return $i;
            }
        }
    }
    $suspicious = 1;
    return $n - 1;
}

# Read a heredoc delimiter the way bash does: a word, quotes removed.
sub read_delim {
    my ($i) = @_;
    my ($delim, $q) = ('', undef);
    for (; $i < $n; $i++) {
        my $c = at($i);
        if (defined $q) { if ($c eq $q) { $q = undef } else { $delim .= $c } next; }
        # $'..' expands escapes in the delimiter; not worth emulating: suspicious.
        if ($c eq '$' && at($i + 1) eq "'") { $suspicious = 1; next; }
        if ($c eq '$' && at($i + 1) eq '"') { next; }
        if ($c eq "'" || $c eq '"') { $q = $c; next; }
        if ($c eq '\\') { $delim .= at(++$i); next; }
        last if $c =~ /[\s;&|()<>]/;
        $delim .= $c;
    }
    $suspicious = 1 if defined $q;
    return ($delim, $i - 1);
}

my %ansi = (a => "\a", b => "\b", e => "\e", E => "\e", f => "\f", n => "\n", r => "\r", t => "\t", v => "\x0b");

for (my $i = 0; $i < $n; $i++) {
    my $c = at($i);
    if (defined $quote) {
        if ($quote eq 'ansi') {
            if ($c eq "'") { undef $quote; next; }
            if ($c eq '\\' && $i + 1 < $n) {
                my $tail = substr($text, $i + 1, 4);
                if ($tail =~ /^x([0-9A-Fa-f]{1,2})/) { $word .= chr(hex $1); $i += 1 + length $1; }
                elsif ($tail =~ /^([0-7]{1,3})/) { $word .= chr(oct($1) & 255); $i += length $1; }
                elsif (exists $ansi{ at($i + 1) }) { $word .= $ansi{ at($i + 1) }; $i++; }
                else { $word .= at(++$i); }
                next;
            }
            $word .= $c; next;
        }
        if ($c eq $quote) { undef $quote; next; }
        push @qnl, $i if $c eq "\n";
        if ($quote eq '"') {
            if ($c eq '\\' && $i + 1 < $n && at($i + 1) =~ /[\$`"\\\n]/) { $word .= at(++$i); next; }
            if ($c eq '`' || ($c eq '$' && at($i + 1) eq '(')) {
                push @stack, $c eq '`' ? '`' : ')';
                undef $quote; subst_start(); $i++ if $c eq '$';
                next;
            }
        }
        $word .= $c; next;
    }
    if (@stack && $c eq $stack[-1]) { pop @stack; flush_cmd(')'); $quote = '"'; $has = 1; next; }
    if ($c eq '\\' && $i + 1 < $n) {
        my $next = at(++$i);
        next if $next eq "\n";          # line continuation
        $word .= $next; $has = 1; next;
    }
    # A comment starts only at a word boundary: after `)` or `}` bash keeps the
    # # in the word ($(echo a)#, }#), and dropping the rest would hide commands.
    if ($c eq '#' && !$has && ($i == 0 || at($i - 1) =~ /[\s;&|(]/)) {   # comment: up to the end of the line
        my $end = index($text, "\n", $i);
        $end = $n if $end < 0;
        push @drop, [$i, $end];
        $i = $end - 1; next;
    }
    if ($c eq "'" || $c eq '"') { $quote = $c; $has = 1; next; }
    if ($c eq '$' && at($i + 1) eq "'") { $quote = 'ansi'; $has = 1; $i++; next; }
    if ($c eq '$' && at($i + 1) eq '{') { $i = scan_param($i); $has = 1; next; }
    if ($c eq '$' && at($i, 3) eq '$((') { $i = scan_arith($i + 1); $has = 1; next; }
    if ($c eq '$' && at($i + 1) eq '[') { $i = scan_arith($i + 1, '[', ']'); $has = 1; next; }
    if (!$has && at($i, 2) eq '((') { $i = scan_arith($i); $has = 1; next; }
    if ($c eq '<' && at($i, 3) eq '<<<') { $word .= '<<<'; $has = 1; $i += 2; next; }
    if ($c eq '<' && at($i, 2) eq '<<') {
        flush_word();
        $i += 2;
        my $strip = 0;
        if (at($i) eq '-') { $strip = 1; $i++; }
        $i++ while $i < $n && at($i) =~ /[ \t]/;
        my ($delim, $last) = read_delim($i);
        $i = $last;
        push @heredocs, [$delim, $strip];
        next;
    }
    if ($c eq "\n") {
        flush_cmd("\n");
        while (@heredocs) {
            my ($delim, $strip) = @{ shift @heredocs };
            my $start = $i + 1;
            my $closed = 0;
            while ($i + 1 < $n) {
                my $end = index($text, "\n", $i + 1);
                $end = $n if $end < 0;
                my $line = substr($text, $i + 1, $end - $i - 1);
                $i = $end;
                $line =~ s/\r$//;
                $line =~ s/^\t+// if $strip;
                if ($line eq $delim) { $closed = 1; last; }
            }
            push @drop, [$start, $i];
            last unless $closed;
        }
        next;
    }
    if ($c eq '`' || ($c eq '$' && at($i + 1) eq '(')) { subst_start(); $i++ if $c eq '$'; next; }
    # & glued to a redirection (0<&-, 3>&1, &>file) belongs to the word.
    if ($c eq '&' && ($word =~ /[<>]$/ || at($i + 1) eq '>')) { $word .= $c; $has = 1; next; }
    if ($c eq ';' && at($i + 1) eq ';') { flush_cmd(';'); push @cmds, [['__CASE_NEXT__'], ';;']; $i++; next; }
    if ($c =~ /[;&|()]/) { flush_cmd($c); next; }
    if ($c eq '{' && !$has && ($i + 1 >= $n || at($i + 1) =~ /[\s;]/)) { flush_cmd(); next; }
    if ($c eq '}' && !$has) { flush_cmd(); next; }
    if ($c =~ /\s/) { flush_word(); next; }
    $word .= $c; $has = 1;
}
$suspicious = 1 if defined $quote || @stack;
flush_cmd();

if ($mode eq 'strip') {
    # Heredoc bodies and comments are dropped; a newline inside quotes becomes a
    # space, so line-based rules never see the middle of a quoted string as a
    # command line.
    my %skip;
    for my $r (@drop) { $skip{$_} = 1 for $r->[0] .. $r->[1] - 1; }
    my %space = map { $_ => 1 } @qnl;
    my $out = '';
    for my $i (0 .. $n - 1) {
        next if $skip{$i};
        $out .= $space{$i} ? ' ' : substr($text, $i, 1);
    }
    print $out;
    exit 0;
}

my %keyword = map { $_ => 1 } qw(if then elif else while until do ! coproc nohup setsid builtin);
my @helpers = qw(day-close-prepare.sh dry-run-complete.sh check-dirty-repos.sh);
my %wl;
if (defined $ENV{WL_ROOT} && length $ENV{WL_ROOT}) {
    $wl{"$ENV{WL_ROOT}/$_"} = 1 for @helpers;
}
if (($ENV{WL_IWE_SCRIPTS_OK} // '') eq '1') {
    for my $h (@helpers) { $wl{"\$IWE_SCRIPTS/$h"} = 1; $wl{"\${IWE_SCRIPTS}/$h"} = 1; }
}
if (($ENV{WL_RELATIVE_OK} // '') eq '1') {
    $wl{"scripts/$_"} = 1 for @helpers;
}

# Drop leading options of a wrapper. $takes: the short letters and long names
# that take an argument. A short cluster like -iu or -uu: the first letter that
# takes an argument ends the cluster; its value is the rest of the word or, if
# nothing is left, the next word.
sub skip_opts {
    my ($w, $short, $long) = @_;
    while (@$w && $w->[0] =~ /^-./) {
        my $o = shift @$w;
        return if $o eq '--';
        if ($o =~ /^--/) {
            shift @$w if $long && $o =~ /^--($long)$/;
            next;
        }
        my $letters = substr($o, 1);
        for my $k (0 .. length($letters) - 1) {
            next unless $short && index($short, substr($letters, $k, 1)) >= 0;
            shift @$w if $k == length($letters) - 1;
            last;
        }
    }
}

my $case_pattern = 0;
for my $entry (@cmds) {
    my ($cmd, $term) = @$entry;
    my @w = @$cmd;
    if ($w[0] eq '__CASE_NEXT__') { $case_pattern = 1; next; }
    if ($w[0] eq 'case') { $case_pattern = $term eq ')' ? 0 : 1; next; }
    if ($w[0] eq 'esac') { $case_pattern = 0; next; }
    if ($case_pattern) { $case_pattern = 0 if $term eq ')'; next; }
    while (@w) {
        my $base = $w[0];
        $base =~ s{.*/}{};
        if ($w[0] =~ /^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=/ || $keyword{$base} || $w[0] eq '--') { shift @w; next; }
        if ($w[0] =~ /^[0-9]*(<<<|<>|>>|>\||&>>|&>|>&|<&|<|>)(.*)$/) {    # redirection
            shift @w;
            shift @w if $2 eq '' && @w;
            next;
        }
        if ($base eq 'command') {
            shift @w;
            if (@w && $w[0] =~ /^-[pvV]*[vV]/) { @w = (); last; }    # command -v: a lookup, nothing runs
            skip_opts(\@w, '', '');
            next;
        }
        if ($base eq 'time')    { shift @w; skip_opts(\@w, '', ''); next; }
        if ($base eq 'exec')    { shift @w; skip_opts(\@w, 'a', ''); next; }
        if ($base eq 'env') {
            shift @w;
            if (grep { /^(-[^-]*S|--split-string)/ } @w) { print "BLOCK env -S\n"; exit 0; }
            skip_opts(\@w, 'uC', 'unset|chdir');
            next;
        }
        if ($base eq 'sudo')    { shift @w; skip_opts(\@w, 'ugCDhprtUT', 'user|group|chdir|prompt|role|type|other-user|host|command-timeout'); next; }
        if ($base eq 'nice')    { shift @w; skip_opts(\@w, 'n', 'adjustment'); next; }
        if ($base eq 'timeout') { shift @w; skip_opts(\@w, 'ks', 'kill-after|signal'); shift @w; next; }
        if ($base eq 'stdbuf' || $base eq 'ionice') { shift @w; skip_opts(\@w, 'ioecn', 'input|output|error|class|classdata'); next; }
        last;
    }
    next unless @w;
    my $prog = $w[0];
    next if $wl{$prog};
    my $script = qr/\.(sh|bash|zsh|ksh|py|pl|rb)\b/;
    if ($prog =~ m{(^|[^\w.])\.\.?/}) { print "BLOCK $prog\n"; exit 0; }
    # Through a variable or ~: "$IWE_SCRIPTS/x", ${X:-x.sh}, ~/bin/x.
    if ($prog =~ m{^[\$~]} && ($prog =~ m{/} || $prog =~ $script)) { print "BLOCK $prog\n"; exit 0; }
    next if $prog =~ /[*?\[]/;           # a glob, not a program name
    if ($prog =~ /\.(sh|bash|zsh|ksh|py|pl|rb)\s*$/) { print "BLOCK $prog\n"; exit 0; }
}
print $suspicious ? "BLOCK unparsable command\n" : "OK\n";
exit 0;
