#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Test::Fatal;
use Digest::MD5 qw(md5_hex);

use lib 'lib';
use lib 'xt/lib';

use Path::Any::Test::Docker;

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

my $docker_ver = Path::Any::Test::Docker->available;
plan skip_all => 'docker not available' unless $docker_ver;

eval { require Paws };
plan skip_all => 'Paws not installed' if $@;

my $docker = Path::Any::Test::Docker->new(
    compose_file => 'docker-compose.yml',
    project_name => 'path-any-s3-xt',
);

$docker->start
    or BAIL_OUT('docker compose failed to start S3/MinIO service');

$docker->wait_for_http( 'http://localhost:9000/minio/health/live', 60 )
    or BAIL_OUT('MinIO health endpoint not ready after 60s');

# Give the createbuckets service time to finish
select undef, undef, undef, 3;

# ---------------------------------------------------------------------------
# Adapter setup
# ---------------------------------------------------------------------------

use Path::Any qw(path);
use Path::Any::Adapter;
use Path::Any::Manager;

Path::Any::Manager->_reset;
Path::Any::Adapter->set(
    'S3',
    bucket     => 'path-any-test',
    endpoint   => 'http://localhost:9000',
    access_key => 'minioadmin',
    secret_key => 'minioadmin123',
    key_prefix => 'xt-test',
);

# Paths: '/file.txt' → S3 key 'xt-test/file.txt'
sub p { path("/$_[0]") }

# ---------------------------------------------------------------------------
# 1. File does not exist before creation
# ---------------------------------------------------------------------------

ok( !p('file.txt')->exists, 'file does not exist before creation' );

# ---------------------------------------------------------------------------
# 2-4. spew / exists / is_file / slurp
# ---------------------------------------------------------------------------

p('file.txt')->spew("Hello, S3!\n");
ok( p('file.txt')->exists,  'file exists after spew' );
ok( p('file.txt')->is_file, 'is_file true after spew' );
is( p('file.txt')->slurp, "Hello, S3!\n", 'slurp returns spewed content' );

# ---------------------------------------------------------------------------
# 5. spew_utf8 / slurp_utf8
# ---------------------------------------------------------------------------

my $unicode = "caf\x{e9} \x{2603}\n";
p('utf8.txt')->spew_utf8($unicode);
is( p('utf8.txt')->slurp_utf8, $unicode, 'slurp_utf8 round-trip' );

# ---------------------------------------------------------------------------
# 6. lines
# ---------------------------------------------------------------------------

p('lines.txt')->spew("one\ntwo\nthree\n");
my @lines = p('lines.txt')->lines;
is( scalar @lines, 3, 'lines returns correct count' );

# ---------------------------------------------------------------------------
# 7. append
# ---------------------------------------------------------------------------

p('append.txt')->spew("first\n");
p('append.txt')->append("second\n");
is( p('append.txt')->slurp, "first\nsecond\n", 'append adds to existing content' );

# ---------------------------------------------------------------------------
# 8. touch
# ---------------------------------------------------------------------------

p('touched.txt')->touch;
ok( p('touched.txt')->exists, 'touch creates object' );

# ---------------------------------------------------------------------------
# 9. size
# ---------------------------------------------------------------------------

p('sized.txt')->spew("12345");
is( p('sized.txt')->size, 5, 'size returns byte count' );

# ---------------------------------------------------------------------------
# 10-12. copy
# ---------------------------------------------------------------------------

p('copy_src.txt')->spew("copy me\n");
p('copy_src.txt')->copy( p('copy_dest.txt') );
ok( p('copy_dest.txt')->exists,  'copy: destination exists' );
is( p('copy_dest.txt')->slurp, "copy me\n", 'copy: content preserved' );
ok( p('copy_src.txt')->exists,   'copy: source still exists' );

# ---------------------------------------------------------------------------
# 13-14. move
# ---------------------------------------------------------------------------

p('mv_src.txt')->spew("move me\n");
p('mv_src.txt')->move( p('mv_dest.txt') );
ok( p('mv_dest.txt')->exists,  'move: destination exists' );
ok( !p('mv_src.txt')->exists,  'move: source gone after move' );

# ---------------------------------------------------------------------------
# 15. remove
# ---------------------------------------------------------------------------

p('to_del.txt')->spew("x");
p('to_del.txt')->remove;
ok( !p('to_del.txt')->exists, 'remove deletes object' );

# ---------------------------------------------------------------------------
# 16-18. mkdir / children / remove_tree
# ---------------------------------------------------------------------------

p('subdir')->mkdir;
ok( p('subdir')->is_dir, 'mkdir creates virtual directory' );

p('subdir/a.txt')->spew('a');
p('subdir/b.txt')->spew('b');

my @kids = p('subdir')->children;
is( scalar @kids, 2, 'children returns 2 items' );

p('subdir')->remove_tree;
ok( !p('subdir')->is_dir, 'remove_tree removes virtual directory' );

# ---------------------------------------------------------------------------
# 19. iterator
# ---------------------------------------------------------------------------

p('iter_dir')->mkdir;
p('iter_dir/x.txt')->spew('x');
p('iter_dir/y.txt')->spew('y');

my $iter = p('iter_dir')->iterator;
my @found;
while ( defined( my $item = $iter->() ) ) {
    push @found, "$item";
}
is( scalar @found, 2, 'iterator yields 2 items' );

p('iter_dir')->remove_tree;

# ---------------------------------------------------------------------------
# 20. digest MD5
# ---------------------------------------------------------------------------

my $content = "digest test\n";
p('digest.txt')->spew($content);
my $expected = md5_hex($content);
is( p('digest.txt')->digest('MD5'), $expected, 'digest(MD5) matches' );

# ---------------------------------------------------------------------------
# 21. chmod is a no-op that returns 1
# ---------------------------------------------------------------------------

p('chmod_test.txt')->spew("x");
my $chmod_result = p('chmod_test.txt')->chmod(0644);
is( $chmod_result, 1, 'chmod returns 1 (no-op for S3)' );

# ---------------------------------------------------------------------------
# 22-24. Capability flags
# ---------------------------------------------------------------------------

my $adapter = path('/file.txt')->adapter;
is( $adapter->can_atomic_write, 0, 'can_atomic_write is 0' );
is( $adapter->can_symlink,      0, 'can_symlink is 0' );
is( $adapter->supports_chmod,   0, 'supports_chmod is 0' );

# ---------------------------------------------------------------------------
# 25-27. Error: slurp missing key throws Path::Any::Error
# ---------------------------------------------------------------------------

my $err = exception { p('no_such_key_xyz.txt')->slurp };
isa_ok( $err, 'Path::Any::Error', 'slurp on missing key throws Path::Any::Error' );
is( ref($err) ? $err->op      : '', 'slurp', 'error op is slurp' );
is( ref($err) ? $err->adapter : '', 'S3',    'error adapter is S3' );

# DESTROY on $docker calls stop() automatically
done_testing;
