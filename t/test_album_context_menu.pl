#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
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
require Plugins::Zvuk::UI::InfoMenu;
require Plugins::Zvuk::API::Async;

# Test 1: _renderRelease structure
my $release = {
	id    => '12345',
	title => 'Test Album',
	artists => [{ title => 'Test Artist' }],
};

my $item = Plugins::Zvuk::Plugin::_renderRelease($release);

is($item->{type}, 'playlist', 'album item has type => playlist');
is($item->{play}, 'zvuk://album:12345', 'album item has play URL');
is($item->{favorites_url}, 'zvuk://album:12345', 'album item has favorites_url');
is($item->{favorites_type}, 'playlist', 'album item has favorites_type => playlist');
ok($item->{itemActions}, 'album item has itemActions');
is($item->{itemActions}{info}{command}[0], 'zvuk_info', 'info action points to zvuk_info');
is_deeply($item->{itemActions}{play}{command}, ['playlist', 'play', 'zvuk://album:12345', '', 0], 'renderRelease has play command with URL in slot 2');
is_deeply($item->{itemActions}{add}{command}, ['playlist', 'add', 'zvuk://album:12345', ''], 'renderRelease has add command with URL in slot 2');
is_deeply($item->{itemActions}{insert}{command}, ['playlist', 'insert', 'zvuk://album:12345', ''], 'renderRelease has insert command with URL in slot 2');

# Test 2: albumInfoMenu full structure
my $client = Test::FakeClient->new(id => 'player1');
{
	no warnings 'once';
	$Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts} = { acctA => { token => 'tokA', name => 'A' } };
	$Slim::Utils::Prefs::CLIENT_STORE{'plugin.zvuk'}{ $client->id }{userId} = 'acctA';
}

my $menu = Plugins::Zvuk::UI::InfoMenu::albumInfoMenu($client, 'zvuk://album:12345', undef, { album => 'Test Album' });

ok($menu, 'albumInfoMenu returned a menu');
my $items = $menu->{items};
is(scalar(@$items), 6, 'albumInfoMenu has 6 top-level items');
is($items->[0]{name}, 'ADD_TO_END', 'item 1 is Add to end');
is_deeply($items->[0]{itemActions}{items}{command}, ['playlist', 'add', 'zvuk://album:12345', ''], 'ADD_TO_END has items command for XMLBrowser');
is_deeply($items->[0]{itemActions}{add}{command}, ['playlist', 'add', 'zvuk://album:12345', ''], 'ADD_TO_END has add command for XMLBrowser');
is_deeply($items->[0]{itemActions}{go}{cmd}, ['playlist', 'add', 'zvuk://album:12345', ''], 'ADD_TO_END cmd contains targetUrl in positional slot 2');
is($items->[0]{itemActions}{go}{params}{url}, 'zvuk://album:12345', 'ADD_TO_END params retains url');
is_deeply($items->[0]{jive}{actions}{go}{cmd}, ['playlist', 'add', 'zvuk://album:12345', ''], 'ADD_TO_END has jive.actions.go');

is($items->[1]{name}, 'PLAY_NEXT', 'item 2 is Play next');
is_deeply($items->[1]{itemActions}{items}{command}, ['playlist', 'insert', 'zvuk://album:12345', ''], 'PLAY_NEXT has items command for XMLBrowser');
is_deeply($items->[1]{itemActions}{insert}{command}, ['playlist', 'insert', 'zvuk://album:12345', ''], 'PLAY_NEXT has insert command for XMLBrowser');
is_deeply($items->[1]{itemActions}{go}{cmd}, ['playlist', 'insert', 'zvuk://album:12345', ''], 'PLAY_NEXT cmd contains targetUrl in positional slot 2');
is($items->[1]{itemActions}{go}{params}{url}, 'zvuk://album:12345', 'PLAY_NEXT params retains url');
is_deeply($items->[1]{jive}{actions}{go}{cmd}, ['playlist', 'insert', 'zvuk://album:12345', ''], 'PLAY_NEXT has jive.actions.go');

is($items->[2]{name}, 'PLAY', 'item 3 is Play');
is_deeply($items->[2]{itemActions}{items}{command}, ['playlist', 'play', 'zvuk://album:12345', '', 0], 'PLAY has items command for XMLBrowser');
is_deeply($items->[2]{itemActions}{play}{command}, ['playlist', 'play', 'zvuk://album:12345', '', 0], 'PLAY has play command for XMLBrowser');
is_deeply($items->[2]{itemActions}{go}{cmd}, ['playlist', 'play', 'zvuk://album:12345', '', 0], 'PLAY cmd contains targetUrl in positional slot 2');
is($items->[2]{itemActions}{go}{params}{url}, 'zvuk://album:12345', 'PLAY params retains url');
is_deeply($items->[2]{jive}{actions}{go}{cmd}, ['playlist', 'play', 'zvuk://album:12345', '', 0], 'PLAY has jive.actions.go');

is($items->[3]{name}, 'PLUGIN_ZVUK_ALBUM_RADIO', 'item 4 is Album Radio');
is($items->[4]{name}, 'JIVE_SAVE_TO_FAVORITES', 'item 5 is Save in favorites');
is_deeply($items->[4]{itemActions}{items}{command}, ['jivefavorites', 'add'], 'JIVE_SAVE_TO_FAVORITES has items command');
is_deeply($items->[4]{jive}{actions}{go}{cmd}, ['jivefavorites', 'add'], 'JIVE_SAVE_TO_FAVORITES has jive.actions.go');
is($items->[5]{name}, 'PLUGIN_ZVUK_ON_ZVUK', 'item 6 is On Zvuk... submenu');

my $sub_items = $items->[5]{items};
ok($sub_items, 'On Zvuk... has sub-items');
is(scalar(@$sub_items), 2, 'On Zvuk... has 2 sub-items');
is($sub_items->[0]{name}, 'PLUGIN_ZVUK_LIKE_ALBUM', 'sub-item 1 is Save Album to Collection');
is($sub_items->[1]{name}, 'PLUGIN_ZVUK_UNLIKE_ALBUM', 'sub-item 2 is Remove Album from Collection');

# Test 3: GQL likeRelease and unlikeRelease mutation dispatch
my $async = Plugins::Zvuk::API::Async->new({ userId => '123' });
my $last_gql;

no warnings 'redefine';
local *Plugins::Zvuk::API::Async::_graphql = sub {
	my ($self, $cb, $op, $gql, $vars) = @_;
	$last_gql = { op => $op, gql => $gql, vars => $vars };
	$cb->({ data => { addCollectionItem => 1 } });
};
use warnings 'redefine';

$async->likeRelease(sub {}, '12345');
is($last_gql->{op}, 'addItemToCollection', 'likeRelease op name is addItemToCollection');
like($last_gql->{gql}, qr/collection\s*\{\s*addItem\(id:\s*\$id,\s*type:\s*\$type\)/, 'likeRelease query uses collection.addItem');
is($last_gql->{vars}{id}, '12345', 'likeRelease passes release ID');
is($last_gql->{vars}{type}, 'release', 'likeRelease passes type release');

$async->unlikeRelease(sub {}, '12345');
is($last_gql->{op}, 'removeItemFromCollection', 'unlikeRelease op name is removeItemFromCollection');
like($last_gql->{gql}, qr/collection\s*\{\s*removeItem\(id:\s*\$id,\s*type:\s*\$type\)/, 'unlikeRelease query uses collection.removeItem');
is($last_gql->{vars}{id}, '12345', 'unlikeRelease passes release ID');
is($last_gql->{vars}{type}, 'release', 'unlikeRelease passes type release');

# Test 4: SqueezePlay JSON action construction and LMS CLI dispatch simulation
{
	# SqueezePlay's _performJSONAction builds request array:
	# [ ...cmd, from, qty, ...params (k:v), 'useContextMenu:1' ]
	my $play_action = $items->[2]{itemActions}{go};
	my @sp_request = @{ $play_action->{cmd} };
	push @sp_request, 0, 200;
	for my $k (sort keys %{ $play_action->{params} || {} }) {
		push @sp_request, "$k:" . $play_action->{params}{$k};
	}
	push @sp_request, 'useContextMenu:1';

	# Verify tokens as received by LMS CLI dispatcher
	is($sp_request[0], 'playlist', 'SP token 0 is playlist');
	is($sp_request[1], 'play', 'SP token 1 is play');
	is($sp_request[2], 'zvuk://album:12345', 'SP token 2 (_item) is the target album URL');
	is($sp_request[3], '', 'SP token 3 (_title) is empty string');
	is($sp_request[4], 0, 'SP token 4 (_fadein) is 0');

	# Simulate LMS CLI dispatch extraction for ['playlist', 'play', '_item', '_title', '_fadein']
	my %lms_params;
	my @spec = ('_item', '_title', '_fadein');
	my $idx = 2;
	for my $param (@spec) {
		$lms_params{$param} = $sp_request[$idx++];
	}
	is($lms_params{'_item'}, 'zvuk://album:12345', 'LMS extracts _item as zvuk://album:12345');
	is($lms_params{'_title'}, '', 'LMS extracts _title as empty');
	is($lms_params{'_fadein'}, 0, 'LMS extracts _fadein as 0');
}

# Test 5: explodePlaylist expands zvuk://album:12345
require Plugins::Zvuk::ProtocolHandler;
{
	no warnings qw(redefine once);
	local *Plugins::Zvuk::Plugin::handleAlbum = sub {
		my ($cl, $cb, $args, $params) = @_;
		is($params->{id}, '12345', 'handleAlbum called with album id 12345');
		$cb->({
			items => [
				{ url => 'zvuk://1001', title => 'Track 1' },
				{ url => 'zvuk://1002', title => 'Track 2' },
			],
		});
	};
	use warnings 'redefine';

	my $exploded;
	Plugins::Zvuk::ProtocolHandler->explodePlaylist($client, 'zvuk://album:12345', sub {
		$exploded = shift;
	});

	ok($exploded, 'explodePlaylist callback invoked');
	is_deeply($exploded, ['zvuk://1001', 'zvuk://1002'], 'explodePlaylist resolved album tracks to array of URLs');
}

# Test 6: Verify LMS XMLBrowser _makeAction and jive resolution logic
{
	# LMS XMLBrowser::_makeAction helper emulation (Slim/Control/XMLBrowser.pm:1665)
	my $_makeAction = sub {
		my ($actions, $actionName, $player, $contextMenu, $nextWindow) = @_;
		if (my $action = $actions->{$actionName}) {
			return undef unless $action->{command} && scalar @{$action->{command}};
			my $params = { %{ $action->{fixedParams} || {} } };
			$params->{menu} ||= 1;
			my %act = (
				cmd    => $action->{command},
				params => $params,
			);
			$act{player} ||= 0 if $player;
			$act{window} = { isContextMenu => 1 } if $contextMenu;
			$act{nextWindow} = $nextWindow if $nextWindow;
			return \%act;
		}
		return undef;
	};

	my $play_item = $items->[2];

	# 1. XMLBrowser extracts actions->{go} via _makeAction(itemActions, 'items')
	my $extracted_go = $_makeAction->($play_item->{itemActions}, 'items', 1, 0, $play_item->{nextWindow});
	ok($extracted_go, 'XMLBrowser extracts actions.go from itemActions.items');
	is_deeply($extracted_go->{cmd}, ['playlist', 'play', 'zvuk://album:12345', '', 0], 'extracted actions.go has playlist play with targetUrl');
	is($extracted_go->{nextWindow}, 'nowPlaying', 'extracted actions.go has nextWindow nowPlaying');
	is($extracted_go->{player}, 0, 'extracted actions.go has player 0');

	# 2. XMLBrowser extracts actions->{play} via _makeAction(itemActions, 'play')
	my $extracted_play = $_makeAction->($play_item->{itemActions}, 'play', 1, 0, 'nowPlaying');
	ok($extracted_play, 'XMLBrowser extracts actions.play from itemActions.play');
	is_deeply($extracted_play->{cmd}, ['playlist', 'play', 'zvuk://album:12345', '', 0], 'extracted actions.play has playlist play with targetUrl');

	# 3. XMLBrowser applies jive.actions.go override (XMLBrowser.pm:1354-1360)
	ok($play_item->{jive} && $play_item->{jive}{actions}{go}, 'play item defines jive.actions.go');
	is_deeply($play_item->{jive}{actions}{go}{cmd}, ['playlist', 'play', 'zvuk://album:12345', '', 0], 'jive.actions.go has playlist play with targetUrl');

	# 4. Old buggy structure demonstration:
	# If an item only has itemActions->{go} without 'items' or 'jive',
	# _makeAction looks for 'items' and gets undef, resulting in no go action,
	# causing XMLBrowser to fall back to ['zvuk_info', 'items'] which fails playback.
	my $buggy_itemActions = {
		go => { player => 0, cmd => ['playlist', 'play'], params => { url => 'zvuk://album:12345' } },
	};
	my $buggy_go = $_makeAction->($buggy_itemActions, 'items', 1, 0, 'nowPlaying');
	is($buggy_go, undef, 'Old structure without "items" key fails XMLBrowser _makeAction resolution');
}

done_testing();
