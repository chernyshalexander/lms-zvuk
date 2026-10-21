#!/usr/bin/env perl
# Unit test for Wave feedback loop (Phase 0.3):
# Verifies:
#  1. getPersonalWave passes contentInput into GraphQL variables when supplied
#  2. ProtocolHandler::getNextTrack stores track info in client pluginData('zvuk_wave_last_track')
#  3. ProtocolHandler::_loadMoreWaveTracks computes elapsed time, playDuration, and isSkipped
#  4. Plugin::_onStop resets zvuk_wave_active and zvuk_wave_last_track
#
# Run: perl t/test_wave_feedback.pl
use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);
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
require Plugins::Zvuk::ProtocolHandler;

sub drain {
    my ($doneRef) = @_;
    my $iterations = 0;
    while (!$$doneRef && @Slim::Utils::Timers::SCHEDULED && $iterations < 20) {
        Slim::Utils::Timers::fireAll();
        $iterations++;
    }
    return $iterations;
}

{
    no warnings 'once';
    $Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts} = { acctA => { token => 'tokA', name => 'A' } };
}

my $client = Test::FakeClient->new(id => 'player1');
{
    no warnings 'once';
    $Slim::Utils::Prefs::CLIENT_STORE{'plugin.zvuk'}{ $client->id }{userId} = 'acctA';
}

my $api = Plugins::Zvuk::API::Async->new({ userId => 'acctA' });

# ---------------------------------------------------------------------
# Test 1: getPersonalWave without contentInput (initial batch)
# ---------------------------------------------------------------------
{
    {
        no warnings 'once';
        %Slim::Utils::Cache::CACHE = ();
    }
    @Slim::Utils::Timers::SCHEDULED = ();
    @Slim::Networking::SimpleAsyncHTTP::POST_LOG = ();
    @Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
        { code => 200, content => '{"data":{"personalWaveContent":[{"id":"t1","title":"Track 1"}]}}' }
    );

    my $result;
    $api->getPersonalWave(sub { $result = shift });
    drain(\$result);

    is(ref $result, 'ARRAY', "Test 1: getPersonalWave returns array ref");
    is(scalar(@$result), 1, "Test 1: returns 1 track");
    my $req = $Slim::Networking::SimpleAsyncHTTP::POST_LOG[0]{args};
    my $body = decode_json($req->[-1]);
    ok(!exists $body->{variables}{contentInput}, "Test 1: contentInput is omitted when not provided");
}

# ---------------------------------------------------------------------
# Test 2: getPersonalWave with contentInput (feedback loop)
# ---------------------------------------------------------------------
{
    {
        no warnings 'once';
        %Slim::Utils::Cache::CACHE = ();
    }
    @Slim::Utils::Timers::SCHEDULED = ();
    @Slim::Networking::SimpleAsyncHTTP::POST_LOG = ();
    @Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
        { code => 200, content => '{"data":{"personalWaveContent":[{"id":"t2","title":"Track 2"}]}}' }
    );

    my $feedback = {
        trackId       => '999',
        trackDuration => 240,
        playDuration  => 180,
        isSkipped     => \0,
    };

    my $result;
    $api->getPersonalWave(sub { $result = shift }, undef, $feedback);
    drain(\$result);

    is(ref $result, 'ARRAY', "Test 2: getPersonalWave returns array ref");
    is(scalar(@$result), 1, "Test 2: returns 1 track");
    my $req = $Slim::Networking::SimpleAsyncHTTP::POST_LOG[0]{args};
    my $body = decode_json($req->[-1]);
    my $input = $body->{variables}{contentInput};
    ok(defined $input, "Test 2: contentInput passed in variables");
    is($input->{trackId}, '999', "Test 2: trackId matches feedback");
    is($input->{trackDuration}, 240, "Test 2: trackDuration matches feedback");
    is($input->{playDuration}, 180, "Test 2: playDuration matches feedback");
    is($input->{isSkipped}, 0, "Test 2: isSkipped is false (not skipped)");
}

# ---------------------------------------------------------------------
# Test 3: ProtocolHandler records zvuk_wave_last_track on getNextTrack
# ---------------------------------------------------------------------
{
    $client->pluginData(zvuk_wave_active => 1);
    $client->pluginData(zvuk_wave_last_track => undef);

    # Create a mock song
    package Test::MockSong;
    sub new {
        my ($class, $url, $client) = @_;
        return bless { url => $url, client => $client, dur => 0, streamUrl => undef }, $class;
    }
    sub track { my $self = shift; return bless { url => $self->{url} }, 'Test::MockTrack'; }
    sub master { return $_[0]->{client}; }
    sub duration { my ($self, $d) = @_; $self->{dur} = $d if defined $d; return $self->{dur}; }
    sub streamUrl { my ($self, $u) = @_; $self->{streamUrl} = $u if defined $u; return $self->{streamUrl}; }
    sub pluginData { return {}; }

    package Test::MockTrack;
    sub url { return $_[0]->{url}; }
    sub content_type { }

    package main;
    my $mockSong = Test::MockSong->new('zvuk://55555', $client);

    @Slim::Utils::Timers::SCHEDULED = ();
    @Slim::Networking::SimpleAsyncHTTP::POST_LOG = ();
    @Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
        { code => 200, content => '{"data":{"mediaContents":[{"id":"55555","duration":210,"stream":{"mid":"http://stream.zvuk/55555.mp3"}}]}}' }
    );

    my $streamData;
    Plugins::Zvuk::ProtocolHandler->getNextTrack($mockSong, sub { $streamData = shift }, sub { die shift });
    drain(\$streamData);

    my $last_track = $client->pluginData('zvuk_wave_last_track');
    ok(defined $last_track, "Test 3: zvuk_wave_last_track is stored");
    is($last_track->{id}, '55555', "Test 3: recorded track ID is correct");
    is($last_track->{duration}, 210, "Test 3: recorded track duration is 210");
    ok(defined $last_track->{started} && $last_track->{started} > 0, "Test 3: recorded started timestamp is valid");
}

# ---------------------------------------------------------------------
# Test 4: _loadMoreWaveTracks sends feedback with isSkipped logic
# ---------------------------------------------------------------------
{
    {
        no warnings 'once';
        %Slim::Utils::Cache::CACHE = ();
    }
    # Simulate track was played for only 30s out of 200s (skipped)
    $client->pluginData(zvuk_wave_last_track => {
        id       => '77777',
        duration => 200,
        started  => time() - 30,
    });

    @Slim::Utils::Timers::SCHEDULED = ();
    @Slim::Networking::SimpleAsyncHTTP::POST_LOG = ();
    @Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
        { code => 200, content => '{"data":{"personalWaveContent":[{"id":"next1","title":"Next Track"}]}}' }
    );

    Plugins::Zvuk::ProtocolHandler::_loadMoreWaveTracks($client);
    my $done = 0;
    drain(\$done);

    ok(scalar(@Slim::Networking::SimpleAsyncHTTP::POST_LOG) >= 1, "Test 4: _loadMoreWaveTracks sent GraphQL query");
    my $req = $Slim::Networking::SimpleAsyncHTTP::POST_LOG[0]{args};
    my $body = decode_json($req->[-1]);
    my $input = $body->{variables}{contentInput};

    ok(defined $input, "Test 4: _loadMoreWaveTracks passed contentInput");
    is($input->{trackId}, '77777', "Test 4: input trackId matches previous track");
    is($input->{isSkipped}, 1, "Test 4: isSkipped is true (30s < 100s threshold)");
}

# ---------------------------------------------------------------------
# Test 5: Plugin::_onStop resets wave state
# ---------------------------------------------------------------------
{
    $client->pluginData(zvuk_wave_active => 1);
    $client->pluginData(zvuk_wave_last_track => { id => '123' });

    package Test::MockStopRequest;
    sub new { my ($class, $client, $action, $subaction) = @_; return bless { client => $client, a => $action, sub => $subaction }, $class; }
    sub client { return $_[0]->{client}; }
    sub getRequest { my ($self, $idx) = @_; return $idx == 0 ? $self->{a} : $self->{sub}; }

    package main;
    my $stopReq = Test::MockStopRequest->new($client, 'stop');
    Plugins::Zvuk::Plugin::_onStop($stopReq);

    is($client->pluginData('zvuk_wave_active'), 0, "Test 5: zvuk_wave_active reset to 0 on stop");
    ok(!defined $client->pluginData('zvuk_wave_last_track'), "Test 5: zvuk_wave_last_track reset to undef on stop");
}

done_testing();
