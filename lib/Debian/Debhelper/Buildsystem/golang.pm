package Debian::Debhelper::Buildsystem::golang;

use strict;
use base 'Debian::Debhelper::Buildsystem';
use Debian::Debhelper::Dh_Lib; 
use Dpkg::Control::Info;
use File::Copy; # in core since 5.002
use File::Path qw(make_path); # in core since 5.001
use File::Find; # in core since 5

sub DESCRIPTION {
    "Go"
}

sub check_auto_buildable {
    return 0
}

sub new {
    my $class = shift;
    my $this = $class->SUPER::new(@_);
    $this->prefer_out_of_source_building();
    _set_dh_gopkg();
    $this->read_shlibconfig();
    return $this;
}

sub _set_dh_gopkg {
    # If DH_GOPKG is missing, try to set it from the XS-Go-Import-Path field
    # from debian/control. If this approach works well, we will only use this
    # method in the future.
    return if defined($ENV{DH_GOPKG}) && $ENV{DH_GOPKG} ne '';

    my $control = Dpkg::Control::Info->new();
    my $source = $control->get_source();
    $ENV{DH_GOPKG} = $source->{"XS-Go-Import-Path"};
}

sub read_shlibconfig {
    my $this = shift;
    my $config = {linkshared => !!$ENV{DH_GOLANG_LINK_SHARED}};

    foreach my $pkg (getpackages("both")) {
        if ($pkg =~ /^lib(golang.*?)-?([0-9]+)$/) {
            $config->{libpkg} = $pkg;
            $config->{libname} = $1;
            $config->{sover} = $2;
            $config->{linkshared} = 1;
        } elsif ($pkg =~ /-dev$/ && !$config->{devpkg}) {
            $config->{devpkg} = $pkg;
        }
    }

    if (defined($config->{libpkg})) {
        $config->{soname} = sprintf("lib%s.so.%s", $config->{libname}, $config->{sover});
    }

    $this->{shlibconfig} = $config;
}

sub _set_gopath {
    my $this = shift;

    if ($this->{shlibconfig}->{linkshared}) {
        $ENV{GOPATH} = $this->{cwd} . '/' . $this->get_builddir() . ':' . $this->{cwd} . '/' . $this->get_builddir() . '/shlibdeps' . ':' . $this->{cwd} . '/' . $this->get_builddir() . '/srcdeps';
    } else {
        $ENV{GOPATH} = $this->{cwd} . '/' . $this->get_builddir()
    }
}

sub _link_contents {
    my ($src, $dst) = @_;

    my @contents = <$src/*>;
    # Safety-Check: We are already _in_ a Go library. Don’t copy its
    # subfolders, this has no use and potentially only screws things up.
    # This situation should never happen, unless some package ships files that
    # are already shipped in another package.
    my @gosrc = grep { /\.go$/ } @contents;
    return if @gosrc > 0;
    my @dirs = grep { -d } @contents;
    for my $dir (@dirs) {
        my $base = basename($dir);
        if (-d "$dst/$base") {
            _link_contents("$src/$base", "$dst/$base");
        } else {
            verbose_print("Symlink $src/$base -> $dst/$base");
            symlink("$src/$base", "$dst/$base");
        }
    }
}

sub configure {
    my $this = shift;

    $this->mkdir_builddir();

    my $builddir = $this->get_builddir();

    ############################################################################
    # Copy all source files into the build directory $builddir/src/$go_package
    ############################################################################

    my $install_all = (exists($ENV{DH_GOLANG_INSTALL_ALL}) &&
                       $ENV{DH_GOLANG_INSTALL_ALL} == 1);

    # By default, only files with the following extensions are installed:
    my %whitelisted_exts = (
        '.go' => 1,
        '.c' => 1,
        '.h' => 1,
        '.proto' => 1,
        '.s' => 1,
    );

    my @sourcefiles;
    find({
        # Ignores ./debian entirely, but not e.g. foo/debian/debian.go
        # Ignores ./.pc (quilt) entirely.
        # Also ignores the build directory to avoid recursive copies.
        preprocess => sub {
            return @_ if $File::Find::dir ne '.';
            return grep {
                $_ ne 'debian' &&
                $_ ne '.pc' &&
                $_ ne '.git' &&
                $_ ne $builddir
            } @_;
        },
        wanted => sub {
            # Strip “./” in the beginning of the path.
            my $name = substr($File::Find::name, 2);
            if ($install_all) {
                # All files will be installed
            } else {
                my $dot = rindex($name, ".");
                return if $dot == -1;
                return unless $whitelisted_exts{substr($name, $dot)};
            }
            return unless -f $name;
            push @sourcefiles, $name;
        },
        no_chdir => 1,
    }, '.');

    # Extra files/directories to install.
    my @install_extra = (exists($ENV{DH_GOLANG_INSTALL_EXTRA}) ?
                         split(/ /, $ENV{DH_GOLANG_INSTALL_EXTRA}) : ());

    find({
        wanted => sub {
            return unless -f $File::Find::name;
            push @sourcefiles, $File::Find::name;
        },
        no_chdir => 1,
    }, @install_extra) if(@install_extra);

    for my $source (@sourcefiles) {
        my $dest = "$builddir/src/$ENV{DH_GOPKG}/$source";
        make_path(dirname($dest));
        # Avoid re-copying the files, this would update their timestamp and
        # make go(1) recompile them.
        next if -f $dest;
        verbose_print("Copy $source -> $dest");
        copy($source, $dest) or error("Could not copy $source to $dest: $!");
    }

    ############################################################################
    # Symlink all available libraries from /usr/share/gocode/src into our
    # buildroot.
    ############################################################################

    if ($this->{shlibconfig}->{linkshared}) {
        # When building or linking against shared libraries, we must make available any
        # shared libraries that are already on the system. GOPATH is set up to have three
        # components: $builddir (for the package we are building), $builddir/shlibdeps
        # (for packages that are built into shared libraries that have already been
        # installed) and $builddir/srcdeps (for dependencies that have only been installed
        # as source). The shlibdeps component is deliberately set up so that the build
        # can't write to it.
        my $installed_shlib_data_dir = "/usr/lib/" . dpkg_architecture_value("DEB_HOST_MULTIARCH") . "/gocode";
        if (-d $installed_shlib_data_dir) {
            make_path("$builddir/shlibdeps/pkg");
            # The go tool does not allow symlinks on GOPATH, so instead of just linking
            # $builddir/shlibdeps to $installed_shlib_data_dir we put a real directory
            # there and symlink src and pkg instead.
            $this->doit_in_builddir("ln", "-sT", "$installed_shlib_data_dir/src", "shlibdeps/src");
            complex_doit("ln", "-s", "$installed_shlib_data_dir/pkg/*_dynlink", "$builddir/shlibdeps/pkg");
        }
        make_path("$builddir/srcdeps/src");
        _link_contents('/usr/share/gocode/src', "$builddir/srcdeps/src");
    } else {
        # NB: The naïve idea of just setting GOPATH=$builddir:/usr/share/gocode does
        # not work. Let’s call the two paths in $GOPATH components. go(1), when
        # installing a package, such as github.com/Debian/dcs/cmd/..., will also
        # install the compiled dependencies, e.g. github.com/mstap/godebiancontrol.
        # When such a dependency is found in a component’s src/ directory, the
        # resulting files will be stored in the same component’s pkg/ directory.
        # That is, in this example, go(1) wants to modify
        # /usr/share/gocode/pkg/linux_amd64/github.com/mstap/godebiancontrol, which
        # will obviously not succeed due to permission errors.
        #
        # Therefore, we just work with a single component that is under our control
        # and symlink all the sources into that component ($builddir).
        _link_contents('/usr/share/gocode/src', "$builddir/src");
    }
}

sub get_targets {
    my $buildpkg = $ENV{DH_GOLANG_BUILDPKG} || "$ENV{DH_GOPKG}/...";
    my @excludes = split(/ /, $ENV{DH_GOLANG_EXCLUDES});
    # If there are no excludes, just pass the form with /... to the go tool, which results
    # in a better name for the shared library when one is being created.
    if (!@excludes) {
        return ($buildpkg)
    }
    my $output = qx(go list $buildpkg);
    my @targets = split(/\n/, $output);

    # Remove all targets that are matched by one of the regular expressions in DH_GOLANG_EXCLUDES.
    for my $pattern (@excludes) {
        @targets = grep { !/$pattern/ } @targets;
    }

    return @targets;
}

# Return where the go tool thinks the shlib for our targets is.
sub go_shlib_path {
    my @targets = get_targets();
    # In principle go list doesn't have to return the same Shlib for every package in
    # @targets, but in that case the go install command would have failed.
    my @shlib = qx(go list -linkshared -f '{{ .Shlib }}' @targets);
    if (@shlib) {
        my $line = $shlib[0];
        chomp($line);
        return $line;
    }
}

sub build_shlib {
    my $this = shift;
    my $config = $this->{shlibconfig};

    my $ldflags = "-r '' -extldflags=-Wl,-soname=" . $config->{soname};

    my @targets = get_targets();

    $this->doit_in_builddir(
        "go", "install", "-v", "-ldflags", $ldflags,
        "-buildmode=shared", "-linkshared", @targets);

    my $shlib = go_shlib_path();
    my $dsodir = dirname($shlib);

    $this->doit_in_builddir("mv", "$shlib", "$dsodir/" . $config->{soname});
    $this->doit_in_builddir("ln", "-s", $config->{soname}, "$shlib");

    $this->doit_in_builddir(
        "go", "install", "-v", "-ldflags", "-r ''",
        "-buildmode=exe", "-linkshared", @targets);
}

sub build {
    my $this = shift;

    $this->_set_gopath();
    if (exists($ENV{DH_GOLANG_GO_GENERATE}) && $ENV{DH_GOLANG_GO_GENERATE} == 1) {
        $this->doit_in_builddir("go", "generate", "-v", @_, get_targets());
    }

    if ($this->{shlibconfig}->{libpkg}) {
        $this->build_shlib();
    } elsif ($this->{shlibconfig}->{linkshared}) {
        $this->doit_in_builddir(
            "go", "install", "-v", "-ldflags=-r ''", "-linkshared", @_, get_targets());
    } else {
        $this->doit_in_builddir("go", "install", "-v", @_, get_targets());
    }
}

sub test {
    my $this = shift;

    $this->_set_gopath();
    $this->doit_in_builddir("go", "test", "-v", @_, get_targets());
}

sub install {
    my $this = shift;
    my $destdir = shift;
    my $builddir = $this->get_builddir();
    my $install_source = 1;
    my $install_binaries = 1;

    while(@_) {
        if($_[0] eq '--no-source') {
            $install_source = 0;
            shift;
        } elsif($_[0] eq '--no-binaries') {
            $install_binaries = 0;
            shift;
        } else {
            error("Unknown option $_[0]");
        }
    }
    my $config = $this->{shlibconfig};

    $this->_set_gopath();

    my @binaries = <$builddir/bin/*>;
    if ($install_binaries and @binaries > 0) {
        $this->doit_in_builddir('mkdir', '-p', "$destdir/usr");
        $this->doit_in_builddir('cp', '-r', 'bin', "$destdir/usr");
    }

    if ($config->{libpkg}) {
        if (!$install_source) {
            die "Must have a source package when building shared library.";
        }
        # Here we are shuffling files about for two packages:
        # 1) The lib package, which just contains usr/lib/$triplet/$soname
        # 2) The dev package, which contains:
        #    a) the source at usr/share/gocode/src/$ENV{DH_GOPKG}
        #    b) the .a files at usr/lib/$triplet/gocode/pkg/*_dynlink/$ENV{DH_GOPKG}
        #    c) the .so symlink at usr/lib/$triplet/gocode/pkg/*_dynlink/lib${foo}.so to the lib as
        #       installed by 1) (${foo} is determined by the go tool and we do not make
        #       any assumptions about it here)
        #    d) a symlink from usr/lib/$triplet/gocode/src/$ENV{DH_GOPKG} to
        #       usr/share/gocode/src/$ENV{DH_GOPKG}
        my $solink = go_shlib_path();

        # lib package
        my $shlib = dirname($solink) . "/" . $config->{soname};
        my $final_shlib_dir = "/usr/lib/" . dpkg_architecture_value("DEB_HOST_MULTIARCH");
        my $shlibdest = tmpdir($config->{libpkg}) . $final_shlib_dir;
        doit('mkdir', '-p', $shlibdest);
        doit('mv', $shlib, $shlibdest);

        # dev package
        # a) source
        my $dest_src = tmpdir($config->{devpkg}) . "/usr/share/gocode/src/$ENV{DH_GOPKG}";
        doit('mkdir', '-p', $dest_src);
        doit('cp', '-r', '-T', "$builddir/src/$ENV{DH_GOPKG}", $dest_src);

        my $dest_lib_prefix = tmpdir($config->{devpkg}) . $final_shlib_dir . "/gocode/";
        my $goos_goarch_dynlink = basename((<$builddir/pkg/*_dynlink>)[0]);

        # b) .a files (this copies the symlink too but that will get overwritten in the next step)
        my $dest_pkg = $dest_lib_prefix . "pkg/$goos_goarch_dynlink";
        doit('mkdir', '-p', $dest_pkg);
        doit('cp', '-r', '-T', "$builddir/pkg/$goos_goarch_dynlink", $dest_pkg);

        # c) .so symlink
        my $dest_solink = $dest_lib_prefix . "pkg/$goos_goarch_dynlink/" . basename($solink);
        doit('ln', '-s', '-f', '-T', $final_shlib_dir . "/" . $config->{soname}, $dest_solink);

        # d) src symlink
        my $dest_srclink = $dest_lib_prefix . "src/$ENV{DH_GOPKG}";
        doit('mkdir', '-p', dirname($dest_srclink));
        doit('ln', '-s', '-T', "/usr/share/gocode/src/$ENV{DH_GOPKG}", $dest_srclink);
    } elsif ($install_source) {
        if ($config->{devpkg}) {
            # If there is a dev package, install files into its tmpdir directly
            # (even if there is no libpkg on this arch, there may be on another,
            # and then $destdir would be debian/tmp, not debian/$devpkg).
            $destdir = tmpdir($config->{devpkg});
        }
        # Path to the src/ directory within $destdir
        my $dest_src = "$destdir/usr/share/gocode/src/$ENV{DH_GOPKG}";
        doit('mkdir', '-p', $dest_src);
        doit('cp', '-r', '-T', "$builddir/src/$ENV{DH_GOPKG}", $dest_src);
    }
}

sub clean {
    my $this = shift;

    $this->rmdir_builddir();
}

1
# vim:ts=4:sw=4:expandtab
