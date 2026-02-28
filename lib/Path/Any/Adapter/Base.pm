package Path::Any::Adapter::Base;

use strict;
use warnings;
use Carp qw(croak);

# ---------------------------------------------------------------------------
# Required interface — subclasses MUST override these
# ---------------------------------------------------------------------------

my @REQUIRED = qw(
    stat lstat size exists is_file is_dir
    slurp lines spew append
    openr openw opena openrw filehandle
    copy move remove touch chmod realpath digest
    mkdir remove_tree children iterator
);

for my $method (@REQUIRED) {
    no strict 'refs';
    *{"Path::Any::Adapter::Base::$method"} = sub {
        my $self = shift;
        croak ref($self) . " does not implement required method '$method'";
    };
}

# ---------------------------------------------------------------------------
# Binmode convenience wrappers — delegate to the base form with options
# ---------------------------------------------------------------------------

sub slurp_raw  { my ($self,$path,@a) = @_; $self->slurp($path, {binmode=>':raw'},      @a) }
sub slurp_utf8 { my ($self,$path,@a) = @_; $self->slurp($path, {binmode=>':encoding(UTF-8)'}, @a) }

sub lines_raw  { my ($self,$path,@a) = @_; $self->lines($path, {binmode=>':raw'},      @a) }
sub lines_utf8 { my ($self,$path,@a) = @_; $self->lines($path, {binmode=>':encoding(UTF-8)'}, @a) }

sub spew_raw   { my ($self,$path,$data,@a) = @_; $self->spew($path, $data, {binmode=>':raw'},      @a) }
sub spew_utf8  { my ($self,$path,$data,@a) = @_; $self->spew($path, $data, {binmode=>':encoding(UTF-8)'}, @a) }

sub append_raw  { my ($self,$path,$data,@a) = @_; $self->append($path, $data, {binmode=>':raw'},      @a) }
sub append_utf8 { my ($self,$path,$data,@a) = @_; $self->append($path, $data, {binmode=>':encoding(UTF-8)'}, @a) }

# ---------------------------------------------------------------------------
# Capability introspection
# ---------------------------------------------------------------------------

sub can_atomic_write { 0 }
sub can_symlink      { 0 }
sub supports_chmod   { 1 }
sub adapter_name     { ref $_[0] }

# ---------------------------------------------------------------------------
# Constructor
# ---------------------------------------------------------------------------

sub new {
    my ( $class, %args ) = @_;
    return bless {%args}, $class;
}

1;

__END__

=head1 NAME

Path::Any::Adapter::Base - Abstract base class for Path::Any adapters

=head1 SYNOPSIS

    package My::Adapter;
    use parent 'Path::Any::Adapter::Base';

    sub stat   { ... }
    sub slurp  { ... }
    # ... implement all required methods

=head1 DESCRIPTION

C<Path::Any::Adapter::Base> defines the interface that every Path::Any adapter
must satisfy.  It provides:

=over 4

=item *

Stub implementations of all required methods that C<croak> with a clear
message if not overridden.

=item *

Default binmode wrappers (C<slurp_raw>, C<slurp_utf8>, etc.) that call the
base method with an appropriate C<binmode> option — subclasses only need to
implement the base form and handle the option.

=item *

Capability introspection methods with conservative defaults.

=back

=head1 REQUIRED METHODS

Subclasses must override:

    stat lstat size exists is_file is_dir
    slurp lines spew append
    openr openw opena openrw filehandle
    copy move remove touch chmod realpath digest
    mkdir remove_tree children iterator

=head1 CAPABILITY METHODS

=head2 can_atomic_write

Returns true if the adapter can write atomically (rename-based).  Default: 0.

=head2 can_symlink

Returns true if the adapter supports symlinks.  Default: 0.

=head2 supports_chmod

Returns true if the adapter supports chmod.  Default: 1.

=head2 adapter_name

Returns a human-readable name for the adapter.  Default: C<ref($self)>.

=head1 AUTHOR

Path::Any Contributors

=head1 LICENSE

Same as Perl itself.

=cut
