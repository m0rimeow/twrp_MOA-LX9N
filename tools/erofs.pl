#!/usr/bin/perl
# Minimal EROFS reader (legacy VLE LZ4) for small partitions.
# Usage: perl tools/erofs.pl image.raw --ls [path]
#        perl tools/erofs.pl image.raw --get <path> <outdir>
use strict; use warnings;
use File::Path qw(make_path);

my ($img, $cmd, $path, $outdir) = @ARGV;
die "usage: $0 image --ls [path] | --get <path> <outdir>\n" unless $cmd;
$path = "/" unless defined $path && length $path;
$path = "/$path" unless $path =~ m{^/};
$path =~ s{/$}{} unless $path eq "/";

open my $fh, "<", $img or die $!;
binmode $fh;

sub rd { my ($off,$len)=@_; return "" if $len<=0; seek($fh,$off,0); my $b; my $n=read($fh,$b,$len); die "short read @$off want $len got $n" unless $n==$len; $b }

my $sb = rd(1024, 96);
my ($magic, $blkbits, $rootnid, $metablk) =
   (unpack("V",substr($sb,0,4)), unpack("C",substr($sb,12,1)),
    unpack("v",substr($sb,14,2)), unpack("V",substr($sb,40,4)));
die sprintf("not erofs (magic 0x%08x)\n",$magic) unless $magic == 0xE0F5E1E2;
my $blksz = 1 << $blkbits;
printf STDERR "erofs: blksz=%d root_nid=%d meta_blk=%d\n", $blksz, $rootnid, $metablk;

# ---- LZ4 raw block decompress (known output length) ----
sub lz4_decompress {
    my ($in, $outlen) = @_;
    my $out = "";
    my ($ip, $ilen) = (0, length $in);
    while (length($out) < $outlen) {
        last if $ip >= $ilen;
        my $token = ord(substr($in, $ip++, 1));
        my $litlen = $token >> 4;
        if ($litlen == 15) {
            while (1) { my $b = ord(substr($in, $ip++, 1)); $litlen += $b; last if $b != 255; }
        }
        if ($litlen) {
            $out .= substr($in, $ip, $litlen);
            $ip += $litlen;
        }
        last if length($out) >= $outlen || $ip >= $ilen;
        my ($off, $ml) = (unpack("v", substr($in, $ip, 2)), $token & 0x0f);
        $ip += 2;
        die "lz4: bad offset 0" if $off == 0;
        if ($ml == 15) {
            while (1) { my $b = ord(substr($in, $ip++, 1)); $ml += $b; last if $b != 255; }
        }
        $ml += 4;
        my $opos = length($out) - $off;
        die "lz4: offset before start" if $opos < 0;
        for (my $i = 0; $i < $ml; $i++) { $out .= substr($out, $opos + $i, 1); }
    }
    return substr($out, 0, $outlen);
}

sub xattr_size {
    my $ic = shift;
    return 0 unless $ic;
    return 12 + 4 * ($ic - 1);
}

sub inode {
    my ($nid) = @_;
    my $off = $metablk * $blksz + $nid * 32;
    my $raw = rd($off, 32);
    my $fmt  = unpack("v", substr($raw, 0, 2));
    my $xic  = unpack("v", substr($raw, 2, 2));
    my $mode = unpack("v", substr($raw, 4, 2));
    my $size = unpack("V", substr($raw, 8, 4));
    my $u    = unpack("V", substr($raw, 16, 4));
    my $isize = 32;
    if ($fmt & 1) {   # extended
        my $raw64 = rd($off, 64);
        $size = unpack("Q", substr($raw64, 8, 8));
        $u    = unpack("V", substr($raw64, 16, 4));
        $isize = 64;
    }
    return { fmt=>$fmt, dl=>(($fmt>>1)&7), mode=>$mode, size=>$size,
             blkaddr=>$u, off=>$off, isize=>$isize, xattr=>xattr_size($xic) };
}

sub is_dir { (($_[0]->{mode}) & 0170000) == 0040000 }
sub is_lnk { (($_[0]->{mode}) & 0170000) == 0120000 }

sub map_indexes {
    my ($ino) = @_;
    my $base = $ino->{off} + $ino->{isize} + $ino->{xattr};
    $base = ($base + 7) & ~7;          # INDEX_ALIGN
    my $hdr = rd($base, 8);
    my ($cb, $advise) = (unpack("C", substr($hdr, 7, 1)), unpack("v", substr($hdr, 4, 2)));
    my $lclusterbits = 12 + ($cb & 7);
    die "compacted_2b indexes not supported\n" if $advise & 1;
    my $p = $base + 8 + 8;             # header + legacy padding
    my $csize = 1 << $lclusterbits;
    my $n = int(($ino->{size} + $csize - 1) / $csize) || 1;
    my @di;
    for my $i (0 .. $n - 1) {
        my $e = rd($p + $i * 8, 8);
        my ($adv, $cofs, $u1, $u2) = unpack("v v v v", $e);
        push @di, { type=>$adv & 3, cofs=>$cofs, blk=>$u1 | ($u2 << 16), d0=>$u1, d1=>$u2 };
    }
    return ($csize, \@di);
}

sub readdata {
    my ($ino) = @_;
    my $size = $ino->{size};
    return "" if $size == 0;
    my $dl = $ino->{dl};
    if ($dl == 0 || $dl == 2) {        # flat plain / flat inline
        my $blocks = int($size / $blksz);
        my $tail = $size % $blksz;
        my $data = $blocks ? rd($ino->{blkaddr} * $blksz, $blocks * $blksz) : "";
        if ($tail) {
            if ($dl == 2) {
                $data .= rd($ino->{off} + $ino->{isize} + $ino->{xattr}, $tail);
            } else {
                $data .= rd(($ino->{blkaddr} + $blocks) * $blksz, $tail);
            }
        }
        return $data;
    }
    if ($dl == 1) {                    # compressed legacy
        my ($csize, $di) = map_indexes($ino);
        my $out = "";
        my $remaining = $size;
        for (my $lcn = 0; $lcn < @$di && $remaining > 0; $lcn++) {
            my $d = $di->[$lcn];
            my $take = $remaining < $csize ? $remaining : $csize;
            if ($d->{type} == 0) {          # PLAIN
                $out .= substr(rd($d->{blk} * $blksz + $d->{cofs}, $csize), 0, $take);
            } elsif ($d->{type} == 1) {     # HEAD
                # count covered lclusters (following NONHEAD chain)
                my $cover = 1;
                while ($lcn + $cover < @$di && $di->[$lcn+$cover]{type} == 2) { $cover++; }
                my $outlen = $csize * $cover;
                my $comp = rd($d->{blk} * $blksz, $blksz * 4);   # read enough padded blocks
                my $plain = lz4_decompress($comp, $outlen);
                $out .= substr($plain, $d->{cofs}, $take);
                $remaining -= $take;
                for my $k (1 .. $cover - 1) {
                    my $t2 = $remaining < $csize ? $remaining : $csize;
                    my $nd = $di->[$lcn + $k];
                    $out .= substr($plain, $nd->{cofs} == 0 ? $k * $csize : $nd->{cofs}, $t2);
                    $remaining -= $t2;
                }
                $lcn += $cover - 1;
                next;
            } elsif ($d->{type} == 2) {
                # NONHEAD without preceding HEAD seen here: resolve via delta
                my $head = $lcn - $d->{d0};
                die "bad delta" if $head < 0;
                my $hd = $di->[$head];
                my $comp = rd($hd->{blk} * $blksz, $blksz * 8);
                my $plain = lz4_decompress($comp, $csize * (@$di - $head));
                $out .= substr($plain, $d->{cofs}, $take);
            } else {
                die "reserved cluster type\n";
            }
            $remaining -= $take;
        }
        return substr($out, 0, $size);
    }
    die "unsupported datalayout $dl\n";
}

sub lsdir {
    my ($ino) = @_;
    my $data = readdata($ino);
    my @ents;
    my $len = length $data;
    my $pos = 0;
    while ($pos < $len) {
        last if $pos + 12 > $len;
        my (undef, $nameoff) = unpack("Q v", substr($data, $pos, 12));
        last if $nameoff == 0;
        my $names_base = $pos + $nameoff;
        my $dpos = $pos;
        while ($dpos + 12 <= $names_base) {
            my ($nid, $noff, $ftype) = unpack("Q v C", substr($data, $dpos, 12));
            my $nameend;
            if ($dpos + 12 < $names_base) {
                $nameend = $pos + unpack("v", substr($data, $dpos + 20, 2));
            } else {
                $nameend = $pos + $blksz > $len ? $len : $pos + $blksz;
            }
            my $name = substr($data, $pos + $noff, $nameend - $pos - $noff);
            $name =~ s/\0.*//s;
            push @ents, { nid=>$nid, name=>$name, ftype=>$ftype } if length $name;
            $dpos += 12;
        }
        $pos += $blksz;
    }
    return @ents;
}

sub resolve {
    my ($p) = @_;
    my $ino = inode($rootnid);
    return $ino if $p eq "/" || $p eq "";
    for my $comp (grep length, split m{/}, $p) {
        die "not a dir: $p ($comp)\n" unless is_dir($ino);
        my @e = lsdir($ino);
        my ($hit) = grep { $_->{name} eq $comp } @e;
        die "'$comp' not found in $p\n" unless $hit;
        $ino = inode($hit->{nid});
    }
    return $ino;
}

if ($cmd eq "--ls") {
    my $ino = resolve($path);
    if (is_dir($ino)) {
        for my $e (lsdir($ino)) {
            my $c = inode($e->{nid});
            printf "%s %-40s %10d dl=%d%s\n", is_dir($c)?"d":(is_lnk($c)?"l":"-"),
                $e->{name}, $c->{size}, $c->{dl},
                is_lnk($c) ? " -> ".readdata($c) : "";
        }
    } else {
        printf "- %-40s %10d dl=%d\n", $path, $ino->{size}, $ino->{dl};
    }
} elsif ($cmd eq "--get") {
    die "need outdir\n" unless $outdir;
    make_path($outdir);
    my $count = 0;
    my @queue = ([$path, $outdir]);
    while (my $item = shift @queue) {
        my ($p, $o) = @$item;
        my $ino = resolve($p);
        if (is_dir($ino)) {
            make_path($o);
            for my $e (lsdir($ino)) {
                next if $e->{name} eq "." || $e->{name} eq "..";
                push @queue, ["$p/$e->{name}", "$o/$e->{name}"];
            }
        } elsif (is_lnk($ino)) {
            open my $lf, ">", "$o.symlink" or warn $!;
            print $lf readdata($ino); close $lf;
        } else {
            my ($dir) = $o =~ m{^(.*)/};
            make_path($dir) if $dir && !-d $dir;
            open my $of, ">", $o or do { warn "$o: $!"; next };
            binmode $of;
            print $of readdata($ino);
            close $of;
            $count++;
            printf "got %s (%d bytes)\n", $p, $ino->{size};
        }
    }
    print "extracted $count files -> $outdir\n";
}
