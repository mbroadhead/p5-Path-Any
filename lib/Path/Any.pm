package Path::Any;

use strict;
use warnings;
use Carp qw(croak);
use Scalar::Util qw(blessed);
use File::Spec ();
use Path::Any::Manager ();
use Path::Any::Error ();

our $VERSION = '0.001';

# ---------------------------------------------------------------------------
# Internal slot indices
# ---------------------------------------------------------------------------
use constant {
    PATH    => 0,   # canonical stringified path
    CANON   => 1,   # File::Spec->canonpath result
    VOL     => 2,   # volume (Windows)
    DIR     => 3,   # directory portion
    FILE    => 4,   # filename portion
    ADAPTER => 5,   # adapter object
};

# ---------------------------------------------------------------------------
# Exporter
# ---------------------------------------------------------------------------
use Exporter 'import';
our @EXPORT_OK = qw(path);

sub path {
    return Path::Any->new(@_);
}

# ---------------------------------------------------------------------------
# Overloading
# ---------------------------------------------------------------------------
use overload
    '""'     => sub { $_[0]->[PATH] },
    '.'      => sub { $_[2] ? "$_[1]" . $_[0]->[PATH] : $_[0]->[PATH] . "$_[1]" },
    'cmp'    => sub { $_[2] ? "$_[1]" cmp $_[0]->[PATH] : $_[0]->[PATH] cmp "$_[1]" },
    '<=>'    => sub { $_[2] ? "$_[1]" cmp $_[0]->[PATH] : $_[0]->[PATH] cmp "$_[1]" },
    fallback => 1;

# ---------------------------------------------------------------------------
# Constructor
# ---------------------------------------------------------------------------

sub new {
    my ( $class, @parts ) = @_;
    croak "Path::Any->new requires at least one argument" unless @parts;

    # Flatten any Path::Any / Path::Tiny objects to strings
    @parts = map { blessed($_) ? "$_" : $_ } @parts;

    # Join parts (like Path::Tiny does)
    my $path;
    if ( @parts == 1 ) {
        $path = $parts[0];
    }
    else {
        $path = File::Spec->catfile(@parts);
    }

    # Normalize empty or undef
    $path = '.' unless defined $path && length $path;

    my ( $vol, $dir, $file ) = File::Spec->splitpath($path);
    my $canon = File::Spec->canonpath($path);

    my $self = bless [], $class;
    $self->[PATH]    = $path;
    $self->[CANON]   = $canon;
    $self->[VOL]     = $vol;
    $self->[DIR]     = $dir;
    $self->[FILE]    = $file;
    $self->[ADAPTER] = Path::Any::Manager->instance->get_adapter($path);

    return $self;
}

# Allow adapter to be overridden post-construction (used by tests/multiplex)
sub _set_adapter {
    my ( $self, $adapter ) = @_;
    $self->[ADAPTER] = $adapter;
    return $self;
}

# ---------------------------------------------------------------------------
# Pure string methods — no adapter involvement
# ---------------------------------------------------------------------------

sub stringify  { $_[0]->[PATH]  }
sub canonpath  { $_[0]->[CANON] }
sub volume     { $_[0]->[VOL]   }

sub basename {
    my ( $self, @suffixes ) = @_;
    my $base = $self->[FILE];
    for my $suffix (@suffixes) {
        $base =~ s/\Q$suffix\E$//;
    }
    return $base;
}

sub is_absolute { File::Spec->file_name_is_absolute( $_[0]->[PATH] ) ? 1 : 0 }
sub is_relative { $_[0]->is_absolute ? 0 : 1 }

sub is_rootdir {
    my ($self) = @_;
    my $path = $self->[CANON];
    return $path eq File::Spec->rootdir ? 1 : 0;
}

sub parent {
    my ( $self, $up ) = @_;
    $up //= 1;
    my $path = $self->[PATH];
    for ( 1 .. $up ) {
        $path = File::Spec->catpath(
            ( File::Spec->splitpath($path) )[0, 1], ''
        );
        # Remove trailing separator added by catpath
        $path = File::Spec->canonpath($path);
        # If we're already at root, stop
        last if $path eq File::Spec->rootdir
             || $path eq File::Spec->curdir;
    }
    return Path::Any->new($path);
}

sub child {
    my ( $self, @parts ) = @_;
    return Path::Any->new( $self->[PATH], @parts );
}

sub sibling {
    my ( $self, @parts ) = @_;
    return $self->parent->child(@parts);
}

sub absolute {
    my ( $self, $base ) = @_;
    return $self if $self->is_absolute;
    $base //= File::Spec->curdir;
    return Path::Any->new( File::Spec->rel2abs( $self->[PATH], "$base" ) );
}

sub relative {
    my ( $self, $base ) = @_;
    $base //= File::Spec->curdir;
    return Path::Any->new( File::Spec->abs2rel( $self->[PATH], "$base" ) );
}

sub subsumes {
    my ( $self, $other ) = @_;
    my $self_str  = $self->[CANON];
    my $other_str = blessed($other) ? $other->canonpath : File::Spec->canonpath($other);

    # Normalize trailing sep
    $self_str  =~ s{[/\\]+$}{};
    $other_str =~ s{[/\\]+$}{};

    return 1 if $self_str eq $other_str;
    return index( $other_str, $self_str . '/' ) == 0 ? 1 : 0;
}

# ---------------------------------------------------------------------------
# Filesystem methods — dispatch to adapter
# ---------------------------------------------------------------------------

# Generate thin dispatch methods for all adapter-backed operations
for my $method (qw(
    stat lstat size exists is_file is_dir
    slurp slurp_raw slurp_utf8
    lines lines_raw lines_utf8
    spew spew_raw spew_utf8
    append append_raw append_utf8
    openr openw opena openrw filehandle
    copy move remove touch chmod realpath digest
    mkdir remove_tree children iterator
)) {
    no strict 'refs';
    *{"Path::Any::$method"} = sub {
        my ( $self, @args ) = @_;
        return $self->[ADAPTER]->$method( $self, @args );
    };
}

# ---------------------------------------------------------------------------
# Capability delegation
# ---------------------------------------------------------------------------

sub can_atomic_write     { $_[0]->[ADAPTER]->can_atomic_write     }
sub can_symlink          { $_[0]->[ADAPTER]->can_symlink          }
sub supports_chmod       { $_[0]->[ADAPTER]->supports_chmod       }
sub has_real_directories { $_[0]->[ADAPTER]->has_real_directories }
sub adapter_name         { $_[0]->[ADAPTER]->adapter_name         }
sub adapter              { $_[0]->[ADAPTER]                       }

# ---------------------------------------------------------------------------
# Higher-level cross-adapter operations
# ---------------------------------------------------------------------------

sub mirror {
    my ( $self, $dest ) = @_;
    $dest = Path::Any->new("$dest")
        unless blessed($dest) && $dest->isa('Path::Any');
    _mirror_recursive( $self, $dest );
    return $dest;
}

sub _mirror_recursive {
    my ( $src, $dest ) = @_;
    if ( $src->is_dir ) {
        $dest->mkdir if $dest->has_real_directories;
        for my $child ( $src->children ) {
            my $child_obj = Path::Any->new("$child");
            _mirror_recursive( $child_obj, $dest->child( $child_obj->basename ) );
        }
    }
    elsif ( $src->is_file ) {
        $dest->parent->mkdir if $dest->has_real_directories;
        $dest->spew_raw( $src->slurp_raw );
    }
    else {
        Path::Any::Error->throw(
            op   => 'mirror',
            file => "$src",
            err  => 'source does not exist or is not a file or directory',
        );
    }
}

1;

__END__

=head1 NAME

Path::Any - Path::Tiny-compatible paths with a pluggable I/O adapter system

=head1 SYNOPSIS

    use Path::Any qw(path);
    use Path::Any::Adapter;

    # Use the local filesystem (default)
    my $p = path('/tmp/hello.txt');
    $p->spew("Hello, world!\n");
    print $p->slurp;

    # Switch globally to an SFTP backend
    Path::Any::Adapter->set('SFTP', host => 'example.com', user => 'deploy');
    my $remote = path('/var/www/index.html');
    $remote->spew($html);

    # Prefix-scoped routing
    Path::Any::Adapter->set({ prefix => '/mnt/nas' }, 'SFTP',
        host => 'nas.internal', user => 'backup');

    my $local  = path('/tmp/scratch.txt');    # Local adapter
    my $remote = path('/mnt/nas/data.csv');   # SFTP adapter

=head1 DESCRIPTION

C<Path::Any> provides the full L<Path::Tiny> filesystem API but routes all I/O
through a pluggable adapter system modeled on L<Log::Any>.  The same
path-manipulation code works against the local filesystem, a remote SFTP
server, or a fan-out multiplex of backends — without changing call sites.

=head1 EXPORTED FUNCTIONS

=head2 path(@parts)

Constructs a new C<Path::Any> object from one or more path components,
joined with the platform-native separator.  Exported on request.

=head1 PURE STRING METHODS

These methods inspect or manipulate the path string only and never call the
adapter:

    stringify  canonpath  volume  basename
    is_absolute  is_relative  is_rootdir
    parent  child  sibling  absolute  relative  subsumes

=head1 FILESYSTEM METHODS

These methods are thin dispatchers that call the same-named method on the
adapter selected at construction time:

    stat lstat size exists is_file is_dir
    slurp  slurp_raw  slurp_utf8
    lines  lines_raw  lines_utf8
    spew   spew_raw   spew_utf8
    append append_raw append_utf8
    openr  openw  opena  openrw  filehandle
    copy   move   remove  touch  chmod
    realpath  digest
    mkdir  remove_tree  children  iterator

=head1 CAPABILITY METHODS

    can_atomic_write  can_symlink  supports_chmod  adapter_name  adapter

These delegate to the underlying adapter object.

=head1 ADAPTER SELECTION

The adapter is chosen once, at C<path()> construction time, by querying
L<Path::Any::Manager>.  Prefix-scoped adapters are matched by longest
prefix; the first global (no-prefix) adapter in the stack is used as a
fallback.  If no adapter is configured, a default
L<Path::Any::Adapter::Local> is used.

=head1 SEE ALSO

L<Path::Tiny>, L<Path::Any::Adapter>, L<Path::Any::Manager>

=head1 AUTHOR

Path::Any Contributors

=head1 LICENSE

Same as Perl itself.

=cut
