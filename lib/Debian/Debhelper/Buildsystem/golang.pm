package Debian::Debhelper::Buildsystem::golang;

use strict;
use base 'Debian::Debhelper::Buildsystem';
use Debian::Debhelper::Dh_Lib; 
use File::Copy; # in core since 5.002
use File::Path qw(make_path); # in core since 5.001
use File::Find; # in core since 5
use File::Spec;

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
    return $this;
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
            symlink("$src/$base", "$dst/$base");
        }
    }
}

sub _set_GOPATH {
    my $this = shift;
    $ENV{GOPATH} = $this->{cwd} . '/' . $this->get_builddir() . ':' . $this->{cwd} . '/' . $this->get_builddir() . '/shlibdeps' . ':' . $this->{cwd} . '/' . $this->get_builddir() . '/srcdeps';
}

sub configure {
    my $this = shift;

    $this->mkdir_builddir();

    my $builddir = $this->get_builddir();

    ############################################################################
    # Copy all .go files into the build directory $builddir/src/$go_package
    ############################################################################

    my $install_all = (exists($ENV{DH_GOLANG_INSTALL_ALL}) &&
                       $ENV{DH_GOLANG_INSTALL_ALL} == 1);
    my @sourcefiles;
    find({
        # Ignores ./debian entirely, but not e.g. foo/debian/debian.go
        # Ignores ./.pc (quilt) entirely.
        # Also ignores the build directory to avoid recursive copies.
        preprocess => sub {
            return @_ if $File::Find::dir ne '.';
            return grep { $_ ne 'debian' && $_ ne '.pc' && $_ ne $builddir } @_;
        },
        wanted => sub {
            my $name = $File::Find::name;
            if ($install_all) {
                # All files will be installed
            } elsif (substr($name, -3) ne '.go') {
                return;
            }
            return unless -f $name;
            # Store regexp/utf.go instead of ./regexp/utf.go
            push @sourcefiles, substr($name, 2);
        },
        no_chdir => 1,
    }, '.');

    for my $source (@sourcefiles) {
        my $dest = "$builddir/src/$ENV{DH_GOPKG}/$source";
        make_path(dirname($dest));
        # Avoid re-copying the files, this would update their timestamp and
        # make go(1) recompile them.
        next if -f $dest;
        doit("cp", "-a", $source, $dest) or error("Could not copy $source to $dest: $!");
    }

    ############################################################################
    # Symlink all available libraries from /usr/share/gocode/src into our
    # buildroot.
    ############################################################################

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
    # Therefore, we set GOPATH to have three components: $builddir, into which
    # is copied the source from the Go package being build, $builddir/shlibdeps,
    # into which is symlinked the installed libraries that are already built
    # into shared libraries and $builddir/srcdeps into which is symlinked the
    # source of installed libraries that are not already built.


    my $installed_shlib_data_dir = "/usr/lib/" . dpkg_architecture_value("DEB_HOST_MULTIARCH") . "/gocode";
    if (-d $installed_shlib_data_dir) {
        make_path("$builddir/shlibdeps/pkg");
        $this->doit_in_builddir("ln", "-sT", "$installed_shlib_data_dir/src", "shlibdeps/src");
        complex_doit("ln", "-s", "$installed_shlib_data_dir/pkg/*_dynlink", "$builddir/shlibdeps/pkg");
    }

    make_path("$builddir/srcdeps/src");
    _link_contents('/usr/share/gocode/src', "$builddir/srcdeps/src");
}

sub shlib {
    my @targets = get_targets();
    # other things will blow up if not every target has the same
    # PkgTargetRoot so let's not worry about that here.
    for my $t (@targets) {
        my $shlib = qx(go list -linkshared -f '{{ .Shlib }}' $t);
        chomp($shlib);
        if ($shlib) {
            return $shlib;
        }
    }
}

sub get_targets {
    my $buildpkg = $ENV{DH_GOLANG_BUILDPKG} || "$ENV{DH_GOPKG}/...";
    my $output = qx(go list $buildpkg);
    my @excludes = split(/ /, $ENV{DH_GOLANG_EXCLUDES});
    my @targets = split(/\n/, $output);

    # Remove all targets that are matched by one of the regular expressions in DH_GOLANG_EXCLUDES.
    for my $pattern (@excludes) {
        @targets = grep { !/$pattern/ } @targets;
    }

    return @targets;
}

sub get_libpkg_name {
    open (CONTROL, 'debian/control') ||
        error("cannot read debian/control: $!\n");

    while (<CONTROL>) {
        chomp;
        s/\s+$//;
        if (/^Package:\s*(.*)/) {
            my $pkg=$1;
            if ($pkg =~ /^lib.*[0-9]$/) {
                close CONTROL;
                return $pkg;
            }
        }
    }

    close CONTROL;
    return undef;
}

sub get_devpkg_name {
    open (CONTROL, 'debian/control') ||
        error("cannot read debian/control: $!\n");

    while (<CONTROL>) {
        chomp;
        s/\s+$//;
        if (/^Package:\s*(.*)/) {
            my $pkg=$1;
            if ($pkg =~ /-dev$/) {
                close CONTROL;
                return $pkg;
            }
        }
    }

    close CONTROL;
    return undef;
}

sub get_libname_version {
    my $pkg = get_libpkg_name();

    if (!$pkg) { return undef; }

    my ($libname, $sover) = ($pkg =~ /^lib(.*?)-?([0-9]+)$/);
    my $r = {
        "libname" => $libname,
        "sover" => $sover,
    };
    return $r;
}

sub buildX {
    if ($dh{VERBOSE}) {
        return ("-x");
    } else {
        return ();
    }
}

sub build_shared {
    my $this = shift;
    my $data = shift;

    my $libname = $data->{libname};
    my $sover = $data->{sover};

    my $soname = "lib${libname}.so.${sover}";
    # Enough quoting to blow your arm off.
    my @ldflags = ("-v -r '' -extldflags=-Wl,-soname=$soname");

    my @targets = get_targets();

    if (!$ENV{DH_GOLANG_BUILDPKG} && !$ENV{DH_GOLANG_EXCLUDES}) {
        @targets = ( "$ENV{DH_GOPKG}/..." );
    }

    # for my $target (@targets) {
    #     my $goxfile = goxfile($target);
    #     if ($goxfile && -f $goxfile) {
    #         $this->doit_in_builddir("rm", <${goxfile}*>);
    #     }
    # }

    $this->doit_in_builddir(
        "go", "install", "-v", buildX(),
        "-ldflags", join(" ", @ldflags),
        "-buildmode=shared", "-linkshared", @targets);
    my $shlib = shlib();
    my $dsodir = dirname($shlib);

    $this->doit_in_builddir("mv", "$shlib", "$dsodir/$soname");
    $this->doit_in_builddir("ln", "-s", "$soname", "$shlib");
}

sub build {
    my $this = shift;

    my $libname_version = get_libname_version();

    $this->_set_GOPATH();

    if ($dh{VERBOSE}) {
        printf("GOPATH is %s\n", $ENV{GOPATH});
    }
    
    if ($libname_version) {
        $this->build_shared($libname_version);
        $this->doit_in_builddir(
            "go", "install", buildX(), "-v", "-ldflags=-r ''", "-buildmode=exe", "-linkshared", @_, get_targets());
    } elsif (exists($ENV{DH_GOLANG_LINK_SHARED})) {
        $this->doit_in_builddir(
            "go", "install", buildX(), "-v", "-ldflags=-r ''", "-linkshared", @_, get_targets());
    } else {
        $this->doit_in_builddir("go", "install", "-v", @_, get_targets());
    }
}

sub test {
    my $this = shift;

    $this->_set_GOPATH();

    $this->doit_in_builddir("go", "test", "-v", @_, get_targets());
}

sub install {
    my $this = shift;
    my $destdir = shift;
    my $builddir = $this->get_builddir();

    $this->_set_GOPATH();

    my @binaries = <$builddir/bin/*>;

    if (@binaries > 0) {
        $this->doit_in_builddir('mkdir', '-p', "$destdir/usr");
        $this->doit_in_builddir('cp', '-r', 'bin', "$destdir/usr");
    }

    my $shlib = shlib();

    if ($shlib) {
        my $dsodir = dirname($shlib);
        my $data = get_libname_version();
        my $libname = $data->{libname};
        my $sover = $data->{sover};
        my $soname = "lib${libname}.so.${sover}";
        my $libpkgname = get_libpkg_name();
        my $finallibdir = "/usr/lib/" . dpkg_architecture_value("DEB_HOST_MULTIARCH");
        my $libdir = tmpdir($libpkgname) . $finallibdir;

        doit('mkdir', '-p', $libdir);
        doit('mv', "$dsodir/$soname", $libdir);

        $this->doit_in_builddir("ln", "-sf", "$finallibdir/$soname", "$shlib");
        my $dest_pkg = tmpdir(get_devpkg_name()) . $finallibdir . "/gocode/";
        doit('mkdir', '-p', $dest_pkg);
        $this->doit_in_builddir('cp', '-r', "pkg", "src", "../" . $dest_pkg);
    } else {
        # Path to the src/ directory within $destdir
        my $dest_src = "$destdir/usr/share/gocode/src";
        $this->doit_in_builddir('mkdir', '-p', $dest_src);
        $this->doit_in_builddir('cp', '-r', '-T', "src", $dest_src);
    }
}

sub clean {
    my $this = shift;

    $this->rmdir_builddir();
}

1
# vim:ts=4:sw=4:expandtab
