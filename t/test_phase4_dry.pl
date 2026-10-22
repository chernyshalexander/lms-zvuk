#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;

binmode STDOUT, ':utf8';
binmode STDERR, ':utf8';
binmode Test::More->builder->output, ':utf8';
binmode Test::More->builder->failure_output, ':utf8';
binmode Test::More->builder->todo_output, ':utf8';

require "$Bin/slim_mocks.pl";
require "$Bin/test_helpers.pl";

my $repo_root = "$Bin/..";
my $tmpdir = tempdir(CLEANUP => 1);
mkdir "$tmpdir/Plugins" or die $!;
symlink($repo_root, "$tmpdir/Plugins/Zvuk") or die "symlink: $!";
unshift @INC, $tmpdir;

require Plugins::Zvuk::UI::Common;
require Plugins::Zvuk::UI::Wave;
require Plugins::Zvuk::UI::Atlas;
require Plugins::Zvuk::WebHandlers;

subtest 'Plugins::Zvuk::UI::Common::uiKind' => sub {
	my $client = Test::FakeClient->new(id => 'test_ui_client');

	# 1. Classic Web Skin
	is(Plugins::Zvuk::UI::Common::uiKind($client, { isWeb => 1 }), 'classic_web', 'isWeb returns classic_web');

	# 2. VFD buttons
	is(Plugins::Zvuk::UI::Common::uiKind($client, { isButton => 1 }), 'player_buttons', 'isButton returns player_buttons');

	# 3. Web-capable
	{
		no warnings 'redefine';
		local *Slim::Utils::Misc::canFollowWeblinks = sub { return 1; };
		is(Plugins::Zvuk::UI::Common::uiKind($client, {}), 'weblink_capable', 'canFollowWeblinks returns weblink_capable');
	}

	# 4. SqueezePlay / Jive
	{
		no warnings 'redefine';
		local *Slim::Utils::Misc::canFollowWeblinks = sub { return 0; };
		local *Test::FakeClient::controllerUA = sub { return 'SqueezePlay/7.8.0'; };
		is(Plugins::Zvuk::UI::Common::uiKind($client, {}), 'jive', 'SqueezePlay UA returns jive');
	}

	# 5. Default fallback
	{
		no warnings 'redefine';
		local *Slim::Utils::Misc::canFollowWeblinks = sub { return 0; };
		local *Test::FakeClient::controllerUA = sub { return undef; };
		is(Plugins::Zvuk::UI::Common::uiKind($client, {}), 'jive', 'fallback returns jive');
	}

	# 6. UI::Wave and UI::Atlas delegate _uiKind to UI::Common
	is(Plugins::Zvuk::UI::Wave::_uiKind($client, { isButton => 1 }), 'player_buttons', 'UI::Wave::_uiKind delegates to UI::Common');
	is(Plugins::Zvuk::UI::Atlas::_uiKind($client, { isWeb => 1 }), 'classic_web', 'UI::Atlas::_uiKind delegates to UI::Common');
};

subtest 'Plugins::Zvuk::UI::Common::popVfdMode' => sub {
	my $client = Test::FakeClient->new(id => 'test_pop_client');
	my $pop_called = 0;
	my $current_mode = 'xmlbrowser';

	{
		no warnings 'redefine', 'once';
		local *Slim::Buttons::Common::mode = sub { return $current_mode; };
		local *Slim::Buttons::Common::popMode = sub { $pop_called++; };

		Plugins::Zvuk::UI::Common::popVfdMode($client);
		is($pop_called, 1, 'popMode called when mode is xmlbrowser');

		$current_mode = 'playlist';
		Plugins::Zvuk::UI::Common::popVfdMode($client);
		is($pop_called, 1, 'popMode NOT called when mode is playlist');

		# Undef client safety
		Plugins::Zvuk::UI::Common::popVfdMode(undef);
		is($pop_called, 1, 'popMode safely handles undef client');
	}
};

subtest 'WebHandlers JSON response helpers' => sub {
	my $req = Test::FakeRequest->new();
	my $resp = Test::FakeResponse->new($req);

	@Slim::Web::HTTP::CAPTURED_RESPONSES = ();
	Plugins::Zvuk::WebHandlers::_sendJsonResponse(undef, $resp, { foo => 'bar', n => 42 });

	is(scalar(@Slim::Web::HTTP::CAPTURED_RESPONSES), 1, 'captured one response');
	is($resp->code(), 200, 'default status code is 200');
	is($resp->content_type(), 'application/json; charset=utf-8', 'Content-Type has UTF-8 charset');

	my $body = $Slim::Web::HTTP::CAPTURED_RESPONSES[0]{body};
	like($body, qr/"foo":"bar"/, 'body has foo:bar');
	like($body, qr/"n":42/, 'body has n:42');

	# Test error helper with extra fields
	@Slim::Web::HTTP::CAPTURED_RESPONSES = ();
	my $resp_err = Test::FakeResponse->new($req);
	Plugins::Zvuk::WebHandlers::_sendJsonError(undef, $resp_err, 'Blocked by WAF', 403, { blocked => 1, custom => 'abc' });

	is($resp_err->code(), 403, 'error status code is 403');
	my $err_body = $Slim::Web::HTTP::CAPTURED_RESPONSES[0]{body};
	like($err_body, qr/"success":0/, 'success is 0');
	like($err_body, qr/"error":"Blocked by WAF"/, 'error message matches');
	like($err_body, qr/"blocked":1/, 'extra blocked field present');
	like($err_body, qr/"custom":"abc"/, 'extra custom field present');
};

subtest 'WebHandlers OAuth template and WaveSettings rendering' => sub {
	# Check physical existence of template
	my $template_path = "$repo_root/HTML/EN/plugins/zvuk/oauthCallback.html";
	ok(-f $template_path, 'oauthCallback.html exists');
	ok(-s $template_path > 500, 'oauthCallback.html is non-empty (>500 bytes)');

	my $req = Test::FakeRequest->new();
	my $resp = Test::FakeResponse->new($req);

	@Slim::Web::HTTP::CAPTURED_RESPONSES = ();
	Plugins::Zvuk::WebHandlers::handleOAuthCallback(undef, $resp);
	is($resp->code(), 200, 'handleOAuthCallback returns HTTP 200');
	is($resp->content_type(), 'text/html; charset=utf-8', 'handleOAuthCallback content-type is text/html');
	is(scalar(@Slim::Web::HTTP::CAPTURED_RESPONSES), 1, 'handleOAuthCallback added response');

	# WaveSettings WebUI & Standalone
	@Slim::Web::HTTP::CAPTURED_RESPONSES = ();
	my $resp_web = Test::FakeResponse->new($req);
	Plugins::Zvuk::WebHandlers::handleWaveSettingsWebUI(undef, $resp_web);
	is($resp_web->code(), 200, 'handleWaveSettingsWebUI returns 200');

	@Slim::Web::HTTP::CAPTURED_RESPONSES = ();
	my $resp_std = Test::FakeResponse->new($req);
	Plugins::Zvuk::WebHandlers::handleWaveSettingsStandalone(undef, $resp_std);
	is($resp_std->code(), 200, 'handleWaveSettingsStandalone returns 200');
};

done_testing();
