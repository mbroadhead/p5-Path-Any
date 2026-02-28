package Path::Any::Adapter::Null;

use strict;
use warnings;
use parent 'Path::Any::Adapter::Base';

# ---------------------------------------------------------------------------
# All operations are no-ops or return sensible empty values.
# Useful for testing code that constructs Path::Any objects without needing
# a real filesystem.
# ---------------------------------------------------------------------------

sub stat        { return () }
sub lstat       { return () }
sub size        { return 0  }
sub exists      { return 0  }
sub is_file     { return 0  }
sub is_dir      { return 0  }

sub slurp       { return '' }
sub lines       { return wantarray ? () : [] }
sub spew        { return 1  }
sub append      { return 1  }

sub openr       { return undef }
sub openw       { return undef }
sub opena       { return undef }
sub openrw      { return undef }
sub filehandle  { return undef }

sub copy        { return 1  }
sub move        { return 1  }
sub remove      { return 1  }
sub touch       { return 1  }
sub chmod       { return 1  }
sub realpath    { return $_[1] }   # echo back the path object unchanged
sub digest      { return ''  }

sub mkdir       { return 1  }
sub remove_tree { return 1  }
sub children    { return wantarray ? () : [] }
sub iterator    {
    # Return a coderef iterator that immediately signals exhaustion
    return sub { return undef };
}

sub adapter_name     { 'Null' }
sub can_atomic_write { 0 }
sub can_symlink      { 0 }
sub supports_chmod   { 0 }

1;

__END__

=head1 NAME

Path::Any::Adapter::Null - No-op adapter for Path::Any

=head1 SYNOPSIS

    use Path::Any::Adapter;
    Path::Any::Adapter->set('Null');

=head1 DESCRIPTION

C<Path::Any::Adapter::Null> is a no-op adapter that accepts all calls and
returns empty/false values without touching any filesystem.  It is useful in
tests where you want to exercise path construction and string methods without
requiring a real filesystem backend.

=head1 AUTHOR

Path::Any Contributors

=head1 LICENSE

Same as Perl itself.

=cut
