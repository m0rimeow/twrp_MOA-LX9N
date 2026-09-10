#!/usr/bin/perl
# Patch a newc cpio ramdisk (gzipped) without unpacking:
#  - copies every original entry verbatim (preserves modes/devnodes/symlinks)
#  - replaces init.rc and aptouch_daemon.rc with patched content
#  - injects the Huawei THP touch stack (aptouch_daemon, tpd, libthp*, 32-bit libs)
# Usage: perl tools/patch_ramdisk.pl in.cpio.gz out.cpio.gz <device_tree_recovery_root>
use strict; use warnings;

my ($in, $out, $root) = @ARGV;
die "usage: in.cpio.gz out.cpio.gz recovery_root_dir\n" unless $root;

sub slurp { open my $f,"<",$_[0] or die "$_[0]: $!"; binmode $f; local $/; my $d=<$f>; close $f; $d }

open my $if, "-|", "gzip -dc \"$in\"" or die "gzip: $!";
binmode $if; local $/; my $data = <$if>; close $if;
die "empty input\n" unless $data;

my $ino = 1000;
my @out;

sub emit {
    my ($name, $mode, $content, $nlink) = @_;
    my $nsize = length($name) + 1;
    my $h = sprintf("070701%08x%08x%08x%08x%08x%08x%08x%08x%08x%08x%08x%08x%08x",
        $ino++, $mode, 0, 0, $nlink // 1, 0, length($content), 0, 0, 0, 0, $nsize, 0);
    my $s = $h . $name . "\0";
    $s .= "\0" x ((4 - length($s) % 4) % 4);
    $s .= $content;
    $s .= "\0" x ((4 - length($content) % 4) % 4);
    push @out, $s;
}

my $aptouch_rc = <<'EOF';
#tp hostprocessing daemon
service aptouch /system/vendor/bin/aptouch_daemon
    user root
    group root
    setenv LD_LIBRARY_PATH /system/lib:/system/vendor/lib

on boot
    start aptouch

on property:thp.service_enable=1
    start aptouch

on property:thp.service_enable=0
    stop aptouch
EOF

my $pos = 0;
my (%seen, $patched_init, $patched_rc);
while ($pos + 110 <= length $data) {
    my $hdr = substr($data, $pos, 110);
    my ($magic, @f) = unpack("A6(A8)13", $hdr);
    $magic = hex $magic;
    die sprintf("bad magic %06x at %d\n", $magic, $pos) unless $magic == 0x070701;
    my ($o_ino,$mode,$uid,$gid,$nlink,$mtime,$fsize,$dmaj,$dmin,$rmaj,$rmin,$nsize,$check) = map { hex } @f;
    my $name = substr($data, $pos + 110, $nsize - 1);
    my $hlen = 110 + $nsize; $hlen += (4 - $hlen % 4) % 4;
    my $dstart = $pos + $hlen;
    my $content = substr($data, $dstart, $fsize);
    $pos = $dstart + $fsize + ((4 - $fsize % 4) % 4);
    last if $name eq "TRAILER!!!";
    $seen{$name} = 1;
    if ($name eq "init.rc") {
        $content =~ s{^(import /init\.recovery\.his\.rc)$}{$1\nimport /aptouch_daemon.rc}m
            or die "init.rc: import anchor not found\n";
        $patched_init = 1;
    } elsif ($name eq "aptouch_daemon.rc") {
        $content = $aptouch_rc;
        $patched_rc = 1;
    }
    emit($name, $mode, $content, $nlink);
}
die "init.rc not found\n" unless $patched_init;
warn "note: no aptouch_daemon.rc in original, adding fresh\n" unless $patched_rc;

# --- inject touch stack ---
my $dir = sub { my $n = shift; emit($n, 0040755, "", 2) unless $seen{$n} };
$dir->("vendor"); $dir->("vendor/bin"); $dir->("vendor/lib"); $dir->("vendor/firmware");
$dir->("system/bin"); $dir->("system/lib");

my $addfile = sub {
    my ($src, $dst, $mode) = @_;
    die "$src missing\n" unless -f $src;
    die "$dst already in archive\n" if $seen{$dst};
    emit($dst, $mode, slurp($src));
    $seen{$dst} = 1;
};

for my $f (qw(aptouch_daemon tpd)) {
    $addfile->("$root/vendor/bin/$f", "vendor/bin/$f", 0100755);
}
for my $f (glob("$root/vendor/lib/*.so")) {
    my ($n) = $f =~ m{([^/]+)$};
    $addfile->($f, "vendor/lib/$n", 0100644);
}
for my $f (glob("$root/vendor/firmware/*")) {
    my ($n) = $f =~ m{([^/]+)$};
    $addfile->($f, "vendor/firmware/$n", 0100644);
}
$addfile->("$root/system/bin/linker", "system/bin/linker", 0100755);
for my $f (glob("$root/system/lib/*.so")) {
    my ($n) = $f =~ m{([^/]+)$};
    $addfile->($f, "system/lib/$n", 0100644);
}
# symlink /system/vendor -> /vendor (stock layout; rc uses /system/vendor/...)
emit("system/vendor", 0120777, "/vendor") unless $seen{"system/vendor"};
# fresh aptouch rc if the archive didn't carry one
emit("aptouch_daemon.rc", 0100644, $aptouch_rc) unless $patched_rc;

# trailer + block pad
emit("TRAILER!!!", 0, "");
my $alld = join "", @out;
$alld .= "\0" x ((512 - length($alld) % 512) % 512);

open my $of, "|-", "gzip -9 > \"$out\"" or die "gzip out: $!";
binmode $of; print $of $alld; close $of;
printf "wrote %s (%d entries, %d bytes uncompressed)\n", $out, scalar(@out), length $alld;
