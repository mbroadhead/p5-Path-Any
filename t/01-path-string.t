#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Spec;

use lib 'lib';
use Path::Any qw(path);
use Path::Any::Adapter;
use Path::Any::Manager;

# Use Null adapter so no filesystem is touched
Path::Any::Manager->_reset;
Path::Any::Adapter->set('Null');

# ---------------------------------------------------------------------------
# Basic construction and stringification
# ---------------------------------------------------------------------------

{
    my $p = path('/foo/bar/baz.txt');
    is("$p", '/foo/bar/baz.txt', 'stringification via overload');
    is($p->stringify, '/foo/bar/baz.txt', 'stringify()');
}

{
    my $p = path('/foo', 'bar', 'baz.txt');
    like("$p", qr{foo.bar.baz\.txt}, 'multi-part constructor joins parts');
}

# ---------------------------------------------------------------------------
# basename / volume
# ---------------------------------------------------------------------------

{
    my $p = path('/foo/bar/baz.txt');
    is($p->basename, 'baz.txt', 'basename');
    is($p->basename('.txt'), 'baz', 'basename with suffix stripped');
}

# ---------------------------------------------------------------------------
# is_absolute / is_relative
# ---------------------------------------------------------------------------

{
    my $abs = path('/absolute/path');
    ok($abs->is_absolute, 'is_absolute true for /absolute/path');
    ok(!$abs->is_relative, 'is_relative false for /absolute/path');

    my $rel = path('relative/path');
    ok(!$rel->is_absolute, 'is_absolute false for relative/path');
    ok($rel->is_relative, 'is_relative true for relative/path');
}

# ---------------------------------------------------------------------------
# parent / child / sibling
# ---------------------------------------------------------------------------

{
    my $p = path('/foo/bar/baz.txt');
    my $parent = $p->parent;
    like("$parent", qr{foo.bar}, 'parent() goes up one level');

    my $grandparent = $p->parent(2);
    like("$grandparent", qr{foo}, 'parent(2) goes up two levels');

    my $child = path('/foo/bar')->child('qux.txt');
    like("$child", qr{foo.bar.qux\.txt}, 'child() appends component');

    my $sibling = $p->sibling('other.txt');
    like("$sibling", qr{foo.bar.other\.txt}, 'sibling() stays in same dir');
}

# ---------------------------------------------------------------------------
# absolute / relative
# ---------------------------------------------------------------------------

{
    my $rel = path('foo/bar');
    my $abs = $rel->absolute('/base');
    like("$abs", qr{base.foo.bar}, 'absolute() prepends base');

    my $back = $abs->relative('/base');
    like("$back", qr{foo.bar}, 'relative() strips base');
}

# ---------------------------------------------------------------------------
# canonpath
# ---------------------------------------------------------------------------

{
    my $p = path('/foo/../foo/./bar');
    # canonpath does NOT resolve ..  on all platforms, but does clean ./
    ok(defined $p->canonpath, 'canonpath returns a string');
}

# ---------------------------------------------------------------------------
# subsumes
# ---------------------------------------------------------------------------

{
    my $parent = path('/foo/bar');
    ok($parent->subsumes('/foo/bar/baz'),  'subsumes child');
    ok($parent->subsumes('/foo/bar'),      'subsumes itself');
    ok(!$parent->subsumes('/foo/baz'),     'does not subsume sibling');
    ok(!$parent->subsumes('/foo/barbaz'),  'does not subsume false prefix match');
}

# ---------------------------------------------------------------------------
# is_rootdir
# ---------------------------------------------------------------------------

SKIP: {
    skip "root dir check is platform-specific (skip on Windows for now)", 1
        if $^O eq 'MSWin32';
    my $root = path('/');
    ok($root->is_rootdir, 'is_rootdir true for /');
}

{
    my $not_root = path('/foo');
    ok(!$not_root->is_rootdir, 'is_rootdir false for /foo');
}

# ---------------------------------------------------------------------------
# String concatenation overload
# ---------------------------------------------------------------------------

{
    my $p = path('/foo/bar');
    is("prefix_" . $p, 'prefix_/foo/bar', 'concatenation overload (left)');
    is($p . "_suffix", '/foo/bar_suffix',  'concatenation overload (right)');
}

# ---------------------------------------------------------------------------
# Comparison overload
# ---------------------------------------------------------------------------

{
    my $a = path('/foo/bar');
    my $b = path('/foo/bar');
    my $c = path('/foo/baz');
    ok($a eq $b, 'eq overload: same paths');
    ok($a ne $c, 'ne overload: different paths');
    ok($a lt $c, 'lt overload: alphabetic');
}

done_testing;
