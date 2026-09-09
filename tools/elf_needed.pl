#!/usr/bin/perl
# Print DT_NEEDED entries of an ELF (32/64-bit, LE). Usage: perl tools/elf_needed.pl file [file...]
use strict; use warnings;
for my $f (@ARGV) {
    open my $fh, "<", $f or do { warn "$f: $!"; next };
    binmode $fh; local $/; my $d = <$fh>; close $fh;
    next unless substr($d,0,4) eq "\x7fELF";
    my $is64 = ord(substr($d,4,1)) == 2;
    my ($phoff, $phentsize, $phnum) = $is64
        ? (unpack("Q", substr($d,32,8)), unpack("v", substr($d,54,2)), unpack("v", substr($d,56,2)))
        : (unpack("V", substr($d,28,4)), unpack("v", substr($d,42,2)), unpack("v", substr($d,44,2)));
    my ($dynoff, $dynvoff, $dynsz);
    for my $i (0..$phnum-1) {
        my $ph = substr($d, $phoff + $i*$phentsize, $phentsize);
        my ($type, $poff, $voff, $filesz) = $is64
            ? (unpack("V",$ph), unpack("V",substr($ph,8,4)), unpack("Q",substr($ph,16,8)), unpack("Q",substr($ph,32,8)))
            : (unpack("V",$ph), unpack("V",substr($ph,4,4)), unpack("V",substr($ph,8,4)), unpack("V",substr($ph,16,4)));
        if ($type == 2) { $dynoff=$poff; $dynvoff=$voff; $dynsz=$filesz; last; }
    }
    next unless defined $dynoff;
    my $dyn = substr($d, $dynoff, $dynsz);
    my $esz = $is64 ? 16 : 8;
    my ($strvoff, $stroff);
    my @needed;
    for (my $o=0; $o+$esz<=length($dyn); $o+=$esz) {
        my ($tag,$val) = $is64 ? unpack("qQ", substr($dyn,$o,16)) : unpack("VV", substr($dyn,$o,8));
        last if $tag == 0;
        if ($tag == 5) { $strvoff = $val; }
        elsif ($tag == 1) { push @needed, $val; }
    }
    next unless defined $strvoff;
    # map vaddr->file offset using PT_LOAD segments
    $stroff = $strvoff;
    for my $i (0..$phnum-1) {
        my $ph = substr($d, $phoff + $i*$phentsize, $phentsize);
        my ($type,$poff,$voff,$filesz) = $is64
            ? (unpack("V",$ph), unpack("V",substr($ph,8,4)), unpack("Q",substr($ph,16,8)), unpack("Q",substr($ph,32,8)))
            : (unpack("V",$ph), unpack("V",substr($ph,4,4)), unpack("V",substr($ph,8,4)), unpack("V",substr($ph,16,4)));
        next unless $type == 1;
        if ($strvoff >= $voff && $strvoff < $voff + $filesz) { $stroff = $poff + ($strvoff - $voff); last; }
    }
    print "$f:\n";
    for my $n (@needed) {
        my $end = index($d, "\0", $stroff + $n);
        print "  ", substr($d, $stroff + $n, $end - $stroff - $n), "\n";
    }
}
