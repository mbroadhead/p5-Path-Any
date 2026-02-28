package Path::Any::Adapter;

use strict;
use warnings;
use Path::Any::Manager ();

# ---------------------------------------------------------------------------
# Public API — thin delegation to the Manager singleton
# ---------------------------------------------------------------------------

sub set {
    my ( $class, @args ) = @_;
    Path::Any::Manager->instance->set(@args);
}

sub remove {
    my ( $class, @args ) = @_;
    Path::Any::Manager->instance->remove(@args);
}

sub get {
    my ( $class, $path_str ) = @_;
    Path::Any::Manager->instance->get_adapter($path_str);
}

1;

__END__

=head1 NAME

Path::Any::Adapter - Configure adapters for Path::Any

=head1 SYNOPSIS

    use Path::Any::Adapter;

    # Global default
    Path::Any::Adapter->set('Local');

    # Prefix-scoped
    Path::Any::Adapter->set({ prefix => '/mnt/nas' }, 'SFTP',
        host => 'nas.example.com',
        user => 'deploy',
    );

    # Remove an adapter class from the stack
    Path::Any::Adapter->remove('SFTP');

    # Retrieve the best adapter for a path (used internally by Path::Any)
    my $adapter = Path::Any::Adapter->get('/mnt/nas/foo.txt');

=head1 DESCRIPTION

C<Path::Any::Adapter> is the public configuration interface for
L<Path::Any>'s pluggable adapter system, modeled on L<Log::Any::Adapter>.

It is a thin shim over L<Path::Any::Manager>, which holds the actual adapter
stack.

=head1 CLASS METHODS

=head2 set($opts_or_category, $adapter_name, %constructor_opts)

Pushes a new adapter onto the global stack.

C<$opts_or_category> may be:

=over 4

=item * A string — treated as a category name (ignored; Log::Any compatibility).

=item * A hashref — may contain a C<prefix> key to scope the adapter to a
path prefix.

=back

C<$adapter_name> is either a short name (C<'Local'>, C<'SFTP'>) that is
resolved to C<Path::Any::Adapter::$name>, or a fully-qualified class name.

=head2 remove($adapter_name)

Removes all stack entries whose adapter class matches C<$adapter_name>.

=head2 get($path_str)

Returns the best-matching adapter object for C<$path_str>.  Normally called
internally by C<Path::Any>, not by application code.

=head1 SEE ALSO

L<Path::Any>, L<Path::Any::Manager>, L<Log::Any::Adapter>

=head1 AUTHOR

Path::Any Contributors

=head1 LICENSE

Same as Perl itself.

=cut
