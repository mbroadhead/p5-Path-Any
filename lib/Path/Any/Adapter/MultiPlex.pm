package Path::Any::Adapter::MultiPlex;

use strict;
use warnings;
use parent 'Path::Any::Adapter::Base';
use Carp qw(croak carp);
use Path::Any::Error ();
use Scalar::Util qw(blessed);

# ---------------------------------------------------------------------------
# Constructor
#
# Required: primary  => $adapter_object
# Optional: secondaries => [$a, $b, ...],
#           on_error    => 'warn' | 'croak' | 'ignore'  (default: warn)
# ---------------------------------------------------------------------------

sub new {
    my ( $class, %args ) = @_;
    croak "primary adapter is required"
        unless $args{primary} && blessed( $args{primary} );

    my $self = $class->SUPER::new(%args);
    $self->{primary}     = $args{primary};
    $self->{secondaries} = $args{secondaries} // [];
    $self->{on_error}    = $args{on_error}    // 'warn';

    # Validate
    croak "secondaries must be an arrayref"
        unless ref( $self->{secondaries} ) eq 'ARRAY';
    croak "on_error must be warn, croak, or ignore"
        unless $self->{on_error} =~ /^(?:warn|croak|ignore)$/;

    return $self;
}

# ---------------------------------------------------------------------------
# Fan-out helper: run a write operation on primary, then all secondaries
# ---------------------------------------------------------------------------

sub _fan_write {
    my ( $self, $method, @args ) = @_;

    # Primary write (always fatal on failure)
    my $result = $self->{primary}->$method(@args);

    # Secondary writes
    for my $sec ( @{ $self->{secondaries} } ) {
        eval { $sec->$method(@args) };
        if ($@) {
            my $err = $@;
            my $msg = blessed($err) ? "$err" : $err;
            if ( $self->{on_error} eq 'croak' ) {
                Path::Any::Error->throw(
                    op      => $method,
                    file    => "$args[0]",
                    err     => $msg,
                    adapter => ref($sec),
                );
            }
            elsif ( $self->{on_error} eq 'warn' ) {
                carp "Path::Any::Adapter::MultiPlex: secondary "
                   . ref($sec) . "->$method failed: $msg";
            }
            # 'ignore': discard
        }
    }

    return $result;
}

# ---------------------------------------------------------------------------
# Read methods — delegate to primary only
# ---------------------------------------------------------------------------

sub stat    { my ($self, @a) = @_; $self->{primary}->stat(@a)    }
sub lstat   { my ($self, @a) = @_; $self->{primary}->lstat(@a)   }
sub size    { my ($self, @a) = @_; $self->{primary}->size(@a)    }
sub exists  { my ($self, @a) = @_; $self->{primary}->exists(@a)  }
sub is_file { my ($self, @a) = @_; $self->{primary}->is_file(@a) }
sub is_dir  { my ($self, @a) = @_; $self->{primary}->is_dir(@a)  }

sub slurp   { my ($self, @a) = @_; $self->{primary}->slurp(@a)   }
sub lines   { my ($self, @a) = @_; $self->{primary}->lines(@a)   }

sub openr   { my ($self, @a) = @_; $self->{primary}->openr(@a)   }
sub openrw  { my ($self, @a) = @_; $self->{primary}->openrw(@a)  }

sub filehandle { my ($self, @a) = @_; $self->{primary}->filehandle(@a) }

sub realpath { my ($self, @a) = @_; $self->{primary}->realpath(@a) }
sub digest   { my ($self, @a) = @_; $self->{primary}->digest(@a)   }
sub children { my ($self, @a) = @_; $self->{primary}->children(@a) }
sub iterator { my ($self, @a) = @_; $self->{primary}->iterator(@a) }

# ---------------------------------------------------------------------------
# Write methods — fan out to primary + all secondaries
# ---------------------------------------------------------------------------

sub spew        { my ($self, @a) = @_; $self->_fan_write('spew',   @a) }
sub append      { my ($self, @a) = @_; $self->_fan_write('append', @a) }
sub touch       { my ($self, @a) = @_; $self->_fan_write('touch',  @a) }
sub mkdir       { my ($self, @a) = @_; $self->_fan_write('mkdir',  @a) }

sub openw {
    my ($self, @a) = @_;
    # Only open on primary; secondary writes aren't handle-based
    return $self->{primary}->openw(@a);
}

sub opena {
    my ($self, @a) = @_;
    return $self->{primary}->opena(@a);
}

sub chmod {
    my ($self, @a) = @_;
    return $self->_fan_write('chmod', @a);
}

sub remove {
    my ($self, @a) = @_;
    return $self->_fan_write('remove', @a);
}

sub remove_tree {
    my ($self, @a) = @_;
    return $self->_fan_write('remove_tree', @a);
}

# copy/move: cross-adapter via slurp+spew
sub copy {
    my ( $self, $src, $dest ) = @_;
    my $data = $self->{primary}->slurp($src);
    return $self->_fan_write('spew', $dest, $data);
}

sub move {
    my ( $self, $src, $dest ) = @_;
    my $result = $self->copy($src, $dest);
    $self->_fan_write('remove', $src);
    return $result;
}

# ---------------------------------------------------------------------------
# Capability — intersection of primary's capabilities
# ---------------------------------------------------------------------------

sub can_atomic_write { $_[0]->{primary}->can_atomic_write }
sub can_symlink      { $_[0]->{primary}->can_symlink      }
sub supports_chmod   { $_[0]->{primary}->supports_chmod   }
sub adapter_name     { 'MultiPlex' }

1;

__END__

=head1 NAME

Path::Any::Adapter::MultiPlex - Fan-out write adapter for Path::Any

=head1 SYNOPSIS

    use Path::Any::Adapter;
    use Path::Any::Adapter::Local;
    use Path::Any::Adapter::SFTP;

    my $local = Path::Any::Adapter::Local->new;
    my $sftp  = Path::Any::Adapter::SFTP->new(host => 'backup.example.com', user => 'backup');

    Path::Any::Adapter->set('MultiPlex',
        primary     => $local,
        secondaries => [$sftp],
        on_error    => 'warn',
    );

=head1 DESCRIPTION

C<Path::Any::Adapter::MultiPlex> fans out write operations to a primary
adapter and one or more secondary adapters.  Read operations are served by
the primary adapter only.

=head1 CONSTRUCTOR OPTIONS

=over 4

=item primary (required)

The primary adapter object (an instance of a C<Path::Any::Adapter::Base>
subclass).

=item secondaries (optional)

Arrayref of secondary adapter objects.  Default: C<[]>.

=item on_error (optional)

How to handle secondary failures.  One of C<warn> (default), C<croak>, or
C<ignore>.

=back

=head1 READ VS WRITE BEHAVIOUR

=over 4

=item *

B<Read methods> (C<stat>, C<slurp>, C<lines>, C<openr>, C<children>, etc.)
are delegated to the primary adapter only.

=item *

B<Write methods> (C<spew>, C<append>, C<touch>, C<mkdir>, C<remove>, etc.)
are applied to the primary first, then fanned out to each secondary.

=back

=head1 ERROR HANDLING

If a secondary write fails:

=over 4

=item C<warn> — emit a Carp warning and continue.

=item C<croak> — die with a C<Path::Any::Error>.

=item C<ignore> — silently discard the error.

=back

Primary failures always propagate.

=head1 AUTHOR

Path::Any Contributors

=head1 LICENSE

Same as Perl itself.

=cut
