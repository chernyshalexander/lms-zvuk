package Plugins::Zvuk::WebHandlers;

use strict;
use warnings;
use utf8;

use JSON::XS;
use JSON::XS::VersionOneAndTwo;
use URI::QueryParam;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings;

use Plugins::Zvuk::API;
use Plugins::Zvuk::WaveSettings;

my $log = logger('plugin.zvuk');

# Resolve the connected player for a raw web/AJAX request, so handlers that
# only get ($httpClient, $response) can still find "the current account".
# Same lookup order as Slim::Plugin::DnDPlay::Plugin::_getClient: explicit
# ?player=<id> query param first, then the Squeezebox-player cookie the
# skins set for the currently selected player.
sub _clientForWebRequest {
	my ($request) = @_;
	return unless $request;

	my $client;
	if (my $id = $request->uri->query_param('player')) {
		$client = Slim::Player::Client::getClient($id);
	}

	if (!$client && (my $cookie = $request->header('Cookie'))) {
		require CGI::Cookie;
		my $cookies = { CGI::Cookie->parse($cookie) };
		if (my $player = $cookies->{'Squeezebox-player'}) {
			$client = Slim::Player::Client::getClient($player->value);
		}
	}

	return $client;
}

# Web UI handler for displaying wave settings (AJAX or standalone)
sub handleWaveSettingsWebUI {
	my ($httpClient, $response) = @_;

	require Plugins::Zvuk::WaveSettings;
	require Slim::Web::HTTP;
	my $request = $response->request;
	my $client = _clientForWebRequest($request);
	my $account_id = $client ? Plugins::Zvuk::Plugin::_getUserIdForClient($client) : 'default';
	my $wave_settings = Plugins::Zvuk::WaveSettings::loadSettings($account_id);

		# Build genres list for JavaScript
		my $genres = Plugins::Zvuk::WaveSettings::getGenres();
		my @genre_list;
		my %genre_labels;
		foreach my $genre (@$genres) {
			push @genre_list, { name => $genre->{name} };
			$genre_labels{$genre->{name}} = Slim::Utils::Strings::string($genre->{label});
		}

		my $vars = {
			wave_settings => $wave_settings,
			genres_json => encode_json(\@genre_list),
			genres_labels_json => encode_json(\%genre_labels),
			selected_genres_json => encode_json($wave_settings->{genres} || []),
			webroot => '/html/',
			playerid => ($client ? $client->id : ''),
		};

		# Use waveSliders.html for settings page integration
		my $template = 'plugins/zvuk/waveSliders.html';

		my $output_ref = Slim::Web::HTTP::filltemplatefile($template, $vars);

		$response->code(200);
		$response->content_type('text/html; charset=utf-8');
		$response->content_length(length($$output_ref));
		Slim::Web::HTTP::addHTTPResponse($httpClient, $response, $output_ref);
}

# Web UI handler for standalone wave settings page (from menu)
sub handleWaveSettingsStandalone {
	my ($httpClient, $response) = @_;

	require Plugins::Zvuk::WaveSettings;
	require Slim::Web::HTTP;
	my $request = $response->request;
	my $client = _clientForWebRequest($request);
	my $account_id = $client ? Plugins::Zvuk::Plugin::_getUserIdForClient($client) : 'default';
	my $wave_settings = Plugins::Zvuk::WaveSettings::loadSettings($account_id);

	# Build genres list for JavaScript
	my $genres = Plugins::Zvuk::WaveSettings::getGenres();
	my @genre_list;
	my %genre_labels;
	foreach my $genre (@$genres) {
		push @genre_list, { name => $genre->{name} };
		$genre_labels{$genre->{name}} = Slim::Utils::Strings::string($genre->{label});
	}

	my $vars = {
		wave_settings => $wave_settings,
		genres_json => encode_json(\@genre_list),
		genres_labels_json => encode_json(\%genre_labels),
		selected_genres_json => encode_json($wave_settings->{genres} || []),
		webroot => '/html/',
		playerid => ($client ? $client->id : ''),
	};

	# Use waveStandalone.html for menu access
	my $template = 'plugins/zvuk/waveStandalone.html';

	my $output_ref = Slim::Web::HTTP::filltemplatefile($template, $vars);

	$response->code(200);
	$response->content_type('text/html; charset=utf-8');
	$response->content_length(length($$output_ref));
	Slim::Web::HTTP::addHTTPResponse($httpClient, $response, $output_ref);
}
	$response->content_length(length($$output_ref));
	Slim::Web::HTTP::addHTTPResponse($httpClient, $response, $output_ref);
}

# Web AJAX handler for saving wave settings from web interface
sub handleSaveWaveSettingsWeb {
	my ($httpClient, $response) = @_;

	my $request = $response->request;

	# Get JSON payload from request body
	my $body = $request->content_ref ? ${$request->content_ref} : '';
	my $data;

	eval {
		$data = decode_json($body);
	};

	if ($@ || !$data) {
		$log->error("Wave Settings Web: Failed to parse JSON: $@");
		$response->code(400);
		$response->content_type('application/json');
		my $json = encode_json({ success => 0, error => 'Invalid JSON' });
		$response->content_length(length($json));
		Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \$json);
		return;
	}

	# Get current account ID from the connected player (falls back to
	# 'default' only if no player is selected in the web UI at all).
	my $client = _clientForWebRequest($request);
	my $account_id = $client ? Plugins::Zvuk::Plugin::_getUserIdForClient($client) : 'default';

	# Validate and save settings
	my $settings = {
		popular  => defined $data->{popular} ? 0.0 + $data->{popular} : 0.5,
		energy   => defined $data->{energy} ? 0.0 + $data->{energy} : 0.5,
		fun      => defined $data->{fun} ? 0.0 + $data->{fun} : 0.5,
		language => $data->{language} || 'all',
		vocal    => defined $data->{vocal} ? 0 + $data->{vocal} : 1,
		genres   => $data->{genres} && ref $data->{genres} eq 'ARRAY' ? $data->{genres} : [],
	};

		Plugins::Zvuk::WaveSettings::saveSettings($account_id, $settings);
		$log->info("Wave settings saved from web interface for account $account_id");

		$response->code(200);
		$response->content_type('application/json');
		my $json = encode_json({ success => 1 });
		$response->content_length(length($json));
		Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \$json);
	}

# Web AJAX handler for getting wave settings for modal initialization
sub handleGetWaveSettingsWeb {
	my ($httpClient, $response) = @_;

	require Plugins::Zvuk::WaveSettings;
	require Slim::Web::HTTP;
	my $request = $response->request;
	my $client = _clientForWebRequest($request);
	my $account_id = $client ? Plugins::Zvuk::Plugin::_getUserIdForClient($client) : 'default';
	my $wave_settings = Plugins::Zvuk::WaveSettings::loadSettings($account_id);

	# Build genres list for JavaScript
	my $genres = Plugins::Zvuk::WaveSettings::getGenres();
	my @genre_list;
	my %genre_labels;
	foreach my $genre (@$genres) {
		push @genre_list, { name => $genre->{name} };
		$genre_labels{$genre->{name}} = Slim::Utils::Strings::string($genre->{label});
	}

	my $response_data = {
		success => 1,
		settings => $wave_settings,
		genres => \@genre_list,
		genre_labels => \%genre_labels,
	};

	$response->code(200);
	$response->content_type('application/json');
	my $json = encode_json($response_data);
	$response->content_length(length($json));
	Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \$json);
}

sub handleSaveOAuthToken {
	my ($httpClient, $response) = @_;

	$log->debug("OAuth: handleSaveOAuthToken called");

	my $request = $response->request;
	my $body = $request->content_ref ? ${$request->content_ref} : '';
	$log->debug("OAuth: Request body length: " . length($body));
	$log->debug("OAuth: Request body (first 100 chars): " . substr($body, 0, 100));

	my $data;

	eval {
		$data = decode_json($body);
	};

	if ($@) {
		$log->error("OAuth: Failed to parse JSON: $@");
	}

	if ($@ || !$data || !$data->{token}) {
		$log->error("OAuth: Failed to parse token request: $@ | data: " . ($data ? 'exists' : 'null') . " | token: " . ($data->{token} ? 'exists' : 'null'));
		$response->code(400);
		$response->content_type('application/json');
		my $json = encode_json({ success => 0, error => 'Missing token' });
		$response->content_length(length($json));
		Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \$json);
		return;
	}

	my $token = $data->{token};

	# Validate token format (32 hex characters)
	if ($token !~ /^[0-9a-f]{32}$/i) {
		$log->error("OAuth: Invalid token format: $token");
		$response->code(400);
		$response->content_type('application/json');
		my $json = encode_json({ success => 0, error => 'Invalid token format' });
		$response->content_length(length($json));
		Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \$json);
		return;
	}

	# Save token immediately without waiting for profile fetch
	my $prefs = preferences('plugin.zvuk');
	my $accounts = $prefs->get('accounts') || {};

	# Generate temporary userId from token hash
	my $tempUserId = substr($token, 0, 16);
	$accounts->{$tempUserId} = {
		token => $token,
		name  => "Account $tempUserId",
	};
	$prefs->set('accounts', $accounts);
	$log->info("OAuth: Token saved immediately with tempUserId=$tempUserId");

	# Send immediate response to client
	$response->code(200);
	$response->content_type('application/json');

	my $json_encoder = JSON::XS->new->utf8(0)->canonical(1);
	my $json = $json_encoder->encode({
		success => 1,
		account => {
			userId => $tempUserId,
			name => "Account"
		}
	});
	$log->debug("OAuth: Sending immediate response: $json");
	$response->content_length(length($json));
	Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \$json);
	$log->debug("OAuth: Response sent immediately");
}

sub handleOAuthCallback {
	my ($httpClient, $response) = @_;

	$log->info("OAuth Callback: Serving browser-side fetch page");

	# Return an HTML page that uses JS to fetch the token from zvuk.com
	# The browser has zvuk.com session cookies, so fetch with credentials:include
	# will return the authenticated profile. If CORS blocks it, manual paste is shown.
	my $html = <<'END_HTML';
<!DOCTYPE html>
<html>
<head>
	<meta charset="UTF-8">
	<title>Zvuk — Авторизация</title>
	<style>
		* { box-sizing: border-box; margin: 0; padding: 0; }
		body {
			font-family: Arial, sans-serif;
			display: flex;
			align-items: center;
			justify-content: center;
			min-height: 100vh;
			background: #f5f5f5;
			padding: 20px;
		}
		.container {
			background: white;
			padding: 40px;
			border-radius: 8px;
			text-align: center;
			box-shadow: 0 2px 8px rgba(0,0,0,0.12);
			max-width: 480px;
			width: 100%;
		}
		h2 { color: #333; margin-bottom: 24px; font-size: 20px; }
		.spinner {
			border: 3px solid #eee;
			border-top: 3px solid #b8a6db;
			border-radius: 50%;
			width: 44px;
			height: 44px;
			animation: spin 0.8s linear infinite;
			margin: 0 auto 16px;
		}
		@keyframes spin { to { transform: rotate(360deg); } }
		.status { color: #666; font-size: 14px; line-height: 1.5; }
		.status.ok  { color: #388e3c; font-weight: bold; }
		.status.err { color: #d32f2f; }
		#manualSection { display: none; margin-top: 24px; text-align: left; }
		#manualSection p { font-size: 13px; color: #555; margin-bottom: 12px; line-height: 1.6; }
		#manualSection a { color: #b8a6db; }
		code { background: #f0f0f0; padding: 2px 5px; border-radius: 3px; font-family: monospace; font-size: 12px; }
		input[type=text] {
			width: 100%;
			padding: 10px 12px;
			border: 1px solid #ddd;
			border-radius: 4px;
			font-size: 13px;
			margin-bottom: 10px;
			font-family: monospace;
		}
		input[type=text]:focus { outline: none; border-color: #b8a6db; }
		button {
			background: #b8a6db;
			color: white;
			border: none;
			padding: 10px 24px;
			border-radius: 4px;
			cursor: pointer;
			font-size: 14px;
			width: 100%;
		}
		button:hover { background: #a594cc; }
		#manualStatus { font-size: 12px; margin-top: 8px; }
	</style>
</head>
<body>
<div class="container">
	<h2>Zvuk — Авторизация</h2>
	<div id="autoSection">
		<div class="spinner" id="spinner"></div>
		<div class="status" id="statusText">Получаем токен авторизации...</div>
	</div>
	<div id="manualSection">
		<p>
			Автоматическое получение токена недоступно (CORS).
			<br>
			<a href="https://zvuk.com/api/tiny/profile" target="_blank">Откройте профиль</a>,
			скопируйте значение поля <code>"token"</code> и вставьте ниже:
		</p>
		<input type="text" id="tokenInput" placeholder="Вставьте token...">
		<button onclick="saveManualToken()">Сохранить</button>
		<div class="status" id="manualStatus"></div>
	</div>
</div>
<script>
function setStatus(text, cls) {
	var el = document.getElementById('statusText');
	el.textContent = text;
	el.className = 'status' + (cls ? ' ' + cls : '');
}

function notifyAndClose(success, error) {
	if (window.opener) {
		window.opener.postMessage(
			success
				? { type: 'zvukOAuthSuccess' }
				: { type: 'zvukOAuthError', error: error || 'Unknown error' },
			'*'
		);
	}
	setTimeout(function() { window.close(); }, 2000);
}

function saveToken(token) {
	return fetch('/plugins/zvuk/saveOAuthToken', {
		method: 'POST',
		headers: { 'Content-Type': 'application/json' },
		body: JSON.stringify({ token: token })
	})
	.then(function(r) { return r.json(); })
	.then(function(data) {
		if (data.success) {
			document.getElementById('spinner').style.display = 'none';
			setStatus('Авторизация успешна! Окно закроется...', 'ok');
			notifyAndClose(true);
		} else {
			throw new Error(data.error || 'Server error');
		}
	});
}

function tryAutoFetch() {
	fetch('https://zvuk.com/api/tiny/profile', {
		credentials: 'include',
		headers: {
			'Accept': 'application/json',
			'Accept-Language': 'ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7',
		}
	})
	.then(function(r) {
		if (!r.ok) throw new Error('HTTP ' + r.status);
		return r.json();
	})
	.then(function(data) {
		var result = data && data.result || data;
		var token = result && result.token;
		var isAnon = result && result.is_anonymous;

		if (!token) throw new Error('no_token');
		if (isAnon) throw new Error('anonymous');

		setStatus('Токен получен, сохраняем...');
		return saveToken(token);
	})
	.catch(function(e) {
		document.getElementById('spinner').style.display = 'none';
		if (e.message === 'anonymous') {
			setStatus('Вы не авторизованы. Войдите на zvuk.com и повторите.', 'err');
		} else {
			// CORS or network error — show manual fallback
			setStatus('Автоматическое получение недоступно.', 'err');
			document.getElementById('manualSection').style.display = 'block';
		}
	});
}

function saveManualToken() {
	var token = document.getElementById('tokenInput').value.trim();
	if (!token) return;
	var ms = document.getElementById('manualStatus');
	ms.textContent = 'Сохраняем...';
	ms.className = 'status';
	saveToken(token).catch(function(e) {
		ms.textContent = 'Ошибка: ' + e.message;
		ms.className = 'status err';
	});
}

tryAutoFetch();
</script>
</body>
</html>
END_HTML

	$response->code(200);
	$response->content_type('text/html; charset=utf-8');
	$response->content_length(length($html));
	Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \$html);
}

sub handleGetAnonymousToken {
	my ($httpClient, $response) = @_;

	$log->info("Anonymous Token: Requesting from Zvuk API");

	require Slim::Networking::SimpleAsyncHTTP;

	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $resp = shift;
			my $data = eval { decode_json($resp->content) };
			my $token = $data && $data->{result} && $data->{result}{token};

			if ($token) {
				my $prefs = preferences('plugin.zvuk');
				my $accounts = $prefs->get('accounts') || {};
				$accounts->{anonymous} = {
					token => $token,
					name  => 'Анонимный (128kbps)',
				};
				$prefs->set('accounts', $accounts);
				$log->info("Anonymous Token: Saved token");

				$response->code(200);
				$response->content_type('application/json');
				my $json = encode_json({ success => 1 });
				$response->content_length(length($json));
				Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \$json);
			}
			else {
				$log->error("Anonymous Token: No token in response: " . $resp->content);
				$response->code(500);
				$response->content_type('application/json');
				my $json = encode_json({ success => 0, error => 'No token in response' });
				$response->content_length(length($json));
				Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \$json);
			}
		},
		sub {
			my ($http, $error) = @_;
			$log->error("Anonymous Token: HTTP error: $error");
			$response->code(500);
			$response->content_type('application/json');
			my $json = encode_json({ success => 0, error => $error });
			$response->content_length(length($json));
			Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \$json);
		}
	);

	$http->get(
		Plugins::Zvuk::API::PROFILE_URL,
		'User-Agent'      => Plugins::Zvuk::API::USER_AGENT,
		'Accept'          => 'application/json, text/plain, */*',
		'Accept-Language' => 'ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7',
		'Referer'         => 'https://zvuk.com/',
		'Origin'          => 'https://zvuk.com',
	);
}

sub handleImageProxy {
	my ($httpClient, $response) = @_;

	my $request = $response->request;
	my $url = $request->uri->query_param('url');

	unless ($url) {
		$response->code(400);
		$response->content_type('text/plain');
		my $err_msg = 'Missing url parameter';
		$response->content_length(length($err_msg));
		Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \$err_msg);
		return;
	}

	# Strip size suffix (e.g. _150x150_f or _50x50_o) added by LMS or client
	# since Zvuk static CDN returns 403 Forbidden for resized filenames,
	# but returns 200 OK for the original image file.
	$url =~ s/_\d+x\d+_[a-z](\.[a-z]+)$/$1/i;

	my $client = _clientForWebRequest($request);
	my $account_id = $client ? Plugins::Zvuk::Plugin::_getUserIdForClient($client) : 'default';
	my $token = Plugins::Zvuk::API->getToken($account_id);

	my %headers = (
		'User-Agent' => Plugins::Zvuk::API::USER_AGENT,
	);
	if ($token) {
		$headers{'x-auth-token'} = $token;
		$headers{'Cookie'} = "auth=$token";
	}

	require Slim::Networking::SimpleAsyncHTTP;
	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $resp = shift;
			$log->info("Image proxy: fetched $url successfully, status code: " . $resp->code);
			$response->code($resp->code);
			
			my $content_type = 'image/png';
			if ($resp->headers) {
				$content_type = $resp->headers->header('Content-Type') || $content_type;
			}
			$response->content_type($content_type);
			
			my $content = $resp->content;
			$response->content_length(length($content));
			Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \$content);
		},
		sub {
			my ($http, $error) = @_;
			$log->error("Image proxy failed for $url: $error");
			$response->code(500);
			$response->content_type('text/plain');
			$response->content_length(length($error));
			Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \$error);
		}
	);

	$log->debug("Image proxy: fetching $url");
	$http->get($url, %headers);
}

1;
