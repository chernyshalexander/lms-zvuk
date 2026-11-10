#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;
no warnings 'once';

require "$Bin/slim_mocks.pl";
require "$Bin/test_helpers.pl";

my $repo_root = "$Bin/..";
my $tmpdir = tempdir(CLEANUP => 1);
mkdir "$tmpdir/Plugins" or die $!;
symlink($repo_root, "$tmpdir/Plugins/Zvuk") or die "symlink: $!";
unshift @INC, $tmpdir;

use Digest::MD5 qw(md5_hex);

# Set main::SCANNER to 1 for scanner tests
$main::SCANNER = 1;

require Plugins::Zvuk::Plugin;
require Plugins::Zvuk::API;
require Plugins::Zvuk::API::Async;
require Plugins::Zvuk::API::Sync;
require Plugins::Zvuk::Importer;
require Plugins::Zvuk::ProtocolHandler;

my $prefs = Slim::Utils::Prefs::preferences('plugin.zvuk');
my $cache = Slim::Utils::Cache->new();

subtest 'Constants and Basic Properties' => sub {
	plan tests => 3;
	ok(Plugins::Zvuk::Importer::CAN_IMPORTER(), 'CAN_IMPORTER is true');
	is(Plugins::Zvuk::Importer->trackUriPrefix(), 'zvuk://', 'trackUriPrefix is zvuk://');
	is(Plugins::Zvuk::Importer->can('needsUpdate') ? 1 : 0, 1, 'needsUpdate method exists');
};

subtest '_enabledAccounts Filtering' => sub {
	plan tests => 4;

	$prefs->set('accounts', {
		'user1' => { token => 'token1', name => 'Active User 1' },
		'user2' => { token => 'token2', name => 'Stale User', stale => 1 },
		'user3' => { token => '', name => 'No Token User' },
		'user4' => { token => 'token4', username => 'Active User 4' },
		'user5' => { token => 'token5', name => 'Disabled Import User' },
	});
	$prefs->set('dontImportAccounts', { 'user5' => 1 });

	my $accounts = Plugins::Zvuk::Importer::_enabledAccounts();
	ok(exists $accounts->{'Active User 1'}, 'user1 is enabled');
	is($accounts->{'Active User 1'}, 'user1', 'user1 maps correctly');
	ok(!exists $accounts->{'Stale User'}, 'stale account is excluded');
	ok(!exists $accounts->{'Disabled Import User'}, 'account in dontImportAccounts is excluded');
};

subtest '_flattenTracksWithNumbers' => sub {
	plan tests => 5;

	my @flat = Plugins::Zvuk::Importer::_flattenTracksWithNumbers({
		tracks => [
			{ id => 't1', position => 5 },
			{ id => 't2' },
			{ id => 't3' },
		]
	});
	is(scalar @flat, 3, 'three tracks flattened');
	is($flat[0]{_track_number}, 5, 'first track uses explicit position 5');
	is($flat[1]{_track_number}, 1, 'second track gets sequential number 1');
	is($flat[2]{_track_number}, 2, 'third track advances to sequential number 2');

	my @empty = Plugins::Zvuk::Importer::_flattenTracksWithNumbers({});
	is(scalar @empty, 0, 'empty tracks returns empty list');
};

subtest '_prepareTrack' => sub {
	plan tests => 15;

	$prefs->set('quality', 'high');
	my $album = {
		id    => '1001',
		title => 'Test Album',
		image => { src => 'https://cdn.zvuk.com/album.jpg' },
	};
	my $track = {
		id       => '2001',
		title    => 'Test Track',
		duration => 245,
		position => 3,
		artists  => [
			{ id => '3001', title => 'Primary Artist' },
			{ id => '3002', title => 'Featured Artist' },
		],
	};

	# Set split char
	$Slim::Utils::Prefs::STORE{'server'}{'splitList'} = '; ';
	local $Plugins::Zvuk::Importer::ct = 'mp3';
	local $Plugins::Zvuk::Importer::splitChar = ';';
	my $trackData = Plugins::Zvuk::Importer::_prepareTrack($album, $track);

	is($trackData->{url}, 'zvuk://2001', 'track url');
	is($trackData->{TITLE}, 'Test Track', 'track title');
	is($trackData->{ARTIST}, 'Primary Artist', 'primary artist');
	is($trackData->{ARTIST_EXTID}, 'zvuk:artist:3001', 'primary artist extid');
	is($trackData->{TRACKARTIST}, 'Featured Artist', 'additional artist in TRACKARTIST');
	is($trackData->{ALBUM}, 'Test Album', 'album title');
	is($trackData->{ALBUM_EXTID}, 'zvuk:album:1001', 'album extid');
	is($trackData->{TRACKNUM}, 3, 'track number from position');
	is($trackData->{SECS}, 245, 'duration in seconds');
	is($trackData->{COVER}, 'https://cdn.zvuk.com/album.jpg?width=500&height=500', 'cover url set');
	is($trackData->{SERVICE_ID}, 'zvuk', 'SERVICE_ID is zvuk');
	is($trackData->{AUDIO}, 1, 'audio flag');
	is($trackData->{EXTID}, 'zvuk://2001', 'track extid');
	is($trackData->{CONTENT_TYPE}, 'mp3', 'content type mp3 for high quality');
	is($trackData->{LOSSLESS}, 0, 'lossless 0 for high quality');
};

subtest '_prepareTrack FLAC Quality' => sub {
	plan tests => 2;

	$prefs->set('quality', 'flac');
	local $Plugins::Zvuk::Importer::ct = 'flc';
	local $Plugins::Zvuk::Importer::splitChar = ';';

	my $album = { id => '1002', title => 'Flac Album' };
	my $track = { id => '2002', title => 'Flac Track', duration => 180 };

	my $trackData = Plugins::Zvuk::Importer::_prepareTrack($album, $track);
	is($trackData->{CONTENT_TYPE}, 'flc', 'content type flc for flac');
	is($trackData->{LOSSLESS}, 1, 'lossless 1 for flac');
};

subtest 'scanAlbums' => sub {
	plan tests => 6;

	@Slim::Plugin::OnlineLibraryBase::STORED_TRACKS = ();
	$cache->clear();
	local $Plugins::Zvuk::Importer::ct = 'mp3';
	local $Plugins::Zvuk::Importer::splitChar = ';';

	# Mock API::Sync responses
	no warnings 'redefine';
	local *Plugins::Zvuk::API::Sync::users_likes_albums = sub {
		return [
			{ id => 'alb1', title => 'Liked Album 1', image => { src => 'cover1.jpg' } },
		];
	};
	local *Plugins::Zvuk::API::Sync::get_album_with_tracks = sub {
		my ($class, $id, $userId) = @_;
		return {
			id     => $id,
			title  => 'Liked Album 1',
			tracks => [
				{ id => 'trk1', title => 'Trk 1', duration => 200, position => 1, artists => [{ id => 'art1', title => 'Art 1' }] },
				{ id => 'trk2', title => 'Trk 2', duration => 210, position => 2, artists => [{ id => 'art1', title => 'Art 1' }] },
			],
		};
	};

	my $accounts = { 'TestAccount' => 'user1' };
	Plugins::Zvuk::Importer->scanAlbums($accounts);

	is(scalar @Slim::Plugin::OnlineLibraryBase::STORED_TRACKS, 1, 'storeTracks called once');
	my $batch = $Slim::Plugin::OnlineLibraryBase::STORED_TRACKS[0];
	is($batch->{accountId}, 'TestAccount', 'accountId passed to storeTracks');
	is(scalar @{ $batch->{tracks} }, 2, '2 tracks stored');
	is($batch->{tracks}[0]{url}, 'zvuk://trk1', 'first track url');
	is($batch->{tracks}[1]{url}, 'zvuk://trk2', 'second track url');

	# Check that album was cached
	my $cachedAlbum = $cache->get('zvuk_album_with_tracks_alb1');
	ok($cachedAlbum && $cachedAlbum->{tracks}, 'album details cached in zvuk_album_with_tracks_alb1');
};

subtest 'scanArtists' => sub {
	plan tests => 5;

	@Slim::Schema::Contributor::CONTRIBUTORS = ();
	$cache->clear();

	no warnings 'redefine';
	local *Plugins::Zvuk::API::Sync::users_likes_artists = sub {
		return [
			{ id => 'art100', title => 'Favorite Artist 1', image => { src => 'https://cdn.zvuk.com/art100.jpg' } },
		];
	};

	my $accounts = { 'TestAccount' => 'user1' };
	Plugins::Zvuk::Importer->scanArtists($accounts);

	is(scalar @Slim::Schema::Contributor::CONTRIBUTORS, 1, 'one contributor added');
	is($Slim::Schema::Contributor::CONTRIBUTORS[0]{artist}, 'Favorite Artist 1', 'artist name normalized');
	is($Slim::Schema::Contributor::CONTRIBUTORS[0]{extid}, 'zvuk:artist:art100', 'artist extid set');
	is($Slim::Schema::Contributor::CONTRIBUTORS[0]{cover}, 'https://cdn.zvuk.com/art100.jpg?width=500&height=500', 'artist cover passed to Contributor');

	# Check artist picture cached
	my $cachedPic = $cache->get('zvuk_artist_image_zvuk:artist:art100');
	ok($cachedPic && $cachedPic =~ /art100\.jpg/, 'artist image cached with key zvuk_artist_image_zvuk:artist:art100');
};

subtest 'scanPlaylists' => sub {
	plan tests => 8;

	%Slim::Schema::OBJECTS = ();

	no warnings 'redefine';
	local *Plugins::Zvuk::API::Sync::users_likes_playlists = sub {
		return [
			{ id => 'pl1', title => 'My Rock Playlist', image => { src => 'rock.jpg' } },
		];
	};
	local *Plugins::Zvuk::API::Sync::get_playlist_tracks = sub {
		return [
			{ id => 't10', title => 'Rock 1' },
			{ id => 't11', title => 'Rock 2' },
		];
	};
	local *Plugins::Zvuk::API::Sync::users_likes_tracks = sub {
		return [
			{ id => 'fav1', title => 'Favorite Song 1' },
			{ id => 'fav2', title => 'Favorite Song 2' },
		];
	};

	my $accounts = { 'TestAccount' => 'user1' };
	Plugins::Zvuk::Importer->scanPlaylists($accounts);

	# Check standard playlist created
	ok(exists $Slim::Schema::OBJECTS{'zvuk://playlist:pl1'}, 'playlist object created');
	my $plObj = $Slim::Schema::OBJECTS{'zvuk://playlist:pl1'};
	is($plObj->{attributes}{CONTENT_TYPE}, 'ssp', 'playlist content type is ssp');
	is_deeply($plObj->{tracks}, ['zvuk://t10', 'zvuk://t11'], 'playlist tracks set');

	# Check favorite tracks playlist created
	ok(exists $Slim::Schema::OBJECTS{'zvuk://playlist:favorites:user1'}, 'favorite tracks playlist created');
	my $favObj = $Slim::Schema::OBJECTS{'zvuk://playlist:favorites:user1'};
	is($favObj->{attributes}{CONTENT_TYPE}, 'ssp', 'favorites content type is ssp');
	is($favObj->{attributes}{COVER}, '/plugins/zvuk/html/images/favorites.png', 'favorites cover image');
	is_deeply($favObj->{tracks}, ['zvuk://fav1', 'zvuk://fav2'], 'favorites tracks set');
	ok($favObj->{attributes}{TITLE} =~ /Zvuk.*PLUGIN_ZVUK_COLLECTION/, 'favorites title includes prefix');
};

subtest 'getArtistPicture' => sub {
	plan tests => 9;

	$cache->clear();

	# 1. From cache with prefixed ID
	$cache->set('zvuk_artist_image_zvuk:artist:999', 'https://cached.jpg');
	my $pic = Plugins::Zvuk::Importer->getArtistPicture('zvuk:artist:999');
	is($pic, 'https://cached.jpg', 'retrieved from cache with prefixed ID');

	# 2. From cache with raw numeric ID
	my $pic_raw = Plugins::Zvuk::Importer->getArtistPicture('999');
	is($pic_raw, 'https://cached.jpg', 'retrieved from cache with raw numeric ID');

	# 3. Via Sync API if not in cache (image hash)
	my $api_fetch_count = 0;
	no warnings 'redefine';
	local *Plugins::Zvuk::API::Sync::get_artist = sub {
		my ($class, $id, $userId) = @_;
		$api_fetch_count++;
		return { id => $id, title => 'Artist 888', image => { src => 'https://api.jpg' } };
	};

	my $pic2 = Plugins::Zvuk::Importer->getArtistPicture('zvuk:artist:888');
	ok($pic2 && $pic2 =~ /api\.jpg/, 'fetched via API and formatted URL');
	is($cache->get('zvuk_artist_image_zvuk:artist:888'), $pic2, 'saved to cache with normalized key');

	# 4. Subsequent retrieval with raw numeric ID hits the cache populated above without API fetch
	my $pic2_raw = Plugins::Zvuk::Importer->getArtistPicture('888');
	is($pic2_raw, $pic2, 'subsequent call with raw numeric ID hits cache');
	is($api_fetch_count, 1, 'API called only once');

	# 5. Artist with cover string instead of image hash
	local *Plugins::Zvuk::API::Sync::get_artist = sub {
		my ($class, $id, $userId) = @_;
		return { id => $id, title => 'Artist 777', cover => 'https://cdn.zvuk.com/cov777.jpg' };
	};
	my $pic_cover = Plugins::Zvuk::Importer->getArtistPicture('zvuk:artist:777');
	ok($pic_cover && $pic_cover =~ /cov777\.jpg/, 'artist with cover property returns valid image URL');
	is($cache->get('zvuk_artist_image_zvuk:artist:777'), $pic_cover, 'artist with cover cached');

	# 6. _cacheArtistPicture with cover property
	Plugins::Zvuk::Importer::_cacheArtistPicture({ id => 'art666', cover => 'https://cdn.zvuk.com/art666.jpg' });
	my $cached666 = $cache->get('zvuk_artist_image_zvuk:artist:art666');
	ok($cached666 && $cached666 =~ /art666\.jpg/, '_cacheArtistPicture caches artist with cover property');
};

subtest 'needsUpdate Detection' => sub {
	plan tests => 4;

	$main::SCANNER = 0; # needsUpdate runs in LMS server (non-scanner)
	$cache->clear();

	# 1. Never scanned: lastScanTime is undef -> returns 1
	my $res1;
	Plugins::Zvuk::Importer->needsUpdate(sub { $res1 = shift; });
	is($res1, 1, 'needsUpdate returns 1 when never scanned');

	# 2. Cached fingerprint matches current fingerprint -> returns 0
	$cache->set('zvuk_library_last_scan', time() - 3600);
	$cache->set('zvuk_library_fingerprint', 'matching_md5_hash');

	no warnings 'redefine';
	local *Plugins::Zvuk::API::Async::getLibraryFingerprint = sub {
		my ($self, $cb) = @_;
		$cb->('matching_md5_hash');
	};

	my $res2;
	Plugins::Zvuk::Importer->needsUpdate(sub { $res2 = shift; });
	is($res2, 0, 'needsUpdate returns 0 when fingerprint unchanged');

	# 3. Fingerprint changed -> returns 1
	local *Plugins::Zvuk::API::Async::getLibraryFingerprint = sub {
		my ($self, $cb) = @_;
		$cb->('different_md5_hash');
	};

	my $res3;
	Plugins::Zvuk::Importer->needsUpdate(sub { $res3 = shift; });
	is($res3, 1, 'needsUpdate returns 1 when fingerprint changed');

	# 4. Plugin.pm onlineLibraryNeedsUpdate forwards properly
	my $res4;
	Plugins::Zvuk::Plugin->onlineLibraryNeedsUpdate(sub { $res4 = shift; });
	is($res4, 1, 'Plugin::onlineLibraryNeedsUpdate forwards to Importer');

	$main::SCANNER = 1;
};

subtest 'ProtocolHandler Explode Playlist and Favorites' => sub {
	plan tests => 5;

	{
		no warnings 'redefine';
		local *Plugins::Zvuk::Plugin::handleCollection = sub {
			my ($client, $cb) = @_;
			$cb->({ items => [{ url => 'zvuk://fav101' }, { url => 'zvuk://fav102' }] });
		};
		local *Plugins::Zvuk::Plugin::handlePlaylist = sub {
			my ($client, $cb, $args, $params) = @_;
			$cb->({ items => [{ url => 'zvuk://pl201' }] });
		};

		my $resFav;
		Plugins::Zvuk::ProtocolHandler->explodePlaylist(undef, 'zvuk://playlist:favorites', sub { $resFav = shift; });
		is_deeply($resFav, ['zvuk://fav101', 'zvuk://fav102'], 'favorites exploded via handleCollection');

		my $resFavUser;
		Plugins::Zvuk::ProtocolHandler->explodePlaylist(undef, 'zvuk://playlist:favorites:user1', sub { $resFavUser = shift; });
		is_deeply($resFavUser, ['zvuk://fav101', 'zvuk://fav102'], 'favorites:user1 exploded via handleCollection');

		my $resPl;
		Plugins::Zvuk::ProtocolHandler->explodePlaylist(undef, 'zvuk://playlist:555', sub { $resPl = shift; });
		is_deeply($resPl, ['zvuk://pl201'], 'numeric playlist exploded via handlePlaylist');
	}

	# Test that real handleCollection resolves user from favorites:$userId
	my $calledUser;
	no warnings 'redefine';
	local *Plugins::Zvuk::API::getClient = sub {
		my ($class, $user) = @_;
		$calledUser = $user;
		my $mock = bless {}, 'MockClient';
		return $mock;
	};
	local *MockClient::getCollection = sub {
		my ($self, $cb, $type) = @_;
		$cb->([{ id => 'trk_user2', title => 'User2 Favorite Track' }]);
	};

	my $collectionResult;
	Plugins::Zvuk::Plugin::handleCollection(undef, sub { $collectionResult = shift; }, {}, { id => 'favorites:user2' });
	is($calledUser, 'user2', 'real handleCollection resolved specific user2 from params');
	is($collectionResult->{items}[0]{url}, 'zvuk://trk_user2', 'handleCollection rendered track from user2 collection');
};

subtest 'API::Sync Fingerprint Computation' => sub {
	plan tests => 2;

	@Slim::Networking::SimpleSyncHTTP::RESPONSES = (
		{
			code    => 200,
			content => JSON::PP::encode_json({
				data => {
					collection => {
						releases  => [{ id => 'r1' }, { id => 'r2' }],
						artists   => [{ id => 'a1' }],
						playlists => [{ id => 'p1' }],
						tracks    => [{ id => 't1' }, { id => 't2' }],
					}
				}
			}),
		}
	);

	my $fp = Plugins::Zvuk::API::Sync->get_library_fingerprint('user1');
	my $expected_fp = md5_hex('rel:r1,r2|art:a1|pl:p1|tr:t1,t2');
	is($fp, $expected_fp, 'sync fingerprint matches expected md5');

	# Test Async getLibraryFingerprint produces identical hash
	@Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
		{
			code    => 200,
			content => JSON::PP::encode_json({
				data => {
					collection => {
						releases  => [{ id => 'r1' }, { id => 'r2' }],
						artists   => [{ id => 'a1' }],
						playlists => [{ id => 'p1' }],
						tracks    => [{ id => 't1' }, { id => 't2' }],
					}
				}
			}),
		}
	);

	my $async_fp;
	my $client = Plugins::Zvuk::API->getClient('user1');
	$client->getLibraryFingerprint(sub { $async_fp = shift; });
	is($async_fp, $expected_fp, 'async fingerprint produces identical md5 hash');
};

subtest 'isImportEnabled with PluginManager fallback' => sub {
	plan tests => 4;

	my $ol_prefs = Slim::Utils::Prefs::preferences('plugin.onlinelibrary');

	# 1. When OnlineLibrary support is globally disabled in LMS
	{
		no warnings 'redefine';
		local *Slim::Music::Import::isOnlineLibrarySupportEnabled = sub { 0 };
		is(Plugins::Zvuk::Importer->isImportEnabled(), 0, 'disabled when isOnlineLibrarySupportEnabled is 0');
	}

	# 2. When support is enabled, enable_PLUGIN_ZVUK is 1, and fallback from Importer to Plugin succeeds
	{
		$ol_prefs->set('enable_PLUGIN_ZVUK', 1);
		is(Plugins::Zvuk::Importer->isImportEnabled(), 1, 'enabled when pref is 1 and fallback dataForPlugin(Plugins::Zvuk::Plugin) succeeds');
	}

	# 3. When enable_PLUGIN_ZVUK is 0
	{
		$ol_prefs->set('enable_PLUGIN_ZVUK', 0);
		is(Plugins::Zvuk::Importer->isImportEnabled(), 0, 'disabled when pref is 0');
	}

	# 4. When onlineLibrary flag in PluginManager is not 'true'
	{
		$ol_prefs->set('enable_PLUGIN_ZVUK', 1);
		local $Slim::Utils::PluginManager::PLUGINS{'Plugins::Zvuk::Plugin'} = { name => 'PLUGIN_ZVUK', onlineLibrary => 'false' };
		is(Plugins::Zvuk::Importer->isImportEnabled(), 0, 'disabled when onlineLibrary flag is not true');
	}
};

subtest 'OnlineLibrary BrowseArtist integration' => sub {
	plan tests => 17;

	# Trigger initPlugin to register with BrowseArtist
	Plugins::Zvuk::Plugin->initPlugin();

	my $registeredHandler = $Slim::Plugin::OnlineLibrary::BrowseArtist::BROWSE_ARTIST_ITEMS{'zvuk'};
	ok($registeredHandler && ref $registeredHandler eq 'CODE', 'BrowseArtist item registered for zvuk');

	my $client = bless { id => 'test_client_id' }, 'Test::FakeClient';
	my $item = $registeredHandler->($client);
	ok($item && ref $item eq 'HASH', 'handler returns item hashref');
	is($item->{type}, 'link', 'item type is link');
	ok($item->{name}, 'item has a localized display name');
	is($item->{url}, \&Plugins::Zvuk::Plugin::browseArtistMenu, 'item url points to browseArtistMenu');

	# Test browseArtistMenu with artist having zvuk:artist extId -> routes to handleArtist
	my $contributorObj = Slim::Schema::Contributor->add({
		artist => 'Linked Artist',
		extid  => 'zvuk:artist:998877',
	});
	my $contributorId = $contributorObj->{id};

	my $browseResult;
	Plugins::Zvuk::Plugin::browseArtistMenu($client, sub { $browseResult = shift; }, { artist_id => $contributorId }, {});
	ok($browseResult && $browseResult->{items}, 'browseArtistMenu returned items for artist with zvuk extid');
	my @itemNames = map { $_->{name} } @{ $browseResult->{items} };
	ok(grep(/ARTIST_RADIO|Radio/i, @itemNames), 'contains artist radio action');

	# Test browseArtistMenu with alphanumeric extId (art100) -> also routes to handleArtist
	my $alphaArtistObj = Slim::Schema::Contributor->add({
		artist => 'Alpha Artist',
		extid  => 'zvuk:artist:art100',
	});
	my $alphaResult;
	Plugins::Zvuk::Plugin::browseArtistMenu($client, sub { $alphaResult = shift; }, { artist_id => $alphaArtistObj->{id} }, {});
	ok($alphaResult && $alphaResult->{items}, 'browseArtistMenu routes alphanumeric artist extId to handleArtist');
	my @alphaNames = map { $_->{name} } @{ $alphaResult->{items} };
	ok(grep(/ARTIST_RADIO|Radio/i, @alphaNames), 'alphanumeric artist contains artist radio action');

	# Test browseArtistMenu with local artist (no extid) and undef client -> fallback search without crashing
	my $localArtistObj = Slim::Schema::Contributor->add({
		artist => 'Local Only Band',
	});
	no warnings 'redefine';
	local *Plugins::Zvuk::API::Async::search = sub {
		my ($self, $cb, $args) = @_;
		if ($args->{query} eq 'Local Only Band') {
			$cb->({ search => { artists => { items => [{ id => 'art_local', title => 'Local Only Band' }] } } });
		} else {
			$cb->({ search => { artists => { items => [] } } });
		}
	};

	my $localResult;
	Plugins::Zvuk::Plugin::browseArtistMenu(undef, sub { $localResult = shift; }, { artist_id => $localArtistObj->{id} }, {});
	ok($localResult && $localResult->{items}, 'browseArtistMenu executed search for local artist without crashing on undef client');
	is($localResult->{items}[0]{name}, 'Local Only Band', 'search returned matched artist');

	# Test browseArtistMenu with local artist where search returns empty -> returns EMPTY item
	my $emptySearchArtist = Slim::Schema::Contributor->add({
		artist => 'Nonexistent Band XYZ',
	});
	my $emptySearchResult;
	Plugins::Zvuk::Plugin::browseArtistMenu($client, sub { $emptySearchResult = shift; }, { artist_id => $emptySearchArtist->{id} }, {});
	ok($emptySearchResult && ref $emptySearchResult eq 'ARRAY' && $emptySearchResult->[0]{title}, 'empty search returns empty message');

	# Test browseArtistMenu with unknown artist id -> returns EMPTY
	my $emptyResult;
	Plugins::Zvuk::Plugin::browseArtistMenu($client, sub { $emptyResult = shift; }, { artist_id => 999999 }, {});
	ok($emptyResult && ref $emptyResult eq 'ARRAY' && $emptyResult->[0]{title}, 'returns empty message for non-existent artist');

	# Test UI/InfoMenu alias delegates to Plugins::Zvuk::Plugin::browseArtistMenu
	my $aliasResult;
	Plugins::Zvuk::UI::InfoMenu::browseArtistMenu($client, sub { $aliasResult = shift; }, { artist_id => $contributorId }, {});
	is(scalar @{ $aliasResult->{items} }, scalar @{ $browseResult->{items} }, 'UI::InfoMenu::browseArtistMenu returns same item count');
	is($aliasResult->{items}[0]{name}, $browseResult->{items}[0]{name}, 'UI::InfoMenu::browseArtistMenu first item name matches');

	# Test handleArtistTracks and handleArtistAlbums with undef client do not crash
	my ($tracksRes, $albumsRes);
	Plugins::Zvuk::Plugin::handleArtistTracks(undef, sub { $tracksRes = shift; }, { id => '123' }, {});
	ok($tracksRes, 'handleArtistTracks handles undef client safely');
	Plugins::Zvuk::Plugin::handleArtistAlbums(undef, sub { $albumsRes = shift; }, { id => '123' }, {});
	ok($albumsRes, 'handleArtistAlbums handles undef client safely');
};

done_testing();
