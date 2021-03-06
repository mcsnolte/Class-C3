use strict;
use warnings;

use Test::More;

BEGIN {
    eval "use NEXT";
    plan skip_all => "NEXT required for this test" if $@;
    plan tests => 4;
}

{
    package Foo;
    use strict;
    use warnings;
    use Class::C3;

    sub foo { 'Foo::foo' }

    package Fuz;
    use strict;
    use warnings;
    use Class::C3;
    BEGIN { our @ISA = ('Foo'); }

    sub foo { 'Fuz::foo => ' . (shift)->next::method }

    package Bar;
    use strict;
    use warnings;
    use Class::C3;
    BEGIN { our @ISA = ('Foo'); }

    sub foo { 'Bar::foo => ' . (shift)->next::method }

    package Baz;
    use strict;
    use warnings;
    require NEXT; # load this as late as possible so we can catch the test skip

    BEGIN { our @ISA = ('Bar', 'Fuz'); }

    sub foo { 'Baz::foo => ' . (shift)->NEXT::foo }
}

Class::C3::initialize();

is(Foo->foo, 'Foo::foo', '... got the right value from Foo->foo');
is(Fuz->foo, 'Fuz::foo => Foo::foo', '... got the right value from Fuz->foo');
is(Bar->foo, 'Bar::foo => Foo::foo', '... got the right value from Bar->foo');

is(Baz->foo, 'Baz::foo => Bar::foo => Fuz::foo => Foo::foo', '... got the right value using NEXT in a subclass of a C3 class');

