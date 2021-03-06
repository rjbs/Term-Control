package Term::Control;

# ABSTRACT:

use 5.020;
use warnings;
use strict;

use Moo;
use experimental qw(signatures);

use Types::Standard qw(Str);
use Type::Utils qw(class_type);

use Term::Terminfo;

has term => (
  is      => 'lazy',
  isa     => Str,
  default => sub {
    $ENV{TERM} // 'vt100'
  },
);

has _terminfo => (
  is      => 'lazy',
  isa     => class_type('Term::Terminfo'),
  default => sub {
    Term::Terminfo->new(shift->term),
  },
);

my @methods = (
  [ clear_screen => 'clear' ],

  [ cursor_move  => 'cup', '$row', '$column' ],

  [ cursor_down  => 'cud1' ],
  [ cursor_up    => 'cuu1' ],
  [ cursor_left  => 'cub1' ],
  [ cursor_right => 'cuf1' ],

  [ cursor_home  => 'home' ],

  [ cursor_invisible => 'civis' ],
  [ cursor_visible   => 'cvvis' ],
  [ cursor_reset     => 'cnorm' ],
);

for my $pair (@methods) {
  my ($method, $cap, @args) = @$pair;
  my $sig = join ',', '$self', @args;
  eval
    "sub $method ($sig) {".
    "  print shift->_expand_capability(\$cap, \@_);".
    "}";
  if (my $err = $@) {
    die "couldn't generate method $method: $err";
  }
}

# something like the traditional curses "tparm" method, which takes a
# capability and args and returns a string for the target terminal. probably
# deficient for esoteric terminals, but maybe we can get away with it in the
# modern era where everything is an xterm anyway
sub _expand_capability ($self, $cap, @params) {
  my $in =
    $self->_terminfo->getstr($cap) //
    $self->_terminfo->getnum($cap) //
    $self->_terminfo->getflag($cap);

  my @out;
  my @stack;

  $self->_evaluate_expr($in, \@params, \@stack, \@out);

  return join '', @out;
}

sub _evaluate_expr ($self, $in, $params, $stack, $out, $t = undef) {
  while (length $in) {

    # take everything up to the first control sequence
    if ($in =~ s/^(?<take>[^%\$]+)//) {
      my ($take) = @+{qw(take)};
      push @$out, $take;
      next;
    }

    # delay sequence $<..>, ignoring
    if ($in =~ s/^\$\<[0-9]+\/?>//) {
      next;
    }

    # percent sequences

    # %%   outputs `%'
    if ($in =~ s/^%%//) {
      push @$out, '%';
      next;
    }

    # %[[:]flags][width[.precision]][doxXs]  as in printf
    if ($in =~ s/^(?<format>%:?[\-\+\# ]*(?:[0-9]+(?:\.[0-9]+)?)?[doxXs])//) {
      my ($format) = @+{qw(format)};
      push @$out, sprintf($format, pop @$stack);
      next;
    }

    # %c   print pop() like %c in printf
    # %s   print pop() like %s in printf
    if ($in =~ s/^%[sc]//) {
      die "need 1 item from stack\n" unless @$stack > 0;
      push @$out, pop @$stack;
      next;
    }

    # %p[1-9] push i'th parameter
    if ($in =~ s/^%p(?<i>[1-9])//) {
      my ($i) = @+{qw(i)};
      die "param $i requested for push, but only ".@$params." passed\n" if $i > @$params;
      my $param = $params->[$i-1];
      die "param $i is undefined, can't push\n" unless defined $param;
      push @$stack, $param;
      next;
    }


    # %P[a-z] set dynamic variable [a-z] to pop()
    # %g[a-z] get dynamic variable [a-z] and push it
    # %P[A-Z] set static variable [a-z] to pop()
    # %g[A-Z] get static variable [a-z] and push it

    # %'c' char constant c
    if ($in =~ s/^%'(?<char>.)'//) {
      my ($char) = @+{qw(char)};
      push @$stack, $char;
      next;
    }

    # %{nn} integer constant nn
    if ($in =~ s/^%\{(?<nn>[0-9]+)}//) {
      my ($nn) = @+{qw(nn)};
      push @$stack, $nn;
      next;
    }

    # %l   push strlen(pop)
    if ($in =~ s/^%l//) {
      push @$stack, length(pop @$stack);
      next;
    }

    # %+ %- %* %/ %m arithmetic (%m is mod): push(pop() op pop())
    # %& %| %^ bit operations (AND, OR and exclusive-OR): push(pop() op pop())
    # %= %> %< logical operations: push(pop() op pop())
    if ($in =~ s/^%(?<op>[+\-\*\/m\&\|\^=><])//) {
      my ($op) = @+{qw(op)};
      die "need 2 items from stack\n" unless @$stack > 0;
      my $y = pop @$stack;
      my $x = pop @$stack;
      push @$stack,
        $op eq '+' ? $x +  $y :
        $op eq '-' ? $x -  $y :
        $op eq '*' ? $x *  $y :
        $op eq '/' ? $x /  $y :
        $op eq 'm' ? $x %  $y :
        $op eq '&' ? $x &  $y :
        $op eq '|' ? $x |  $y :
        $op eq '^' ? $x ^  $y :
        $op eq '=' ? $x == $y :
        $op eq '>' ? $x >  $y :
        $op eq '<' ? $x <  $y :
          die "impossible binary op %op\n";
      next;
    }

    # %A, %O logical AND and OR operations (for conditionals)
    if ($in =~ s/^%(?<op>[AO])//) {
      my ($op) = @+{qw(op)};
      my $x = pop @$stack;
      my $y = pop @$stack;
      if ($op eq 'A') { push @$stack, ($x != 0 && $y != 0) ? 1 : 0 }
      if ($op eq 'O') { push @$stack, ($x != 0 || $y != 0) ? 1 : 0 }
      next;
    }

    # %! %~ unary operations (logical and bit complement): push(op pop())
    if ($in =~ s/^%(?<op>[\!\~])//) {
      my ($op) = @+{qw(op)};
      die "need 1 item from stack\n" unless @$stack > 0;
      my $v = pop @$stack;
      push @$stack,
        $op eq '!' ? !$v :
        $op eq '~' ? ~$v :
          die "impossible unary op $op\n";
      next;
    }

    # %i   add 1 to first two parameters (for ANSI terminals)
    if ($in =~ s/^%i//) {
      $params->[0]++ if exists $params->[0];
      $params->[1]++ if exists $params->[1];
      next;
    }

    if ($in =~ s/^%t//) {
      die "%t outside of %?...%;\n" unless $t;
      die "need 1 item from stack\n" unless @$stack > 0;
      my $bool = pop @$stack;
      return if $bool == 0;
      $$t = 1;
      next;
    }

    # %? expr %t thenpart %e elsepart %;
    if ($in =~ s/^%\?(?<if>.*?)(?<!%)%;//) {
      my ($if) = $+{if};
      my @subexpr = split /(?<!%)%e/, $if;

      SUBEXPR: for my $p (@subexpr) {
        my $t = 0;
        $self->_evaluate_expr($p, $params, $stack, $out, \$t);
        last SUBEXPR if $t;;
      }

      next;
    }

    die "unknown % sequence $in\n";
  }

}

1;
