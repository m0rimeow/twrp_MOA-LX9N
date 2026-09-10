#!/usr/bin/perl
# Pack a ramdisk-only Android boot image (header v0, no kernel/dtb).
# This matches the format the Honor 9A (MOA-LX9N) expects in the
# recovery_ramdisk partition (verified against a known-working image:
# base 0x10000000, page 2048, ramdisk @ +0x1000000, tags @ +0x100).
# Usage: perl tools/pack_ramdisk_img.pl out.img ramdisk.cpio.gz "cmdline" base pagesize ramdisk_off tags_off
use strict; use warnings;
use Digest::SHA qw(sha1);

my ($out, $ramdiskf, $cmdline, $base, $page, $roff, $toff) = @ARGV;
die "usage: out ramdisk cmdline base pagesize ramdisk_off tags_off\n" unless defined $toff;
$base = hex($base) if $base =~ /^0x/;
$page = hex($page) if $page =~ /^0x/;
$roff = hex($roff) if $roff =~ /^0x/;
$toff = hex($toff) if $toff =~ /^0x/;

sub slurp { open my $f,"<",$_[0] or die "$_[0]: $!"; binmode $f; local $/; my $d=<$f>; close $f; $d }
my $r = slurp($ramdiskf);

my $hdr = "ANDROID!";
$hdr .= pack("V", 0);                  # kernel_size
$hdr .= pack("V", $base + 0x8000);     # kernel_addr
$hdr .= pack("V", length $r);          # ramdisk_size
$hdr .= pack("V", $base + $roff);      # ramdisk_addr
$hdr .= pack("V", 0);                  # second_size
$hdr .= pack("V", $base + 0xf00000);   # second_addr
$hdr .= pack("V", $base + $toff);      # tags_addr
$hdr .= pack("V", $page);              # page_size
$hdr .= pack("V", 0);                  # header_version (v0)
$hdr .= pack("V", 0x10040121);         # os_version (matches stock/working image)
$hdr .= pack("a16", "");               # name
$hdr .= pack("a512", $cmdline);        # cmdline
$hdr .= sha1($r);                      # id = SHA1 over kernel(empty)+ramdisk+second(empty)
# header v0 ends here (608 bytes), page-pad follows

open my $o, ">", $out or die $!;
binmode $o;
print $o $hdr;
print $o "\0" x ($page - length($hdr));
print $o $r;
close $o;
printf "wrote %s (ramdisk=%d)\n", $out, length $r;
