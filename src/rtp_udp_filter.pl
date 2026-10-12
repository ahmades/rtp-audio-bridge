#!/usr/bin/env perl

use strict;
use warnings;
use IO::Socket::INET;
use IO::Handle;
use Socket qw(inet_aton inet_ntoa sockaddr_in unpack_sockaddr_in);

my ($local_address, $local_port, $allowed_address, $ready_path) = @ARGV;
open my $ready, '>', $ready_path or die "Cannot open relay status pipe: $!\n";
$ready->autoflush(1);

my $receiver = IO::Socket::INET->new(
    LocalAddr => $local_address,
    LocalPort => $local_port,
    Proto => 'udp',
    ReuseAddr => 0,
);
if (!$receiver) {
    print {$ready} "ERROR: Cannot bind UDP receiver socket: $!\n";
    exit 1;
}

my $target = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1',
    LocalPort => 0,
    Proto => 'udp',
    ReuseAddr => 0,
);
if (!$target) {
    print {$ready} "ERROR: Cannot reserve local UDP relay port: $!\n";
    exit 1;
}

my $target_port = $target->sockport;
close $target;
my $forwarder = IO::Socket::INET->new(Proto => 'udp');
if (!$forwarder) {
    print {$ready} "ERROR: Cannot create local UDP relay socket: $!\n";
    exit 1;
}

my $forward_address = sockaddr_in($target_port, inet_aton('127.0.0.1'));
print {$ready} "$target_port\n";
close $ready;

while (1) {
    my $packet = '';
    my $peer = $receiver->recv($packet, 65535);
    next unless defined $peer;

    my (undef, $peer_address) = unpack_sockaddr_in($peer);
    next unless inet_ntoa($peer_address) eq $allowed_address;
    $forwarder->send($packet, 0, $forward_address);
}