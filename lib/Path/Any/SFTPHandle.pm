package Path::Any::SFTPHandle;

use strict;
use warnings;
use Carp qw(croak);
use Symbol qw(gensym);

# ---------------------------------------------------------------------------
# Create a tied filehandle wrapping a Net::SFTP::Foreign handle
#
# Usage:
#   my $fh = Path::Any::SFTPHandle->open($sftp_handle, $pool, $sftp_conn);
# ---------------------------------------------------------------------------

sub open {
    my ( $class, $sftp_fh, $pool, $sftp ) = @_;
    my $sym = gensym;
    tie *$sym, $class, $sftp_fh, $pool, $sftp;
    return $sym;
}

# ---------------------------------------------------------------------------
# Tie interface
# ---------------------------------------------------------------------------

sub TIEHANDLE {
    my ( $class, $sftp_fh, $pool, $sftp ) = @_;
    return bless {
        fh   => $sftp_fh,
        pool => $pool,
        sftp => $sftp,
        eof  => 0,
    }, $class;
}

sub READ {
    my ( $self, undef, $len, $offset ) = @_;
    $offset //= 0;
    my $buf = $self->{fh}->read($len);
    if ( !defined $buf ) {
        $self->{eof} = 1;
        return 0;
    }
    substr( $_[1], $offset ) = $buf;
    return length($buf);
}

sub READLINE {
    my ($self) = @_;
    if (wantarray) {
        my @lines;
        while ( defined( my $line = $self->{fh}->getline ) ) {
            push @lines, $line;
        }
        $self->{eof} = 1;
        return @lines;
    }
    my $line = $self->{fh}->getline;
    $self->{eof} = 1 unless defined $line;
    return $line;
}

sub WRITE {
    my ( $self, $buf, $len, $offset ) = @_;
    $offset //= 0;
    $len    //= length($buf);
    my $data = substr( $buf, $offset, $len );
    my $result = $self->{fh}->write($data);
    return defined($result) ? $len : undef;
}

sub PRINT {
    my ( $self, @args ) = @_;
    my $buf = join( defined($,) ? $, : '', @args );
    $buf .= $\ if defined $\;
    return $self->WRITE($buf);
}

sub PRINTF {
    my ( $self, $fmt, @args ) = @_;
    return $self->PRINT( sprintf( $fmt, @args ) );
}

sub GETC {
    my ($self) = @_;
    my $buf;
    my $n = $self->READ( $buf, 1 );
    return $n ? $buf : undef;
}

sub EOF {
    my ($self) = @_;
    return $self->{eof};
}

sub CLOSE {
    my ($self) = @_;
    my $result = eval { $self->{fh}->close; 1 };
    # Return the SFTP connection to the pool
    if ( $self->{pool} && $self->{sftp} ) {
        $self->{pool}->release( $self->{sftp} );
        $self->{sftp} = undef;
    }
    return $result ? 1 : 0;
}

sub DESTROY {
    my ($self) = @_;
    # Ensure connection is returned even if handle isn't explicitly closed
    if ( $self->{sftp} && $self->{pool} ) {
        eval { $self->{pool}->release( $self->{sftp} ) };
        $self->{sftp} = undef;
    }
}

1;

__END__

=head1 NAME

Path::Any::SFTPHandle - Tied filehandle wrapping a Net::SFTP::Foreign handle

=head1 SYNOPSIS

    use Path::Any::SFTPHandle;

    my $fh = Path::Any::SFTPHandle->open($sftp_file_handle, $pool, $sftp_conn);
    while (<$fh>) { print }
    close $fh;   # returns $sftp_conn to $pool

=head1 DESCRIPTION

C<Path::Any::SFTPHandle> wraps a L<Net::SFTP::Foreign> file handle in a
standard Perl tied filehandle.  When the handle is closed (explicitly or by
going out of scope), the underlying SFTP connection is returned to the
L<Path::Any::ConnectionPool>.

=head1 METHODS

=head2 open($sftp_fh, $pool, $sftp)

Creates a new tied filehandle.  Returns a glob reference that can be used
wherever a regular filehandle is expected.

=head1 AUTHOR

Path::Any Contributors

=head1 LICENSE

Same as Perl itself.

=cut
