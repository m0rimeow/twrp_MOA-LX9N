#!/usr/bin/perl
# Convert Android sparse image to raw. Usage: perl tools/simg2raw.pl super.img super.raw
use strict; use warnings;

my ($in, $out) = @ARGV or die "usage: $0 sparse.img out.raw\n";
open my $ifh, "<", $in or die $!;
binmode $ifh;
open my $ofh, ">", $out or die $!;
binmode $ofh;

my $hdr; read($ifh, $hdr, 28) == 28 or die "short header";
my ($magic, $maj, $min, $fhsz, $chsz, $blksz, $tblk, $tchunk) = unpack("VvvvvVVV", $hdr);
die sprintf("bad magic 0x%08x (not sparse)\n", $magic) unless $magic == 0xed26ff3a;
seek($ifh, $fhsz, 0);
printf "sparse: blksz=%d total_blks=%d chunks=%d\n", $blksz, $tblk, $tchunk;

my $outblk = 0;
for my $i (1 .. $tchunk) {
    my $ch; read($ifh, $ch, 12) == 12 or die "short chunk hdr";
    my ($ctype, $res, $csz, $tot) = unpack("vvVV", $ch);
    my $datasz = $csz * $blksz;
    if ($ctype == 0xCAC1) {          # RAW
        my $left = $datasz;
        while ($left > 0) {
            my $want = $left > 4194304 ? 4194304 : $left;
            my $buf; my $n = read($ifh, $buf, $want);
            die "short read" unless $n == $want;
            print $ofh $buf;
            $left -= $n;
        }
    } elsif ($ctype == 0xCAC2) {     # FILL
        my $fill; read($ifh, $fill, 4);
        my ($pattern) = unpack("V", $fill);
        my $block;
        if ($pattern == 0) { $block = "\0" x $blksz; }
        else { $block = pack("V", $pattern) x ($blksz / 4); }
        for (1 .. $csz) { print $ofh $block; }
    } elsif ($ctype == 0xCAC3) {     # DON'T CARE -> zeros
        my $left = $datasz;
        my $zeros = "\0" x 4194304;
        while ($left > 0) {
            my $want = $left > 4194304 ? 4194304 : $left;
            print $ofh substr($zeros, 0, $want);
            $left -= $want;
        }
    } elsif ($ctype == 0xCAC4) {     # CRC
        read($ifh, my $crc, 4);
    } else {
        die sprintf("unknown chunk type 0x%x", $ctype);
    }
    # skip padding
    my $consumed = ($ctype == 0xCAC1 ? $datasz : $ctype == 0xCAC2 || $ctype == 0xCAC4 ? 4 : 0);
    my $pad = $tot - 12 - $consumed;
    seek($ifh, $pad, 1) if $pad > 0;
    $outblk += $csz;
}
close $ifh; close $ofh;
print "wrote $out (", $outblk * $blksz, " bytes)\n";
