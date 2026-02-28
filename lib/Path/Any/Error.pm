package Path::Any::Error;

use strict;
use warnings;

use overload
    '""'     => \&stringify,
    fallback => 1;

sub new {
    my ( $class, %args ) = @_;
    return bless {
        op      => $args{op}      // '(unknown)',
        file    => $args{file}    // '(unknown)',
        err     => $args{err}     // '(unknown)',
        adapter => $args{adapter} // '(unknown)',
    }, $class;
}

sub throw {
    my ( $class, %args ) = @_;
    die $class->new(%args);
}

sub op      { $_[0]->{op} }
sub file    { $_[0]->{file} }
sub err     { $_[0]->{err} }
sub adapter { $_[0]->{adapter} }

sub stringify {
    my ($self) = @_;
    return sprintf(
        'Path::Any::Error: op=%s file=%s adapter=%s err=%s',
        $self->{op}, $self->{file}, $self->{adapter}, $self->{err}
    );
}

1;

__END__

=head1 NAME

Path::Any::Error - Exception class for Path::Any filesystem errors

=head1 SYNOPSIS

    use Path::Any::Error;

    Path::Any::Error->throw(
        op      => 'slurp',
        file    => '/some/file',
        err     => $!,
        adapter => 'Local',
    );

    # Or catch and inspect:
    eval { ... };
    if ( my $e = $@ ) {
        if ( ref $e && $e->isa('Path::Any::Error') ) {
            warn "Failed op: ", $e->op;
            warn "On file:  ", $e->file;
        }
    }

=head1 DESCRIPTION

C<Path::Any::Error> is the exception object thrown by all C<Path::Any> adapters
when a filesystem operation fails.  It overloads stringification so it can be
used in string contexts.

=head1 METHODS

=head2 new(%args)

Constructs a new error object.  Accepts C<op>, C<file>, C<err>, and C<adapter>.

=head2 throw(%args)

Constructs and C<die>s with the error object.

=head2 op

The name of the failing operation (e.g. C<slurp>, C<spew>).

=head2 file

The path on which the operation was attempted.

=head2 err

The low-level error message (typically C<$!> or an exception string).

=head2 adapter

The adapter class name that raised the error.

=head2 stringify

Returns a human-readable error string.  Also invoked by the C<""> overload.

=head1 AUTHOR

Path::Any Contributors

=head1 LICENSE

Same as Perl itself.

=cut
