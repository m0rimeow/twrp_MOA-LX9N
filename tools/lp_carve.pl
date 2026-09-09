#!/usr/bin/perl
# Carve a named dynamic partition out of a raw super.img.
# Usage: perl tools/lp_carve.pl super.raw <partition_name> [out.img]
#        perl tools/lp_carve.pl super.raw --list
use strict; use warnings;

my ($file, $want, $out) = @ARGV or die "usage: $0 super.raw <name>|--list [out]\n";
open my $fh, "<", $file or die $!;
binmode $fh;

# locate LP metadata header magic "0PLA" within first MiB
my $scan; seek($fh, 0, 0); read($fh, $scan, 1048576);
my $hoff = index($scan, "0PLA");
die "no LP magic in first MiB\n" if $hoff < 0;
print "LP header at $hoff\n";
seek($fh, $hoff, 0);
my $hdr; read($fh, $hdr, 64) == 64 or die;
my ($magic, $maj, $min, $hdrsz, $cksum, $taboff, $tabsize) = unpack("VvvV a32 VV", $hdr);

my $geo; read($fh, $geo, 12);
my ($mmax, $mslots, $lblk) = unpack("VVV", $geo);
printf "LP v%d.%d hdr=%d tables_off=%d tables_sz=%d lblk=%d\n", $maj, $min, $hdrsz, $taboff, $tabsize, $lblk;

# Huawei LP layout: descriptors at hoff+80 as 4 x (offset, count, entry_size),
# entries region at hoff+128. Descriptor offsets are relative to entries region.
my $descbase = $hoff + 80;
my $entbase = $hoff + 128;
seek($fh, $descbase, 0); my $descs; read($fh, $descs, 48);

sub table { # index -> (offset,count,entry_size)
    my $i = shift;
    return unpack("VVV", substr($descs, $i * 12, 12));
}
my ($po, $pn, $pe) = table(0);  # partitions
my ($eo, $en, $ee) = table(1);  # extents
printf "partitions: %d x %d @%d, extents: %d x %d @%d\n", $pn, $pe, $po, $en, $ee, $eo;

sub rd { my ($off,$len)=@_; seek($fh,$off,0); my $b; read($fh,$b,$len); return $b; }

my @parts;
for my $i (0 .. $pn - 1) {
    my $e = rd($entbase + $po + $i * $pe, $pe);
    my ($name, $attr, $first_ext, $num_ext) = unpack("a36 V V V", $e);
    $name =~ s/\0.*//;
    my @ext;
    for my $j (0 .. $num_ext - 1) {
        my $x = rd($entbase + $eo + ($first_ext + $j) * $ee, $ee);
        my ($nsec, $ttype, $tdata, $tsrc) = unpack("Q V Q V", $x);
        push @ext, [$nsec, $ttype, $tdata];
    }
    push @parts, { name => $name, extents => \@ext };
    printf "%-16s %8.1f MB  %s\n", $name,
        (grep { $_->[1] == 0 } @ext) ? (unpack("%32Q*", pack("Q*", map { $_->[0] } grep { $_->[1]==0 } @ext)) * 512)/1048576 : 0,
        join(" ", map { sprintf("[%d@%d t%d]", $_->[0], $_->[1], $_->[2]) } @ext);
}

exit 0 if $want eq "--list";
my ($p) = grep { $_->{name} eq $want } @parts;
die "partition '$want' not found\n" unless $p;
$out ||= "$want.raw";
open my $ofh, ">", $out or die $!;
binmode $ofh;
my $total = 0;
for my $x (@{$p->{extents}}) {
    my ($nsec, $ttype, $tdata) = @$x;
    if ($ttype == 0) {
        seek($fh, $tdata * 512, 0);
        my $left = $nsec * 512;
        while ($left > 0) {
            my $w = $left > 4194304 ? 4194304 : $left;
            my $buf; my $n = read($fh, $buf, $w);
            die "short read" unless $n == $w;
            print $ofh $buf; $left -= $n;
        }
        $total += $nsec * 512;
    } else {
        # zero-fill (e.g. zero type)
        my $left = $nsec * 512; my $z = "\0" x 4194304;
        while ($left > 0) { my $w = $left > 4194304 ? 4194304 : $left; print $ofh substr($z,0,$w); $left -= $w; }
    }
}
print "wrote $out ($total bytes)\n";
