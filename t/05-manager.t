#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Test::Fatal;

use lib 'lib';
use Path::Any qw(path);
use Path::Any::Adapter;
use Path::Any::Manager;
use Path::Any::Adapter::Local;
use Path::Any::Adapter::Null;

# ---------------------------------------------------------------------------
# Reset manager before each logical section
# ---------------------------------------------------------------------------

sub reset_manager { Path::Any::Manager->_reset }

# ---------------------------------------------------------------------------
# Default adapter (no configuration → Local)
# ---------------------------------------------------------------------------

{
    reset_manager();
    my $mgr = Path::Any::Manager->instance;
    my $adapter = $mgr->get_adapter('/some/path');
    isa_ok($adapter, 'Path::Any::Adapter::Local', 'default adapter is Local');
}

# ---------------------------------------------------------------------------
# set() / get_adapter() — global adapter
# ---------------------------------------------------------------------------

{
    reset_manager();
    Path::Any::Adapter->set('Null');
    my $adapter = Path::Any::Adapter->get('/any/path');
    isa_ok($adapter, 'Path::Any::Adapter::Null', 'set Null → get returns Null');
}

# ---------------------------------------------------------------------------
# Stack ordering: newest-first
# ---------------------------------------------------------------------------

{
    reset_manager();
    Path::Any::Adapter->set('Local');
    Path::Any::Adapter->set('Null');

    my $adapter = Path::Any::Adapter->get('/anything');
    isa_ok($adapter, 'Path::Any::Adapter::Null', 'newest adapter wins');
}

# ---------------------------------------------------------------------------
# remove()
# ---------------------------------------------------------------------------

{
    reset_manager();
    Path::Any::Adapter->set('Null');
    Path::Any::Adapter->set('Local');
    Path::Any::Adapter->remove('Local');

    my $adapter = Path::Any::Adapter->get('/any');
    isa_ok($adapter, 'Path::Any::Adapter::Null', 'remove() removes from stack');
}

# ---------------------------------------------------------------------------
# Prefix routing — SFTP-like adapter on a prefix
# ---------------------------------------------------------------------------

{
    reset_manager();

    # Register Null as a scoped adapter for /mnt/nas
    my $mgr = Path::Any::Manager->instance;
    $mgr->set( { prefix => '/mnt/nas' }, 'Null' );

    # Global fallback
    Path::Any::Adapter->set('Local');

    my $nas_adapter   = $mgr->get_adapter('/mnt/nas/some/file.txt');
    my $local_adapter = $mgr->get_adapter('/tmp/local_file.txt');

    isa_ok($nas_adapter,   'Path::Any::Adapter::Null',  'prefix /mnt/nas routes to Null');
    isa_ok($local_adapter, 'Path::Any::Adapter::Local', 'other paths route to Local');
}

# ---------------------------------------------------------------------------
# Prefix routing — exact match
# ---------------------------------------------------------------------------

{
    reset_manager();
    my $mgr = Path::Any::Manager->instance;
    $mgr->set( { prefix => '/exact' }, 'Null' );
    Path::Any::Adapter->set('Local');

    my $exact = $mgr->get_adapter('/exact');
    isa_ok($exact, 'Path::Any::Adapter::Null', 'exact prefix match works');
}

# ---------------------------------------------------------------------------
# Prefix routing — non-match should not be confused by partial strings
# ---------------------------------------------------------------------------

{
    reset_manager();
    my $mgr = Path::Any::Manager->instance;
    $mgr->set( { prefix => '/foo' }, 'Null' );
    Path::Any::Adapter->set('Local');

    # /foobar should NOT match /foo
    my $adapter = $mgr->get_adapter('/foobar/baz.txt');
    isa_ok($adapter, 'Path::Any::Adapter::Local', '/foobar does not match prefix /foo');
}

# ---------------------------------------------------------------------------
# Adapter cached in Path::Any object at construction time
# ---------------------------------------------------------------------------

{
    reset_manager();
    Path::Any::Adapter->set('Null');
    my $p = path('/some/path');

    isa_ok($p->adapter, 'Path::Any::Adapter::Null', 'adapter cached at construction');

    # Change global adapter after construction — cached adapter unchanged
    Path::Any::Adapter->set('Local');
    isa_ok($p->adapter, 'Path::Any::Adapter::Null', 'adapter not changed after construction');
}

# ---------------------------------------------------------------------------
# stack() introspection
# ---------------------------------------------------------------------------

{
    reset_manager();
    Path::Any::Adapter->set('Local');
    Path::Any::Adapter->set('Null');

    my @stack = Path::Any::Manager->instance->stack;
    is(scalar @stack, 2, 'stack has 2 entries');
    isa_ok($stack[0]->{adapter}, 'Path::Any::Adapter::Null',  'first entry is Null');
    isa_ok($stack[1]->{adapter}, 'Path::Any::Adapter::Local', 'second entry is Local');
}

# ---------------------------------------------------------------------------
# Fully-qualified class name in set()
# ---------------------------------------------------------------------------

{
    reset_manager();
    Path::Any::Adapter->set('Path::Any::Adapter::Null');
    my $adapter = Path::Any::Adapter->get('/x');
    isa_ok($adapter, 'Path::Any::Adapter::Null', 'fully-qualified class name works');
}

# ---------------------------------------------------------------------------
# set() with extra constructor options
# ---------------------------------------------------------------------------

{
    reset_manager();
    # set() with extra options (no-op for Null, but should not die)
    my $result = eval { Path::Any::Adapter->set('Null'); 1 };
    ok($result, 'set() with simple adapter name does not die');
    my $adapter = Path::Any::Adapter->get('/x');
    isa_ok($adapter, 'Path::Any::Adapter::Null', 'adapter registered correctly');
}

done_testing;
