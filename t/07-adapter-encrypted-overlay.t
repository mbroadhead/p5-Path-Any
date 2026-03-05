#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Test::Fatal;
use File::Temp qw(tempdir);
use File::Spec;

use lib 'lib';
use Path::Any qw(path);
use Path::Any::Adapter::Local;
use Path::Any::Adapter::EncryptedOverlay;

# ---------------------------------------------------------------------------
# Skip everything if gpg is not available
# ---------------------------------------------------------------------------

my $gpg_bin;
for my $candidate (qw(gpg2 gpg)) {
    for my $dir ( split /:/, ( $ENV{PATH} // '' ) ) {
        my $p = "$dir/$candidate";
        if ( -x $p ) { $gpg_bin = $p; last }
    }
    last if $gpg_bin;
}

plan skip_all => 'gpg / gpg2 not found in PATH' unless $gpg_bin;

# ---------------------------------------------------------------------------
# Shared test infrastructure
# ---------------------------------------------------------------------------

my $dir   = tempdir( CLEANUP => 1 );
my $local = Path::Any::Adapter::Local->new;

my $PASS = 'test-passphrase-12345';

sub make_adapter {
    return Path::Any::Adapter::EncryptedOverlay->new(
        inner      => $local,
        passphrase => $PASS,
        gpg_bin    => $gpg_bin,
    );
}

sub td { path( File::Spec->catfile( $dir, @_ ) ) }

# ---------------------------------------------------------------------------
# Constructor validation
# ---------------------------------------------------------------------------

{
    my $err = exception {
        Path::Any::Adapter::EncryptedOverlay->new(
            inner => $local,
            # missing recipient/passphrase
        );
    };
    ok( defined $err, 'constructor croaks without recipient or passphrase' );
    like( "$err", qr/recipient.*passphrase/i, 'error mentions recipient/passphrase' );
}

{
    my $err = exception {
        Path::Any::Adapter::EncryptedOverlay->new(
            passphrase => $PASS,
            # missing inner
        );
    };
    ok( defined $err, 'constructor croaks without inner adapter' );
    like( "$err", qr/inner/i, 'error mentions inner' );
}

# ---------------------------------------------------------------------------
# Adapter introspection
# ---------------------------------------------------------------------------

{
    my $enc = make_adapter();
    is( $enc->adapter_name,         'EncryptedOverlay', 'adapter_name' );
    is( $enc->can_atomic_write,     0,                  'can_atomic_write is 0' );
    is( $enc->can_symlink,          0,                  'can_symlink is 0' );
    is( $enc->supports_chmod,       1,                  'supports_chmod delegates to inner' );
    is( $enc->has_real_directories, 1,                  'has_real_directories delegates to inner' );
}

# ---------------------------------------------------------------------------
# spew / slurp roundtrip
# ---------------------------------------------------------------------------

{
    my $enc = make_adapter();
    my $f   = td('plain.gpg');

    $enc->spew( $f, "hello encrypted world\n" );

    ok( $f->exists, 'file exists after encrypted spew' );

    # Raw content must NOT be the plaintext
    my $raw = $f->slurp_raw;
    unlike( $raw, qr/hello/, 'raw stored content is not plaintext' );

    my $decrypted = $enc->slurp($f);
    is( $decrypted, "hello encrypted world\n", 'slurp round-trips plaintext' );

    $f->remove;
}

# ---------------------------------------------------------------------------
# Binary data roundtrip
# ---------------------------------------------------------------------------

{
    my $enc   = make_adapter();
    my $f     = td('binary.gpg');
    my $bytes = join '', map { chr($_) } 0 .. 255;

    $enc->spew( $f, $bytes );
    my $back = $enc->slurp($f);
    is( $back, $bytes, 'binary data round-trips correctly' );

    $f->remove;
}

# ---------------------------------------------------------------------------
# lines
# ---------------------------------------------------------------------------

{
    my $enc = make_adapter();
    my $f   = td('lines.gpg');

    $enc->spew( $f, "alpha\nbeta\ngamma\n" );

    my @lines = $enc->lines($f);
    is( scalar @lines, 3,        'lines() returns 3 lines' );
    is( $lines[0],     "alpha\n", 'first line correct' );

    my $aref = $enc->lines($f);
    is( ref($aref), 'ARRAY', 'lines() in scalar context returns arrayref' );

    $f->remove;
}

# ---------------------------------------------------------------------------
# append
# ---------------------------------------------------------------------------

{
    my $enc = make_adapter();
    my $f   = td('append.gpg');

    $enc->spew( $f, "line1\n" );
    $enc->append( $f, "line2\n" );
    $enc->append( $f, "line3\n" );

    my $content = $enc->slurp($f);
    is( $content, "line1\nline2\nline3\n", 'append accumulates correctly' );

    $f->remove;
}

# ---------------------------------------------------------------------------
# openr filehandle
# ---------------------------------------------------------------------------

{
    my $enc = make_adapter();
    my $f   = td('openr.gpg');

    $enc->spew( $f, "read me\n" );
    my $fh = $enc->openr($f);
    ok( defined $fh, 'openr returns a filehandle' );

    my $line = <$fh>;
    is( $line, "read me\n", 'read from openr handle returns plaintext' );
    close $fh;

    $f->remove;
}

# ---------------------------------------------------------------------------
# openw filehandle
# ---------------------------------------------------------------------------

{
    my $enc = make_adapter();
    my $f   = td('openw.gpg');

    my $fh = $enc->openw($f);
    ok( defined $fh, 'openw returns a filehandle' );
    print $fh "written via handle\n";
    close $fh;

    my $content = $enc->slurp($f);
    is( $content, "written via handle\n", 'openw handle encrypted on close' );

    $f->remove;
}

# ---------------------------------------------------------------------------
# opena filehandle
# ---------------------------------------------------------------------------

{
    my $enc = make_adapter();
    my $f   = td('opena.gpg');

    $enc->spew( $f, "first\n" );

    my $fh = $enc->opena($f);
    print $fh "second\n";
    close $fh;

    is( $enc->slurp($f), "first\nsecond\n", 'opena appends via handle' );

    $f->remove;
}

# ---------------------------------------------------------------------------
# openrw is not supported
# ---------------------------------------------------------------------------

{
    my $enc = make_adapter();
    my $err = exception { $enc->openrw( td('rw.gpg') ) };
    ok( defined $err, 'openrw throws' );
    like( "$err", qr/openrw/i, 'error message mentions openrw' );
}

# ---------------------------------------------------------------------------
# filehandle() routing
# ---------------------------------------------------------------------------

{
    my $enc = make_adapter();
    my $f   = td('fh_route.gpg');

    # Write via filehandle('>')
    my $wfh = $enc->filehandle( $f, '>' );
    print $wfh "routed write\n";
    close $wfh;

    # Read via filehandle('<')
    my $rfh = $enc->filehandle( $f, '<' );
    my $line = <$rfh>;
    is( $line, "routed write\n", 'filehandle < reads decrypted' );
    close $rfh;

    # Append via filehandle('>>')
    my $afh = $enc->filehandle( $f, '>>' );
    print $afh "appended\n";
    close $afh;

    is( $enc->slurp($f), "routed write\nappended\n", 'filehandle >> appends' );

    $f->remove;
}

# ---------------------------------------------------------------------------
# copy / move
# ---------------------------------------------------------------------------

{
    my $enc = make_adapter();
    my $src  = td('copy_src.gpg');
    my $dest = td('copy_dest.gpg');

    $enc->spew( $src, "copy content\n" );
    $enc->copy( $src, $dest );

    ok( $dest->exists, 'dest exists after copy' );
    is( $enc->slurp($dest), "copy content\n", 'copied content decrypts correctly' );
    ok( $src->exists, 'src still exists after copy' );

    $src->remove;
    $dest->remove;
}

{
    my $enc = make_adapter();
    my $src  = td('move_src.gpg');
    my $dest = td('move_dest.gpg');

    $enc->spew( $src, "move content\n" );
    $enc->move( $src, $dest );

    ok( $dest->exists,  'dest exists after move' );
    ok( !$src->exists,  'src gone after move' );
    is( $enc->slurp($dest), "move content\n", 'moved content decrypts correctly' );

    $dest->remove;
}

# ---------------------------------------------------------------------------
# digest operates on plaintext
# ---------------------------------------------------------------------------

SKIP: {
    eval { require Digest::MD5 };
    skip 'Digest::MD5 not available', 3 if $@;

    my $enc = make_adapter();
    my $f   = td('digest.gpg');

    $enc->spew( $f, "hello" );
    my $d1 = $enc->digest( $f, 'MD5' );

    # Re-encrypt same content (different ciphertext due to random session key)
    $enc->spew( $f, "hello" );
    my $d2 = $enc->digest( $f, 'MD5' );

    like( $d1, qr/^[0-9a-f]{32}$/, 'digest returns hex MD5' );
    is( $d1, $d2, 'digest is stable across re-encryptions of same content' );

    # Different content => different digest
    $enc->spew( $f, "world" );
    my $d3 = $enc->digest( $f, 'MD5' );
    isnt( $d1, $d3, 'digest changes when content changes' );

    $f->remove;
}

# ---------------------------------------------------------------------------
# Pass-through: exists / is_file / is_dir / touch / remove
# ---------------------------------------------------------------------------

{
    my $enc = make_adapter();
    my $f   = td('passthru.gpg');

    ok( !$enc->exists($f),  'exists false before creation' );
    $enc->spew( $f, "x" );
    ok( $enc->exists($f),   'exists true after spew' );
    ok( $enc->is_file($f),  'is_file true for file' );
    ok( !$enc->is_dir($f),  'is_dir false for file' );

    $enc->remove($f);
    ok( !$enc->exists($f),  'exists false after remove' );
}

{
    my $enc = make_adapter();
    my $d   = td('enc_subdir');

    $enc->mkdir($d);
    ok( $enc->is_dir($d), 'mkdir creates directory via passthrough' );

    $enc->remove_tree($d);
    ok( !$enc->exists($d), 'remove_tree via passthrough' );
}

done_testing;
