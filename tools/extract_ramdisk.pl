#!/usr/bin/perl
# Extract a (gzip) cpio "newc" ramdisk without cpio(1).
# Usage: perl tools/extract_ramdisk.pl ramdisk.cpio.gz outdir
use strict; use warnings;
use File::Path qw(make_path);

my ($arc, $out) = @ARGV or die "usage: $0 ramdisk.cpio[.gz] outdir\n";
make_path($out);

my $data;
{
    local $/;
    if ($arc =~ /\.gz$/) {
        open my $fh, "-|", "gzip -dc \"$arc\"" or die $!;
        binmode $fh; $data = <$fh>; close $fh;
    } else {
        open my $fh, "<", $arc or die $!; binmode $fh; $data = <$fh>; close $fh;
    }
}
die "empty archive\n" unless $data;

my $pos = 0;
my $count = 0;
while ($pos + 110 <= length $data) {
    my $magic = substr($data, $pos, 6);
    last if $magic ne "070701" && $magic ne "070702";
    my @f = map { hex } map { substr($data, $pos + 6 + $_*8, 8) } 0..12;
    my ($mode, $filesize, $namesize) = ($f[1], $f[6], $f[11]);
    my $name = substr($data, $pos + 110, $namesize - 1);
    $pos += 110 + $namesize;
    $pos = ($pos + 3) & ~3;
    last if $name eq "TRAILER!!!";

    my $path = "$out/$name";
    my $type = $mode & 0170000;
    if ($type == 0040000) {            # directory
        make_path($path);
    } elsif ($type == 0100000) {       # regular file
        my ($dir) = $path =~ m{^(.*)/};
        make_path($dir) if $dir && !-d $dir;
        open my $fh, ">", $path or do { warn "write $path: $!"; $pos += $filesize; $pos = ($pos+3)&~3; next };
        binmode $fh; print $fh substr($data, $pos, $filesize); close $fh;
        chmod($mode & 0777, $path);
    } elsif ($type == 0120000) {       # symlink
        my $target = substr($data, $pos, $filesize);
        my ($dir) = $path =~ m{^(.*)/};
        make_path($dir) if $dir && !-d $dir;
        if (eval { symlink($target, $path); 1 }) { } else {
            open my $fh, ">", "$path.symlink" or warn $!;
            print $fh $target if $fh; close $fh if $fh;
        }
    } elsif ($type == 0060000 || $type == 0020000) {  # block/char dev -> record
        open my $fh, ">>", "$out/DEVNODES.txt" or warn $!;
        printf $fh "%s mode=%o major=%d minor=%d\n", $name, $mode, $f[7]*256+0+$f[8], $f[9]*256+$f[10];
        close $fh;
    }
    $count++;
    $pos += $filesize;
    $pos = ($pos + 3) & ~3;
}
print "extracted $count entries -> $out\n";
