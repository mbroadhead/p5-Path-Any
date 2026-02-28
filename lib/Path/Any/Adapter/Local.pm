package Path::Any::Adapter::Local;

use strict;
use warnings;
use parent 'Path::Any::Adapter::Base';
use Carp qw(croak);
use Path::Tiny 0.140 ();
use Path::Any::Error ();
use Scalar::Util qw(blessed);

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

sub _pt {
    my ($path) = @_;
    # Accept either a Path::Any object (which stringifies) or a plain string
    return Path::Tiny::path("$path");
}

# Wrap a Path::Tiny call, translating errors to Path::Any::Error.
# Propagates list/scalar/void context so list-returning methods work correctly.
sub _wrap {
    my ( $adapter, $op, $path, $code ) = @_;
    my $want = wantarray;
    my ( @list, $scalar );
    eval {
        if ($want) { @list  = $code->() }
        else       { $scalar = $code->() }
    };
    if ($@) {
        my $err = $@;
        die $err if blessed($err) && $err->isa('Path::Any::Error');
        my $msg = blessed($err) ? "$err" : $err;
        Path::Any::Error->throw(
            op      => $op,
            file    => "$path",
            err     => $msg,
            adapter => 'Local',
        );
    }
    return $want ? @list : $scalar;
}

# Extract binmode option from arg list
# Accepts: ({binmode => ':raw'}, ...) or (binmode => ':raw', ...)
sub _extract_binmode {
    my ($args_ref) = @_;
    my $binmode;
    if ( @$args_ref && ref $args_ref->[0] eq 'HASH' ) {
        my $opts = shift @$args_ref;
        $binmode = $opts->{binmode};
    }
    elsif ( @$args_ref >= 2 && $args_ref->[0] eq 'binmode' ) {
        shift @$args_ref;
        $binmode = shift @$args_ref;
    }
    return $binmode;
}

# ---------------------------------------------------------------------------
# Stat / existence
# ---------------------------------------------------------------------------

sub stat {
    my ( $self, $path ) = @_;
    return _wrap( $self, 'stat', $path, sub { _pt($path)->stat } );
}

sub lstat {
    my ( $self, $path ) = @_;
    return _wrap( $self, 'lstat', $path, sub { _pt($path)->lstat } );
}

sub size {
    my ( $self, $path ) = @_;
    return _wrap( $self, 'size', $path, sub { _pt($path)->size } );
}

sub exists {
    my ( $self, $path ) = @_;
    return _wrap( $self, 'exists', $path, sub { _pt($path)->exists } );
}

sub is_file {
    my ( $self, $path ) = @_;
    return _wrap( $self, 'is_file', $path, sub { _pt($path)->is_file } );
}

sub is_dir {
    my ( $self, $path ) = @_;
    return _wrap( $self, 'is_dir', $path, sub { _pt($path)->is_dir } );
}

# ---------------------------------------------------------------------------
# Read
# ---------------------------------------------------------------------------

sub slurp {
    my ( $self, $path, @args ) = @_;
    my $binmode = _extract_binmode(\@args);
    my $opts = $binmode ? { binmode => $binmode } : {};
    return _wrap( $self, 'slurp', $path, sub { _pt($path)->slurp($opts) } );
}

sub lines {
    my ( $self, $path, @args ) = @_;
    my $binmode = _extract_binmode(\@args);
    my $opts = $binmode ? { binmode => $binmode } : {};
    # Always collect in list context; return arrayref in scalar context
    my @lines = _wrap( $self, 'lines', $path, sub { _pt($path)->lines($opts) } );
    return wantarray ? @lines : \@lines;
}

# ---------------------------------------------------------------------------
# Write
# ---------------------------------------------------------------------------

sub spew {
    my ( $self, $path, $data, @args ) = @_;
    my $binmode = _extract_binmode(\@args);
    my $opts = $binmode ? { binmode => $binmode } : {};
    return _wrap( $self, 'spew', $path, sub { _pt($path)->spew($opts, $data) } );
}

sub append {
    my ( $self, $path, $data, @args ) = @_;
    my $binmode = _extract_binmode(\@args);
    my $opts = $binmode ? { binmode => $binmode } : {};
    return _wrap( $self, 'append', $path, sub { _pt($path)->append($opts, $data) } );
}

# ---------------------------------------------------------------------------
# Filehandles
# ---------------------------------------------------------------------------

sub openr {
    my ( $self, $path, @args ) = @_;
    my $binmode = _extract_binmode(\@args);
    return _wrap( $self, 'openr', $path, sub {
        $binmode ? _pt($path)->openr($binmode) : _pt($path)->openr
    });
}

sub openw {
    my ( $self, $path, @args ) = @_;
    my $binmode = _extract_binmode(\@args);
    return _wrap( $self, 'openw', $path, sub {
        $binmode ? _pt($path)->openw($binmode) : _pt($path)->openw
    });
}

sub opena {
    my ( $self, $path, @args ) = @_;
    my $binmode = _extract_binmode(\@args);
    return _wrap( $self, 'opena', $path, sub {
        $binmode ? _pt($path)->opena($binmode) : _pt($path)->opena
    });
}

sub openrw {
    my ( $self, $path, @args ) = @_;
    my $binmode = _extract_binmode(\@args);
    return _wrap( $self, 'openrw', $path, sub {
        $binmode ? _pt($path)->openrw($binmode) : _pt($path)->openrw
    });
}

sub filehandle {
    my ( $self, $path, $mode, @args ) = @_;
    my $binmode = _extract_binmode(\@args);
    return _wrap( $self, 'filehandle', $path, sub {
        $binmode ? _pt($path)->filehandle($mode, $binmode)
                 : _pt($path)->filehandle($mode)
    });
}

# ---------------------------------------------------------------------------
# Filesystem mutation
# ---------------------------------------------------------------------------

sub copy {
    my ( $self, $src, $dest ) = @_;
    return _wrap( $self, 'copy', $src, sub { _pt($src)->copy("$dest") } );
}

sub move {
    my ( $self, $src, $dest ) = @_;
    return _wrap( $self, 'move', $src, sub { _pt($src)->move("$dest") } );
}

sub remove {
    my ( $self, $path ) = @_;
    return _wrap( $self, 'remove', $path, sub { _pt($path)->remove } );
}

sub touch {
    my ( $self, $path ) = @_;
    return _wrap( $self, 'touch', $path, sub { _pt($path)->touch } );
}

sub chmod {
    my ( $self, $path, $mode ) = @_;
    return _wrap( $self, 'chmod', $path, sub { _pt($path)->chmod($mode) } );
}

sub realpath {
    my ( $self, $path ) = @_;
    return _wrap( $self, 'realpath', $path, sub { _pt($path)->realpath } );
}

sub digest {
    my ( $self, $path, @args ) = @_;
    return _wrap( $self, 'digest', $path, sub { _pt($path)->digest(@args) } );
}

# ---------------------------------------------------------------------------
# Directory operations
# ---------------------------------------------------------------------------

sub mkdir {
    my ( $self, $path ) = @_;
    return _wrap( $self, 'mkdir', $path, sub { _pt($path)->mkpath } );
}

sub remove_tree {
    my ( $self, $path ) = @_;
    return _wrap( $self, 'remove_tree', $path, sub { _pt($path)->remove_tree } );
}

sub children {
    my ( $self, $path, @args ) = @_;
    my @kids = _wrap( $self, 'children', $path, sub { _pt($path)->children(@args) } );
    return wantarray ? @kids : \@kids;
}

sub iterator {
    my ( $self, $path, @args ) = @_;
    return _wrap( $self, 'iterator', $path, sub {
        _pt($path)->iterator(@args);
    });
}

# ---------------------------------------------------------------------------
# Capability
# ---------------------------------------------------------------------------

sub can_atomic_write { 1 }
sub can_symlink      { 1 }
sub supports_chmod   { 1 }
sub adapter_name     { 'Local' }

1;

__END__

=head1 NAME

Path::Any::Adapter::Local - Local filesystem adapter for Path::Any

=head1 SYNOPSIS

    use Path::Any::Adapter;
    Path::Any::Adapter->set('Local');

=head1 DESCRIPTION

C<Path::Any::Adapter::Local> wraps L<Path::Tiny> to provide the full
C<Path::Any> filesystem interface against the local filesystem.  It is the
default adapter when no other adapter has been configured.

All C<Path::Tiny::Error> exceptions are translated to L<Path::Any::Error>.

=head1 CAPABILITIES

    can_atomic_write  => 1
    can_symlink       => 1
    supports_chmod    => 1

=head1 AUTHOR

Path::Any Contributors

=head1 LICENSE

Same as Perl itself.

=cut
