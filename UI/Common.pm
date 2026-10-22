package Plugins::Zvuk::UI::Common;

use strict;
use warnings;
use utf8;

use Slim::Utils::Log;

my $log = logger('plugin.zvuk');

# Determine the UI kind of the requesting client:
# - 'classic_web': Classic LMS web skin (isWeb flag)
# - 'player_buttons': Hardware player with physical buttons / VFD (Boom, Transporter, Classic)
# - 'weblink_capable': Material UI, iPeng, SqueezePad, web-capable clients
# - 'jive': SqueezePlay, Touch, Radio, Controller, or default fallback
sub uiKind {
	my ($client, $args) = @_;

	# 1. Classic Web Skin
	return 'classic_web' if $args && $args->{isWeb};

	# 2. VFD buttons on classic hardware player (Boom, Transporter)
	return 'player_buttons' if $args && $args->{isButton};

	# 3. CLI / JSON-RPC / cometd (Material UI / Jive / SqueezePlay / mobile apps)
	if ($client && Slim::Utils::Misc::canFollowWeblinks($client)) {
		return 'weblink_capable'; # Material, iPeng, SqueezePad
	}
	if ($client && $client->can('controllerUA') && $client->controllerUA && $client->controllerUA =~ /^SqueezePlay/) {
		return 'jive'; # Squeezebox Touch, Radio, Controller, desktop SqueezePlay
	}

	# 4. Unknown/fallback: default to jive/native UI
	return 'jive';
}

# Safely pop VFD xmlbrowser mode when an action is triggered from onRight on hardware players
sub popVfdMode {
	my ($client) = @_;
	return unless $client;

	if (defined &Slim::Buttons::Common::popMode && (Slim::Buttons::Common::mode($client) || '') eq 'xmlbrowser') {
		Slim::Buttons::Common::popMode($client);
	}
}

1;
