package Plugins::Zvuk::UI::Atlas;

use strict;
use warnings;
use utf8;

use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Prefs;

use Plugins::Zvuk::API;
use Plugins::Zvuk::UI::Common;

my $log = logger('plugin.zvuk');

sub _uiKind {
	return Plugins::Zvuk::UI::Common::uiKind(@_);
}

sub _renderIslandItem {
	my ($client, $island, $is_buttons) = @_;
	my $id = $island->{id};
	my $title = $island->{title} || 'Island';
	my $tracks = $island->{track_count} // 0;
	my $share = $island->{share} // 0;
	my $share_pct = sprintf('%.1f%%', $share * 100);

	my $line2 = "$tracks " . cstring($client, 'PLUGIN_ZVUK_ATLAS_TRACKS_COUNT') . " · $share_pct";
	my $cover = ($island->{covers} && ref $island->{covers} eq 'ARRAY' && @{ $island->{covers} })
		? $island->{covers}[0]{cover_url}
		: undef;

	my $item = {
		name        => "$title · $line2",
		line1       => $title,
		line2       => $line2,
		type        => 'outline',
		url         => \&handleIslandDetail,
		play        => "zvuk://atlas:$id",
		image       => $cover || 'plugins/zvuk/html/images/playlists.png',
		passthrough => [{ island_id => $id }],
	};

	# Never set nextWindow => 'refresh' on player_buttons to prevent Slim::Buttons popMode crash
	return $item;
}

sub handleAtlasMenu {
	my ($client, $cb, $args) = @_;

	my $api = Plugins::Zvuk::Plugin::_get_api_client($client);
	unless ($api) {
		$cb->({
			items => [{
				name => cstring($client, 'PLUGIN_ZVUK_ERROR_NOT_LOGGED_IN'),
				type => 'text',
			}]
		});
		return;
	}

	require Plugins::Zvuk::API::Atlas;
	my $userId = Plugins::Zvuk::Plugin::_getUserIdForClient($client);
	my $atlas = Plugins::Zvuk::API::Atlas->new({ userId => $userId });

	$atlas->getMap(sub {
		my ($map, $err) = @_;
		if ($err || !$map || !$map->{islands} || !@{ $map->{islands} }) {
			my $msg = $err ? (cstring($client, 'PLUGIN_ZVUK_ATLAS_ERROR') . ": $err") : cstring($client, 'PLUGIN_ZVUK_ATLAS_EMPTY');
			$cb->({
				items => [{
					name => $msg,
					type => 'text',
				}]
			});
			return;
		}

		my $kind = _uiKind($client, $args);
		my $is_buttons = ($kind eq 'player_buttons');
		my $is_weblink = ($kind eq 'classic_web' || $kind eq 'weblink_capable');

		my @items = (
			{
				name  => cstring($client, 'PLUGIN_ZVUK_ATLAS_ALL_ISLANDS'),
				type  => 'outline',
				url   => \&handleAllIslands,
				image => 'plugins/zvuk/html/images/playlists.png',
			},
			{
				name  => cstring($client, 'PLUGIN_ZVUK_ATLAS_GENRES'),
				type  => 'outline',
				url   => \&handleGenresMenu,
				image => 'html/images/musicfolder.png',
			},
			{
				name  => cstring($client, 'PLUGIN_ZVUK_ATLAS_MOODS'),
				type  => 'outline',
				url   => \&handleMoodsMenu,
				image => 'plugins/zvuk/html/images/radio.png',
			},
			{
				name      => cstring($client, 'PLUGIN_ZVUK_ATLAS_RANDOM'),
				type      => 'audio',
				url       => $is_buttons ? \&handleStartRandomIslandWave : 'zvuk://atlas:random',
				play      => 'zvuk://atlas:random',
				on_select => 'play',
				image     => 'plugins/zvuk/html/images/radio.png',
			},
		);

		if ($is_weblink) {
			push @items, {
				name    => cstring($client, 'PLUGIN_ZVUK_ATLAS_WEB_MAP'),
				type    => 'weblink',
				url     => '/plugins/zvuk/atlasStandalone.html',
				weblink => '/plugins/zvuk/atlasStandalone.html',
				image   => 'plugins/zvuk/html/images/playlists.png',
			};
		}

		$cb->({
			name  => cstring($client, 'PLUGIN_ZVUK_ATLAS'),
			title => cstring($client, 'PLUGIN_ZVUK_ATLAS'),
			items => \@items,
		});
	});
}

sub handleAllIslands {
	my ($client, $cb, $args) = @_;

	my $userId = Plugins::Zvuk::Plugin::_getUserIdForClient($client);
	require Plugins::Zvuk::API::Atlas;
	my $atlas = Plugins::Zvuk::API::Atlas->new({ userId => $userId });

	$atlas->getMap(sub {
		my ($map, $err) = @_;
		if ($err || !$map || !$map->{islands}) {
			$cb->({ items => [{ name => cstring($client, 'PLUGIN_ZVUK_ATLAS_ERROR'), type => 'text' }] });
			return;
		}

		my $kind = _uiKind($client, $args);
		my $is_buttons = ($kind eq 'player_buttons');

		# Sort islands by share descending, then track_count descending
		my @sorted = sort {
			($b->{share} // 0) <=> ($a->{share} // 0)
			|| ($b->{track_count} // 0) <=> ($a->{track_count} // 0)
		} @{ $map->{islands} };

		my @items;
		for my $island (@sorted) {
			push @items, _renderIslandItem($client, $island, $is_buttons);
		}

		$cb->({
			name  => cstring($client, 'PLUGIN_ZVUK_ATLAS_ALL_ISLANDS'),
			title => cstring($client, 'PLUGIN_ZVUK_ATLAS_ALL_ISLANDS'),
			items => \@items,
		});
	});
}

sub handleGenresMenu {
	my ($client, $cb, $args) = @_;

	my $userId = Plugins::Zvuk::Plugin::_getUserIdForClient($client);
	require Plugins::Zvuk::API::Atlas;
	my $atlas = Plugins::Zvuk::API::Atlas->new({ userId => $userId });

	$atlas->getMap(sub {
		my ($map, $err) = @_;
		if ($err || !$map || !$map->{islands}) {
			$cb->({ items => [{ name => cstring($client, 'PLUGIN_ZVUK_ATLAS_ERROR'), type => 'text' }] });
			return;
		}

		my %genres;
		for my $island (@{ $map->{islands} }) {
			my $g = $island->{genre} || 'other';
			$genres{$g} ||= { islands => [], total_tracks => 0 };
			push @{ $genres{$g}{islands} }, $island;
			$genres{$g}{total_tracks} += ($island->{track_count} || 0);
		}

		my @sorted_genres = sort {
			$genres{$b}{total_tracks} <=> $genres{$a}{total_tracks}
			|| lc($a) cmp lc($b)
		} keys %genres;

		my @items;
		for my $g (@sorted_genres) {
			my $info = $genres{$g};
			my $num_islands = scalar(@{ $info->{islands} });
			my $tracks_count = $info->{total_tracks};

			my $genre_display = ucfirst($g);
			my $name = sprintf("%s (%d %s · %d %s)",
				$genre_display,
				$num_islands,
				cstring($client, 'PLUGIN_ZVUK_ATLAS_ISLANDS_COUNT'),
				$tracks_count,
				cstring($client, 'PLUGIN_ZVUK_ATLAS_TRACKS_COUNT')
			);

			my $cover = ($info->{islands}[0]{covers} && @{ $info->{islands}[0]{covers} })
				? $info->{islands}[0]{covers}[0]{cover_url}
				: undef;

			push @items, {
				name        => $name,
				type        => 'outline',
				url         => \&handleGenreIslands,
				image       => $cover || 'html/images/musicfolder.png',
				passthrough => [{ genre => $g }],
			};
		}

		$cb->({
			name  => cstring($client, 'PLUGIN_ZVUK_ATLAS_GENRES'),
			title => cstring($client, 'PLUGIN_ZVUK_ATLAS_GENRES'),
			items => \@items,
		});
	});
}

sub handleGenreIslands {
	my ($client, $cb, $args, $params) = @_;
	my $genre = ($params && $params->{genre}) || ($args && $args->{genre});

	my $userId = Plugins::Zvuk::Plugin::_getUserIdForClient($client);
	require Plugins::Zvuk::API::Atlas;
	my $atlas = Plugins::Zvuk::API::Atlas->new({ userId => $userId });

	$atlas->getMap(sub {
		my ($map, $err) = @_;
		if ($err || !$map || !$map->{islands}) {
			$cb->({ items => [{ name => cstring($client, 'PLUGIN_ZVUK_ATLAS_ERROR'), type => 'text' }] });
			return;
		}

		my $kind = _uiKind($client, $args);
		my $is_buttons = ($kind eq 'player_buttons');

		my @islands = grep { ($_->{genre} // '') eq ($genre // '') } @{ $map->{islands} };
		my @sorted = sort {
			($b->{share} // 0) <=> ($a->{share} // 0)
			|| ($b->{track_count} // 0) <=> ($a->{track_count} // 0)
		} @islands;

		my @items;
		for my $island (@sorted) {
			push @items, _renderIslandItem($client, $island, $is_buttons);
		}

		my $title = defined $genre ? ucfirst($genre) : cstring($client, 'PLUGIN_ZVUK_ATLAS_GENRES');
		$cb->({
			name  => $title,
			title => $title,
			items => \@items,
		});
	});
}

sub handleMoodsMenu {
	my ($client, $cb, $args) = @_;

	my $userId = Plugins::Zvuk::Plugin::_getUserIdForClient($client);
	require Plugins::Zvuk::API::Atlas;
	my $atlas = Plugins::Zvuk::API::Atlas->new({ userId => $userId });

	$atlas->getMap(sub {
		my ($map, $err) = @_;
		if ($err || !$map || !$map->{islands}) {
			$cb->({ items => [{ name => cstring($client, 'PLUGIN_ZVUK_ATLAS_ERROR'), type => 'text' }] });
			return;
		}

		my %moods;
		for my $island (@{ $map->{islands} }) {
			my $m = $island->{mood} || 'other';
			$moods{$m} ||= { islands => [], total_tracks => 0 };
			push @{ $moods{$m}{islands} }, $island;
			$moods{$m}{total_tracks} += ($island->{track_count} || 0);
		}

		my @sorted_moods = sort {
			$moods{$b}{total_tracks} <=> $moods{$a}{total_tracks}
			|| lc($a) cmp lc($b)
		} keys %moods;

		my @items;
		for my $m (@sorted_moods) {
			my $info = $moods{$m};
			my $num_islands = scalar(@{ $info->{islands} });
			my $tracks_count = $info->{total_tracks};

			my $mood_display = ucfirst($m);
			my $name = sprintf("%s (%d %s · %d %s)",
				$mood_display,
				$num_islands,
				cstring($client, 'PLUGIN_ZVUK_ATLAS_ISLANDS_COUNT'),
				$tracks_count,
				cstring($client, 'PLUGIN_ZVUK_ATLAS_TRACKS_COUNT')
			);

			my $cover = ($info->{islands}[0]{covers} && @{ $info->{islands}[0]{covers} })
				? $info->{islands}[0]{covers}[0]{cover_url}
				: undef;

			push @items, {
				name        => $name,
				type        => 'outline',
				url         => \&handleMoodIslands,
				image       => $cover || 'plugins/zvuk/html/images/radio.png',
				passthrough => [{ mood => $m }],
			};
		}

		$cb->({
			name  => cstring($client, 'PLUGIN_ZVUK_ATLAS_MOODS'),
			title => cstring($client, 'PLUGIN_ZVUK_ATLAS_MOODS'),
			items => \@items,
		});
	});
}

sub handleMoodIslands {
	my ($client, $cb, $args, $params) = @_;
	my $mood = ($params && $params->{mood}) || ($args && $args->{mood});

	my $userId = Plugins::Zvuk::Plugin::_getUserIdForClient($client);
	require Plugins::Zvuk::API::Atlas;
	my $atlas = Plugins::Zvuk::API::Atlas->new({ userId => $userId });

	$atlas->getMap(sub {
		my ($map, $err) = @_;
		if ($err || !$map || !$map->{islands}) {
			$cb->({ items => [{ name => cstring($client, 'PLUGIN_ZVUK_ATLAS_ERROR'), type => 'text' }] });
			return;
		}

		my $kind = _uiKind($client, $args);
		my $is_buttons = ($kind eq 'player_buttons');

		my @islands = grep { ($_->{mood} // '') eq ($mood // '') } @{ $map->{islands} };
		my @sorted = sort {
			($b->{share} // 0) <=> ($a->{share} // 0)
			|| ($b->{track_count} // 0) <=> ($a->{track_count} // 0)
		} @islands;

		my @items;
		for my $island (@sorted) {
			push @items, _renderIslandItem($client, $island, $is_buttons);
		}

		my $title = defined $mood ? ucfirst($mood) : cstring($client, 'PLUGIN_ZVUK_ATLAS_MOODS');
		$cb->({
			name  => $title,
			title => $title,
			items => \@items,
		});
	});
}

sub handleIslandDetail {
	my ($client, $cb, $args, $params) = @_;
	my $island_id = ($params && $params->{island_id}) || ($args && $args->{island_id});

	unless ($island_id) {
		$cb->({ items => [{ name => cstring($client, 'PLUGIN_ZVUK_ATLAS_ERROR'), type => 'text' }] });
		return;
	}

	my $userId = Plugins::Zvuk::Plugin::_getUserIdForClient($client);
	require Plugins::Zvuk::API::Atlas;
	my $atlas = Plugins::Zvuk::API::Atlas->new({ userId => $userId });

	$atlas->getMap(sub {
		my ($map, $err) = @_;
		my $island;
		if ($map && $map->{islands}) {
			($island) = grep { $_->{id} eq $island_id } @{ $map->{islands} };
		}

		my $kind = _uiKind($client, $args);
		my $is_buttons = ($kind eq 'player_buttons');

		my $title = $island ? $island->{title} : 'Island';
		my $cover = ($island && $island->{covers} && @{ $island->{covers} })
			? $island->{covers}[0]{cover_url}
			: 'plugins/zvuk/html/images/playlists.png';

		my @items = (
			{
				name        => cstring($client, 'PLUGIN_ZVUK_ATLAS_PLAY_STREAM'),
				type        => 'audio',
				url         => $is_buttons ? \&handleStartIslandWave : "zvuk://atlas:$island_id",
				play        => "zvuk://atlas:$island_id",
				on_select   => 'play',
				image       => $cover,
				passthrough => [{ island_id => $island_id }],
			},
			{
				name        => cstring($client, 'PLUGIN_ZVUK_ATLAS_TRACKS'),
				type        => 'outline',
				url         => \&handleIslandTrackList,
				image       => $cover,
				passthrough => [{ island_id => $island_id }],
			},
		);

		$cb->({
			name  => $title,
			title => $title,
			items => \@items,
		});
	});
}

sub handleIslandTrackList {
	my ($client, $cb, $args, $params) = @_;
	my $island_id = ($params && $params->{island_id}) || ($args && $args->{island_id});

	unless ($island_id) {
		$cb->({ items => [{ name => cstring($client, 'PLUGIN_ZVUK_ATLAS_ERROR'), type => 'text' }] });
		return;
	}

	my $userId = Plugins::Zvuk::Plugin::_getUserIdForClient($client);
	require Plugins::Zvuk::API::Atlas;
	my $atlas = Plugins::Zvuk::API::Atlas->new({ userId => $userId });

	$atlas->getIslandTracks(sub {
		my ($data, $err) = @_;
		if ($err || !$data || !$data->{tracks}) {
			$cb->({ items => [{ name => cstring($client, 'PLUGIN_ZVUK_ATLAS_ERROR'), type => 'text' }] });
			return;
		}

		my $tracks = $data->{tracks} || [];

		# Normalize tracks for metadata cache
		my @norm_tracks;
		for my $t (@$tracks) {
			my %copy = %$t;
			$copy{id} = $copy{track_id} if !$copy{id} && $copy{track_id};
			push @norm_tracks, \%copy;
		}
		Plugins::Zvuk::API->cacheTrackMetadata(\@norm_tracks);

		my @items;
		for my $track (@norm_tracks) {
			my $track_id = $track->{id};
			my $title = $track->{title} || 'Track';
			my $artist = $track->{artist} || '';
			my $name = $artist ? "$artist - $title" : $title;

			push @items, {
				name      => $name,
				line1     => $title,
				line2     => $artist,
				type      => 'audio',
				url       => "zvuk://$track_id",
				play      => "zvuk://$track_id",
				on_select => 'play',
				image     => $track->{cover_url},
			};
		}

		$cb->({
			name  => $data->{title} || cstring($client, 'PLUGIN_ZVUK_ATLAS_TRACKS'),
			title => $data->{title} || cstring($client, 'PLUGIN_ZVUK_ATLAS_TRACKS'),
			items => \@items,
		});
	}, $island_id);
}

sub handleStartIslandWave {
	my ($client, $cb, $args, $params) = @_;
	unless ($client) {
		$cb->() if $cb && ref($cb) eq 'CODE';
		return;
	}

	my $island_id = ($params && $params->{island_id}) || ($args && $args->{island_id});
	unless ($island_id) {
		$cb->() if $cb && ref($cb) eq 'CODE';
		return;
	}

	$log->info("Starting Atlas Island Wave playback for client " . ($client->name || ref($client) || ''));

	if (_uiKind($client, $args) eq 'player_buttons') {
		Plugins::Zvuk::UI::Common::popVfdMode($client);
	}

	$client->execute(['playlist', 'play', "zvuk://atlas:$island_id"]);

	if (defined &Slim::Buttons::Common::pushModeLeft) {
		if ((Slim::Buttons::Common::mode($client) || '') ne 'playlist') {
			Slim::Buttons::Common::pushModeLeft($client, 'playlist');
		}
	}

	$cb->() if $cb && ref($cb) eq 'CODE';
}

sub handleStartRandomIslandWave {
	my ($client, $cb, $args) = @_;
	unless ($client) {
		$cb->() if $cb && ref($cb) eq 'CODE';
		return;
	}

	my $userId = Plugins::Zvuk::Plugin::_getUserIdForClient($client);
	require Plugins::Zvuk::API::Atlas;
	my $atlas = Plugins::Zvuk::API::Atlas->new({ userId => $userId });

	$atlas->getMap(sub {
		my ($map, $err) = @_;
		my $islands = ($map && $map->{islands}) ? $map->{islands} : [];
		unless (@$islands) {
			$cb->() if $cb && ref($cb) eq 'CODE';
			return;
		}

		my $random_idx = int(rand(scalar(@$islands)));
		my $chosen = $islands->[$random_idx];
		my $island_id = $chosen->{id};

		$log->info("Starting Random Atlas Island Wave: " . ($chosen->{title} || '') . " ($island_id)");

		if (_uiKind($client, $args) eq 'player_buttons') {
			Plugins::Zvuk::UI::Common::popVfdMode($client);
		}

		$client->execute(['playlist', 'play', "zvuk://atlas:$island_id"]);

		if (defined &Slim::Buttons::Common::pushModeLeft) {
			if ((Slim::Buttons::Common::mode($client) || '') ne 'playlist') {
				Slim::Buttons::Common::pushModeLeft($client, 'playlist');
			}
		}

		$cb->() if $cb && ref($cb) eq 'CODE';
	});
}

1;
