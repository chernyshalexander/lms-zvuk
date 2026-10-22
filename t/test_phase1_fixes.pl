#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use open qw(:std :utf8);
no warnings 'once';

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
require Plugins::Zvuk::API;
require Plugins::Zvuk::API::Async;
require Plugins::Zvuk::WebHandlers;
require Plugins::Zvuk::ProtocolHandler;
require Plugins::Zvuk::UI::GigaMix;

# =========================================================================
# 1. WebHandlers::handleImageProxy Security & Allowlist
# =========================================================================
subtest 'WebHandlers::handleImageProxy security allowlist' => sub {
    my $client = Test::FakeClient->new(id => 'img_client');
    $Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts} = {
        'default' => { token => 'secret_token_123', name => 'Default User' }
    };

    # 1a: Missing url parameter -> 400 Bad Request
    {
        @Slim::Web::HTTP::CAPTURED_RESPONSES = ();
        my $req = Test::FakeRequest->new(client => $client, query => {});
        my $conn = bless {}, 'Test::FakeHTTPConnection';
        my $resp = Test::FakeResponse->new($req);

        Plugins::Zvuk::WebHandlers::handleImageProxy($conn, $resp);

        is(scalar @Slim::Web::HTTP::CAPTURED_RESPONSES, 1, 'Missing url: captured response');
        is($Slim::Web::HTTP::CAPTURED_RESPONSES[0]{response}->code, 400, 'HTTP 400 returned');
        is($Slim::Web::HTTP::CAPTURED_RESPONSES[0]{body}, 'Missing url parameter', 'Correct 400 message');
    }

    # 1b: Untrusted external URLs -> 403 Forbidden
    my @untrusted_urls = (
        'http://evil.com/image.png',
        'https://evil.com/image.png',
        'https://attacker.org/zvuk.com/avatar.jpg',
        'https://zvuk.com.attacker.com/evil.png',
        'https://evil-zvuk.com/photo.jpg',
        'http://zvuk.com/image.png', # insecure http must be blocked
        'ftp://zvuk.com/image.png',
        'javascript:alert(1)',
        'data:text/html,evil',
    );

    for my $bad_url (@untrusted_urls) {
        @Slim::Web::HTTP::CAPTURED_RESPONSES = ();
        @Slim::Networking::SimpleAsyncHTTP::POST_LOG = ();
        my $req = Test::FakeRequest->new(client => $client, query => { url => $bad_url });
        my $conn = bless {}, 'Test::FakeHTTPConnection';
        my $resp = Test::FakeResponse->new($req);

        Plugins::Zvuk::WebHandlers::handleImageProxy($conn, $resp);

        is(scalar @Slim::Web::HTTP::CAPTURED_RESPONSES, 1, "Blocked untrusted url: $bad_url");
        is($Slim::Web::HTTP::CAPTURED_RESPONSES[0]{response}->code, 403, "HTTP 403 for $bad_url");
        is($Slim::Web::HTTP::CAPTURED_RESPONSES[0]{body}, 'Forbidden: untrusted image host', "403 message for $bad_url");
        is(scalar @Slim::Networking::SimpleAsyncHTTP::POST_LOG, 0, "No HTTP request dispatched for $bad_url");
    }

    # 1c: Trusted Zvuk CDN & web URLs -> 200 OK + auth headers attached
    my @trusted_urls = (
        'https://zvuk.com/pic.jpg',
        'https://cdn.zvuk.com/pic_150x150_f.jpg',
        'https://image.zvuk.ru/artist_50x50_o.png',
        'https://sberzvuk.com/cover.jpg',
        'https://img.sberzvuk.com/cover.jpg',
    );

    for my $good_url (@trusted_urls) {
        @Slim::Web::HTTP::CAPTURED_RESPONSES = ();
        @Slim::Networking::SimpleAsyncHTTP::POST_LOG = ();
        @Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
            { code => 200, content => 'FAKE_IMAGE_DATA', content_type => 'image/jpeg' }
        );

        my $req = Test::FakeRequest->new(client => $client, query => { url => $good_url });
        my $conn = bless {}, 'Test::FakeHTTPConnection';
        my $resp = Test::FakeResponse->new($req);

        Plugins::Zvuk::WebHandlers::handleImageProxy($conn, $resp);

        is(scalar @Slim::Networking::SimpleAsyncHTTP::POST_LOG, 1, "Dispatched request for $good_url");
        my $log_entry = $Slim::Networking::SimpleAsyncHTTP::POST_LOG[0];
        is($log_entry->{method}, 'GET', 'Used GET method');

        # Verify size suffix stripping: _150x150_f.jpg -> .jpg
        my ($requested_url, %req_headers) = @{ $log_entry->{args} };
        unlike($requested_url, qr/_\d+x\d+_[a-z]\./, 'Stripped resize suffix from URL');
        is($req_headers{'x-auth-token'}, 'secret_token_123', 'Auth token header attached for trusted host');
        is($req_headers{'Cookie'}, 'auth=secret_token_123', 'Cookie auth attached for trusted host');

        is(scalar @Slim::Web::HTTP::CAPTURED_RESPONSES, 1, "Response sent to LMS for $good_url");
        is($Slim::Web::HTTP::CAPTURED_RESPONSES[0]{response}->code, 200, "HTTP 200 returned for $good_url");
        is($Slim::Web::HTTP::CAPTURED_RESPONSES[0]{body}, 'FAKE_IMAGE_DATA', 'Content forwarded');
    }
};

# =========================================================================
# 2. ProtocolHandler DRM FLAC Fallback
# =========================================================================
subtest 'ProtocolHandler flacdrm skipping and fallback' => sub {
    my $client = Test::FakeClient->new(id => 'ph_client');
    my $song = Test::FakeSong->new(url => 'zvuk://1001', client => $client);

    # Set quality preference to 'flac'
    $Slim::Utils::Prefs::STORE{'plugin.zvuk'}{quality} = 'flac';

    # 2a: flac is present -> chooses flac, format 'flc'
    {
        no warnings 'redefine';
        local *Plugins::Zvuk::API::Async::getStream = sub {
            my ($self, $cb, $id) = @_;
            $cb->([{
                duration => 180,
                stream   => {
                    flac    => 'https://stream.zvuk.com/track.flac',
                    flacdrm => 'https://drm.zvuk.com/track.flacdrm',
                    high    => 'https://stream.zvuk.com/track_320.mp3',
                    mid     => 'https://stream.zvuk.com/track_128.mp3',
                }
            }]);
        };

        my $error;
        Plugins::Zvuk::ProtocolHandler->getNextTrack($song, sub {}, sub { $error = shift });

        ok(!$error, 'No error in getNextTrack with flac');
        is($song->streamUrl, 'https://stream.zvuk.com/track.flac', 'Selected unencrypted flac URL');
        is($song->pluginData('format'), 'flc', 'Format is flc');
    }

    # 2b: flac is absent, but flacdrm and high are present -> must skip flacdrm and select high (MP3 320)
    {
        no warnings 'redefine';
        local *Plugins::Zvuk::API::Async::getStream = sub {
            my ($self, $cb, $id) = @_;
            $cb->([{
                duration => 180,
                stream   => {
                    flacdrm => 'https://drm.zvuk.com/track.flacdrm',
                    high    => 'https://stream.zvuk.com/track_320.mp3',
                    mid     => 'https://stream.zvuk.com/track_128.mp3',
                }
            }]);
        };

        my $error;
        Plugins::Zvuk::ProtocolHandler->getNextTrack($song, sub {}, sub { $error = shift });

        ok(!$error, 'No error in getNextTrack when falling back from flacdrm');
        is($song->streamUrl, 'https://stream.zvuk.com/track_320.mp3', 'Skipped flacdrm, selected high MP3');
        is($song->pluginData('format'), 'mp3', 'Format is mp3');
    }

    # 2c: flac and high are absent, flacdrm and mid are present -> selects mid MP3
    {
        no warnings 'redefine';
        local *Plugins::Zvuk::API::Async::getStream = sub {
            my ($self, $cb, $id) = @_;
            $cb->([{
                duration => 180,
                stream   => {
                    flacdrm => 'https://drm.zvuk.com/track.flacdrm',
                    mid     => 'https://stream.zvuk.com/track_128.mp3',
                }
            }]);
        };

        my $error;
        Plugins::Zvuk::ProtocolHandler->getNextTrack($song, sub {}, sub { $error = shift });

        ok(!$error, 'No error in getNextTrack when falling back to mid MP3');
        is($song->streamUrl, 'https://stream.zvuk.com/track_128.mp3', 'Skipped flacdrm, selected mid MP3');
        is($song->pluginData('format'), 'mp3', 'Format is mp3');
    }
};

# =========================================================================
# 3. API::Async::clearClient
# =========================================================================
subtest 'API::Async::clearClient argument handling' => sub {
    # Reset state
    Plugins::Zvuk::API::Async->clearClient();

    # Create two clients
    my $c1 = Plugins::Zvuk::API::Async->new({ userId => 'user1' });
    my $c2 = Plugins::Zvuk::API::Async->new({ userId => 'user2' });

    ok($c1 && $c2, 'Clients instantiated');
    is(Plugins::Zvuk::API::Async->new({ userId => 'user1' }), $c1, 'user1 returns cached instance');
    is(Plugins::Zvuk::API::Async->new({ userId => 'user2' }), $c2, 'user2 returns cached instance');

    # Clear single user by ID string: Plugins::Zvuk::API::Async->clearClient('user1')
    Plugins::Zvuk::API::Async->clearClient('user1');
    my $c1_fresh = Plugins::Zvuk::API::Async->new({ userId => 'user1' });
    isnt($c1_fresh, $c1, 'user1 cache evicted by string argument clearClient("user1")');
    is(Plugins::Zvuk::API::Async->new({ userId => 'user2' }), $c2, 'user2 still cached');

    # Clear via instance method: $c1_fresh->clearClient()
    $c1_fresh->clearClient();
    my $c1_fresh2 = Plugins::Zvuk::API::Async->new({ userId => 'user1' });
    isnt($c1_fresh2, $c1_fresh, 'user1 evicted via instance method call $client->clearClient()');
    is(Plugins::Zvuk::API::Async->new({ userId => 'user2' }), $c2, 'user2 still cached');

    # Clear all via class method with no arguments: Plugins::Zvuk::API::Async->clearClient()
    Plugins::Zvuk::API::Async->clearClient();
    my $c1_fresh3 = Plugins::Zvuk::API::Async->new({ userId => 'user1' });
    my $c2_fresh = Plugins::Zvuk::API::Async->new({ userId => 'user2' });
    isnt($c1_fresh3, $c1_fresh2, 'user1 evicted after class method clearClient()');
    isnt($c2_fresh, $c2, 'user2 evicted after class method clearClient()');
};

# =========================================================================
# 4. GigaMix Menu Rendering vs Stream Activation
# =========================================================================
subtest 'GigaMix menu rendering does not activate stream' => sub {
    my $client = Test::FakeClient->new(id => 'gigamix_client');
    $client->pluginData('zvuk_gigamix_active', 0);
    $client->pluginData('zvuk_gigamix_cursor', undef);
    $client->pluginData('zvuk_gigamix_prompt', undef);

    my $renderPlaylist = \&Plugins::Zvuk::UI::GigaMix::_renderGigaMixPlaylist;
    my $result_menu;

    $renderPlaylist->($client, sub { $result_menu = shift }, {
        genId        => 'test_gen_1',
        playlistName => 'Test AI Playlist',
        cursor       => 'cursor_abc123',
        tracks       => [
            { id => 501, title => 'Track 1' },
            { id => 502, title => 'Track 2' },
        ],
    }, 'Chill music prompt');

    ok($result_menu && @{ $result_menu->{items} }, 'Menu items returned');
    ok(!$client->pluginData('zvuk_gigamix_active'), 'zvuk_gigamix_active remains 0 after menu render');
    is($client->pluginData('zvuk_gigamix_cursor'), undef, 'zvuk_gigamix_cursor remains undef after menu render');
    is($client->pluginData('zvuk_gigamix_prompt'), undef, 'zvuk_gigamix_prompt remains undef after menu render');
};

# =========================================================================
# 5. Consolidated getShortPlaylists and _renderPlaylist
# =========================================================================
subtest 'Consolidated getShortPlaylists and _renderPlaylist' => sub {
    # 5a: getShortPlaylists includes trackCount
    my $api = Plugins::Zvuk::API::Async->new({ userId => 'user_test' });
    my @captured_args;
    {
        no warnings 'redefine';
        local *Plugins::Zvuk::API::Async::_graphql = sub {
            my ($self, $cb, $operationName, $query, $variables, $options) = @_;
            @captured_args = ($operationName, $query, $variables, $options);
            $cb->({ getPlaylists => [
                { id => 10, title => 'Editorial 1', trackCount => 25, description => 'Top tracks' }
            ] });
        };

        my $res;
        $api->getShortPlaylists(sub { $res = shift }, [10], { ttl => 300 });

        is($captured_args[0], 'getShortPlaylist', 'operationName is getShortPlaylist');
        like($captured_args[1], qr/trackCount/, 'GraphQL query includes trackCount');
        is_deeply($captured_args[2]{ids}, [10], 'variables.ids is [10]');
        is_deeply($captured_args[3], { ttl => 300 }, 'Options passed through to _graphql');
        is($res->[0]{trackCount}, 25, 'trackCount returned');
    }

    # 5b: getEditorialPlaylistMetadata delegates to getShortPlaylists
    {
        no warnings 'redefine';
        local *Plugins::Zvuk::API::Async::_graphql = sub {
            my ($self, $cb, $operationName, $query, $variables, $options) = @_;
            @captured_args = ($operationName, $query, $variables, $options);
            $cb->({ getPlaylists => [{ id => 20, title => 'Editorial 2' }] });
        };

        my $res;
        $api->getEditorialPlaylistMetadata(sub { $res = shift }, [20]);

        is($captured_args[0], 'getShortPlaylist', 'getEditorialPlaylistMetadata used getShortPlaylist');
        is_deeply($captured_args[3], { ttl => Plugins::Zvuk::API::DYNAMIC_TTL() }, 'Used dynamic TTL');
    }

    # 5c: _renderPlaylist includes line1 and line2
    my $playlist_item = Plugins::Zvuk::Plugin::_renderPlaylist({
        id          => 30,
        title       => 'Summer Vibes',
        description => 'Best summer songs',
    });
    is($playlist_item->{name}, 'Summer Vibes', 'name is Summer Vibes');
    is($playlist_item->{line1}, 'Summer Vibes', 'line1 is Summer Vibes');
    is($playlist_item->{line2}, 'Best summer songs', 'line2 is Best summer songs');
    is($playlist_item->{type}, 'link', 'type is link');

    # 5d: _renderEditorialPlaylist produces identical structure
    my $editorial_item = Plugins::Zvuk::Plugin::_renderEditorialPlaylist({
        id          => 30,
        title       => 'Summer Vibes',
        description => 'Best summer songs',
    });
    is_deeply($editorial_item, $playlist_item, '_renderEditorialPlaylist returns identical item');
};

# =========================================================================
# 6. Strings.txt: PLUGIN_ZVUK_ARTISTS token definition
# =========================================================================
subtest 'strings.txt: PLUGIN_ZVUK_ARTISTS is defined' => sub {
    open my $fh, '<:encoding(UTF-8)', "$Bin/../strings.txt" or die "Cannot open strings.txt: $!";
    my $content = do { local $/; <$fh> };
    close $fh;

    ok($content =~ /^PLUGIN_ZVUK_ARTISTS\s*\n\tEN\t([^\n]+)\n\tRU\t([^\n]+)/m, 'PLUGIN_ZVUK_ARTISTS defined with EN and RU');
    is($1, 'Artists', 'EN translation is Artists');
    is($2, 'Исполнители', 'RU translation is Исполнители');
};

done_testing();
