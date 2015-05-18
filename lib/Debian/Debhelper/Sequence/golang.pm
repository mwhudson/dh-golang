#!/usr/bin/perl
use warnings;
use strict;
use Debian::Debhelper::Dh_Lib;

insert_before('dh_gencontrol', 'dh_golang');
insert_before('dh_makeshlibs', 'dh_makegolangshlibs');
remove_command('dh_makeshlibs');
remove_command('dh_strip');

# XXX: -u is deprecated, but we cannot use “-- -Zxz” because additional command
# options will be appended (“-O--buildsystem=golang”), resulting in
# “dh_builddeb -- -Zxz -O--buildsystem=golang”, which fails.
add_command_options('dh_builddeb', '-u-Zxz');

1
