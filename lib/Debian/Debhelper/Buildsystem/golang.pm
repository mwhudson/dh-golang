package Debian::Debhelper::Buildsystem::golang;

use strict;
use base 'Debian::Debhelper::Buildsystem';
use Debian::Debhelper::Dh_Lib; 
use File::Copy; # in core since 5.002
use File::Path qw(make_path); # in core since 5.001
use File::Find; # in core since 5
use Cwd ();

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
        copy($source, $dest) or error("Could not copy $source to $dest: $!");
    }

    ############################################################################
    # Symlink all available libraries from /usr/share/gocode/src into our
    # buildroot.
    ############################################################################

    # NB: The naïve idea of just setting GOPATH=$builddir:/usr/share/godoc does
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

    if (exists($ENV{DH_GOLANG_SHLIB_NAME})) {
        _link_contents('/usr/share/gocode/pkg', "$builddir/pkg");
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

sub build {
    my $this = shift;
    my $builddir = $this->get_builddir();

    $ENV{GOPATH} = $this->{cwd} . '/' . $this->get_builddir();
    if (exists($ENV{DH_GOLANG_SHLIB_NAME})) {
        my $basesoname = "lib$ENV{DH_GOLANG_SHLIB_NAME}.so.$ENV{DH_GOLANG_SHLIB_ABIREV}";
        my $fullsoname = Cwd::abs_path("$builddir/$basesoname.$ENV{DH_GOLANG_SHLIB_SUBREV}");
        my @ldflags = ("-o", $fullsoname, "-soname", $basesoname);
        for my $el (@ldflags) {
            $el = "-Wl," . $el;
        }
        $this->doit_in_builddir(
            "go", "install", "-v", "-x",
            "-compiler", "gccgo",
            "-gccgoflags", join(" ", @ldflags),
            "-buildmode=shared", @_, get_targets());
        $this->doit_in_builddir("ln", "-s", "$basesoname.$ENV{DH_GOLANG_SHLIB_SUBREV}", $basesoname);
        $this->doit_in_builddir(
            "go", "install", "-x", "-v", "-buildmode=exe", "-compiler", "gccgo", "-linkshared", @_, get_targets());
    } else {
        $this->doit_in_builddir("go", "install", "-v", @_, get_targets());
    }
}

sub test {
    my $this = shift;

    $ENV{GOPATH} = $this->{cwd} . '/' . $this->get_builddir();
    $this->doit_in_builddir("go", "test", "-v", @_, get_targets());
}

sub install {
    my $this = shift;
    my $destdir = shift;
    my $builddir = $this->get_builddir();

    my @binaries = <$builddir/bin/*>;
    if (@binaries > 0) {
        $this->doit_in_builddir('mkdir', '-p', "$destdir/usr");
        $this->doit_in_builddir('cp', '-r', 'bin', "$destdir/usr");
    }

    my @shlibs = <$builddir/*.so.*>;

    if (@shlibs > 0) {
        my $libdir = "$destdir/usr/lib/" . qx(dpkg-architecture -qDEB_HOST_GNU_TYPE);
        chomp($libdir);
        $this->doit_in_builddir('mkdir', '-p', $libdir);
        doit('cp', "-a", @shlibs, $libdir);
        # XXX need to copy dso markers
    }

    # Path to the src/ directory within $destdir
    my $dest_src = "$destdir/usr/share/gocode/src/$ENV{DH_GOPKG}";
    $this->doit_in_builddir('mkdir', '-p', $dest_src);
    $this->doit_in_builddir('cp', '-r', '-T', "src/$ENV{DH_GOPKG}", $dest_src);
}

sub clean {
    my $this = shift;

    $this->rmdir_builddir();
}

1
# vim:ts=4:sw=4:expandtab
