package Path::Any::Adapter::S3;

use strict;
use warnings;
use parent 'Path::Any::Adapter::Base';
use Carp qw(croak);
use Path::Any::Error ();
use Symbol ();

# ---------------------------------------------------------------------------
# Constructor
#
# Required: bucket
# Optional: region (us-east-1), access_key, secret_key,
#           endpoint (MinIO URL), key_prefix, force_path_style (1)
# ---------------------------------------------------------------------------

sub new {
    my ( $class, %args ) = @_;
    croak "bucket is required" unless $args{bucket};
    $args{region} //= 'us-east-1';
    $args{force_path_style} //= 1;
    my $self = $class->SUPER::new(%args);
    $self->{_s3} = undef;  # lazy
    return $self;
}

# ---------------------------------------------------------------------------
# Lazy Paws S3 client
# ---------------------------------------------------------------------------

sub _s3 {
    my ($self) = @_;
    unless ( $self->{_s3} ) {
        unless ( $INC{'Paws.pm'} ) {
            eval { require Paws };
            if ($@) {
                die "Path::Any::Adapter::S3 requires Paws. "
                  . "Install it with: cpanm Paws\n";
            }
        }
        require Paws::Credential::Explicit;

        my $creds = Paws::Credential::Explicit->new(
            access_key => $self->{access_key} // '',
            secret_key => $self->{secret_key} // '',
        );

        my %svc_args = (
            region      => $self->{region},
            credentials => $creds,
        );
        $svc_args{endpoint}         = $self->{endpoint}         if $self->{endpoint};
        $svc_args{force_path_style} = $self->{force_path_style} if $self->{force_path_style};

        # Paws::S3 emits a "not stable" warning at load time; suppress it.
        local $SIG{__WARN__} = sub {
            warn @_ unless $_[0] =~ /not stable/i;
        };
        $self->{_s3} = Paws->service( 'S3', %svc_args );
    }
    return $self->{_s3};
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

sub _key {
    my ( $self, $path ) = @_;
    my $key = "$path";
    $key =~ s{^/+}{};
    if ( defined $self->{key_prefix} && length $self->{key_prefix} ) {
        $key = $self->{key_prefix} . '/' . $key;
    }
    return $key;
}

sub _path_from_key {
    my ( $self, $key ) = @_;
    $key =~ s{/$}{};
    if ( defined $self->{key_prefix} && length $self->{key_prefix} ) {
        my $pfx = $self->{key_prefix};
        $key =~ s{^\Q$pfx\E/}{};
    }
    return '/' . $key;
}

sub _wrap {
    my ( $self, $op, $path, $code ) = @_;
    my $want = wantarray;
    my ( @list, $scalar );
    eval {
        if ($want) { @list   = $code->() }
        else       { $scalar = $code->() }
    };
    if ($@) {
        my $err = $@;
        my $msg;
        if ( ref $err ) {
            $msg = eval { $err->message } // eval { "$err" } // '(unknown)';
        }
        else {
            $msg = $err;
        }
        Path::Any::Error->throw(
            op      => $op,
            file    => "$path",
            err     => $msg,
            adapter => 'S3',
        );
    }
    return $want ? @list : $scalar;
}

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

sub _is_404 {
    my ($err) = @_;
    return 0 unless defined $err;
    # Check Paws exception attributes (names differ by version)
    if ( ref $err ) {
        my $code = eval { $err->code }
               // eval { $err->Code }
               // '';
        my $status = eval { $err->http_status }
                  // eval { $err->status_code }
                  // eval { $err->StatusCode }
                  // 0;
        return 1 if $code   =~ /^(NoSuchKey|NotFound|404)$/i;
        return 1 if $status == 404;
    }
    # Fallback: check stringified form
    return "$err" =~ /404|NoSuchKey|NotFound/i ? 1 : 0;
}

sub _body_str {
    my ($body) = @_;
    return '' unless defined $body;
    return ref $body ? $body->to_string : $body;
}

# ---------------------------------------------------------------------------
# Stat / existence
# ---------------------------------------------------------------------------

sub stat {
    my ( $self, $path ) = @_;
    my $key = $self->_key($path);
    my $result = eval {
        my $resp = $self->_s3->HeadObject(
            Bucket => $self->{bucket},
            Key    => $key,
        );
        return {
            size  => $resp->ContentLength // 0,
            mtime => time,
        };
    };
    if ($@) {
        return undef if _is_404($@);
        my $msg = ref($@) ? ( eval { $@->message } // "$@" ) : "$@";
        Path::Any::Error->throw(
            op      => 'stat',
            file    => "$path",
            err     => $msg,
            adapter => 'S3',
        );
    }
    return $result;
}

sub lstat { goto &stat }

sub size {
    my ( $self, $path ) = @_;
    my $st = $self->stat($path);
    return defined($st) ? $st->{size} : undef;
}

sub exists {
    my ( $self, $path ) = @_;
    # Try as a direct object first
    my $st = eval { $self->stat($path) };
    return 1 if !$@ && defined $st;
    # Then check as a directory (prefix)
    return $self->is_dir($path);
}

sub is_file {
    my ( $self, $path ) = @_;
    my $key = $self->_key($path);
    return 0 if $key =~ m{/$};    # directory keys are never files
    my $result = eval {
        $self->_s3->HeadObject( Bucket => $self->{bucket}, Key => $key );
        1;
    };
    return ( $@ || !$result ) ? 0 : 1;
}

sub is_dir {
    my ( $self, $path ) = @_;
    my $key = $self->_key($path);
    $key .= '/' unless $key =~ m{/$};
    my $resp = eval {
        $self->_s3->ListObjectsV2(
            Bucket  => $self->{bucket},
            Prefix  => $key,
            MaxKeys => 1,
        );
    };
    return 0 if $@;
    return ( @{ $resp->Contents // [] } > 0
          || @{ $resp->CommonPrefixes // [] } > 0 ) ? 1 : 0;
}

# ---------------------------------------------------------------------------
# Read
# ---------------------------------------------------------------------------

sub slurp {
    my ( $self, $path, @args ) = @_;
    my $binmode = _extract_binmode( \@args );
    my $data = $self->_wrap( 'slurp', $path, sub {
        my $resp = $self->_s3->GetObject(
            Bucket => $self->{bucket},
            Key    => $self->_key($path),
        );
        return _body_str( $resp->Body );
    });
    if ( my $enc = _binmode_to_encoding($binmode) ) {
        require Encode;
        $data = Encode::decode( $enc, $data );
    }
    return $data;
}

sub lines {
    my ( $self, $path, @args ) = @_;
    my $data  = $self->slurp($path);
    my @lines = split /^/m, $data;
    return wantarray ? @lines : \@lines;
}

# ---------------------------------------------------------------------------
# Write
# ---------------------------------------------------------------------------

sub spew {
    my ( $self, $path, $data, @args ) = @_;
    my $binmode = _extract_binmode( \@args );
    $data = '' unless defined $data;
    $data = join( '', @$data ) if ref($data) eq 'ARRAY';
    if ( my $enc = _binmode_to_encoding($binmode) ) {
        require Encode;
        $data = Encode::encode( $enc, $data );
    }
    return $self->_wrap( 'spew', $path, sub {
        $self->_s3->PutObject(
            Bucket => $self->{bucket},
            Key    => $self->_key($path),
            Body   => $data,
        );
        return 1;
    });
}

sub append {
    my ( $self, $path, $data, @args ) = @_;
    _extract_binmode( \@args );
    my $existing = eval { $self->slurp($path) } // '';
    $data = '' unless defined $data;
    $data = join( '', @$data ) if ref($data) eq 'ARRAY';
    return $self->spew( $path, $existing . $data );
}

# ---------------------------------------------------------------------------
# Filehandles
# ---------------------------------------------------------------------------

sub openr {
    my ( $self, $path, @args ) = @_;
    my $data = $self->slurp($path);
    open( my $fh, '<', \$data )
        or Path::Any::Error->throw(
            op => 'openr', file => "$path", err => $!, adapter => 'S3' );
    return $fh;
}

sub openw {
    my ( $self, $path, @args ) = @_;
    my $fh = Symbol::gensym();
    tie *$fh, 'Path::Any::S3Handle',
        adapter => $self,
        path    => $path,
        mode    => 'write';
    return $fh;
}

sub opena {
    my ( $self, $path, @args ) = @_;
    my $existing = eval { $self->slurp($path) } // '';
    my $fh = Symbol::gensym();
    tie *$fh, 'Path::Any::S3Handle',
        adapter => $self,
        path    => $path,
        mode    => 'append',
        initial => $existing;
    return $fh;
}

sub openrw {
    my ( $self, $path, @args ) = @_;
    return $self->openr( $path, @args );    # S3 is not truly read-write
}

sub filehandle {
    my ( $self, $path, $mode, @args ) = @_;
    $mode //= '<';
    return $self->openr( $path, @args ) if $mode eq '<';
    return $self->openw( $path, @args ) if $mode eq '>';
    return $self->opena( $path, @args ) if $mode eq '>>';
    return $self->openr( $path, @args );    # +< / +> fall back to read
}

# ---------------------------------------------------------------------------
# Filesystem mutation
# ---------------------------------------------------------------------------

sub copy {
    my ( $self, $src, $dest ) = @_;
    return $self->_wrap( 'copy', $src, sub {
        my $src_key  = $self->_key($src);
        my $dest_key = $self->_key($dest);
        $self->_s3->CopyObject(
            Bucket     => $self->{bucket},
            Key        => $dest_key,
            CopySource => $self->{bucket} . '/' . $src_key,
        );
        return 1;
    });
}

sub move {
    my ( $self, $src, $dest ) = @_;
    $self->copy( $src, $dest );
    return $self->remove($src);
}

sub remove {
    my ( $self, $path ) = @_;
    return $self->_wrap( 'remove', $path, sub {
        $self->_s3->DeleteObject(
            Bucket => $self->{bucket},
            Key    => $self->_key($path),
        );
        return 1;
    });
}

sub touch {
    my ( $self, $path ) = @_;
    return $self->_wrap( 'touch', $path, sub {
        my $key = $self->_key($path);
        my $exists = eval {
            $self->_s3->HeadObject( Bucket => $self->{bucket}, Key => $key );
            1;
        };
        unless ( $exists && !$@ ) {
            $self->_s3->PutObject(
                Bucket => $self->{bucket},
                Key    => $key,
                Body   => '',
            );
        }
        return 1;
    });
}

sub chmod { return 1 }    # no-op: S3 has no POSIX permissions

sub realpath {
    my ( $self, $path ) = @_;
    return "$path";
}

sub digest {
    my ( $self, $path, $algo ) = @_;
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
    return $self->_wrap( 'mkdir', $path, sub {
        my $key = $self->_key($path);
        $key .= '/' unless $key =~ m{/$};
        $self->_s3->PutObject(
            Bucket => $self->{bucket},
            Key    => $key,
            Body   => '',
        );
        return 1;
    });
}

sub remove_tree {
    my ( $self, $path ) = @_;
    return $self->_wrap( 'remove_tree', $path, sub {
        my $key = $self->_key($path);
        $key .= '/' unless $key =~ m{/$};

        my $token;
        my @keys;

        do {
            my %args = ( Bucket => $self->{bucket}, Prefix => $key );
            $args{ContinuationToken} = $token if $token;

            my $resp = $self->_s3->ListObjectsV2(%args);

            for my $item ( @{ $resp->Contents // [] } ) {
                push @keys, $item->Key;
            }

            $token = $resp->IsTruncated ? $resp->NextContinuationToken : undef;
        } while ($token);

        push @keys, $key;    # include the directory marker itself

        for my $k (@keys) {
            eval {
                $self->_s3->DeleteObject(
                    Bucket => $self->{bucket},
                    Key    => $k,
                );
            };
        }

        return 1;
    });
}

sub children {
    my ( $self, $path, @args ) = @_;
    my @kids = $self->_wrap( 'children', $path, sub {
        my $key = $self->_key($path);
        $key .= '/' unless $key =~ m{/$};

        my $resp = $self->_s3->ListObjectsV2(
            Bucket    => $self->{bucket},
            Prefix    => $key,
            Delimiter => '/',
        );

        my @children;

        for my $prefix ( @{ $resp->CommonPrefixes // [] } ) {
            my $p     = $prefix->Prefix;
            my $cpath = $self->_path_from_key($p);
            require Path::Any;
            push @children, Path::Any->new($cpath);
        }

        for my $item ( @{ $resp->Contents // [] } ) {
            my $k = $item->Key;
            next if $k eq $key;    # skip the directory marker
            my $cpath = $self->_path_from_key($k);
            require Path::Any;
            push @children, Path::Any->new($cpath);
        }

        return @children;
    });
    return wantarray ? @kids : \@kids;
}

sub iterator {
    my ( $self, $path, @args ) = @_;
    my $entries = [ $self->children($path) ];    # list context → real list
    my $idx = 0;
    return sub { return $entries->[$idx++] };
}

# ---------------------------------------------------------------------------
# Capability
# ---------------------------------------------------------------------------

sub can_atomic_write { 0 }
sub can_symlink      { 0 }
sub supports_chmod   { 0 }
sub adapter_name     { 'S3' }

# ===========================================================================
# Path::Any::S3Handle — tied filehandle for buffered writes to S3
# ===========================================================================

package Path::Any::S3Handle;

sub TIEHANDLE {
    my ( $class, %args ) = @_;
    return bless {
        buf     => '',
        initial => $args{initial} // '',
        adapter => $args{adapter},
        path    => $args{path},
        mode    => $args{mode} // 'write',
        closed  => 0,
    }, $class;
}

sub PRINT {
    my ( $self, @data ) = @_;
    my $sep = defined($,) ? $, : '';
    my $end = defined($\) ? $\ : '';
    $self->{buf} .= join( $sep, @data ) . $end;
    return 1;
}

sub PRINTF {
    my ( $self, $fmt, @args ) = @_;
    $self->{buf} .= sprintf( $fmt, @args );
    return 1;
}

sub WRITE {
    my ( $self, $buf, $len, $offset ) = @_;
    $offset //= 0;
    $self->{buf} .= substr( $buf, $offset, $len );
    return $len;
}

sub READLINE { return undef }
sub GETC     { return undef }
sub READ     { return 0 }
sub EOF      { return 1 }

sub CLOSE {
    my ($self) = @_;
    return 1 if $self->{closed};
    $self->{closed} = 1;
    my $content = $self->{initial} . $self->{buf};
    $self->{adapter}->spew( $self->{path}, $content );
    return 1;
}

sub DESTROY {
    my ($self) = @_;
    $self->CLOSE unless $self->{closed};
}

1;

__END__

=head1 NAME

Path::Any::Adapter::S3 - Paws-based S3 adapter for Path::Any

=head1 SYNOPSIS

    use Path::Any::Adapter;

    Path::Any::Adapter->set('S3',
        bucket     => 'my-bucket',
        region     => 'us-east-1',
        access_key => $ENV{AWS_ACCESS_KEY_ID},
        secret_key => $ENV{AWS_SECRET_ACCESS_KEY},
    );

    # With MinIO:
    Path::Any::Adapter->set('S3',
        bucket     => 'path-any-test',
        endpoint   => 'http://localhost:9000',
        access_key => 'minioadmin',
        secret_key => 'minioadmin123',
        key_prefix => 'xt-test',
    );

=head1 DESCRIPTION

C<Path::Any::Adapter::S3> wraps L<Paws> to expose the full C<Path::Any>
filesystem interface against an S3-compatible object store (AWS S3, MinIO, etc.).

The Paws library is loaded lazily — the module will compile without it, but
the first filesystem operation will fail with a descriptive error if Paws is
not installed.

=head1 CONSTRUCTOR OPTIONS

=over 4

=item bucket (required)

The S3 bucket name.

=item region (optional, default us-east-1)

The AWS region (or the region string expected by the S3-compatible store).

=item access_key / secret_key (optional)

Explicit credentials.  If omitted, Paws falls back to the usual AWS credential
chain (environment variables, ~/.aws/credentials, instance profile, etc.).

=item endpoint (optional)

Custom endpoint URL, e.g. C<http://localhost:9000> for MinIO.

=item key_prefix (optional)

A prefix prepended to every S3 key, allowing multiple logical namespaces
within a single bucket.  Example: C<'xt-test'> makes C</foo.txt> resolve to
the key C<xt-test/foo.txt>.

=item force_path_style (optional, default 1)

Passed through to the Paws S3 service constructor.  Required for MinIO and
other path-style-only stores.

=back

=head1 CAPABILITIES

    can_atomic_write  => 0   (PutObject is atomic but not rename-based)
    can_symlink       => 0
    supports_chmod    => 0   (chmod is a no-op that always returns 1)

=head1 VIRTUAL DIRECTORIES

S3 has no real directories.  This adapter models directories as empty objects
whose keys end with C</> (the common S3 convention).  C<mkdir> creates such a
marker object; C<is_dir> checks for its existence or for objects sharing the
key prefix; C<remove_tree> deletes all objects under the prefix.

=head1 WRITE FILEHANDLES

C<openw> and C<opena> return filehandles backed by C<Path::Any::S3Handle>,
an in-memory tied filehandle.  Data is accumulated in a buffer and flushed
to S3 via C<PutObject> when the filehandle is closed.

=head1 DEPENDENCIES

L<Paws> (optional — loaded lazily at runtime with a descriptive error if absent).

=head1 AUTHOR

Path::Any Contributors

=head1 LICENSE

Same as Perl itself.

=cut
