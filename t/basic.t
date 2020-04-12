use v5.20.0;
use warnings;

use Term::Control;
use Test::More;
use Test::BinaryData;

my $tc = Term::Control->new(term => 'xterm');

isa_ok($tc, 'Term::Control', '$tc');

is_binary(
  $tc->_expand_capability('clear'),
  "\e[H\e[2J",
  "xterm clear is what we expect",
);

# pulled from infocmp on my macOS machine -- rjbs, 2020-04-11
my $xterm_setb =
  "\e[4%?%p1%{1}%=%t4%e%p1%{3}%=%t6%e%p1%{4}%=%t1%e%p1%{6}%=%t3%e%p1%d%;m";

# BROKEN DOWN:
#   \E[4      {literal}
#   %?        if
#     %p1       push param 1 onto stack
#     %{1}      push number 1 onto stack
#     %=        pop, pop, push equality of 2 values
#     %t        then
#       4         {literal}
#   %e        else if
#     %p1       push param 1 onto stack
#     %{3}      push number 3 onto stack
#     %=        pop, pop, push equality of 2 values
#     %t        then
#       6         {literal}
#   %e        else if
#     %p1
#     %{4}
#     %=
#     %t
#       1
#   %e        else if
#     %p1
#     %{6}
#     %=
#     %t
#       3
#   %e        else
#     %p1       push param 1 onto stack
#     %d        pop, format as double, emit
#   %;        end if
#   m         {literal}

is_binary(
  $tc->_terminfo->getstr('setb'),
  $xterm_setb,
  'setb is correct in terminfo',
);

{
  my @stack;
  my @out;
  $tc->_evaluate_expr($xterm_setb, [3], \@stack, \@out);

  is_binary(
    join(q{}, @out),
    "\e[46m",
    "let's set our xterm BG to 3",
  );
}

{
  my @stack;
  my @out;
  $tc->_evaluate_expr($xterm_setb, [7], \@stack, \@out);

  is_binary(
    join(q{}, @out),
    "\e[47m",
    "let's set our xterm BG to 7",
  );
}

done_testing;
