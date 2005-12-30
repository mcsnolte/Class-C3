
package Class::C3;

use strict;
use warnings;

use Scalar::Util 'blessed';

our $VERSION = '0.09';

# this is our global stash of both 
# MRO's and method dispatch tables
# the structure basically looks like
# this:
#
#   $MRO{$class} = {
#      MRO => [ <class precendence list> ],
#      methods => {
#          orig => <original location of method>,
#          code => \&<ref to original method>
#      },
#      has_overload_fallback => (1 | 0)
#   }
#
our %MRO;

# use these for debugging ...
sub _dump_MRO_table { %MRO }
our $TURN_OFF_C3 = 0;

sub import {
    my $class = caller();
    # skip if the caller is main::
    # since that is clearly not relevant
    return if $class eq 'main';
    return if $TURN_OFF_C3;
    # make a note to calculate $class 
    # during INIT phase
    $MRO{$class} = undef unless exists $MRO{$class};
}

## initializers

# NOTE:
# this will not run under the following
# conditions:
#  - mod_perl
#  - require Class::C3;
#  - eval "use Class::C3"
# in all those cases, you need to call 
# the initialize() function manually
INIT { initialize() }

sub initialize {
    # why bother if we don't have anything ...
    return unless keys %MRO;
    _calculate_method_dispatch_tables();
    _apply_method_dispatch_tables();
    %next::METHOD_CACHE = ();
}

sub uninitialize {
    # why bother if we don't have anything ...
    return unless keys %MRO;    
    _remove_method_dispatch_tables();    
    %next::METHOD_CACHE = ();
}

sub reinitialize {
    uninitialize();
    # clean up the %MRO before we re-initialize
    $MRO{$_} = undef foreach keys %MRO;
    initialize();
}

## functions for applying C3 to classes

sub _calculate_method_dispatch_tables {
    foreach my $class (keys %MRO) {
        _calculate_method_dispatch_table($class);
    }
}

sub _calculate_method_dispatch_table {
    my $class = shift;
    no strict 'refs';
    my @MRO = calculateMRO($class);
    $MRO{$class} = { MRO => \@MRO };
    my $has_overload_fallback = 0;
    my %methods;
    # NOTE: 
    # we do @MRO[1 .. $#MRO] here because it
    # makes no sense to interogate the class
    # which you are calculating for. 
    foreach my $local (@MRO[1 .. $#MRO]) {
        # if overload has tagged this module to 
        # have use "fallback", then we want to
        # grab that value 
        $has_overload_fallback = ${"${local}::()"} 
            if defined ${"${local}::()"};
        foreach my $method (grep { defined &{"${local}::$_"} } keys %{"${local}::"}) {
            # skip if already overriden in local class
            next unless !defined *{"${class}::$method"}{CODE};
            $methods{$method} = {
                orig => "${local}::$method",
                code => \&{"${local}::$method"}
            } unless exists $methods{$method};
        }
    }    
    # now stash them in our %MRO table
    $MRO{$class}->{methods} = \%methods; 
    $MRO{$class}->{has_overload_fallback} = $has_overload_fallback;        
}

sub _apply_method_dispatch_tables {
    foreach my $class (keys %MRO) {
        _apply_method_dispatch_table($class);
    }     
}

sub _apply_method_dispatch_table {
    my $class = shift;
    no strict 'refs';
    ${"${class}::()"} = $MRO{$class}->{has_overload_fallback}
        if $MRO{$class}->{has_overload_fallback};
    foreach my $method (keys %{$MRO{$class}->{methods}}) {
        *{"${class}::$method"} = $MRO{$class}->{methods}->{$method}->{code};
    }    
}

sub _remove_method_dispatch_tables {
    foreach my $class (keys %MRO) {
        _remove_method_dispatch_table($class);
    }       
}

sub _remove_method_dispatch_table {
    my $class = shift;
    no strict 'refs';
    delete ${"${class}::"}{"()"} if $MRO{$class}->{has_overload_fallback};    
    foreach my $method (keys %{$MRO{$class}->{methods}}) {
        delete ${"${class}::"}{$method}
            if defined *{"${class}::${method}"}{CODE} && 
               (*{"${class}::${method}"}{CODE} eq $MRO{$class}->{methods}->{$method}->{code});       
    }   
}

## functions for calculating C3 MRO

# this function is a perl-port of the 
# python code on this page:
#   http://www.python.org/2.3/mro.html
sub _merge {                
    my (@seqs) = @_;
    my $class_being_merged = $seqs[0]->[0];
    my @res; 
    while (1) {
        # remove all empty seqences
        my @nonemptyseqs = (map { (@{$_} ? $_ : ()) } @seqs);
        # return the list if we have no more no-empty sequences
        return @res if not @nonemptyseqs; 
        my $reject;
        my $cand; # a canidate ..
        foreach my $seq (@nonemptyseqs) {
            $cand = $seq->[0]; # get the head of the list
            my $nothead;            
            foreach my $sub_seq (@nonemptyseqs) {
                # XXX - this is instead of the python "in"
                my %in_tail = (map { $_ => 1 } @{$sub_seq}[ 1 .. $#{$sub_seq} ]);
                # NOTE:
                # jump out as soon as we find one matching
                # there is no reason not too. However, if 
                # we find one, then just remove the '&& last'
                ++$nothead && last if exists $in_tail{$cand};      
            }
            last unless $nothead; # leave the loop with our canidate ...
            $reject = $cand;
            $cand = undef;        # otherwise, reject it ...
        }
        die "Inconsistent hierarchy found while merging '$class_being_merged':\n\t" .
            "current merge results [\n\t\t" . (join ",\n\t\t" => @res) . "\n\t]\n\t" .
            "mergeing failed on '$reject'\n" if not $cand;
        push @res => $cand;
        # now loop through our non-empties and pop 
        # off the head if it matches our canidate
        foreach my $seq (@nonemptyseqs) {
            shift @{$seq} if $seq->[0] eq $cand;
        }
    }
}

sub calculateMRO {
    my ($class) = @_;
    no strict 'refs';
    return _merge(
        [ $class ],                                        # the class we are linearizing
        (map { [ calculateMRO($_) ] } @{"${class}::ISA"}), # the MRO of all the superclasses
        [ @{"${class}::ISA"} ]                             # a list of all the superclasses    
    );
}

package  # hide me from PAUSE
    next; 

use strict;
use warnings;

use Scalar::Util 'blessed';

our $VERSION = '0.05';

our %METHOD_CACHE;

sub method {
    my $level = 1;
    my ($method_caller, $label, @label);
    while ($method_caller = (caller($level++))[3]) {
      @label = (split '::', $method_caller);
      $label = pop @label;
      last unless
        $label eq '(eval)' ||
        $label eq '__ANON__';
    }
    my $caller   = join '::' => @label;    
    my $self     = $_[0];
    my $class    = blessed($self) || $self;
    
    goto &{ $METHOD_CACHE{"$class|$caller|$label"} ||= do {

      my @MRO = Class::C3::calculateMRO($class);

      my $current;
      while ($current = shift @MRO) {
          last if $caller eq $current;
      }

      no strict 'refs';
      my $found;
      foreach my $class (@MRO) {
          next if (defined $Class::C3::MRO{$class} && 
                   defined $Class::C3::MRO{$class}{methods}{$label});          
          last if (defined ($found = *{$class . '::' . $label}{CODE}));
      }

      die "No next::method '$label' found for $self" unless $found;

      $found;
    } };
}

1;

__END__

=pod

=head1 NAME

Class::C3 - A pragma to use the C3 method resolution order algortihm

=head1 SYNOPSIS

    package A;
    use Class::C3;     
    sub hello { 'A::hello' }

    package B;
    use base 'A';
    use Class::C3;     

    package C;
    use base 'A';
    use Class::C3;     

    sub hello { 'C::hello' }

    package D;
    use base ('B', 'C');
    use Class::C3;    

    # Classic Diamond MI pattern
    #    <A>
    #   /   \
    # <B>   <C>
    #   \   /
    #    <D>

    package main;

    print join ', ' => Class::C3::calculateMRO('Diamond_D') # prints D, B, C, A

    print D->hello() # prints 'C::hello' instead of the standard p5 'A::hello'
    
    D->can('hello')->();          # can() also works correctly
    UNIVERSAL::can('D', 'hello'); # as does UNIVERSAL::can()

=head1 DESCRIPTION

This is currently an experimental pragma to change Perl 5's standard method resolution order 
from depth-first left-to-right (a.k.a - pre-order) to the more sophisticated C3 method resolution
order. 

=head2 What is C3?

C3 is the name of an algorithm which aims to provide a sane method resolution order under multiple
inheritence. It was first introduced in the langauge Dylan (see links in the L<SEE ALSO> section),
and then later adopted as the prefered MRO (Method Resolution Order) for the new-style classes in 
Python 2.3. Most recently it has been adopted as the 'canonical' MRO for Perl 6 classes, and the 
default MRO for Parrot objects as well.

=head2 How does C3 work.

C3 works by always preserving local precendence ordering. This essentially means that no class will 
appear before any of it's subclasses. Take the classic diamond inheritence pattern for instance:

     <A>
    /   \
  <B>   <C>
    \   /
     <D>

The standard Perl 5 MRO would be (D, B, A, C). The result being that B<A> appears before B<C>, even 
though B<C> is the subclass of B<A>. The C3 MRO algorithm however, produces the following MRO 
(D, B, C, A), which does not have this same issue.

This example is fairly trival, for more complex examples and a deeper explaination, see the links in
the L<SEE ALSO> section.

=head2 How does this module work?

This module uses a technique similar to Perl 5's method caching. During the INIT phase, this module 
calculates the MRO of all the classes which called C<use Class::C3>. It then gathers information from 
the symbol tables of each of those classes, and builds a set of method aliases for the correct 
dispatch ordering. Once all these C3-based method tables are created, it then adds the method aliases
into the local classes symbol table. 

The end result is actually classes with pre-cached method dispatch. However, this caching does not
do well if you start changing your C<@ISA> or messing with class symbol tables, so you should consider
your classes to be effectively closed. See the L<CAVEATS> section for more details.

=head1 OPTIONAL LOWERCASE PRAGMA

This release also includes an optional module B<c3> in the F<opt/> folder. I did not include this in 
the regular install since lowercase module names are considered I<"bad"> by some people. However I
think that code looks much nicer like this:

  package MyClass;
  use c3;
  
The the more clunky:

  package MyClass;
  use Class::C3;
  
But hey, it's your choice, thats why it is optional.

=head1 FUNCTIONS

=over 4

=item B<calculateMRO ($class)>

Given a C<$class> this will return an array of class names in the proper C3 method resolution order.

=item B<initialize>

This can be used to initalize the C3 method dispatch tables. You need to call this if you are running
under mod_perl, or in any other environment which does not run the INIT phase of the perl compiler.

NOTE: 
This can B<not> be used to re-load the dispatch tables for all classes. Use C<reinitialize> for that.

=item B<uninitialize>

Calling this function results in the removal of all cached methods, and the restoration of the old Perl 5
style dispatch order (depth-first, left-to-right). 

=item B<reinitialize>

This effectively calls C<uninitialize> followed by C<initialize> the result of which is a reloading of
B<all> the calculated C3 dispatch tables. 

It should be noted that if you have a large class library, this could potentially be a rather costly 
operation.

=back

=head1 METHOD REDISPATCHING

It is always useful to be able to re-dispatch your method call to the "next most applicable method". This 
module provides a pseudo package along the lines of C<SUPER::> or C<NEXT::> which will re-dispatch the 
method along the C3 linearization. This is best show with an examples.

  # a classic diamond MI pattern ...
     <A>
    /   \
  <B>   <C>
    \   /
     <D>
  
  package A;
  use c3; 
  sub foo { 'A::foo' }       
 
  package B;
  use base 'A'; 
  use c3;     
  sub foo { 'B::foo => ' . (shift)->next::method() }       
 
  package B;
  use base 'A'; 
  use c3;    
  sub foo { 'C::foo => ' . (shift)->next::method() }   
 
  package D;
  use base ('B', 'C'); 
  use c3; 
  sub foo { 'D::foo => ' . (shift)->next::method() }   
  
  print D->foo; # prints out "D::foo => B::foo => C::foo => A::foo"

A few things to note. First, we do not require you to add on the method name to the C<next::method> 
call (this is unlike C<NEXT::> and C<SUPER::> which do require that). This helps to enforce the rule 
that you cannot dispatch to a method of a different name (this is how C<NEXT::> behaves as well). 

The next thing to keep in mind is that you will need to pass all arguments to C<next::method> it can 
not automatically use the current C<@_>. 

=head1 CAVEATS

Let me first say, this is an experimental module, and so it should not be used for anything other 
then other experimentation for the time being. 

That said, it is the authors intention to make this into a completely usable and production stable 
module if possible. Time will tell.

And now, onto the caveats.

=over 4

=item Use of C<SUPER::>.

The idea of C<SUPER::> under multiple inheritence is ambigious, and generally not recomended anyway.
However, it's use in conjuntion with this module is very much not recommended, and in fact very 
discouraged. The recommended approach is to instead use the supplied C<next::method> feature, see
more details on it's usage above.

=item Changing C<@ISA>.

It is the author's opinion that changing C<@ISA> at runtime is pure insanity anyway. However, people
do it, so I must caveat. Any changes to the C<@ISA> will not be reflected in the MRO calculated by this
module, and therefor probably won't even show up. If you do this, you will need to call C<reinitialize> 
in order to recalulate B<all> method dispatch tables. See the C<reinitialize> documentation and an example
in F<t/20_reinitialize.t> for more information.

=item Adding/deleting methods from class symbol tables.

This module calculates the MRO for each requested class during the INIT phase by interogatting the symbol
tables of said classes. So any symbol table manipulation which takes place after our INIT phase is run will
not be reflected in the calculated MRO. Just as with changing the C<@ISA>, you will need to call 
C<reinitialize> for any changes you make to take effect.

=back

=head1 TODO

=over 4

=item More tests

You can never have enough tests :)

=back

=head1 CODE COVERAGE

I use B<Devel::Cover> to test the code coverage of my tests, below is the B<Devel::Cover> report on this 
module's test suite.

 ---------------------------- ------ ------ ------ ------ ------ ------ ------
 File                           stmt   bran   cond    sub    pod   time  total
 ---------------------------- ------ ------ ------ ------ ------ ------ ------
 Class/C3.pm                    98.6   90.9   73.3   96.0  100.0   96.8   95.3
 ---------------------------- ------ ------ ------ ------ ------ ------ ------
 Total                          98.6   90.9   73.3   96.0  100.0   96.8   95.3
 ---------------------------- ------ ------ ------ ------ ------ ------ ------

=head1 SEE ALSO

=head2 The original Dylan paper

=over 4

=item L<http://www.webcom.com/haahr/dylan/linearization-oopsla96.html>

=back

=head2 The prototype Perl 6 Object Model uses C3

=over 4

=item L<http://svn.openfoundry.org/pugs/perl5/Perl6-MetaModel/>

=back

=head2 Parrot now uses C3

=over 4

=item L<http://aspn.activestate.com/ASPN/Mail/Message/perl6-internals/2746631>

=item L<http://use.perl.org/~autrijus/journal/25768>

=back

=head2 Python 2.3 MRO related links

=over 4

=item L<http://www.python.org/2.3/mro.html>

=item L<http://www.python.org/2.2.2/descrintro.html#mro>

=back

=head2 C3 for TinyCLOS

=over 4

=item L<http://www.call-with-current-continuation.org/eggs/c3.html>

=back 

=head1 ACKNOWLEGEMENTS

=over 4

=item Thanks to Matt S. Trout for using this module in his module L<DBIx::Class> 
and finding many bugs and providing fixes.

=item Thanks to Justin Guenther for making C<next::method> more robust by handling 
calls inside C<eval> and anon-subs.

=back

=head1 AUTHOR

Stevan Little, E<lt>stevan@iinteractive.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2005 by Infinity Interactive, Inc.

L<http://www.iinteractive.com>

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself. 

=cut