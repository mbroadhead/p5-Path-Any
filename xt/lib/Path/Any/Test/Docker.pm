package Path::Any::Test::Docker;

use strict;
use warnings;
use Carp qw(croak carp);

# ---------------------------------------------------------------------------
# available()
#
# Returns 'v2' if "docker compose" (v2) works,
#         'v1' if "docker-compose" (v1) works,
#          0   if neither is found.
# ---------------------------------------------------------------------------

sub available {
    # First verify the daemon is reachable (binary alone is not enough)
    return 0 unless system('docker info >/dev/null 2>&1') == 0;

    if ( system('docker compose version >/dev/null 2>&1') == 0 ) {
        return 'v2';
    }
    if ( system('docker-compose version >/dev/null 2>&1') == 0 ) {
        return 'v1';
    }
    return 0;
}

# ---------------------------------------------------------------------------
# new(%args)
#
# Args:
#   compose_file  — path to docker-compose.yml (default: docker-compose.yml)
#   project_name  — docker compose project name (default: path-any-xt)
#   timeout       — seconds to wait for services (default: 120)
# ---------------------------------------------------------------------------

sub new {
    my ( $class, %args ) = @_;

    my $ver = available();
    croak "docker is not available" unless $ver;

    return bless {
        compose_file  => $args{compose_file} // 'docker-compose.yml',
        project_name  => $args{project_name} // 'path-any-xt',
        timeout       => $args{timeout}      // 120,
        _version      => $ver,
        _started      => 0,
    }, $class;
}

# ---------------------------------------------------------------------------
# start()
#
# Brings up Docker Compose services.
# With v2 uses --wait (blocks until healthchecks pass).
# With v1 just does -d and relies on the caller to poll.
#
# Returns 1 on success, 0 on failure.
# ---------------------------------------------------------------------------

sub start {
    my ($self) = @_;

    my $f = $self->{compose_file};
    my $p = $self->{project_name};

    my $cmd;
    if ( $self->{_version} eq 'v2' ) {
        # Avoid --wait: it treats any exited container (including one-shot
        # "createbuckets" that exits 0) as a failure.  We rely on
        # wait_for_port / wait_for_http in the caller instead.
        $cmd = qq{docker compose -f "$f" -p "$p" up -d 2>&1};
    }
    else {
        $cmd = qq{docker-compose -f "$f" -p "$p" up -d 2>&1};
    }

    my $output = `$cmd`;
    my $status = $?;

    if ( $status != 0 ) {
        carp "docker compose up failed (exit $status):\n$output";
        return 0;
    }

    $self->{_started} = 1;
    return 1;
}

# ---------------------------------------------------------------------------
# stop()
#
# Tears down services and removes volumes.
# ---------------------------------------------------------------------------

sub stop {
    my ($self) = @_;
    return unless $self->{_started};

    my $f = $self->{compose_file};
    my $p = $self->{project_name};

    my $cmd;
    if ( $self->{_version} eq 'v2' ) {
        $cmd = qq{docker compose -f "$f" -p "$p" down -v 2>&1};
    }
    else {
        $cmd = qq{docker-compose -f "$f" -p "$p" down -v 2>&1};
    }

    `$cmd`;
    $self->{_started} = 0;
    return 1;
}

# ---------------------------------------------------------------------------
# wait_for_port($host, $port, $timeout_secs)
#
# Polls TCP connection until it succeeds or times out.
# Returns 1 on success, 0 on timeout.
# ---------------------------------------------------------------------------

sub wait_for_port {
    my ( $self_or_class, $host, $port, $timeout ) = @_;
    $timeout //= 30;

    require IO::Socket::INET;

    my $deadline = time + $timeout;
    while ( time < $deadline ) {
        my $sock = IO::Socket::INET->new(
            PeerHost => $host,
            PeerPort => $port,
            Proto    => 'tcp',
            Timeout  => 1,
        );
        if ($sock) {
            $sock->close;
            return 1;
        }
        select undef, undef, undef, 0.5;
    }
    return 0;
}

# ---------------------------------------------------------------------------
# wait_for_http($url, $timeout_secs)
#
# Polls HTTP GET until a 2xx response or times out.
# Returns 1 on success, 0 on timeout.
# ---------------------------------------------------------------------------

sub wait_for_http {
    my ( $self_or_class, $url, $timeout ) = @_;
    $timeout //= 30;

    require HTTP::Tiny;

    my $ua       = HTTP::Tiny->new( timeout => 2 );
    my $deadline = time + $timeout;

    while ( time < $deadline ) {
        my $resp = eval { $ua->get($url) };
        if ( !$@ && $resp && $resp->{success} ) {
            return 1;
        }
        select undef, undef, undef, 0.5;
    }
    return 0;
}

# ---------------------------------------------------------------------------
# ensure_sftp_key($key_path)
#
# Generates an RSA key pair at $key_path / $key_path.pub if not present,
# then writes the public key to authorized_keys in the same directory.
# The private key is chmod'd 600.
#
# Can be called as a class or instance method.
# ---------------------------------------------------------------------------

sub ensure_sftp_key {
    my ( $self_or_class, $key_path ) = @_;

    unless ( -f $key_path ) {
        my $rc = system(
            'ssh-keygen', '-t', 'rsa', '-b', '4096',
            '-N', '', '-f', $key_path
        );
        die "ssh-keygen failed (exit $rc)" if $rc != 0;
    }

    ( my $dir = $key_path ) =~ s{/[^/]+$}{};
    $dir = '.' unless length $dir;

    open my $pub_fh, '<', "$key_path.pub"
        or die "Cannot read $key_path.pub: $!";
    my $pubkey = do { local $/; <$pub_fh> };
    close $pub_fh;

    open my $ak, '>', "$dir/authorized_keys"
        or die "Cannot write $dir/authorized_keys: $!";
    print $ak $pubkey;
    close $ak;

    chmod 0600, $key_path;

    return $key_path;
}

# ---------------------------------------------------------------------------
# DESTROY — automatically stop if we started
# ---------------------------------------------------------------------------

sub DESTROY {
    my ($self) = @_;
    $self->stop if ref($self) && $self->{_started};
}

1;

__END__

=head1 NAME

Path::Any::Test::Docker - Docker Compose lifecycle helper for Path::Any author tests

=head1 SYNOPSIS

    use Path::Any::Test::Docker;

    plan skip_all => 'docker not available'
        unless Path::Any::Test::Docker->available;

    Path::Any::Test::Docker->ensure_sftp_key('xt/fixtures/sftp/test_key');

    my $docker = Path::Any::Test::Docker->new(
        compose_file => 'docker-compose.yml',
        project_name => 'path-any-xt',
    );

    $docker->start or BAIL_OUT('docker compose failed');

    $docker->wait_for_port('127.0.0.1', 2222, 30)
        or BAIL_OUT('SFTP port not ready');

    # ... run tests ...

    $docker->stop;   # also called automatically in DESTROY

=head1 METHODS

=head2 available

Class method.  Returns C<'v2'>, C<'v1'>, or C<0>.

=head2 new(%args)

Constructor.  C<compose_file>, C<project_name>, C<timeout>.

=head2 start

Runs C<docker compose up -d --wait> (v2) or C<docker-compose up -d> (v1).
Returns 1 on success, 0 on failure.

=head2 stop

Runs C<docker compose down -v>.

=head2 wait_for_port($host, $port, $timeout)

Polls a TCP port until connectable or timeout.

=head2 wait_for_http($url, $timeout)

Polls an HTTP URL until a successful response or timeout.

=head2 ensure_sftp_key($key_path)

Generates an RSA key pair at C<$key_path> if not already present, then writes
the public key into C<authorized_keys> in the same directory.

=head1 AUTHOR

Path::Any Contributors

=head1 LICENSE

Same as Perl itself.

=cut
