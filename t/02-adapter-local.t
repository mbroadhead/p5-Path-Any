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
use Path::Any::Manager;
use Path::Any::Error;

Path::Any::Manager->_reset;
Path::Any::Adapter->set('Local');

my $dir = tempdir( CLEANUP => 1 );

sub td { path( File::Spec->catfile($dir, @_) ) }

# ---------------------------------------------------------------------------
# exists / is_file / is_dir
# ---------------------------------------------------------------------------

{
    my $f = td('nonexistent.txt');
    ok(!$f->exists,  'nonexistent file: exists() false');
    ok(!$f->is_file, 'nonexistent file: is_file() false');
    ok(!$f->is_dir,  'nonexistent file: is_dir() false');

    my $d = td();
    ok($d->exists, 'temp dir exists');
    ok($d->is_dir, 'temp dir is_dir');
}

# ---------------------------------------------------------------------------
# spew / slurp
# ---------------------------------------------------------------------------

{
    my $f = td('hello.txt');
    $f->spew("Hello, world!\n");
    ok($f->exists,  'file exists after spew');
    ok($f->is_file, 'is_file after spew');

    my $content = $f->slurp;
    is($content, "Hello, world!\n", 'slurp returns spewed content');
}

# ---------------------------------------------------------------------------
# spew_utf8 / slurp_utf8
# ---------------------------------------------------------------------------

{
    my $f = td('unicode.txt');
    my $str = "Héllo, wörld! \x{263A}\n";
    $f->spew_utf8($str);
    my $back = $f->slurp_utf8;
    is($back, $str, 'round-trip UTF-8 spew/slurp');
}

# ---------------------------------------------------------------------------
# spew_raw / slurp_raw
# ---------------------------------------------------------------------------

{
    my $f = td('binary.bin');
    my $bytes = join('', map { chr($_) } 0..255);
    $f->spew_raw($bytes);
    my $back = $f->slurp_raw;
    is($back, $bytes, 'round-trip raw binary spew/slurp');
}

# ---------------------------------------------------------------------------
# lines
# ---------------------------------------------------------------------------

{
    my $f = td('lines.txt');
    $f->spew("line1\nline2\nline3\n");
    my @lines = $f->lines;
    is(scalar @lines, 3, 'lines() returns 3 lines');
    is($lines[0], "line1\n", 'first line correct');

    my $aref = $f->lines;
    is(ref($aref), 'ARRAY', 'lines() in scalar context returns arrayref');
    is(scalar @$aref, 3, 'arrayref has 3 elements');
}

# ---------------------------------------------------------------------------
# append
# ---------------------------------------------------------------------------

{
    my $f = td('append.txt');
    $f->spew("line1\n");
    $f->append("line2\n");
    my $content = $f->slurp;
    is($content, "line1\nline2\n", 'append adds to file');
}

# ---------------------------------------------------------------------------
# touch
# ---------------------------------------------------------------------------

{
    my $f = td('touched.txt');
    ok(!$f->exists, 'file does not exist before touch');
    $f->touch;
    ok($f->exists,  'file exists after touch');
    ok($f->is_file, 'touched file is_file');
    is($f->size, 0, 'touched file has size 0');
}

# ---------------------------------------------------------------------------
# size
# ---------------------------------------------------------------------------

{
    my $f = td('sized.txt');
    $f->spew("12345");
    is($f->size, 5, 'size() returns byte count');
}

# ---------------------------------------------------------------------------
# copy / move
# ---------------------------------------------------------------------------

{
    my $src  = td('copy_src.txt');
    my $dest = td('copy_dest.txt');
    $src->spew("copy me\n");
    $src->copy($dest);
    ok($dest->exists, 'dest exists after copy');
    is($dest->slurp, "copy me\n", 'dest content matches src after copy');
    ok($src->exists,  'src still exists after copy');

    my $mv_src  = td('move_src.txt');
    my $mv_dest = td('move_dest.txt');
    $mv_src->spew("move me\n");
    $mv_src->move($mv_dest);
    ok($mv_dest->exists,  'dest exists after move');
    ok(!$mv_src->exists,  'src gone after move');
}

# ---------------------------------------------------------------------------
# remove
# ---------------------------------------------------------------------------

{
    my $f = td('to_remove.txt');
    $f->spew("delete me\n");
    ok($f->exists, 'file exists before remove');
    $f->remove;
    ok(!$f->exists, 'file gone after remove');
}

# ---------------------------------------------------------------------------
# mkdir / children / remove_tree
# ---------------------------------------------------------------------------

{
    my $subdir = td('subdir');
    $subdir->mkdir;
    ok($subdir->is_dir, 'mkdir creates directory');

    td('subdir', 'a.txt')->spew('a');
    td('subdir', 'b.txt')->spew('b');

    my @kids = $subdir->children;
    is(scalar @kids, 2, 'children() returns 2 items');

    my $aref = $subdir->children;
    is(ref($aref), 'ARRAY', 'children() in scalar context returns arrayref');

    $subdir->remove_tree;
    ok(!$subdir->exists, 'remove_tree removes directory tree');
}

# ---------------------------------------------------------------------------
# iterator
# ---------------------------------------------------------------------------

{
    my $d = td('iter_dir');
    $d->mkdir;
    td('iter_dir', 'x.txt')->spew('x');
    td('iter_dir', 'y.txt')->spew('y');

    my $iter = $d->iterator;
    my @found;
    while ( defined( my $item = $iter->() ) ) {
        push @found, "$item";
    }
    is(scalar @found, 2, 'iterator yields 2 items');
}

# ---------------------------------------------------------------------------
# openr / openw
# ---------------------------------------------------------------------------

{
    my $f = td('handle.txt');
    $f->spew("handle test\n");

    my $fh = $f->openr;
    ok(defined $fh, 'openr returns a filehandle');
    my $line = <$fh>;
    is($line, "handle test\n", 'read from openr filehandle');
    close $fh;

    my $wfh = $f->openw;
    ok(defined $wfh, 'openw returns a filehandle');
    print $wfh "written\n";
    close $wfh;
    is($f->slurp, "written\n", 'written via openw handle');
}

# ---------------------------------------------------------------------------
# stat / lstat
# ---------------------------------------------------------------------------

{
    my $f = td('stat_test.txt');
    $f->spew("test");
    my $stat = $f->stat;
    ok(defined $stat, 'stat() returns a value');
    # File::stat or POSIX stat object — just check it's defined
}

# ---------------------------------------------------------------------------
# realpath
# ---------------------------------------------------------------------------

{
    my $f = td('real.txt');
    $f->spew("x");
    my $real = $f->realpath;
    ok(defined $real, 'realpath returns a value');
}

# ---------------------------------------------------------------------------
# chmod
# ---------------------------------------------------------------------------

SKIP: {
    skip "chmod tests not meaningful on Windows", 1 if $^O eq 'MSWin32';
    my $f = td('chmod_test.txt');
    $f->spew("x");
    my $result = eval { $f->chmod(0644); 1 };
    ok($result, 'chmod does not die');
}

# ---------------------------------------------------------------------------
# digest
# ---------------------------------------------------------------------------

{
    my $f = td('digest.txt');
    $f->spew("hello");
    my $md5 = eval { $f->digest('MD5') };
    SKIP: {
        skip "Digest::MD5 not available", 1 unless defined $md5;
        like($md5, qr/^[0-9a-f]{32}$/, 'digest returns hex MD5');
    }
}

# ---------------------------------------------------------------------------
# mirror
# ---------------------------------------------------------------------------

{
    my $src = td('mirror_src');
    $src->mkdir;
    td('mirror_src', 'a.txt')->spew('file a');
    td('mirror_src', 'b.txt')->spew('file b');
    my $sub = td('mirror_src', 'sub');
    $sub->mkdir;
    td('mirror_src', 'sub', 'c.txt')->spew('file c');

    my $dest = td('mirror_dest');
    $src->mirror($dest);

    ok($dest->is_dir,                                   'mirror creates dest dir');
    is(td('mirror_dest', 'a.txt')->slurp, 'file a',    'mirror copies a.txt');
    is(td('mirror_dest', 'b.txt')->slurp, 'file b',    'mirror copies b.txt');
    ok(td('mirror_dest', 'sub')->is_dir,                'mirror creates subdirectory');
    is(td('mirror_dest', 'sub', 'c.txt')->slurp, 'file c', 'mirror copies nested file');
}

{
    my $src = td('mirror_file_src.txt');
    $src->spew("single file\n");
    my $dest = td('mirror_file_dest.txt');
    $src->mirror($dest);
    is($dest->slurp, "single file\n", 'mirror works on a single file');
}

{
    my $err = exception { td('mirror_nonexistent')->mirror(td('mirror_out')) };
    ok(defined $err, 'mirror on nonexistent source throws');
    isa_ok($err, 'Path::Any::Error') if ref $err;
}

# ---------------------------------------------------------------------------
# mirror compare => 'size'
# ---------------------------------------------------------------------------

{
    my $src = td('cmp_size_src');
    $src->mkdir;
    td('cmp_size_src', 'same.txt')->spew('identical content');
    td('cmp_size_src', 'diff.txt')->spew('original');

    my $dest = td('cmp_size_dest');
    $src->mirror($dest);

    # Pre-populate dest: same.txt identical, diff.txt has shorter content
    td('cmp_size_dest', 'same.txt')->spew('identical content');
    td('cmp_size_dest', 'diff.txt')->spew('x');  # 1 byte vs 8 bytes in src

    $src->mirror($dest, compare => 'size');

    is( td('cmp_size_dest', 'same.txt')->slurp, 'identical content',
        'compare=size: identical file left as-is' );
    is( td('cmp_size_dest', 'diff.txt')->slurp, 'original',
        'compare=size: different-size file overwritten' );
}

# ---------------------------------------------------------------------------
# mirror compare => 'size+digest'
# ---------------------------------------------------------------------------

{
    my $md5_ok = eval { require Digest::MD5; 1 };
    SKIP: {
        skip 'Digest::MD5 not available', 4 unless $md5_ok;

        my $src = td('cmp_digest_src');
        $src->mkdir;
        td('cmp_digest_src', 'same.txt')->spew('hello world');
        # same length as 'hello world' (11 bytes) but different content
        td('cmp_digest_src', 'samesize.txt')->spew('hello world');

        my $dest = td('cmp_digest_dest');
        $src->mirror($dest);

        # Make dest identical for same.txt, same-size-but-different for samesize.txt
        td('cmp_digest_dest', 'same.txt')->spew('hello world');
        td('cmp_digest_dest', 'samesize.txt')->spew('dlrow olleh');

        $src->mirror($dest, compare => 'size+digest');

        is( td('cmp_digest_dest', 'same.txt')->slurp, 'hello world',
            'compare=size+digest: identical content left as-is' );
        is( td('cmp_digest_dest', 'samesize.txt')->slurp, 'hello world',
            'compare=size+digest: same-size but different content overwritten' );

        # Also verify that compare=size would NOT catch the same-size difference
        td('cmp_digest_dest', 'samesize.txt')->spew('dlrow olleh');
        $src->mirror($dest, compare => 'size');
        is( td('cmp_digest_dest', 'samesize.txt')->slurp, 'dlrow olleh',
            'compare=size: same-size file skipped even with different content' );

        # Non-existent dest file is always copied
        td('cmp_digest_dest', 'same.txt')->remove;
        $src->mirror($dest, compare => 'size+digest');
        is( td('cmp_digest_dest', 'same.txt')->slurp, 'hello world',
            'compare=size+digest: missing dest file is copied' );
    }
}

# ---------------------------------------------------------------------------
# Error handling: slurp non-existent file throws Path::Any::Error
# ---------------------------------------------------------------------------

{
    my $f = td('no_such_file_xyz.txt');
    my $err = exception { $f->slurp };
    ok(defined $err, 'slurp on missing file throws');
    isa_ok($err, 'Path::Any::Error', 'thrown error is Path::Any::Error')
        if ref $err;
    if ( ref($err) && $err->isa('Path::Any::Error') ) {
        is($err->op, 'slurp', 'error op is slurp');
        like($err->adapter, qr/Local/, 'error adapter is Local');
    }
}

done_testing;
