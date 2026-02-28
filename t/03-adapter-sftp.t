#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Test::Fatal;

use lib 'lib';
use Path::Any::Manager;

# ---------------------------------------------------------------------------
# This test requires a running SFTP server.
# Set the following environment variables to run against a real server:
#
#   PATH_ANY_SFTP_HOST  — hostname (default: skip)
#   PATH_ANY_SFTP_USER  — username (default: current user)
#   PATH_ANY_SFTP_PORT  — port     (default: 22)
#   PATH_ANY_SFTP_DIR   — remote working directory for test files
#
# Without these variables the test is skipped.
# ---------------------------------------------------------------------------

my $host = $ENV{PATH_ANY_SFTP_HOST};
my $user = $ENV{PATH_ANY_SFTP_USER} // $ENV{USER} // 'test';
my $port = $ENV{PATH_ANY_SFTP_PORT} // 22;
my $rdir = $ENV{PATH_ANY_SFTP_DIR}  // '/tmp/path_any_sftp_test';

plan skip_all => 'Set PATH_ANY_SFTP_HOST to run SFTP tests'
    unless $host;

# Check that Net::SFTP::Foreign is available
eval { require Net::SFTP::Foreign };
plan skip_all => 'Net::SFTP::Foreign is not installed' if $@;

plan tests => 20;

use Path::Any qw(path);
use Path::Any::Adapter;

Path::Any::Manager->_reset;
Path::Any::Adapter->set('SFTP',
    host => $host,
    user => $user,
    port => $port,
);

sub rp { path("$rdir/$_[0]") }

# ---------------------------------------------------------------------------
# Setup: create remote working directory
# ---------------------------------------------------------------------------

{
    my $result = eval { path($rdir)->mkdir; 1 };
    ok($result, 'created remote working directory') or diag $@;
}

# ---------------------------------------------------------------------------
# Basic write / read
# ---------------------------------------------------------------------------

{
    my $f = rp('hello.txt');
    $f->spew("Hello, SFTP!\n");
    ok($f->exists,  'file exists after spew');
    ok($f->is_file, 'is_file after spew');

    my $content = $f->slurp;
    is($content, "Hello, SFTP!\n", 'slurp returns spewed content');
}

# ---------------------------------------------------------------------------
# lines
# ---------------------------------------------------------------------------

{
    my $f = rp('lines.txt');
    $f->spew("a\nb\nc\n");
    my @lines = $f->lines;
    is(scalar @lines, 3, 'lines returns correct count');
}

# ---------------------------------------------------------------------------
# append
# ---------------------------------------------------------------------------

{
    my $f = rp('append.txt');
    $f->spew("line1\n");
    $f->append("line2\n");
    is($f->slurp, "line1\nline2\n", 'append works');
}

# ---------------------------------------------------------------------------
# touch
# ---------------------------------------------------------------------------

{
    my $f = rp('touched.txt');
    $f->touch;
    ok($f->exists, 'touch creates file');
}

# ---------------------------------------------------------------------------
# copy / move
# ---------------------------------------------------------------------------

{
    my $src  = rp('copy_src.txt');
    my $dest = rp('copy_dest.txt');
    $src->spew("copy me\n");
    $src->copy($dest);
    ok($dest->exists, 'dest exists after copy');
    is($dest->slurp, "copy me\n", 'content matches after copy');
    ok($src->exists, 'src still exists after copy');
}

{
    my $ms = rp('mv_src.txt');
    my $md = rp('mv_dest.txt');
    $ms->spew("move\n");
    $ms->move($md);
    ok($md->exists,  'dest exists after move');
    ok(!$ms->exists, 'src gone after move');
}

# ---------------------------------------------------------------------------
# remove
# ---------------------------------------------------------------------------

{
    my $f = rp('to_del.txt');
    $f->spew("x");
    $f->remove;
    ok(!$f->exists, 'remove deletes file');
}

# ---------------------------------------------------------------------------
# mkdir / children / remove_tree
# ---------------------------------------------------------------------------

{
    my $d = rp('subdir');
    $d->mkdir;
    ok($d->is_dir, 'mkdir creates directory');

    rp('subdir/a.txt')->spew('a');
    rp('subdir/b.txt')->spew('b');

    my @kids = $d->children;
    is(scalar @kids, 2, 'children returns 2 items');

    $d->remove_tree;
    ok(!$d->exists, 'remove_tree removes directory');
}

# ---------------------------------------------------------------------------
# iterator
# ---------------------------------------------------------------------------

{
    my $d = rp('iter_dir');
    $d->mkdir;
    rp('iter_dir/x.txt')->spew('x');
    rp('iter_dir/y.txt')->spew('y');

    my $iter = $d->iterator;
    my @found;
    while ( defined( my $item = $iter->() ) ) {
        push @found, "$item";
    }
    is(scalar @found, 2, 'iterator yields items');
    rp('iter_dir')->remove_tree;
}

# ---------------------------------------------------------------------------
# Connection pooling: acquire/release cycle
# ---------------------------------------------------------------------------

{
    my $adapter = path($rdir)->adapter;
    my $pool = $adapter->_pool;
    ok(defined $pool, 'connection pool is created');

    # Do two operations and check pool is reusing connections
    rp('pool_a.txt')->spew('a');
    rp('pool_b.txt')->spew('b');
    # We can only check idle count is within pool_size
    ok($pool->idle_count <= $pool->{pool_size}, 'idle count within pool_size');
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

eval { path($rdir)->remove_tree };
pass('cleanup remote dir');
