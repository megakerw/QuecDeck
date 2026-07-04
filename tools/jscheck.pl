#!/usr/bin/perl
# Structural checker for the project's vanilla JS: bracket balance aware of
# strings, template literals (with nested ${}), comments, and regex literals.
# Not a parser; catches unbalanced brackets and unterminated strings, which
# are the realistic hand-edit failures. Dev tool, not deployed (no node on
# the dev machine, so this is the only host-side JS check available).
use strict; use warnings;

my $exit = 0;
for my $path (@ARGV) {
    my $err = check($path);
    if ($err) { print "$path:$err\n"; $exit = 1; }
    else      { print "$path: OK\n"; }
}
exit $exit;

sub check {
    my ($path) = @_;
    open my $fh, '<', $path or return " cannot open";
    local $/; my $src = <$fh>; close $fh;
    my @stack; my $i = 0; my $n = length $src; my $line = 1; my $prev = '';
    my %pairs = (')' => '(', ']' => '[', '}' => '{');
    while ($i < $n) {
        my $c = substr($src, $i, 1);
        if ($c eq "\n") { $line++; $i++; next; }
        my $two = substr($src, $i, 2);
        if ($two eq '//' && !(@stack && $stack[-1] eq '`')) {
            my $j = index($src, "\n", $i); $i = $j < 0 ? $n : $j; next;
        }
        if ($two eq '/*' && !(@stack && $stack[-1] eq '`')) {
            my $j = index($src, '*/', $i + 2);
            return "$line: unterminated block comment" if $j < 0;
            $line += (substr($src, $i, $j - $i) =~ tr/\n//);
            $i = $j + 2; next;
        }
        if (@stack && $stack[-1] eq '`') {
            if ($c eq '\\') { $i += 2; next; }
            if ($c eq '`') { pop @stack; $i++; next; }
            if ($two eq '${') { push @stack, '{'; $i += 2; next; }
            $line++ if $c eq "\n";
            $i++; next;
        }
        if ($c eq '"' || $c eq "'") {
            my $j = $i + 1;
            while ($j < $n) {
                my $d = substr($src, $j, 1);
                if ($d eq '\\') { $j += 2; next; }
                last if $d eq $c;
                return "$line: unterminated string" if $d eq "\n";
                $j++;
            }
            return "$line: unterminated string" if $j >= $n;
            $i = $j + 1; $prev = '"'; next;
        }
        if ($c eq '`') { push @stack, '`'; $i++; $prev = '`'; next; }
        if ($c eq '/' && ($prev eq '' || $prev =~ /[=(,\[!&|?:;{}\n]/)) {
            # Heuristic regex scan. If no closing / before the newline, this
            # was division after all (e.g. the / that ENDS /x{2}/, where prev
            # is '}'); consume one char and continue instead of erroring.
            my $j = $i + 1; my $in_class = 0; my $found = 0;
            while ($j < $n) {
                my $d = substr($src, $j, 1);
                if ($d eq '\\') { $j += 2; next; }
                $in_class = 1 if $d eq '[';
                $in_class = 0 if $d eq ']';
                if ($d eq '/' && !$in_class) { $found = 1; last; }
                last if $d eq "\n";
                $j++;
            }
            if ($found) {
                $i = $j + 1;
                $i++ while $i < $n && substr($src, $i, 1) =~ /[a-z]/i;
                $prev = '/'; next;
            }
            $i++; $prev = '/'; next;
        }
        if ($c =~ /[(\[{]/) { push @stack, $c; }
        elsif ($c =~ /[)\]}]/) {
            return "$line: unmatched $c" if !@stack;
            my $top = pop @stack;
            return "$line: $c closes $top" if $top eq '`' || $top ne $pairs{$c};
        }
        $prev = $c if $c !~ /\s/;
        $i++;
    }
    return " EOF with open: @stack" if @stack;
    return "";
}
