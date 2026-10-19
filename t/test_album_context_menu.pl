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
require Plugins::Zvuk::Browse::InfoMenu;
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

# Test 2: albumInfoMenu full structure
my $client = Test::FakeClient->new(id => 'player1');
{
	no warnings 'once';
	$Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts} = { acctA => { token => 'tokA', name => 'A' } };
	$Slim::Utils::Prefs::CLIENT_STORE{'plugin.zvuk'}{ $client->id }{userId} = 'acctA';
}

my $menu = Plugins::Zvuk::Browse::InfoMenu::albumInfoMenu($client, 'zvuk://album:12345', undef, { album => 'Test Album' });

ok($menu, 'albumInfoMenu returned a menu');
my $items = $menu->{items};
is(scalar(@$items), 6, 'albumInfoMenu has 6 top-level items');
is($items->[0]{name}, 'ADD_TO_END', 'item 1 is Add to end');
is($items->[1]{name}, 'PLAY_NEXT', 'item 2 is Play next');
is($items->[2]{name}, 'PLAY', 'item 3 is Play');
is($items->[3]{name}, 'PLUGIN_ZVUK_ALBUM_RADIO', 'item 4 is Album Radio');
is($items->[4]{name}, 'JIVE_SAVE_TO_FAVORITES', 'item 5 is Save in favorites');
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

done_testing();
