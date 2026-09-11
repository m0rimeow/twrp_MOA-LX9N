#!/usr/bin/perl
# Overlay files onto a newc cpio ramdisk (gzipped), keeping every other entry
# verbatim:
#  - every file under <overlay_dir> replaces (keeping its mode) or is added
#    to the archive at the same relative path
#  - with <panic_on_oops> given, init.rc's "write /proc/sys/kernel/panic_on_oops"
#    is set to that value (0 keeps adb alive through a driver oops, for debugging)
# Usage: perl tools/patch_overlay.pl in.cpio.gz out.cpio.gz overlay_dir [panic_on_oops]
use strict; use warnings;
use File::Find;

my ($in, $out, $overlay, $panic) = @ARGV;
die "usage: in.cpio.gz out.cpio.gz overlay_dir [panic_on_oops]\n"
    unless $overlay && -d $overlay;
die "panic_on_oops must be 0 or 1\n" if defined $panic && $panic !~ /^[01]$/;

sub slurp { open my $f,"<",$_[0] or die "$_[0]: $!"; binmode $f; local $/; my $d=<$f>; close $f; $d }

my %ov;
find({ no_chdir => 1, wanted => sub {
    return unless -f $_;
    (my $rel = $_) =~ s{^\Q$overlay\E/}{};
    my $c = slurp($_);
    $c =~ s/\r\n/\n/g if $rel =~ /\.(rc|sh)$/;   # scripts must be LF
    $ov{$rel} = $c;
}}, $overlay);

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

my $pos = 0;
my (%seen, $patched_init);
while ($pos + 110 <= length $data) {
    my ($magic, @f) = unpack("A6(A8)13", substr($data, $pos, 110));
    die sprintf("bad magic %s at %d\n", $magic, $pos) unless $magic eq "070701";
    my ($o_ino,$mode,$uid,$gid,$nlink,$mtime,$fsize,$dmaj,$dmin,$rmaj,$rmin,$nsize,$check) = map { hex } @f;
    my $name = substr($data, $pos + 110, $nsize - 1);
    my $hlen = 110 + $nsize; $hlen += (4 - $hlen % 4) % 4;
    my $content = substr($data, $pos + $hlen, $fsize);
    $pos += $hlen + $fsize + ((4 - $fsize % 4) % 4);
    last if $name eq "TRAILER!!!";
    $seen{$name} = 1;
    if (exists $ov{$name}) {
        $content = $ov{$name};
        print "replaced $name\n";
    } elsif (defined $panic && $name eq "init.rc") {
        $content =~ s{^(\s*write /proc/sys/kernel/panic_on_oops) [01]$}{$1 $panic}m
            or die "init.rc: panic_on_oops line not found\n";
        $patched_init = 1;
        print "init.rc: panic_on_oops $panic\n";
    }
    emit($name, $mode, $content, $nlink);
}
die "init.rc not found\n" if defined $panic && !$patched_init;

for my $name (sort keys %ov) {
    next if $seen{$name};
    my @parts = split m{/}, $name;
    for my $i (0 .. $#parts - 1) {
        my $d = join "/", @parts[0 .. $i];
        emit($d, 0040755, "", 2), $seen{$d} = 1 unless $seen{$d};
    }
    emit($name, $name =~ m{^sbin/} ? 0100750 : 0100644, $ov{$name});
    print "added $name\n";
}

emit("TRAILER!!!", 0, "");
my $alld = join "", @out;
$alld .= "\0" x ((512 - length($alld) % 512) % 512);

open my $of, "|-", "gzip -9 > \"$out\"" or die "gzip out: $!";
binmode $of; print $of $alld; close $of;
printf "wrote %s (%d entries, %d bytes uncompressed)\n", $out, scalar(@out), length $alld;
