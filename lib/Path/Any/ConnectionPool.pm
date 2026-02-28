package Path::Any::ConnectionPool;

use strict;
use warnings;
use Carp qw(croak);
use Scalar::Util qw(weaken);

# ---------------------------------------------------------------------------
# Constructor
#
# Required args: host, user
# Optional args: port (22), pool_size (3), sftp_opts ({})
# ---------------------------------------------------------------------------

sub new {
    my ( $class, %args ) = @_;
    croak "host is required" unless $args{host};
    croak "user is required" unless $args{user};

    return bless {
        host      => $args{host},
        user      => $args{user},
        port      => $args{port}      // 22,
        pool_size => $args{pool_size} // 3,
        sftp_opts => $args{sftp_opts} // {},
        idle      => [],   # array of idle Net::SFTP::Foreign objects
        active    => 0,    # count of checked-out connections
    }, $class;
}

# ---------------------------------------------------------------------------
# acquire() — return a live connection, creating one if necessary
# ---------------------------------------------------------------------------

sub acquire {
    my ($self) = @_;

    # Try to find a live idle connection
    while ( my $sftp = shift @{ $self->{idle} } ) {
        if ( $self->_test_connection($sftp) ) {
            $self->{active}++;
            return $sftp;
        }
        # Otherwise discard and try next
    }

    # Create a new connection
    my $sftp = $self->_connect;
    $self->{active}++;
    return $sftp;
}

# ---------------------------------------------------------------------------
# release($sftp) — return a connection to the idle pool (or discard)
# ---------------------------------------------------------------------------

sub release {
    my ( $self, $sftp ) = @_;
    $self->{active}-- if $self->{active} > 0;

    if ( scalar @{ $self->{idle} } < $self->{pool_size} ) {
        push @{ $self->{idle} }, $sftp;
    }
    # else: let it go out of scope and be garbage-collected
}

# ---------------------------------------------------------------------------
# Internal
# ---------------------------------------------------------------------------

sub _connect {
    my ($self) = @_;
    _require_sftp();

    my $sftp = Net::SFTP::Foreign->new(
        $self->{host},
        user      => $self->{user},
        port      => $self->{port},
        %{ $self->{sftp_opts} },
    );

    if ( $sftp->error ) {
        die sprintf(
            "Path::Any::ConnectionPool: cannot connect to %s@%s:%s — %s\n",
            $self->{user}, $self->{host}, $self->{port}, $sftp->error
        );
    }

    return $sftp;
}

sub _test_connection {
    my ( $self, $sftp ) = @_;
    # A cheap stat on '.' verifies the connection is still alive
    my $stat = eval { $sftp->stat('.') };
    return $@ ? 0 : ( $stat ? 1 : 0 );
}

sub _require_sftp {
    unless ( $INC{'Net/SFTP/Foreign.pm'} ) {
        eval { require Net::SFTP::Foreign; Net::SFTP::Foreign->import };
        if ($@) {
            die "Path::Any::Adapter::SFTP requires Net::SFTP::Foreign >= 1.90. "
              . "Install it with: cpanm Net::SFTP::Foreign\n";
        }
    }
}

# Pool statistics (for debugging / tests)
sub idle_count   { scalar @{ $_[0]->{idle} } }
sub active_count { $_[0]->{active} }

1;

__END__

=head1 NAME

Path::Any::ConnectionPool - SFTP connection lifecycle management

=head1 SYNOPSIS

    use Path::Any::ConnectionPool;

    my $pool = Path::Any::ConnectionPool->new(
        host      => 'sftp.example.com',
        user      => 'deploy',
        pool_size => 3,
    );

    my $sftp = $pool->acquire;
    # ... use $sftp ...
    $pool->release($sftp);

=head1 DESCRIPTION

C<Path::Any::ConnectionPool> manages a pool of L<Net::SFTP::Foreign>
connections to a single SFTP host.  Idle connections are tested for liveness
before being reused; stale connections are discarded.

=head1 METHODS

=head2 new(%args)

Required: C<host>, C<user>.
Optional: C<port> (default 22), C<pool_size> (default 3), C<sftp_opts> (hashref).

=head2 acquire

Returns a live C<Net::SFTP::Foreign> connection.  Creates a new connection if
none are idle or all idle connections are stale.

=head2 release($sftp)

Returns a connection to the idle pool.  If the pool is full, the connection is
discarded.

=head2 idle_count / active_count

Return the number of idle / checked-out connections (useful for tests).

=head1 AUTHOR

Path::Any Contributors

=head1 LICENSE

Same as Perl itself.

=cut
