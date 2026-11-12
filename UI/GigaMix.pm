package Plugins::Zvuk::UI::GigaMix;

use strict;
use warnings;
use utf8;

use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);
use URI::Escape qw(uri_escape_utf8);

my $log = logger('plugin.zvuk');

# --- GigaMix AI Playlist Generator ---

sub handleGigaMix {
	my ($client, $cb) = @_;

	$cb->({ items => [
		{
			name => cstring($client, 'PLUGIN_ZVUK_GIGAMIX_PROMPT'),
			type => 'search',
			url  => \&handleGigaMixSearch,
		},
	]});
}

sub handleGigaMixSearch {
	my ($client, $cb, $args) = @_;

	my $prompt = $args->{search};
	unless ($prompt && length($prompt)) {
		$cb->({ items => [
			{ name => cstring($client, 'PLUGIN_ZVUK_GIGAMIX_EMPTY_PROMPT'), type => 'text' },
		]});
		return;
	}

	my $api = Plugins::Zvuk::Plugin::_get_api_client($client);

	$log->info("GigaMix: generating playlist for: $prompt");

	$api->getGenerativePlaylist(sub {
		my $result = shift || {};
		_renderGigaMixPlaylist($client, $cb, $result, $prompt);
	}, { queryText => $prompt });
}

sub handleGigaMixRemake {
	my ($client, $cb, $args, $params) = @_;
	my $api = Plugins::Zvuk::Plugin::_get_api_client($client);

	my $prompt = $params->{prompt};
	$log->info("GigaMix: remixing playlist for: $prompt");

	$api->remakeGenerativePlaylist(sub {
		my $result = shift || {};
		_renderGigaMixPlaylist($client, $cb, $result, $prompt);
	}, { queryText => $prompt });
}

sub handleGigaMixAddMore {
	my ($client, $cb, $args, $params) = @_;
	my $api = Plugins::Zvuk::Plugin::_get_api_client($client);

	my $cursor        = $params->{cursor};
	my $prompt        = $params->{prompt};
	my $initialTracks = $params->{initialTracks} || [];

	$log->info("GigaMix: adding more tracks for: $prompt");

	$api->getGenerativePlaylistPage(sub {
		my $result = shift || {};

		if ($result->{error}) {
			$log->error("GigaMix: failed to add more tracks: $result->{error}");
			$cb->({ items => [
				{ name => cstring($client, 'PLUGIN_ZVUK_GIGAMIX_ERROR_LOAD_MORE'), type => 'text' },
				{ name => "Error: $result->{error}", type => 'text' },
			]});
			return;
		}

		my $newTracks = $result->{tracks} || [];
		my $newCursor = $result->{cursor};

		$log->info("GigaMix: loaded " . scalar(@$newTracks) . " more tracks, adding to playlist");

		unless (@$newTracks) {
			$log->info("GigaMix: no more tracks available");
			$cb->({ items => [
				{ name => cstring($client, 'PLUGIN_ZVUK_GIGAMIX_NO_RESULTS') . " - плейлист исчерпан", type => 'text' },
			]});
			return;
		}

		# Add loaded tracks to the actual player playlist
		foreach my $track (@$newTracks) {
			Slim::Control::Request::executeRequest(
				$client, ['playlist', 'add', 'zvuk://' . $track->{id}]
			);
		}

		# Save GigaMix context for autoplay at end of playlist
		if ($newCursor) {
			require Plugins::Zvuk::StreamManager;
			Plugins::Zvuk::StreamManager->startStream($client, 'gigamix', {
				cursor => $newCursor,
				prompt => $prompt,
			});
		} else {
			require Plugins::Zvuk::StreamManager;
			Plugins::Zvuk::StreamManager->stopStream($client);
		}

		$log->info("GigaMix: successfully added " . scalar(@$newTracks) . " tracks to playlist");

		my @allTracks = (@$initialTracks, @$newTracks);
		my $addedMsg  = sprintf(cstring($client, 'PLUGIN_ZVUK_GIGAMIX_ADDED_TRACKS'), scalar(@$newTracks));

		if ($client && $client->can('showBriefly')) {
			$client->showBriefly({
				line     => [ cstring($client, 'PLUGIN_ZVUK_GIGAMIX'), $addedMsg ],
				duration => 1,
			});
		}

		# Transition to the updated track list (old + new tracks) after 1 second
		require Slim::Utils::Timers;
		require Time::HiRes;
		Slim::Utils::Timers::setTimer(
			undef,
			Time::HiRes::time() + 1,
			sub {
				_renderGigaMixPlaylist($client, $cb, {
					tracks => \@allTracks,
					cursor => $newCursor,
				}, $prompt);
			},
		);
	}, { cursor => $cursor, limit => 5 });
}

sub handleGigaMixNextPage {
	my ($client, $cb, $args, $params) = @_;

	my $cursor = $params->{cursor};
	my $prompt = $params->{prompt};

	unless ($cursor) {
		$log->warn("GigaMix: next page called without cursor");
		$cb->({ items => [
			{ name => cstring($client, 'PLUGIN_ZVUK_GIGAMIX_ERROR_CURSOR'), type => 'text' },
		]});
		return;
	}

	my $api = Plugins::Zvuk::Plugin::_get_api_client($client);

	$log->info("GigaMix: loading next page with cursor='$cursor'");

	$api->getGenerativePlaylistPage(sub {
		my $result = shift || {};

		if ($result->{error}) {
			$log->error("GigaMix: getGenerativePlaylistPage failed with error: $result->{error}");
			$cb->({ items => [
				{ name => cstring($client, 'PLUGIN_ZVUK_GIGAMIX_ERROR_LOAD_MORE') . " ($result->{error})", type => 'text' },
			]});
			return;
		}

		my $tracks = $result->{tracks} || [];
		my $nextCursor = $result->{cursor};

		my @items = map { Plugins::Zvuk::Plugin::_renderTrack($_, 1) } @$tracks;

		if ($nextCursor) {
			push @items, {
				name        => cstring($client, 'NEXT_PAGE'),
				type        => 'link',
				url         => \&handleGigaMixNextPage,
				passthrough => [{ cursor => $nextCursor, prompt => $prompt }],
			};
		}

		$cb->({ items => \@items });
	}, { limit => 20, cursor => $cursor });
}

sub _renderGigaMixPlaylist {
	my ($client, $cb, $result, $prompt) = @_;

	if ($result->{error}) {
		$log->error("GigaMix: generation failed: $result->{error}");
		$cb->({ items => [
			{ name => cstring($client, 'PLUGIN_ZVUK_GIGAMIX_ERROR_GENERATE'), type => 'text' },
		]});
		return;
	}

	my $playlistName = $result->{playlistName};
	my $tracks       = $result->{tracks} || [];
	my $cursor       = $result->{cursor};
	my $genId        = $result->{genId} // 'n/a';

	$log->info("GigaMix: playlist generated - genId=$genId, tracks=" . scalar(@$tracks));

	unless (@$tracks) {
		$cb->({ items => [
			{ name => cstring($client, 'PLUGIN_ZVUK_GIGAMIX_NO_RESULTS'), type => 'text' },
		]});
		return;
	}

	if ($client) {
		$client->pluginData(zvuk_gigamix_prepared => {
			prompt => $prompt,
			tracks => $tracks,
			cursor => $cursor,
		});
	}

	my @items;

	my $escaped_prompt = uri_escape_utf8($prompt // '');
	push @items, {
		name  => cstring($client, 'PLUGIN_ZVUK_GIGAMIX_PLAY_STREAM'),
		line1 => cstring($client, 'PLUGIN_ZVUK_GIGAMIX_PLAY_STREAM'),
		type  => 'audio',
		url   => "zvuk://gigamix:$escaped_prompt",
		play  => "zvuk://gigamix:$escaped_prompt",
		image => 'plugins/zvuk/html/images/gigamix_svg.png',
	};

	push @items, map { Plugins::Zvuk::Plugin::_renderTrack($_, 1) } @$tracks;

	push @items, {
		name        => cstring($client, 'PLUGIN_ZVUK_GIGAMIX_REMAKE'),
		type        => 'link',
		url         => \&handleGigaMixRemake,
		passthrough => [{ prompt => $prompt }],
		image       => 'plugins/zvuk/html/images/remake_svg.png',
	};

	# Add "More Tracks" button if cursor exists (pagination available)
	if ($cursor) {
		push @items, {
			name        => cstring($client, 'PLUGIN_ZVUK_GIGAMIX_ADD_MORE'),
			type        => 'link',
			url         => \&handleGigaMixAddMore,
			passthrough => [{ cursor => $cursor, prompt => $prompt, initialTracks => $tracks }],
			image       => 'plugins/zvuk/html/images/add_more_svg.png',
		};
	}

	$cb->({ items => \@items });
}

1;
