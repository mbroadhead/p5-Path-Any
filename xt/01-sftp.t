#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Test::Fatal;
use Cwd qw(abs_path);
use Digest::MD5 qw(md5_hex);

use lib 'lib';
use lib 'xt/lib';

use Path::Any::Test::Docker;

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

my $docker_ver = Path::Any::Test::Docker->available;
plan skip_all => 'docker not available' unless $docker_ver;

eval { require Net::SFTP::Foreign };
plan skip_all => 'Net::SFTP::Foreign not installed' if $@;

# Generate SSH key pair and write authorized_keys before starting Docker
# (the docker-compose volume mount reads it at container start)
Path::Any::Test::Docker->ensure_sftp_key('xt/fixtures/sftp/test_key');

my $docker = Path::Any::Test::Docker->new(
    compose_file => 'docker-compose.yml',
    project_name => 'path-any-sftp-xt',
);

$docker->start
    or BAIL_OUT('docker compose failed to start SFTP service');

$docker->wait_for_port( '127.0.0.1', 2222, 60 )
    or BAIL_OUT('SFTP port 2222 not ready after 60s');

# Give sshd a moment to finish key exchange setup
select undef, undef, undef, 1;

# ---------------------------------------------------------------------------
# Adapter setup
# ---------------------------------------------------------------------------

use Path::Any qw(path);
use Path::Any::Adapter;
use Path::Any::Manager;

Path::Any::Manager->_reset;
Path::Any::Adapter->set(
    'SFTP',
    host => '127.0.0.1',
    user => 'testuser',
    port => 2222,
    sftp_opts => {
        key_path        => abs_path('xt/fixtures/sftp/test_key'),
        stderr_discard  => 1,
        more            => [
            '-o', 'StrictHostKeyChecking=no',
            '-o', 'UserKnownHostsFile=/dev/null',
        ],
    },
);

# atmoz/sftp: command "testuser::1001:::upload" chroots to /home/testuser
# and creates /home/testuser/upload — visible via SFTP as /upload
my $base = '/upload';
sub rp { path("$base/$_[0]") }

# ---------------------------------------------------------------------------
# 1. File does not exist before creation
# ---------------------------------------------------------------------------

ok( !rp('hello.txt')->exists, 'file does not exist before creation' );

# ---------------------------------------------------------------------------
# 2-4. spew / exists / is_file / slurp round-trip
# ---------------------------------------------------------------------------

rp('hello.txt')->spew("Hello, SFTP!\n");
ok( rp('hello.txt')->exists,  'file exists after spew' );
ok( rp('hello.txt')->is_file, 'is_file true after spew' );

is( rp('hello.txt')->slurp, "Hello, SFTP!\n", 'slurp returns spewed content' );

# ---------------------------------------------------------------------------
# 5. spew_utf8 / slurp_utf8
# ---------------------------------------------------------------------------

my $unicode = "caf\x{e9} \x{2603}\n";
rp('utf8.txt')->spew_utf8($unicode);
is( rp('utf8.txt')->slurp_utf8, $unicode, 'slurp_utf8 round-trip' );

# ---------------------------------------------------------------------------
# 6-7. lines — list and scalar (arrayref) context
# ---------------------------------------------------------------------------

rp('lines.txt')->spew("alpha\nbeta\ngamma\n");
my @lines = rp('lines.txt')->lines;
is( scalar @lines, 3, 'lines returns 3 elements in list context' );

my $lref = rp('lines.txt')->lines;
is( ref $lref, 'ARRAY', 'lines returns arrayref in scalar context' );

# ---------------------------------------------------------------------------
# 8. append
# ---------------------------------------------------------------------------

rp('append.txt')->spew("first\n");
rp('append.txt')->append("second\n");
is( rp('append.txt')->slurp, "first\nsecond\n", 'append adds to existing content' );

# ---------------------------------------------------------------------------
# 9. touch creates an empty file
# ---------------------------------------------------------------------------

ok( !rp('touched.txt')->exists, 'touched file absent before touch' );
rp('touched.txt')->touch;
ok( rp('touched.txt')->exists, 'touch creates empty file' );

# ---------------------------------------------------------------------------
# 10. size
# ---------------------------------------------------------------------------

rp('sized.txt')->spew("12345");
is( rp('sized.txt')->size, 5, 'size returns byte count' );

# ---------------------------------------------------------------------------
# 11-13. copy
# ---------------------------------------------------------------------------

rp('copy_src.txt')->spew("copy me\n");
rp('copy_src.txt')->copy( rp('copy_dest.txt') );
ok( rp('copy_dest.txt')->exists,  'copy: destination exists' );
is( rp('copy_dest.txt')->slurp, "copy me\n", 'copy: content preserved' );
ok( rp('copy_src.txt')->exists,  'copy: source still exists' );

# ---------------------------------------------------------------------------
# 14-15. move
# ---------------------------------------------------------------------------

rp('mv_src.txt')->spew("move me\n");
rp('mv_src.txt')->move( rp('mv_dest.txt') );
ok( rp('mv_dest.txt')->exists,   'move: destination exists' );
ok( !rp('mv_src.txt')->exists,   'move: source gone after move' );

# ---------------------------------------------------------------------------
# 16. remove
# ---------------------------------------------------------------------------

rp('to_del.txt')->spew("x");
rp('to_del.txt')->remove;
ok( !rp('to_del.txt')->exists, 'remove deletes file' );

# ---------------------------------------------------------------------------
# 17-19. mkdir / children / remove_tree
# ---------------------------------------------------------------------------

rp('subdir')->mkdir;
ok( rp('subdir')->is_dir, 'mkdir creates directory' );

rp('subdir/a.txt')->spew('a');
rp('subdir/b.txt')->spew('b');

my @kids = rp('subdir')->children;
is( scalar @kids, 2, 'children returns 2 items' );

rp('subdir')->remove_tree;
ok( !rp('subdir')->exists, 'remove_tree removes directory and contents' );

# ---------------------------------------------------------------------------
# 20-21. iterator — returns undef when exhausted
# ---------------------------------------------------------------------------

rp('iter_dir')->mkdir;
rp('iter_dir/x.txt')->spew('x');
rp('iter_dir/y.txt')->spew('y');

my $iter = rp('iter_dir')->iterator;
my @found;
while ( defined( my $item = $iter->() ) ) {
    push @found, "$item";
}
is( scalar @found, 2, 'iterator yields 2 items' );
is( $iter->(), undef, 'iterator returns undef when exhausted' );

rp('iter_dir')->remove_tree;

# ---------------------------------------------------------------------------
# 22-23. openr / openw filehandles
# ---------------------------------------------------------------------------

rp('fh_test.txt')->spew("filehandle content\n");
my $rfh = rp('fh_test.txt')->openr;
my $read = do { local $/; <$rfh> };
close $rfh;
is( $read, "filehandle content\n", 'openr returns readable filehandle' );

my $wfh = rp('fh_write.txt')->openw;
print $wfh "written via handle\n";
close $wfh;
is( rp('fh_write.txt')->slurp, "written via handle\n", 'openw filehandle writes to file' );

# ---------------------------------------------------------------------------
# 24. digest MD5
# ---------------------------------------------------------------------------

my $content = "digest test\n";
rp('digest.txt')->spew($content);
my $expected = md5_hex($content);
is( rp('digest.txt')->digest('MD5'), $expected, 'digest(MD5) matches' );

# ---------------------------------------------------------------------------
# 25. Connection pool: idle count within pool_size
# ---------------------------------------------------------------------------

{
    my $adapter = path("$base")->adapter;
    my $pool    = $adapter->_pool;

    rp('pool_a.txt')->spew('a');
    rp('pool_b.txt')->spew('b');

    ok(
        $pool->idle_count <= $pool->{pool_size},
        'connection pool idle count is within pool_size'
    );
}

# ---------------------------------------------------------------------------
# 26. Error: slurp missing file throws Path::Any::Error
# ---------------------------------------------------------------------------

my $err = exception { rp('no_such_file_xyz.txt')->slurp };
isa_ok( $err, 'Path::Any::Error', 'slurp on missing file throws Path::Any::Error' );
is( ref($err) ? $err->op      : '', 'slurp', 'error op is slurp' );
is( ref($err) ? $err->adapter : '', 'SFTP',  'error adapter is SFTP' );

# ---------------------------------------------------------------------------
# 27-32. mirror — directory tree
# ---------------------------------------------------------------------------

rp('mirror_src')->mkdir;
rp('mirror_src/a.txt')->spew('file a');
rp('mirror_src/b.txt')->spew('file b');
rp('mirror_src/sub')->mkdir;
rp('mirror_src/sub/c.txt')->spew('file c');

rp('mirror_src')->mirror( rp('mirror_dest') );

ok( rp('mirror_dest')->is_dir,                              'mirror: dest dir created' );
is( rp('mirror_dest/a.txt')->slurp,     'file a',           'mirror: a.txt copied' );
is( rp('mirror_dest/b.txt')->slurp,     'file b',           'mirror: b.txt copied' );
ok( rp('mirror_dest/sub')->is_dir,                          'mirror: subdirectory created' );
is( rp('mirror_dest/sub/c.txt')->slurp, 'file c',           'mirror: nested file copied' );

# ---------------------------------------------------------------------------
# 33. mirror — single file
# ---------------------------------------------------------------------------

rp('mirror_file_src.txt')->spew("single file\n");
rp('mirror_file_src.txt')->mirror( rp('mirror_file_dest.txt') );
is( rp('mirror_file_dest.txt')->slurp, "single file\n", 'mirror: single file copied' );

# DESTROY on $docker will call stop() automatically
done_testing;
