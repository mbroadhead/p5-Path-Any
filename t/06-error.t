#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Test::Fatal;

use lib 'lib';
use Path::Any::Error;

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

{
    my $e = Path::Any::Error->new(
        op      => 'slurp',
        file    => '/foo/bar.txt',
        err     => 'No such file or directory',
        adapter => 'Local',
    );

    isa_ok($e, 'Path::Any::Error', 'new() creates a Path::Any::Error');
    is($e->op,      'slurp',                    'op accessor');
    is($e->file,    '/foo/bar.txt',             'file accessor');
    is($e->err,     'No such file or directory','err accessor');
    is($e->adapter, 'Local',                    'adapter accessor');
}

# ---------------------------------------------------------------------------
# Defaults for missing fields
# ---------------------------------------------------------------------------

{
    my $e = Path::Any::Error->new;
    is($e->op,      '(unknown)', 'op defaults to (unknown)');
    is($e->file,    '(unknown)', 'file defaults to (unknown)');
    is($e->err,     '(unknown)', 'err defaults to (unknown)');
    is($e->adapter, '(unknown)', 'adapter defaults to (unknown)');
}

# ---------------------------------------------------------------------------
# Stringification overload
# ---------------------------------------------------------------------------

{
    my $e = Path::Any::Error->new(
        op      => 'spew',
        file    => '/tmp/out.txt',
        err     => 'Permission denied',
        adapter => 'Local',
    );

    my $str = "$e";
    like($str, qr/Path::Any::Error/, 'stringification contains class name');
    like($str, qr/spew/,             'stringification contains op');
    like($str, qr{/tmp/out\.txt},    'stringification contains file');
    like($str, qr/Permission denied/,'stringification contains err');
    like($str, qr/Local/,            'stringification contains adapter');
}

# ---------------------------------------------------------------------------
# throw() dies with the object
# ---------------------------------------------------------------------------

{
    my $err = exception {
        Path::Any::Error->throw(
            op      => 'mkdir',
            file    => '/nope',
            err     => 'Read-only filesystem',
            adapter => 'Local',
        );
    };

    ok(defined $err, 'throw() causes die');
    isa_ok($err, 'Path::Any::Error', 'thrown value is a Path::Any::Error');
    is($err->op,   'mkdir',               'thrown error op correct');
    is($err->file, '/nope',               'thrown error file correct');
    is($err->err,  'Read-only filesystem','thrown error err correct');
}

# ---------------------------------------------------------------------------
# Can be caught by ref check
# ---------------------------------------------------------------------------

{
    my $caught;
    eval {
        Path::Any::Error->throw(op => 'test', file => '/x', err => 'oops', adapter => 'Null');
    };
    if ( my $e = $@ ) {
        $caught = $e if ref($e) && $e->isa('Path::Any::Error');
    }
    ok(defined $caught, 'exception caught via isa check');
    is($caught->op, 'test', 'caught exception has correct op');
}

# ---------------------------------------------------------------------------
# Use in string context in eval block
# ---------------------------------------------------------------------------

{
    eval {
        Path::Any::Error->throw(
            op => 'lines', file => '/a', err => 'EIO', adapter => 'SFTP'
        );
    };
    like($@, qr/EIO/, 'error stringifies in eval $@');
    like($@, qr/SFTP/, 'error contains adapter name in $@');
}

done_testing;
