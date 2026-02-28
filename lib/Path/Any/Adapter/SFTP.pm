package Path::Any::Adapter::SFTP;

use strict;
use warnings;
use parent 'Path::Any::Adapter::Base';
use Carp qw(croak);
use Path::Any::Error     ();
use Path::Any::ConnectionPool ();
use Path::Any::SFTPHandle     ();

# ---------------------------------------------------------------------------
# Constructor
#
# Required: host, user
# Optional: port (22), pool_size (3), sftp_opts ({})
# ---------------------------------------------------------------------------

sub new {
    my ( $class, %args ) = @_;
    croak "host is required" unless $args{host};

    $args{user} //= do {
        require POSIX;
        (POSIX::getpwuid($>))[0] // croak "user is required";
    };

    my $self = $class->SUPER::new(%args);
    # Lazy — pool is not created until first operation
    $self->{_pool} = undef;
    return $self;
}

sub _pool {
    my ($self) = @_;
    unless ( $self->{_pool} ) {
        $self->{_pool} = Path::Any::ConnectionPool->new(
            host      => $self->{host},
            user      => $self->{user},
            port      => $self->{port}      // 22,
            pool_size => $self->{pool_size} // 3,
            sftp_opts => $self->{sftp_opts} // {},
        );
    }
    return $self->{_pool};
}

# ---------------------------------------------------------------------------
# Helper: run an operation inside an acquired/released connection
# ---------------------------------------------------------------------------

sub _with_sftp {
    my ( $self, $op, $path, $code ) = @_;
    my $pool = $self->_pool;
    my $sftp = $pool->acquire;
    my $result = eval { $code->($sftp) };
    my $err = $@;
    # Always release unless we're returning the connection inside a handle
    $pool->release($sftp) unless $err && ref($err) eq 'Path::Any::_KeepConnection';
    if ($err) {
        my $msg = ref($err) ? "$err" : $err;
        Path::Any::Error->throw(
            op      => $op,
            file    => "$path",
            err     => $msg,
            adapter => 'SFTP',
        );
    }
    return $result;
}

# ---------------------------------------------------------------------------
# Stat / existence
# ---------------------------------------------------------------------------

sub stat {
    my ( $self, $path ) = @_;
    return $self->_with_sftp( 'stat', $path, sub {
        my ($sftp) = @_;
        return $sftp->stat("$path");
    });
}

sub lstat {
    my ( $self, $path ) = @_;
    return $self->_with_sftp( 'lstat', $path, sub {
        my ($sftp) = @_;
        return $sftp->lstat("$path");
    });
}

sub size {
    my ( $self, $path ) = @_;
    my $attr = $self->stat($path);
    return defined($attr) ? $attr->size : undef;
}

sub exists {
    my ( $self, $path ) = @_;
    my $attr = eval { $self->stat($path) };
    return $@ ? 0 : ( defined($attr) ? 1 : 0 );
}

sub is_file {
    my ( $self, $path ) = @_;
    my $attr = eval { $self->stat($path) };
    return 0 if $@;
    return defined($attr) && !( $attr->perm & 0040000 ) ? 1 : 0;
}

sub is_dir {
    my ( $self, $path ) = @_;
    my $attr = eval { $self->stat($path) };
    return 0 if $@;
    return defined($attr) && ( $attr->perm & 0040000 ) ? 1 : 0;
}

# ---------------------------------------------------------------------------
# Read
# ---------------------------------------------------------------------------

sub slurp {
    my ( $self, $path, @args ) = @_;
    my $binmode = _extract_binmode(\@args);
    my $data = $self->_with_sftp( 'slurp', $path, sub {
        my ($sftp) = @_;
        my $d = $sftp->get_content("$path");
        die $sftp->error . "\n" if $sftp->error;
        return $d;
    });
    if ( my $enc = _binmode_to_encoding($binmode) ) {
        require Encode;
        $data = Encode::decode( $enc, $data );
    }
    return $data;
}

sub lines {
    my ( $self, $path, @args ) = @_;
    my $data = $self->slurp($path);
    my @lines = split /^/m, $data;
    return wantarray ? @lines : \@lines;
}

# ---------------------------------------------------------------------------
# Write
# ---------------------------------------------------------------------------

sub spew {
    my ( $self, $path, $data, @args ) = @_;
    my $binmode = _extract_binmode(\@args);
    $data = '' unless defined $data;
    $data = join('', @$data) if ref($data) eq 'ARRAY';
    if ( my $enc = _binmode_to_encoding($binmode) ) {
        require Encode;
        $data = Encode::encode( $enc, $data );
    }
    return $self->_with_sftp( 'spew', $path, sub {
        my ($sftp) = @_;
        $sftp->put_content($data, "$path")
            or die $sftp->error . "\n";
        return 1;
    });
}

sub append {
    my ( $self, $path, $data, @args ) = @_;
    my $existing = eval { $self->slurp($path) } // '';
    $data = '' unless defined $data;
    $data = join('', @$data) if ref($data) eq 'ARRAY';
    return $self->spew($path, $existing . $data);
}

# ---------------------------------------------------------------------------
# Filehandles
# ---------------------------------------------------------------------------

sub openr {
    my ( $self, $path, @args ) = @_;
    return $self->filehandle($path, '<');
}

sub openw {
    my ( $self, $path, @args ) = @_;
    return $self->filehandle($path, '>');
}

sub opena {
    my ( $self, $path, @args ) = @_;
    return $self->filehandle($path, '>>');
}

sub openrw {
    my ( $self, $path, @args ) = @_;
    return $self->filehandle($path, '+<');
}

sub filehandle {
    my ( $self, $path, $mode, @args ) = @_;
    $mode //= '<';
    my $pool = $self->_pool;
    my $sftp = $pool->acquire;
    my $sftp_fh = eval { $sftp->open("$path", _mode_flags($mode)) };
    if ($@ || !$sftp_fh) {
        my $err = $@ || $sftp->error;
        $pool->release($sftp);
        Path::Any::Error->throw(
            op      => 'filehandle',
            file    => "$path",
            err     => "$err",
            adapter => 'SFTP',
        );
    }
    # SFTPHandle takes ownership of $sftp and will return it to pool on close
    return Path::Any::SFTPHandle->open($sftp_fh, $pool, $sftp);
}

sub _mode_flags {
    my ($mode) = @_;
    # Net::SFTP::Foreign::open takes SFTP protocol flags (SSH2_FXF_*),
    # NOT Fcntl flags.  The SSH2_FXF values are fixed by the SFTP spec.
    my ( $READ, $WRITE, $APPEND, $CREAT, $TRUNC )
        = ( 0x01, 0x02, 0x04, 0x08, 0x10 );
    my %map = (
        '<'  => $READ,
        '>'  => $WRITE | $CREAT | $TRUNC,
        '>>' => $WRITE | $CREAT | $APPEND,
        '+<' => $READ  | $WRITE,
        '+>' => $READ  | $WRITE | $CREAT | $TRUNC,
    );
    return $map{$mode} // $READ;
}

# ---------------------------------------------------------------------------
# Filesystem mutation
# ---------------------------------------------------------------------------

sub copy {
    my ( $self, $src, $dest ) = @_;
    return $self->_with_sftp( 'copy', $src, sub {
        my ($sftp) = @_;
        # SFTP has no native copy; slurp+spew
        my $data = $sftp->get_content("$src");
        die $sftp->error . "\n" if $sftp->error;
        $sftp->put_content($data, "$dest")
            or die $sftp->error . "\n";
        return 1;
    });
}

sub move {
    my ( $self, $src, $dest ) = @_;
    return $self->_with_sftp( 'move', $src, sub {
        my ($sftp) = @_;
        $sftp->rename("$src", "$dest")
            or die $sftp->error . "\n";
        return 1;
    });
}

sub remove {
    my ( $self, $path ) = @_;
    return $self->_with_sftp( 'remove', $path, sub {
        my ($sftp) = @_;
        $sftp->remove("$path")
            or die $sftp->error . "\n";
        return 1;
    });
}

sub touch {
    my ( $self, $path ) = @_;
    # Create empty file if not exists, else update mtime via utime
    return $self->_with_sftp( 'touch', $path, sub {
        my ($sftp) = @_;
        my $attr = $sftp->stat("$path");
        if ($attr) {
            $sftp->setstat("$path", atime => time, mtime => time)
                or die $sftp->error . "\n";
        }
        else {
            $sftp->put_content('', "$path")
                or die $sftp->error . "\n";
        }
        return 1;
    });
}

sub chmod {
    my ( $self, $path, $mode ) = @_;
    return $self->_with_sftp( 'chmod', $path, sub {
        my ($sftp) = @_;
        $sftp->setstat("$path", perm => $mode)
            or die $sftp->error . "\n";
        return 1;
    });
}

sub realpath {
    my ( $self, $path ) = @_;
    return $self->_with_sftp( 'realpath', $path, sub {
        my ($sftp) = @_;
        my $real = $sftp->realpath("$path");
        die $sftp->error . "\n" unless defined $real;
        return $real;
    });
}

sub digest {
    my ( $self, $path, $algo, @args ) = @_;
    $algo //= 'MD5';
    my $data = $self->slurp($path);
    require Digest;
    my $d = Digest->new($algo);
    $d->add($data);
    return $d->hexdigest;
}

# ---------------------------------------------------------------------------
# Directory operations
# ---------------------------------------------------------------------------

sub mkdir {
    my ( $self, $path ) = @_;
    return $self->_with_sftp( 'mkdir', $path, sub {
        my ($sftp) = @_;
        # mkpath equivalent — create intermediate dirs
        my $p = "$path";
        my @parts;
        while ($p ne '/' && $p ne '.') {
            unshift @parts, $p;
            $p =~ s{/[^/]+$}{} or last;
            $p = '/' if $p eq '';
        }
        for my $dir (@parts) {
            my $attr = eval { $sftp->stat($dir) };
            next if defined $attr;
            $sftp->mkdir($dir)
                or die $sftp->error . "\n";
        }
        return 1;
    });
}

sub remove_tree {
    my ( $self, $path ) = @_;
    return $self->_with_sftp( 'remove_tree', $path, sub {
        my ($sftp) = @_;
        _recursive_remove($sftp, "$path");
        return 1;
    });
}

sub _recursive_remove {
    my ($sftp, $path) = @_;
    my $attr = $sftp->stat($path) or return;
    if ( $attr->perm & 0040000 ) {
        # Directory
        my $ls = $sftp->ls($path, wanted => sub { $_[1]->{filename} !~ /^\.\.?$/ });
        for my $entry ( @{ $ls // [] } ) {
            _recursive_remove($sftp, "$path/$entry->{filename}");
        }
        $sftp->rmdir($path) or die $sftp->error . "\n";
    }
    else {
        $sftp->remove($path) or die $sftp->error . "\n";
    }
}

sub children {
    my ( $self, $path, @args ) = @_;
    # Always return an arrayref from the closure: _with_sftp evaluates in
    # scalar context, so wantarray inside the sub is always false.
    my $kids_ref = $self->_with_sftp( 'children', $path, sub {
        my ($sftp) = @_;
        my $ls = $sftp->ls("$path",
            wanted     => sub { $_[1]->{filename} !~ /^\.\.?$/ },
            names_only => 1,
        );
        die $sftp->error . "\n" if $sftp->error;
        return [ map { require Path::Any; Path::Any->new("$path/$_") }
                 @{ $ls // [] } ];
    });
    my @kids = @{ $kids_ref // [] };
    return wantarray ? @kids : \@kids;
}

sub iterator {
    my ( $self, $path, @args ) = @_;
    my $pool = $self->_pool;
    my $sftp = $pool->acquire;
    my $ls   = eval { $sftp->ls("$path",
        wanted => sub { $_[1]->{filename} !~ /^\.\.?$/ },
        names_only => 1,
    )};
    my $err = $@;
    $pool->release($sftp);
    if ($err || $sftp->error) {
        Path::Any::Error->throw(
            op      => 'iterator',
            file    => "$path",
            err     => $err || $sftp->error,
            adapter => 'SFTP',
        );
    }
    my @entries = map { require Path::Any; Path::Any->new("$path/$_") } @{ $ls // [] };
    my $idx = 0;
    return sub { return $entries[$idx++] };
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

sub _extract_binmode {
    my ($args_ref) = @_;
    my $binmode;
    if ( @$args_ref && ref $args_ref->[0] eq 'HASH' ) {
        my $opts = shift @$args_ref;
        $binmode = $opts->{binmode};
    }
    return $binmode;
}

sub _binmode_to_encoding {
    my ($binmode) = @_;
    return 'UTF-8' if $binmode && $binmode eq ':utf8';
    return $1      if $binmode && $binmode =~ /^:encoding\((.+)\)$/;
    return undef;
}

# ---------------------------------------------------------------------------
# Capability
# ---------------------------------------------------------------------------

sub can_atomic_write { 0 }
sub can_symlink      { 0 }
sub supports_chmod   { 1 }
sub adapter_name     { 'SFTP' }

1;

__END__

=head1 NAME

Path::Any::Adapter::SFTP - SFTP adapter for Path::Any

=head1 SYNOPSIS

    use Path::Any::Adapter;
    Path::Any::Adapter->set('SFTP',
        host => 'sftp.example.com',
        user => 'deploy',
    );

=head1 DESCRIPTION

C<Path::Any::Adapter::SFTP> wraps L<Net::SFTP::Foreign> to expose the full
C<Path::Any> filesystem interface against an SFTP server.

Connections are managed by L<Path::Any::ConnectionPool> — no TCP connection
is established until the first filesystem operation.

=head1 CONSTRUCTOR OPTIONS

=over 4

=item host (required)

The SFTP hostname.

=item user (optional)

The SFTP username.  Defaults to the current OS user.

=item port (optional, default 22)

The SFTP port.

=item pool_size (optional, default 3)

Maximum number of idle connections to keep.

=item sftp_opts (optional)

Hashref of extra options passed to C<Net::SFTP::Foreign->new>.

=back

=head1 CAPABILITIES

    can_atomic_write  => 0   (writes are non-atomic)
    can_symlink       => 0
    supports_chmod    => 1

=head1 DEPENDENCIES

L<Net::SFTP::Foreign> >= 1.90 (optional — module fails at runtime with a
descriptive message if absent).

=head1 AUTHOR

Path::Any Contributors

=head1 LICENSE

Same as Perl itself.

=cut
