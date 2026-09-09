#!/usr/bin/perl
# Repack an Android boot image (header v2, with dtb) from components.
# Usage: perl tools/repack_img.pl out.img kernel ramdisk.gz dtb "cmdline" \
#          base pagesize kernel_off ramdisk_off second_off tags_off dtb_off
# Offsets relative to base; pass addresses-hex. Example values are MOA-LX9N's.
use strict; use warnings;

my ($out, $kernelf, $ramdiskf, $dtbf, $cmdline,
    $base, $page, $koff, $roff, $soff, $toff, $dtoff) = @ARGV;
die "usage\n" unless defined $dtoff;
$base = hex($base) if $base =~ /^0x/;
$page = hex($page) if $page =~ /^0x/;
$koff = hex($koff) if $koff =~ /^0x/;
$roff = hex($roff) if $roff =~ /^0x/;
$soff = hex($soff) if $soff =~ /^0x/;
$toff = hex($toff) if $toff =~ /^0x/;
$dtoff = hex($dtoff) if $dtoff =~ /^0x/;

sub slurp { open my $f,"<",$_[0] or die "$_[0]: $!"; binmode $f; local $/; my $d=<$f>; close $f; $d }
my $k = slurp($kernelf);
my $r = slurp($ramdiskf);
my $dtb = $dtbf ne "NONE" ? slurp($dtbf) : "";

my $hdr = "ANDROID!";
$hdr .= pack("V", length $k);          # kernel_size
$hdr .= pack("V", $base + $koff);      # kernel_addr
$hdr .= pack("V", length $r);          # ramdisk_size
$hdr .= pack("V", $base + $roff);      # ramdisk_addr
$hdr .= pack("V", 0);                  # second_size
$hdr .= pack("V", $base + $soff);      # second_addr
$hdr .= pack("V", $base + $toff);      # tags_addr
$hdr .= pack("V", $page);              # page_size
$hdr .= pack("V", 2);                  # header_version
$hdr .= pack("V", 0);                  # os_version
$hdr .= pack("a16", "");               # name
$hdr .= pack("a512", $cmdline);        # cmdline
$hdr .= pack("V8", (0) x 8);           # id
$hdr .= pack("a1024", "");             # extra_cmdline
$hdr .= pack("V", 0);                  # recovery_dtbo_size
$hdr .= pack("Q", 0);                  # recovery_dtbo_offset
$hdr .= pack("V", 1660);               # header_size
$hdr .= pack("V", length $dtb);        # dtb_size
$hdr .= pack("Q", $base + $dtoff);     # dtb_addr
die "header mismatch" unless length($hdr) == 1660;

open my $o, ">", $out or die $!;
binmode $o;
print $o $hdr;
print $o "\0" x ($page - length($hdr));
my $align = sub { my $pos = shift; return ($pos + $page - 1) & ~($page - 1); };
my $cur = $page;
print $o $k; $cur += length $k;
print $o "\0" x ($align->($cur) - $cur); $cur = $align->($cur);
print $o $r; $cur += length $r;
print $o "\0" x ($align->($cur) - $cur); $cur = $align->($cur);
print $o $dtb;
close $o;
printf "wrote %s (k=%d r=%d dtb=%d)\n", $out, length $k, length $r, length $dtb;
