#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

my @modules = qw(
    Path::Any
    Path::Any::Adapter
    Path::Any::Adapter::Base
    Path::Any::Adapter::Local
    Path::Any::Adapter::Null
    Path::Any::Adapter::MultiPlex
    Path::Any::Manager
    Path::Any::Error
    Path::Any::Iterator
    Path::Any::ConnectionPool
    Path::Any::SFTPHandle
);

plan tests => scalar @modules;

for my $module (@modules) {
    use_ok($module) or diag "Failed to load $module";
}
