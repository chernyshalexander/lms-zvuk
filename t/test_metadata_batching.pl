#!/usr/bin/env perl
# Regression test: LMS asks for track metadata one track at a time, and the plugin
# used to fire one getTracks request per track within milliseconds (7 identical
# log lines, 7 separate GraphQL round-trips, 7 cache entries).
#
# Contract under test:
#   - several ids requested in one burst produce ONE getTracks call carrying all ids;
#   - the same id requested twice in the burst is fetched once;
#   - callers still get their newmetadata notification after the batch resolves.
#
# Run: perl t/test_metadata_batching.pl
use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;

require "$Bin/slim_mocks.pl";
require "$Bin/test_helpers.pl";

my $repo_root = "$Bin/..";
my $tmpdir = tempdir(CLEANUP => 1);
mkdir "$tmpdir/Plugins" or die $!;
symlink($repo_root, "$tmpdir/Plugins/Zvuk") or die "symlink: $!";
unshift @INC, $tmpdir;

require Plugins::Zvuk::Plugin;
require Plugins::Zvuk::API::Async;
require Plugins::Zvuk::ProtocolHandler;

my $client = Test::FakeClient->new(id => 'player1');
{
	no warnings 'once';
	$Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts} = { acctA => { token => 'tokA', name => 'A' } };
	$Slim::Utils::Prefs::CLIENT_STORE{'plugin.zvuk'}{ $client->id }{userId} = 'acctA';
	$Slim::Utils::Prefs::CLIENT_STORE{'plugin.zvuk'}{ $client->id }{'_ts_userId'} = time();
	$Slim::Utils::Prefs::STORE{'plugin.zvuk'}{quality} = 'mp3';
}

# Capture the outgoing getTracks calls instead of hitting the network.
my @calls;
no warnings 'redefine';
local *Plugins::Zvuk::API::Async::getTracks = sub {
	my ($self, $cb, $ids) = @_;
	push @calls, [ @$ids ];
	$cb->([ map { { id => $_, title => "Track $_", duration => 100 } } @$ids ]);
};
use warnings 'redefine';

my @notified;
no warnings 'redefine';
*Slim::Control::Request::notifyFromArray = sub {
	my ($c, $what) = @_;
	push @notified, $what->[0];
	return;
};
use warnings 'redefine';

# A burst of metadata lookups, as LMS does right after a queue is built.
Plugins::Zvuk::ProtocolHandler->getMetadataFor($client, 'zvuk://111');
Plugins::Zvuk::ProtocolHandler->getMetadataFor($client, 'zvuk://222');
Plugins::Zvuk::ProtocolHandler->getMetadataFor($client, 'zvuk://333');
Plugins::Zvuk::ProtocolHandler->getMetadataFor($client, 'zvuk://222');  # duplicate

is(scalar(@calls), 0, 'nothing is requested before the batch window closes');

# Fire the batching timer
Slim::Utils::Timers::fireAll();

is(scalar(@calls), 1, 'one getTracks call for the whole burst');
is_deeply($calls[0], [ 111, 222, 333 ], 'the call carries every distinct id once');

ok((grep { $_ eq 'newmetadata' } @notified), 'callers are notified after the batch resolves');

# --- a second burst is a second call ------------------------------------
@calls = ();
Plugins::Zvuk::ProtocolHandler->getMetadataFor($client, 'zvuk://444');
Plugins::Zvuk::ProtocolHandler->getMetadataFor($client, 'zvuk://555');
Slim::Utils::Timers::fireAll();

is(scalar(@calls), 1, 'a later burst is batched too');
is_deeply($calls[0], [ 444, 555 ], 'the later batch carries its own ids');

# --- cached metadata short-circuits -------------------------------------
@calls = ();
Plugins::Zvuk::API->cache->set('zvuk_meta_777', {
	id => 777, title => 'Cached', duration => 200, artist => 'A',
	album => 'B', icon => '', cover => '',
}, 3600);
Plugins::Zvuk::ProtocolHandler->getMetadataFor($client, 'zvuk://777');
Slim::Utils::Timers::fireAll();

is(scalar(@calls), 0, 'a cached track does not trigger a request');

done_testing();
