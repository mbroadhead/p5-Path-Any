package Path::Any::Iterator;

use strict;
use warnings;

# ---------------------------------------------------------------------------
# Lazy iterator abstraction
#
# Wraps a coderef that returns the next Path::Any object or undef at
# exhaustion.  Provides a minimal interface so consumers don't have to
# know whether they have a raw coderef or an object.
# ---------------------------------------------------------------------------

sub new {
    my ( $class, $coderef ) = @_;
    return bless { code => $coderef, done => 0 }, $class;
}

# Wrap an adapter's raw iterator coderef
sub from_coderef {
    my ( $class, $coderef ) = @_;
    return $class->new($coderef);
}

# Return the next item, or undef when exhausted
sub next {
    my ($self) = @_;
    return undef if $self->{done};
    my $item = $self->{code}->();
    if ( !defined $item ) {
        $self->{done} = 1;
        return undef;
    }
    return $item;
}

# Collect all remaining items into an arrayref
sub all {
    my ($self) = @_;
    my @items;
    while ( defined( my $item = $self->next ) ) {
        push @items, $item;
    }
    return \@items;
}

# Allow use as a coderef: my $iter = ...; while (my $p = $iter->()) { ... }
use overload
    '&{}' => sub {
        my ($self) = @_;
        return sub { $self->next };
    },
    fallback => 1;

1;

__END__

=head1 NAME

Path::Any::Iterator - Lazy iterator abstraction for Path::Any directory listings

=head1 SYNOPSIS

    my $iter = Path::Any::Iterator->from_coderef($adapter->iterator($path));

    while ( defined( my $child = $iter->next ) ) {
        print $child->stringify, "\n";
    }

    # Or collect everything at once:
    my $all = $iter->all;

    # Or use as a coderef:
    while ( my $child = $iter->() ) { ... }

=head1 DESCRIPTION

C<Path::Any::Iterator> wraps a coderef iterator (as returned by adapter
C<iterator()> methods) in an object that provides C<next()> and C<all()>
convenience methods.

=head1 METHODS

=head2 new($coderef)

Wraps C<$coderef> in an iterator object.

=head2 from_coderef($coderef)

Alias for C<new>.

=head2 next

Returns the next C<Path::Any> object, or C<undef> when the listing is
exhausted.

=head2 all

Collects all remaining items and returns an arrayref.

=head1 AUTHOR

Path::Any Contributors

=head1 LICENSE

Same as Perl itself.

=cut
