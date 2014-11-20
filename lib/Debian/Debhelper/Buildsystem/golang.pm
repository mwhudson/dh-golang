package Debian::Debhelper::Buildsystem::golang;

use strict;

use Data::Dumper;

use base 'Debian::Debhelper::Buildsystem';
use Debian::Debhelper::Dh_Lib;
use File::Basename qw(dirname);
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

    if (exists($ENV{DH_GOLANG_SHLIB_NAME}) || exists($ENV{DH_GOLANG_USE_SHLIBS})) {
        $this->doit_in_builddir("cp", "-rT", "/usr/share/gocode/pkg", "pkg");
    }
}

sub get_dsodir {
    chomp(my $GOOS = qx(go env GOOS));
    chomp(my $GOARCH = qx(go env GOARCH));
    return "pkg/shared_gccgo_${GOOS}_${GOARCH}"
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

sub get_build_targets {

    my $pkg;
    my $imports;
    my $libname;
    my @result;

    open (CONTROL, 'debian/control') ||
        error("cannot read debian/control: $!\n");
    while (<CONTROL>) {
        chomp;
        s/\s+$//;
        if (/^Package:\s*(.*)/) {
            $pkg=$1;
        }
        if (/^X-Go-Import-Path:\s*(.*)$/) {
            my $data = { pkg => $pkg };
            my @gopkgs = split(/\s+/, $1);
            $data->{"gopkgs"} = [ @gopkgs ];
            my ($sover) = ($pkg =~ /[^0-9]([0-9]+)$/);
            $libname = $pkg;
            $libname =~ s/[-0-9]+$//;
            $data->{"libname"} = $libname;
            ($data->{"linkername"}) = ($libname =~ /^lib(.*)$/);
            $data->{"basename"} = "$libname.so";
            $data->{"soname"} = "$libname.so.$sover";
            push @result, $data;
        }
    }
    close CONTROL;

    return @result;
}

sub build_one {
    my $this = shift;
    my $d = shift;
    my %data = %$d;

    print Dumper \%data;

    my @ldflags = ("-soname", $data{soname});
    my @gopkgs = @{$data{gopkgs}};
    my $dsodir = get_dsodir();

    for my $el (@ldflags) {
        $el = "-Wl," . $el;
    }

    my $output = qx(go list @gopkgs);
    my @targets = split(/\n/, $output);

    for my $target (@targets) {
        $this->doit_in_builddir("rm", "-f", "$dsodir/$target.dsoname");
        $this->doit_in_builddir("rm", "-f", "$dsodir/$target.gox");
    }

    $this->doit_in_builddir(
        "go", "install", "-v", "-x",
        "-libname", $data{"linkername"},
        "-compiler", "gccgo",
        "-gccgoflags", join(" ", @ldflags),
        "-buildmode=shared", @gopkgs);
    $this->doit_in_builddir("mv", "$dsodir/$data{basename}", "$dsodir/$data{soname}");
    $this->doit_in_builddir("ln", "-s", "$data{soname}", "$dsodir/$data{basename}");
}

sub build {
    my $this = shift;

    my @data = get_build_targets();

    $ENV{GOPATH} = $this->{cwd} . '/' . $this->get_builddir();

    if (@data > 0) {
        foreach my $pkg ( @data ) {
            $this->build_one(\%$pkg);
        }
    } elsif (exists($ENV{DH_GOLANG_LINK_SHARED})) {
        $this->doit_in_builddir(
            "go", "install", "-x", "-v", "-compiler", "gccgo", "-build=linkshared", @_, get_targets());
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
    my $dsodir = get_dsodir();

    my @binaries = <$builddir/bin/*>;
    if (@binaries > 0) {
        $this->doit_in_builddir('mkdir', '-p', "$destdir/usr");
        $this->doit_in_builddir('cp', '-r', 'bin', "$destdir/usr");
    }

    my @shlibs = <$builddir/$dsodir/*.so*>;

    if (@shlibs > 0) {
        my $libdir = "$destdir/usr/lib/" . dpkg_architecture_value("DEB_HOST_MULTIARCH");
        chomp($libdir);
        $this->doit_in_builddir('mkdir', '-p', $libdir);
        doit('cp', "-a", @shlibs, $libdir);
        $ENV{GOPATH} = $this->{cwd} . '/' . $this->get_builddir();
        for my $t (get_targets()) {
            my $srcd = "$dsodir/${t}.gox.dsoname";
            my $srcg = "$dsodir/${t}.gox";
            my $dest = dirname("$destdir/usr/share/gocode/$dsodir/$t");
            $this->doit_in_builddir('mkdir', '-p', $dest);
            $this->doit_in_builddir('cp', $srcd, $dest);
            $this->doit_in_builddir('cp', "$srcg", $dest);
        }
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
