#!/usr/bin/perl
# Scan a large file (e.g. Huawei UPDATE.APP) for ANDROID! boot images and
# carve each one out using sizes from its header.
# Usage: perl tools/carve_bootimgs.pl UPDATE.APP outdir
use strict; use warnings;
use File::Path qw(make_path);

my ($file, $out) = @ARGV or die "usage: $0 UPDATE.APP outdir\n";
make_path($out);

open my $fh, "<", $file or die $!;
binmode $fh;

my $page = 0;
sub palign { my ($n) = @_; return int(($n + $page - 1) / $page) * $page; }

my $off = 0;
my $chunk = 16 * 1024 * 1024;
my $tail = "";
my $found = 0;
my $fileoff = 0;

while (1) {
    my $buf;
    my $n = read($fh, $buf, $chunk);
    last unless $n;
    my $scan = $tail . $buf;
    my $base = $fileoff - length($tail);
    my $p = 0;
    my $hold;   # absolute start of a pending incomplete match
    while (($p = index($scan, "ANDROID!", $p)) >= 0) {
        my $abspos = $base + $p;
        # need header bytes
        if (length($scan) - $p < 1660) { $hold = $p; last; }   # wait for more data
        my @h = unpack("V14", substr($scan, $p + 8, 56));
        my ($ks, $rs, $ss, $pagesz, $hv) = ($h[0], $h[2], $h[4], $h[7], $h[8]);
        if (($pagesz == 2048 || $pagesz == 4096 || $pagesz == 1024 || $pagesz == 512)
            && $ks > 0 && $ks < 134217728 && $rs < 268435456 && $ss < 67108864) {
            $page = $pagesz;
            my $total = $page + palign($ks) + palign($rs) + palign($ss);
            if ($hv == 1 || $hv == 2) {
                my $dtbo = unpack("V", substr($scan, $p + 1632, 4));
                $total += palign($dtbo);
            }
            if ($hv == 2) {
                my $dtb = unpack("V", substr($scan, $p + 1648, 4));
                $total += palign($dtb);
            }
            if (length($scan) - $p >= $total) {
                my $name = sprintf("%s/img_%08d.img", $out, $abspos);
                open my $ofh, ">", $name or die $!;
                binmode $ofh;
                print $ofh substr($scan, $p, $total);
                close $ofh;
                printf "carved %s (off=%d, k=%d r=%d s=%d page=%d hv=%d total=%d)\n",
                    $name, $abspos, $ks, $rs, $ss, $page, $hv, $total;
                $found++;
                $p += $total;
                next;
            } else { $hold = $p; last; }  # need more data
        }
        $p += 8;
    }
    # keep tail: from the pending match if any, else last bytes to catch
    # magic/header spanning chunk boundaries
    if (defined $hold) {
        $tail = substr($scan, $hold);
    } else {
        $tail = substr($scan, length($scan) - 1700 > 0 ? length($scan) - 1700 : 0);
    }
    $fileoff += $n;
}
print "done, $found image(s) carved\n";
