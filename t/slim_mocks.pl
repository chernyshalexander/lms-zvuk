#!/usr/bin/env perl
# Minimal duck-typed mocks for the Slim:: framework surface that
# Plugin.pm / ProtocolHandler.pm / Settings.pm / API.pm / API/Async.pm
# touch at `require` time and during the specific code paths exercised
# by t/reproduce_p0_multiaccount_bugs.pl.
#
# Technique: replace-via-%INC, as documented in docs/TESTING_SLIM_MOCKING.md.
use strict;
use warnings;

unless (caller) {
    require Test::More;
    Test::More::plan(skip_all => 'Helper library, not a standalone test');
}

use JSON::PP ();

# LMS defines this as a compile-time constant in the server bootstrap;
# Plugin.pm's initPlugin() guards web-route registration on it.
sub main::WEBUI() { 0 }

# ---- logging ----
package Slim::Utils::Log;
require Exporter;
our @ISA = ('Exporter');
our @EXPORT = qw(logger);
my $singleton = bless {}, 'Slim::Utils::Log::Logger';
sub logger { return $singleton; }
sub addLogCategory { }
$INC{'Slim/Utils/Log.pm'} = 1;

package Slim::Utils::Log::Logger;
sub info  { }
sub debug { }
sub warn  { }
sub error { }
sub is_debug { 0 }

# ---- preferences ----
package Slim::Utils::Prefs;
require Exporter;
our @ISA = ('Exporter');
our @EXPORT = qw(preferences);
our %STORE;         # namespace => { key => val }
our %CLIENT_STORE;  # namespace => { clientid => { key => val } }
sub preferences { my ($ns) = @_; return bless { ns => $ns }, 'Slim::Utils::Prefs::Namespace'; }
$INC{'Slim/Utils/Prefs.pm'} = 1;

package Slim::Utils::Prefs::Namespace;
sub init {
    my ($self, $defaults) = @_;
    my $ns = $self->{ns};
    for my $k (keys %$defaults) {
        $Slim::Utils::Prefs::STORE{$ns}{$k} = $defaults->{$k} unless exists $Slim::Utils::Prefs::STORE{$ns}{$k};
    }
}
sub get { my ($self, $key) = @_; return $Slim::Utils::Prefs::STORE{$self->{ns}}{$key}; }
sub set { my ($self, $key, $val) = @_; $Slim::Utils::Prefs::STORE{$self->{ns}}{$key} = $val; }
sub remove { my ($self, $key) = @_; delete $Slim::Utils::Prefs::STORE{$self->{ns}}{$key}; }
sub client {
    my ($self, $client) = @_;
    my $cid = ref($client) ? $client->id : $client;
    return bless { ns => $self->{ns}, cid => $cid }, 'Slim::Utils::Prefs::ClientNamespace';
}

package Slim::Utils::Prefs::ClientNamespace;
sub get { my ($self, $key) = @_; return $Slim::Utils::Prefs::CLIENT_STORE{$self->{ns}}{$self->{cid}}{$key}; }
sub set { my ($self, $key, $val) = @_; $Slim::Utils::Prefs::CLIENT_STORE{$self->{ns}}{$self->{cid}}{$key} = $val; }
sub remove { my ($self, $key) = @_; delete $Slim::Utils::Prefs::CLIENT_STORE{$self->{ns}}{$self->{cid}}{$key}; }

# ---- cache ----
package Slim::Utils::Cache;
our %CACHE;
sub new    { return bless {}, __PACKAGE__; }
sub get    { my ($self, $k) = @_; return $CACHE{$k}; }
sub set    { my ($self, $k, $v, $ttl) = @_; $CACHE{$k} = $v; }
sub remove { my ($self, $k) = @_; delete $CACHE{$k}; }
sub clear  { %CACHE = (); }
$INC{'Slim/Utils/Cache.pm'} = 1;

# ---- plugin manager (unused in the paths under test, just needs to exist) ----
package Slim::Utils::PluginManager;
$INC{'Slim/Utils/PluginManager.pm'} = 1;

# ---- timers ----
# Real semantics (Slim/Utils/Timers.pm:66-95): $when is an ABSOLUTE epoch
# time, fired via EV::timer($when - $now, ...). This mock captures calls so
# tests can assert $when was computed as time()+delay, not a bare delay, and
# can fire them synchronously on demand instead of running a real event loop.
package Slim::Utils::Timers;
our @SCHEDULED;  # [{ when => ..., coderef => ..., args => [...] }, ...]
sub setTimer {
    my ($obj, $when, $coderef, @args) = @_;
    my $entry = { when => $when, coderef => $coderef, args => \@args };
    push @SCHEDULED, $entry;
    return $entry;
}
sub fireAll {
    my @toFire = @SCHEDULED;
    @SCHEDULED = ();
    $_->{coderef}->(@{ $_->{args} }) for @toFire;
}
$INC{'Slim/Utils/Timers.pm'} = 1;

# ---- strings ----
package Slim::Utils::Strings;
require Exporter;
our @ISA = ('Exporter');
our @EXPORT_OK = qw(string cstring);
sub string  { my ($key) = @_; return $key; }
sub cstring { my ($client, $key) = @_; return $key; }
$INC{'Slim/Utils/Strings.pm'} = 1;

# ---- base classes (never instantiated for real, just need to satisfy `use base`) ----
package Slim::Plugin::OPMLBased;
our $VERSION = 1;
sub _pluginDataFor { return 'mock_icon.png'; }
sub initPlugin     { }
$INC{'Slim/Plugin/OPMLBased.pm'} = 1;

package Slim::Web::Settings;
our $VERSION = 1;
sub beforeRender { }
sub handler { return ''; }
$INC{'Slim/Web/Settings.pm'} = 1;

package Slim::Player::Protocols::HTTPS;
our $VERSION = 1;
$INC{'Slim/Player/Protocols/HTTPS.pm'} = 1;

package Slim::Networking::Async::HTTP;
$INC{'Slim/Networking/Async/HTTP.pm'} = 1;

package Slim::Utils::Scanner::Remote;
sub parseRemoteHeader { }
$INC{'Slim/Utils/Scanner/Remote.pm'} = 1;

# ---- HTTP client used by API/Async.pm::_graphql ----
# Scripted via @Slim::Networking::SimpleAsyncHTTP::RESPONSES: one descriptor
# consumed per post() call, e.g. { code => 400 } (HTTP error response --
# mirrors the real Slim::Networking::Async::HTTP behavior of routing any
# non-2xx/3xx status to the error callback with a headers-only response,
# body never read, per Async/HTTP.pm:432-434), { network_error => '...' }
# (no HTTP response at all -- connect/DNS/timeout failure), or
# { code => 200, content => '...' } (success). Defaults to a bare 200 with
# an empty JSON object if the queue runs out.
package Slim::Networking::SimpleAsyncHTTP;
our @POST_LOG;
our @RESPONSES;
our @PENDING_CALLS;
sub new {
    my ($class, $successCb, $errorCb, $opts) = @_;
    return bless { successCb => $successCb, errorCb => $errorCb, opts => $opts }, $class;
}
sub post {
    my ($self, @args) = @_;
    push @POST_LOG, { method => 'POST', args => \@args, opts => $self->{opts} };
    my $resp = shift(@RESPONSES) || { code => 200, content => '{"data":{}}' };

    my $fire = sub {
        if ($resp->{network_error}) {
            $self->{errorCb}->($self, $resp->{network_error}, undef);
        } elsif ($resp->{code} && $resp->{code} !~ /^2/) {
            my $fakeResponse = Test::FakeHTTPResponse->new($resp->{code}, $resp->{content});
            $self->{errorCb}->($self, "$resp->{code} " . ($resp->{message} || 'Error'), $fakeResponse);
        } else {
            $self->{successCb}->(Test::FakeHTTPResponse->new($resp->{code} // 200, $resp->{content}));
        }
    };

    if ($resp->{defer}) {
        push @PENDING_CALLS, $fire;
    } else {
        $fire->();
    }
}
sub get {
    my ($self, @args) = @_;
    push @POST_LOG, { method => 'GET', args => \@args, opts => $self->{opts} };
    my $resp = shift(@RESPONSES) || { code => 200, content => '{"data":{}}' };

    my $fire = sub {
        if ($resp->{network_error}) {
            $self->{errorCb}->($self, $resp->{network_error}, undef);
        } elsif ($resp->{code} && $resp->{code} !~ /^2/) {
            my $fakeResponse = Test::FakeHTTPResponse->new($resp->{code}, $resp->{content});
            $self->{errorCb}->($self, "$resp->{code} " . ($resp->{message} || 'Error'), $fakeResponse);
        } else {
            $self->{successCb}->(Test::FakeHTTPResponse->new($resp->{code} // 200, $resp->{content}));
        }
    };

    if ($resp->{defer}) {
        push @PENDING_CALLS, $fire;
    } else {
        $fire->();
    }
}
sub put {
    my ($self, @args) = @_;
    push @POST_LOG, { method => 'PUT', args => \@args, opts => $self->{opts} };
    my $resp = shift(@RESPONSES) || { code => 200, content => '{"island_alive":true}' };

    my $fire = sub {
        if ($resp->{network_error}) {
            $self->{errorCb}->($self, $resp->{network_error}, undef);
        } elsif ($resp->{code} && $resp->{code} !~ /^2/) {
            my $fakeResponse = Test::FakeHTTPResponse->new($resp->{code}, $resp->{content});
            $self->{errorCb}->($self, "$resp->{code} " . ($resp->{message} || 'Error'), $fakeResponse);
        } else {
            $self->{successCb}->(Test::FakeHTTPResponse->new($resp->{code} // 200, $resp->{content}));
        }
    };

    if ($resp->{defer}) {
        push @PENDING_CALLS, $fire;
    } else {
        $fire->();
    }
}
$INC{'Slim/Networking/SimpleAsyncHTTP.pm'} = 1;

package Test::FakeHTTPResponse;
sub new     { my ($class, $code, $content, $content_type) = @_; return bless { code => $code, content => $content, content_type => $content_type }, $class; }
sub code    { return $_[0]->{code}; }
sub content { return $_[0]->{content}; }
sub headers { my $self = shift; return Test::FakeHTTPHeaders->new($self->{content_type} // 'image/png'); }

package Test::FakeHTTPHeaders;
sub new    { my ($class, $ct) = @_; return bless { ct => $ct }, $class; }
sub header { return $_[0]->{ct}; }

# ---- web plumbing used by the raw AJAX handlers ----
package Slim::Web::HTTP;
our @CAPTURED_RESPONSES;
sub filltemplatefile {
    my ($template, $vars) = @_;
    my $html = "<!-- $template -->";
    return \$html;
}
sub addHTTPResponse {
    my ($httpClient, $response, $bodyRef) = @_;
    push @CAPTURED_RESPONSES, { response => $response, body => $$bodyRef };
}
$INC{'Slim/Web/HTTP.pm'} = 1;

package Slim::Player::Client;
our %CLIENTS;
sub getClient { my ($id) = @_; return $CLIENTS{$id}; }
sub clients   { return values %CLIENTS; }
$INC{'Slim/Player/Client.pm'} = 1;

package Slim::Player::Playlist;
sub count { return 10; }
$INC{'Slim/Player/Playlist.pm'} = 1;

package Slim::Player::ProtocolHandlers;
our %HANDLERS;
sub registerHandler {
    my ($class, $scheme, $handler) = @_;
    $HANDLERS{$scheme} = $handler;
}
sub handlerForURL {
    my ($class, $url) = @_;
    my ($scheme) = $url =~ m{^(\w+)://};
    return $HANDLERS{$scheme};
}
$INC{'Slim/Player/ProtocolHandlers.pm'} = 1;

package Slim::Player::Source;
sub playingSongIndex { return 1; }
$INC{'Slim/Player/Source.pm'} = 1;

package Slim::Music::Info;
sub setDuration { }
sub setBitrate  { }
$INC{'Slim/Music/Info.pm'} = 1;

package Slim::Control::Request;
our @EXECUTED_REQUESTS;
sub executeRequest {
    my ($client, $cmd) = @_;
    push @EXECUTED_REQUESTS, { client => $client, cmd => $cmd };
}
sub addDispatch { }
sub subscribe   { }
$INC{'Slim/Control/Request.pm'} = 1;

# ---- JSON (real JSON::PP under the hood; JSON::XS/.VersionOneAndTwo are XS-only and not installed here) ----
package JSON::XS;
require Exporter;
our @ISA = ('JSON::PP', 'Exporter');
our @EXPORT = qw(encode_json decode_json);
no warnings 'once';
*encode_json = \&JSON::PP::encode_json;
*decode_json = \&JSON::PP::decode_json;
$INC{'JSON/XS.pm'} = 1;

package JSON::XS::VersionOneAndTwo;
require Exporter;
our @ISA = ('Exporter');
our @EXPORT = qw(encode_json decode_json to_json from_json);
no warnings 'once';
*encode_json = \&JSON::PP::encode_json;
*decode_json = \&JSON::PP::decode_json;
*to_json     = \&JSON::PP::encode_json;
*from_json   = \&JSON::PP::decode_json;
$INC{'JSON/XS/VersionOneAndTwo.pm'} = 1;

package Slim::Utils::Misc;
sub isWebBrowser { return 0; }
sub canFollowWeblinks { return 0; }
$INC{'Slim/Utils/Misc.pm'} = 1;

package Slim::Menu::Base;
our %PROVIDERS;
sub registerInfoProvider {
    my ($class, $name, %details) = @_;
    $PROVIDERS{$class}{$name} = \%details;
}

package Slim::Menu::TrackInfo;
our @ISA = qw(Slim::Menu::Base);
$INC{'Slim/Menu/TrackInfo.pm'} = 1;

package Slim::Menu::AlbumInfo;
our @ISA = qw(Slim::Menu::Base);
$INC{'Slim/Menu/AlbumInfo.pm'} = 1;

package Slim::Menu::ArtistInfo;
our @ISA = qw(Slim::Menu::Base);
$INC{'Slim/Menu/ArtistInfo.pm'} = 1;

1;
