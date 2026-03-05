package Path::Any::Adapter::EncryptedOverlay;

use strict;
use warnings;
use parent 'Path::Any::Adapter::Base';
use Carp        qw(croak carp);
use File::Temp  qw(tempfile);
use Scalar::Util qw(blessed);
use Symbol       ();
use Path::Any::Error ();

# ---------------------------------------------------------------------------
# Constructor
#
# Required: inner     => $adapter_object
#           recipient => 'you@example.com'   (asymmetric, GPG key ID or email)
#       OR  passphrase => 'secret'            (symmetric)
#
# Optional: gpg_bin  => '/usr/bin/gpg'
#           gpg_home => '/path/to/.gnupg'
# ---------------------------------------------------------------------------

sub new {
    my ( $class, %args ) = @_;

    croak "inner adapter is required"
        unless $args{inner} && blessed( $args{inner} );
    croak "one of 'recipient' or 'passphrase' is required"
        unless defined $args{recipient} || defined $args{passphrase};

    $args{gpg_bin} //= _find_gpg();
    croak "gpg binary not found; install GnuPG or set gpg_bin => '/path/to/gpg'"
        unless defined $args{gpg_bin} && -x $args{gpg_bin};

    my $self = $class->SUPER::new(%args);
    $self->{inner}      = $args{inner};
    $self->{recipient}  = $args{recipient};
    $self->{passphrase} = $args{passphrase};
    $self->{gpg_bin}    = $args{gpg_bin};
    $self->{gpg_home}   = $args{gpg_home};

    return $self;
}

# ---------------------------------------------------------------------------
# GPG binary discovery
# ---------------------------------------------------------------------------

sub _find_gpg {
    for my $candidate (qw(gpg2 gpg)) {
        for my $dir ( split /:/, ( $ENV{PATH} // '' ) ) {
            my $path = "$dir/$candidate";
            return $path if -x $path;
        }
    }
    return undef;
}

# ---------------------------------------------------------------------------
# Core GPG operations
# ---------------------------------------------------------------------------

# Returns a list of base gpg arguments common to all invocations.
sub _base_args {
    my ($self) = @_;
    my @args = ( $self->{gpg_bin}, '--batch', '--yes', '--quiet', '--no-tty' );
    push @args, '--homedir', $self->{gpg_home} if $self->{gpg_home};
    return @args;
}

# Writes the passphrase to a mode-0600 temp file and returns
# the file path and the args needed to consume it.  The temp
# file is unlinked when the returned File::Temp object goes
# out of scope in the caller.
sub _passphrase_file {
    my ($self) = @_;
    my ( $fh, $file ) = tempfile( UNLINK => 1 );
    chmod 0600, $file;
    print $fh $self->{passphrase};
    close $fh;
    return ( $file, '--passphrase-file', $file, '--pinentry-mode', 'loopback' );
}

# Encrypt $plaintext and return the raw ciphertext bytes.
sub _encrypt {
    my ( $self, $plaintext ) = @_;

    # Write plaintext to a temp file so stdin can carry the passphrase fd.
    my ( $pt_fh, $pt_file ) = tempfile( UNLINK => 1 );
    binmode $pt_fh;
    print $pt_fh $plaintext;
    close $pt_fh;

    my @cmd = $self->_base_args;

    if ( defined $self->{recipient} ) {
        push @cmd, '--encrypt', '--recipient', $self->{recipient};
    }
    else {
        my ( $pp_file, @pp_args ) = $self->_passphrase_file;
        push @cmd, '--symmetric', @pp_args;
    }

    push @cmd, '--output', '-', $pt_file;

    my $ciphertext = _capture_cmd(@cmd);
    return $ciphertext;
}

# Decrypt $ciphertext and return the plaintext bytes.
sub _decrypt {
    my ( $self, $ciphertext ) = @_;

    my ( $ct_fh, $ct_file ) = tempfile( UNLINK => 1 );
    binmode $ct_fh;
    print $ct_fh $ciphertext;
    close $ct_fh;

    my @cmd = $self->_base_args;

    if ( defined $self->{passphrase} ) {
        my ( $pp_file, @pp_args ) = $self->_passphrase_file;
        push @cmd, @pp_args;
    }

    push @cmd, '--decrypt', '--output', '-', $ct_file;

    my $plaintext = _capture_cmd(@cmd);
    return $plaintext;
}

# Run @cmd, capture stdout as raw bytes, die on non-zero exit.
sub _capture_cmd {
    my (@cmd) = @_;

    my $output = '';
    open my $fh, '-|', @cmd
        or croak "Failed to exec '$cmd[0]': $!";
    binmode $fh;
    local $/;
    $output = <$fh>;
    close $fh;
    my $exit = $? >> 8;
    croak "'$cmd[0]' exited with status $exit" if $exit;
    return $output;
}

# ---------------------------------------------------------------------------
# Pass-through methods (no encryption/decryption needed)
# ---------------------------------------------------------------------------

sub stat        { my ($self,@a)=@_; $self->{inner}->stat(@a)        }
sub lstat       { my ($self,@a)=@_; $self->{inner}->lstat(@a)       }
sub exists      { my ($self,@a)=@_; $self->{inner}->exists(@a)      }
sub is_file     { my ($self,@a)=@_; $self->{inner}->is_file(@a)     }
sub is_dir      { my ($self,@a)=@_; $self->{inner}->is_dir(@a)      }
sub touch       { my ($self,@a)=@_; $self->{inner}->touch(@a)       }
sub chmod       { my ($self,@a)=@_; $self->{inner}->chmod(@a)       }
sub realpath    { my ($self,@a)=@_; $self->{inner}->realpath(@a)    }
sub mkdir       { my ($self,@a)=@_; $self->{inner}->mkdir(@a)       }
sub remove      { my ($self,@a)=@_; $self->{inner}->remove(@a)      }
sub remove_tree { my ($self,@a)=@_; $self->{inner}->remove_tree(@a) }
sub children    { my ($self,@a)=@_; $self->{inner}->children(@a)    }
sub iterator    { my ($self,@a)=@_; $self->{inner}->iterator(@a)    }

# size() reports the ciphertext size, which differs from plaintext size.
# This is intentional — it reflects what is stored.
sub size { my ($self,@a)=@_; $self->{inner}->size(@a) }

# ---------------------------------------------------------------------------
# Read with decryption
# ---------------------------------------------------------------------------

sub slurp {
    my ( $self, $path, @args ) = @_;
    my $ciphertext = eval { $self->{inner}->slurp( $path, { binmode => ':raw' } ) };
    if ($@) { die $@ }
    return $self->_decrypt($ciphertext);
}

sub lines {
    my ( $self, $path, @args ) = @_;
    my $plaintext = $self->slurp($path);
    my @lines = split /(?<=\n)/, $plaintext;
    return wantarray ? @lines : \@lines;
}

# ---------------------------------------------------------------------------
# Write with encryption
# ---------------------------------------------------------------------------

sub spew {
    my ( $self, $path, $data, @args ) = @_;
    my $ciphertext = $self->_encrypt($data);
    return $self->{inner}->spew( $path, $ciphertext, { binmode => ':raw' } );
}

sub append {
    my ( $self, $path, $data, @args ) = @_;
    my $existing = $self->{inner}->exists($path) ? $self->slurp($path) : '';
    return $self->spew( $path, $existing . $data );
}

# ---------------------------------------------------------------------------
# Filehandle operations
# ---------------------------------------------------------------------------

# openr: decrypt to an in-memory scalar, return a read handle over it.
sub openr {
    my ( $self, $path, @args ) = @_;
    my $plaintext = $self->slurp($path);
    open my $fh, '<', \$plaintext
        or croak "Cannot open in-memory read handle: $!";
    return $fh;
}

# openw: return a tied write handle that encrypts the buffer on close.
sub openw {
    my ( $self, $path ) = @_;
    my $glob = Symbol::gensym();
    tie *$glob, 'Path::Any::Adapter::EncryptedOverlay::WriteHandle',
        $self, $path, 'write';
    return $glob;
}

# opena: return a tied write handle that appends (decrypt+concat+encrypt) on close.
sub opena {
    my ( $self, $path ) = @_;
    my $glob = Symbol::gensym();
    tie *$glob, 'Path::Any::Adapter::EncryptedOverlay::WriteHandle',
        $self, $path, 'append';
    return $glob;
}

# openrw: not supportable — GPG produces a new ciphertext blob on every write,
# so random-access in-place modification is not meaningful.
sub openrw {
    my ( $self, $path ) = @_;
    croak "Path::Any::Adapter::EncryptedOverlay does not support openrw; "
        . "use slurp + spew for read-modify-write instead";
}

sub filehandle {
    my ( $self, $path, $mode, @args ) = @_;
    return $self->openr($path)  if $mode eq '<';
    return $self->openw($path)  if $mode eq '>';
    return $self->opena($path)  if $mode eq '>>';
    croak "Unsupported filehandle mode '$mode' for EncryptedOverlay";
}

# ---------------------------------------------------------------------------
# digest — operates on plaintext so callers get a content hash, not a
#          ciphertext hash (which would change on every re-encryption).
# ---------------------------------------------------------------------------

sub digest {
    my ( $self, $path, @args ) = @_;
    my $plaintext = $self->slurp($path);
    my ( $tmp_fh, $tmp_file ) = tempfile( UNLINK => 1 );
    binmode $tmp_fh;
    print $tmp_fh $plaintext;
    close $tmp_fh;

    require Path::Any::Adapter::Local;
    my $local = Path::Any::Adapter::Local->new;
    return $local->digest( $tmp_file, @args );
}

# ---------------------------------------------------------------------------
# copy / move
# ---------------------------------------------------------------------------

sub copy {
    my ( $self, $src, $dest ) = @_;
    my $plaintext = $self->slurp($src);
    return $self->spew( $dest, $plaintext );
}

sub move {
    my ( $self, $src, $dest ) = @_;
    $self->copy( $src, $dest );
    return $self->{inner}->remove($src);
}

# ---------------------------------------------------------------------------
# Capability flags
# ---------------------------------------------------------------------------

sub can_atomic_write     { 0 }
sub can_symlink          { 0 }
sub supports_chmod       { $_[0]->{inner}->supports_chmod }
sub has_real_directories { $_[0]->{inner}->has_real_directories }
sub adapter_name         { 'EncryptedOverlay' }

# ===========================================================================
# Tied filehandle for buffered write / append
# ===========================================================================

package Path::Any::Adapter::EncryptedOverlay::WriteHandle;

use Carp qw(croak carp);

sub TIEHANDLE {
    my ( $class, $adapter, $path, $mode ) = @_;
    return bless {
        adapter => $adapter,
        path    => $path,
        mode    => $mode,   # 'write' or 'append'
        buf     => '',
        closed  => 0,
    }, $class;
}

sub PRINT {
    my ( $self, @data ) = @_;
    $self->{buf} .= join( '', @data );
    return 1;
}

sub WRITE {
    my ( $self, $buf, $len, $offset ) = @_;
    $offset //= 0;
    $self->{buf} .= substr( $buf, $offset, $len );
    return $len;
}

sub CLOSE {
    my ($self) = @_;
    return 1 if $self->{closed};
    $self->{closed} = 1;

    my $adapter = $self->{adapter};
    my $path    = $self->{path};

    if ( $self->{mode} eq 'append' ) {
        $adapter->append( $path, $self->{buf} );
    }
    else {
        $adapter->spew( $path, $self->{buf} );
    }

    $self->{buf} = undef;
    return 1;
}

sub DESTROY {
    my ($self) = @_;
    return if $self->{closed} || !defined $self->{buf};
    my $ok = eval { $self->CLOSE(); 1 };
    carp "EncryptedOverlay WriteHandle: error flushing on DESTROY: $@" unless $ok;
}

1;

__END__

=head1 NAME

Path::Any::Adapter::EncryptedOverlay - Transparent GPG encryption adapter for Path::Any

=head1 SYNOPSIS

    use Path::Any::Adapter;
    use Path::Any::Adapter::Local;

    my $local = Path::Any::Adapter::Local->new;

    # Symmetric encryption (passphrase-based)
    Path::Any::Adapter->set('EncryptedOverlay',
        inner      => $local,
        passphrase => 'correct horse battery staple',
    );

    # Asymmetric encryption (GPG key)
    Path::Any::Adapter->set('EncryptedOverlay',
        inner     => $local,
        recipient => 'you@example.com',
    );

    # Custom GPG binary / home directory
    Path::Any::Adapter->set('EncryptedOverlay',
        inner      => $local,
        passphrase => 'secret',
        gpg_bin    => '/usr/local/bin/gpg2',
        gpg_home   => '/etc/myapp/gnupg',
    );

    # Use exactly like any other adapter:
    path('/secure/data.gpg')->spew("top secret\n");
    my $text = path('/secure/data.gpg')->slurp;   # "top secret\n"

=head1 DESCRIPTION

C<Path::Any::Adapter::EncryptedOverlay> is a I<decorator> adapter that wraps
any other C<Path::Any> adapter and transparently encrypts data before writing
and decrypts it after reading.  The underlying storage adapter sees only
ciphertext; calling code sees only plaintext.

Encryption is performed by shelling out to the system C<gpg> (or C<gpg2>)
binary.  Both symmetric (passphrase) and asymmetric (public-key recipient)
modes are supported.

=head2 Passphrase security

When C<passphrase> is given it is written to a mode-0600 temporary file and
passed to GPG via C<--passphrase-file>.  It is never placed on the command
line (which would expose it in the process list).

=head1 CONSTRUCTOR OPTIONS

=over 4

=item inner (required)

The adapter object that provides the actual storage backend
(C<Local>, C<S3>, C<SFTP>, etc.).

=item recipient

A GPG key ID, fingerprint, or email address for asymmetric (public-key)
encryption.  Mutually exclusive with C<passphrase>.

=item passphrase

A passphrase string for symmetric (C<--symmetric>) encryption.
Mutually exclusive with C<recipient>.

=item gpg_bin (optional)

Path to the C<gpg> or C<gpg2> binary.  Defaults to the first C<gpg2> or
C<gpg> found on C<$PATH>.

=item gpg_home (optional)

Path to a GnuPG home directory (C<--homedir>).  Defaults to GnuPG's own
default (usually C<~/.gnupg>).

=back

=head1 ENCRYPTED METHODS

=over 4

=item spew

Encrypts the supplied data before delegating to the inner adapter.

=item slurp

Reads ciphertext from the inner adapter and decrypts it.

=item lines

Decrypts then splits on newline boundaries.

=item append

Decrypts any existing content, appends the new data, re-encrypts, and
writes the result back.  This requires a full read-modify-write cycle.

=item openr

Decrypts the file and returns a read filehandle over the plaintext held
in memory.

=item openw

Returns a write filehandle whose buffer is encrypted and flushed to the
inner adapter when the handle is closed.

=item opena

Like C<openw> but the buffer is appended (via C<append>) on close.

=item openrw

Not supported.  Throws an exception with a suggestion to use
C<slurp> + C<spew> instead.

=item filehandle

Routes to C<openr> (C<< < >>), C<openw> (C<< > >>), or C<opena>
(C<<< >> >>>).

=item digest

Decrypts the file content, then computes the digest over the plaintext.
This ensures that callers get a content hash that is stable across
re-encryptions of the same data.

=item copy / move

Decrypt from source, re-encrypt to destination (via the same key/passphrase).

=back

=head1 PASS-THROUGH METHODS

The following methods are delegated directly to the inner adapter without
any encryption or decryption:

    stat lstat size exists is_file is_dir
    touch chmod realpath
    mkdir remove remove_tree children iterator

Note that C<size> returns the B<ciphertext> size, which is larger than the
plaintext size.  This is intentional — it reflects the actual bytes stored.

=head1 LIMITATIONS

=over 4

=item *

B<Symlinks are disabled.> Following a symlink to an unencrypted path on the
inner adapter would silently expose plaintext.  C<can_symlink> always returns
0.

=item *

B<No seekable random-access.> Because GPG produces an opaque blob per write,
C<openrw> is not supported.

=item *

B<Filename encryption.> This adapter does not encrypt filenames or directory
structure.  Path components remain visible to anyone who can list the inner
adapter's storage.

=item *

B<Performance.> Every read or write involves forking a C<gpg> process and
handling full-file I/O in memory.  It is not suitable for very large files.

=back

=head1 AUTHOR

Path::Any Contributors

=head1 LICENSE

Same as Perl itself.

=cut
