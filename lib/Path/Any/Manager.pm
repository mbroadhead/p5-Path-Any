package Path::Any::Manager;

use strict;
use warnings;
use Carp qw(croak confess);
use Scalar::Util qw(blessed);

# Singleton instance
my $instance;

sub instance {
    my ($class) = @_;
    $instance //= bless {
        stack  => [],   # [ { adapter => $obj, prefix => $str_or_undef }, ... ]
    }, $class;
    return $instance;
}

# Reset for testing
sub _reset {
    $instance = undef;
}

# ---------------------------------------------------------------------------
# set($opts_or_name, $adapter_name, %opts)
#
# Two call forms:
#   set('AdapterName', %opts)           — global adapter
#   set({prefix=>'/p'}, 'Name', %opts)  — prefix-scoped adapter
# ---------------------------------------------------------------------------

sub set {
    my ( $self, $first, @rest ) = @_;
    $self = $self->instance unless ref $self;

    my ($prefix, $adapter_name, %opts);
    if ( ref $first eq 'HASH' ) {
        $prefix       = $first->{prefix};
        $adapter_name = shift @rest;
        %opts         = @rest;
    }
    else {
        # $first IS the adapter name
        $adapter_name = $first;
        %opts         = @rest;
    }

    my $class = _resolve_class($adapter_name);
    _load_class($class);
    my $adapter = $class->new(%opts);

    # Newest-first: unshift
    unshift @{ $self->{stack} }, {
        adapter => $adapter,
        prefix  => $prefix,
    };

    return $self;
}

# ---------------------------------------------------------------------------
# remove($adapter_name_or_class)
# Removes all stack entries whose adapter class matches.
# ---------------------------------------------------------------------------

sub remove {
    my ( $self, $adapter_name ) = @_;
    $self = $self->instance unless ref $self;

    my $class = _resolve_class($adapter_name);
    @{ $self->{stack} } = grep { ref( $_->{adapter} ) ne $class } @{ $self->{stack} };
    return $self;
}

# ---------------------------------------------------------------------------
# get_adapter($path_str)
# Returns the first adapter whose prefix matches $path_str (or any adapter
# with no prefix).  Falls back to a default Local adapter if stack is empty.
# ---------------------------------------------------------------------------

sub get_adapter {
    my ( $self, $path_str ) = @_;
    $self = $self->instance unless ref $self;

    # First pass: prefix-scoped entries (newest first among matching)
    for my $entry ( @{ $self->{stack} } ) {
        my $prefix = $entry->{prefix};
        next unless defined $prefix;

        # Normalize prefix for clean prefix matching
        my $norm_prefix = $prefix;
        $norm_prefix .= '/' unless $norm_prefix =~ m{/$};
        my $norm_path  = $path_str;
        $norm_path     .= '/' unless $norm_path =~ m{/$};

        if ( index( $norm_path, $norm_prefix ) == 0 || $path_str eq $prefix ) {
            return $entry->{adapter};
        }
    }

    # Second pass: global entries (no prefix), newest first
    for my $entry ( @{ $self->{stack} } ) {
        return $entry->{adapter} unless defined $entry->{prefix};
    }

    # Default: create a Local adapter on demand
    return _default_local_adapter($self);
}

# ---------------------------------------------------------------------------
# stack — returns a copy of the current stack (for introspection / tests)
# ---------------------------------------------------------------------------

sub stack {
    my ($self) = @_;
    $self = $self->instance unless ref $self;
    return @{ $self->{stack} };
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

sub _resolve_class {
    my ($name) = @_;
    return $name if $name =~ /::/;
    return "Path::Any::Adapter::$name";
}

sub _load_class {
    my ($class) = @_;
    ( my $file = $class ) =~ s{::}{/}g;
    $file .= '.pm';
    require $file unless $INC{$file};
}

my $default_local;
sub _default_local_adapter {
    my ($self) = @_;
    unless ($default_local) {
        _load_class('Path::Any::Adapter::Local');
        $default_local = Path::Any::Adapter::Local->new;
    }
    return $default_local;
}

1;

__END__

=head1 NAME

Path::Any::Manager - Adapter stack and prefix routing for Path::Any

=head1 SYNOPSIS

    use Path::Any::Manager;

    my $mgr = Path::Any::Manager->instance;
    $mgr->set('Local');
    $mgr->set({ prefix => '/mnt/nas' }, 'SFTP', host => 'nas.example.com');

    my $adapter = $mgr->get_adapter('/mnt/nas/some/file');  # SFTP adapter
    my $local   = $mgr->get_adapter('/tmp/local/file');     # Local adapter

=head1 DESCRIPTION

C<Path::Any::Manager> is a singleton that maintains an ordered stack of
adapter entries.  Each entry may optionally carry a path prefix.

=over 4

=item *

Entries are stored newest-first; the first matching entry wins.

=item *

If an entry has no prefix, it matches any path (global fallback).

=item *

If the stack is empty, a default C<Path::Any::Adapter::Local> is returned.

=back

=head1 METHODS

=head2 instance

Returns the singleton C<Path::Any::Manager> instance.

=head2 set($opts_or_category, $adapter_name, %constructor_opts)

Adds an adapter to the top of the stack.  C<$opts_or_category> is either a
string (ignored; Log::Any compatibility) or a hashref with a C<prefix> key.

=head2 remove($adapter_name)

Removes all stack entries whose adapter class matches C<$adapter_name>.

=head2 get_adapter($path_str)

Returns the best-matching adapter for the given path string.

=head2 stack

Returns the current stack as a list of hashrefs (C<adapter>, C<prefix>).

=head1 AUTHOR

Path::Any Contributors

=head1 LICENSE

Same as Perl itself.

=cut
