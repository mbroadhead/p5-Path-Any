#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Test::Fatal;
use File::Temp qw(tempdir);
use File::Spec;

use lib 'lib';
use Path::Any qw(path);
use Path::Any::Adapter;
use Path::Any::Adapter::Local;
use Path::Any::Adapter::Null;
use Path::Any::Adapter::MultiPlex;
use Path::Any::Manager;
use Path::Any::Error;

my $dir = tempdir( CLEANUP => 1 );

# ---------------------------------------------------------------------------
# SpyAdapter: records all method calls without touching the filesystem
# ---------------------------------------------------------------------------

{
    package SpyAdapter;
    use parent -norequire, 'Path::Any::Adapter::Base';

    sub new {
        my ($class) = @_;
        return bless { calls => [] }, $class;
    }

    sub calls { $_[0]->{calls} }
    sub reset_calls { $_[0]->{calls} = [] }

    # Record each call and return a success value
    for my $m (qw(stat lstat size exists is_file is_dir
                  slurp lines spew append openr openw opena openrw filehandle
                  copy move remove touch chmod realpath digest
                  mkdir remove_tree children iterator)) {
        no strict 'refs';
        *{"SpyAdapter::$m"} = sub {
            my ($self, @args) = @_;
            push @{ $self->{calls} }, $m;
            # Return sensible defaults
            return 1 if $m =~ /^(spew|append|touch|mkdir|remove|remove_tree|copy|move|chmod)$/;
            return '' if $m eq 'slurp';
            return wantarray ? () : [] if $m =~ /^(lines|children)$/;
            return sub { undef } if $m eq 'iterator';
            return undef;
        };
    }
}

sub in_dir { path( File::Spec->catfile($dir, @_) ) }

# ---------------------------------------------------------------------------
# Reads come from primary only
# ---------------------------------------------------------------------------

{
    my $primary = Path::Any::Adapter::Local->new;
    my $spy     = SpyAdapter->new;
    my $mx = Path::Any::Adapter::MultiPlex->new(
        primary     => $primary,
        secondaries => [$spy],
    );

    my $f = in_dir('read_test.txt');
    $f->spew("primary content\n");

    my $content = $mx->slurp($f);
    is($content, "primary content\n", 'slurp reads from primary');
    is(scalar(grep { $_ eq 'slurp' } @{ $spy->calls }), 0,
        'secondary NOT called for slurp');

    $f->remove;
}

# ---------------------------------------------------------------------------
# Writes fan out to both primary and secondary
# ---------------------------------------------------------------------------

{
    my $primary = Path::Any::Adapter::Local->new;
    my $spy     = SpyAdapter->new;
    my $mx = Path::Any::Adapter::MultiPlex->new(
        primary     => $primary,
        secondaries => [$spy],
    );

    my $f = in_dir('write_test.txt');
    $mx->spew($f, "fanout content\n");

    ok($f->exists, 'primary has file after multiplex spew');
    is($f->slurp, "fanout content\n", 'primary content correct');
    is(scalar(grep { $_ eq 'spew' } @{ $spy->calls }), 1,
        'secondary spew called once');

    $f->remove;
}

# ---------------------------------------------------------------------------
# append fans out
# ---------------------------------------------------------------------------

{
    my $primary = Path::Any::Adapter::Local->new;
    my $spy     = SpyAdapter->new;
    my $mx = Path::Any::Adapter::MultiPlex->new(
        primary     => $primary,
        secondaries => [$spy],
    );

    my $f = in_dir('append_test.txt');
    $mx->spew($f, "line1\n");
    $spy->reset_calls;
    $mx->append($f, "line2\n");

    is($f->slurp, "line1\nline2\n", 'primary append correct');
    is(scalar(grep { $_ eq 'append' } @{ $spy->calls }), 1,
        'secondary append called');

    $f->remove;
}

# ---------------------------------------------------------------------------
# touch fans out
# ---------------------------------------------------------------------------

{
    my $primary = Path::Any::Adapter::Local->new;
    my $spy     = SpyAdapter->new;
    my $mx = Path::Any::Adapter::MultiPlex->new(
        primary     => $primary,
        secondaries => [$spy],
    );

    my $f = in_dir('touch_test.txt');
    $mx->touch($f);
    ok($f->exists, 'primary touched');
    is(scalar(grep { $_ eq 'touch' } @{ $spy->calls }), 1,
        'secondary touch called');

    $f->remove;
}

# ---------------------------------------------------------------------------
# remove fans out
# ---------------------------------------------------------------------------

{
    my $primary = Path::Any::Adapter::Local->new;
    my $spy     = SpyAdapter->new;
    my $mx = Path::Any::Adapter::MultiPlex->new(
        primary     => $primary,
        secondaries => [$spy],
    );

    my $f = in_dir('del_test.txt');
    $f->spew("x");
    $mx->remove($f);
    ok(!$f->exists, 'primary file removed');
    is(scalar(grep { $_ eq 'remove' } @{ $spy->calls }), 1,
        'secondary remove called');
}

# ---------------------------------------------------------------------------
# on_error => 'warn': secondary failure is warned, not croaked
# ---------------------------------------------------------------------------

{
    package FailAdapter;
    use parent -norequire, 'Path::Any::Adapter::Base';
    sub spew   { die "spew failed intentionally\n" }
    sub append { die "append failed\n" }
    # All other required methods inherit the croak stub from Base —
    # but MultiPlex only calls spew/append for write fan-out in this test.
    for my $m (qw(stat lstat size exists is_file is_dir
                  lines openr openw opena openrw filehandle
                  copy move remove touch chmod realpath digest
                  mkdir remove_tree children iterator)) {
        no strict 'refs';
        *{"FailAdapter::$m"} = sub { return undef };
    }
}

{
    package main;
    my $primary   = Path::Any::Adapter::Local->new;
    my $secondary = FailAdapter->new;

    my $mx = Path::Any::Adapter::MultiPlex->new(
        primary     => $primary,
        secondaries => [$secondary],
        on_error    => 'warn',
    );

    my $f = in_dir('warn_test.txt');
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };

    my $result = eval { $mx->spew($f, "x\n"); 1 };
    ok($result, 'spew succeeds with warn on_error');
    ok(scalar @warnings > 0, 'warning emitted for secondary failure');
    like($warnings[0], qr/secondary.*spew failed/i, 'warning mentions secondary and error');

    $f->remove if $f->exists;
}

# ---------------------------------------------------------------------------
# on_error => 'croak': secondary failure throws
# ---------------------------------------------------------------------------

{
    my $primary   = Path::Any::Adapter::Local->new;
    my $secondary = FailAdapter->new;

    my $mx = Path::Any::Adapter::MultiPlex->new(
        primary     => $primary,
        secondaries => [$secondary],
        on_error    => 'croak',
    );

    my $f = in_dir('croak_test.txt');
    my $err = exception { $mx->spew($f, "x\n") };
    ok(defined $err, 'croak on_error throws on secondary failure');
    isa_ok($err, 'Path::Any::Error') if ref $err;

    $f->remove if $f->exists;
}

# ---------------------------------------------------------------------------
# on_error => 'ignore': secondary failure is silently swallowed
# ---------------------------------------------------------------------------

{
    my $primary   = Path::Any::Adapter::Local->new;
    my $secondary = FailAdapter->new;

    my $mx = Path::Any::Adapter::MultiPlex->new(
        primary     => $primary,
        secondaries => [$secondary],
        on_error    => 'ignore',
    );

    my $f = in_dir('ignore_test.txt');
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };

    my $result = eval { $mx->spew($f, "x\n"); 1 };
    ok($result, 'spew succeeds with ignore on_error');
    is(scalar @warnings, 0, 'no warning emitted with ignore on_error');

    $f->remove if $f->exists;
}

# ---------------------------------------------------------------------------
# mkdir fans out
# ---------------------------------------------------------------------------

{
    my $primary = Path::Any::Adapter::Local->new;
    my $spy     = SpyAdapter->new;

    my $mx = Path::Any::Adapter::MultiPlex->new(
        primary     => $primary,
        secondaries => [$spy],
    );

    my $d = in_dir('mkd_test');
    $mx->mkdir($d);
    ok($d->is_dir, 'primary dir created');
    is(scalar(grep { $_ eq 'mkdir' } @{ $spy->calls }), 1,
        'secondary mkdir called');

    $d->remove_tree;
}

# ---------------------------------------------------------------------------
# adapter_name
# ---------------------------------------------------------------------------

{
    my $mx = Path::Any::Adapter::MultiPlex->new(
        primary     => Path::Any::Adapter::Local->new,
        secondaries => [],
    );
    is($mx->adapter_name, 'MultiPlex', 'adapter_name is MultiPlex');
}

done_testing;
