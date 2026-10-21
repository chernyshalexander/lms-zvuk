#!/usr/bin/env perl
# Unit test for multi-page recommendations loading logic.
# Verifies:
#  1. When totalPages == 1, only one request is made.
#  2. When totalPages > 1 and no specific page is requested, a second query
#     is fired for the remaining pages, merged, and correctly ordered.
#  3. When a specific page is requested, only that page is queried.
#
# Run: perl t/test_multi_page_recommendations.pl
use strict;
use warnings;
use FindBin qw($Bin);
use JSON::PP qw(decode_json);
use File::Temp qw(tempdir);
use Test::More;

require "$Bin/slim_mocks.pl";

my $repo_root = "$Bin/..";
my $tmpdir = tempdir(CLEANUP => 1);
mkdir "$tmpdir/Plugins" or die $!;
symlink($repo_root, "$tmpdir/Plugins/Zvuk") or die "symlink: $!";
unshift @INC, $tmpdir;

require Plugins::Zvuk::Plugin;

sub drain {
    my ($doneRef) = @_;
    my $iterations = 0;
    while (!$$doneRef && @Slim::Utils::Timers::SCHEDULED && $iterations < 20) {
        Slim::Utils::Timers::fireAll();
        $iterations++;
    }
    return $iterations;
}

# A valid token for testing
{
    no warnings 'once';
    $Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts} = { acctA => { token => 'tokA', name => 'A' } };
}

my $api = Plugins::Zvuk::API::Async->new({ userId => 'acctA' });

# ---------------------------------------------------------------------
# Scenario 1: totalPages == 1
# ---------------------------------------------------------------------
{
    %Slim::Utils::Cache::CACHE = ();
    @Slim::Utils::Timers::SCHEDULED = ();
    @Slim::Networking::SimpleAsyncHTTP::POST_LOG = ();
    @Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
        {
            code => 200,
            content => '{"data":{"dynamicBlock":{"totalPages":1,"pages":[{"page":1,"items":[{"__typename":"Artist","id":"a1","title":"Artist 1"}]}]}}}'
        }
    );

    my $result;
    $api->getMusicRecommendations(sub { $result = shift }, { contentType => 'Music' });
    drain(\$result);

    is(scalar(@Slim::Networking::SimpleAsyncHTTP::POST_LOG), 1,
        "Scenario 1: only 1 GraphQL query is sent when totalPages == 1");
    ok(defined $result && !$result->{error}, "Scenario 1 succeeds");
    is(scalar(@{$result->{allItems}}), 1, "Scenario 1: returns exactly 1 item");
    is($result->{artists}[0]{title}, 'Artist 1', "Scenario 1: artist is correct");
}

# ---------------------------------------------------------------------
# Scenario 2: totalPages == 3 (all pages loaded, merged and sorted)
# ---------------------------------------------------------------------
{
    %Slim::Utils::Cache::CACHE = ();
    @Slim::Utils::Timers::SCHEDULED = ();
    @Slim::Networking::SimpleAsyncHTTP::POST_LOG = ();
    
    # We supply 2 HTTP responses in order
    @Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
        # Response 1: page 1
        {
            code => 200,
            content => '{"data":{"dynamicBlock":{"totalPages":3,"pages":[{"page":1,"items":[{"__typename":"Artist","id":"a1","title":"Artist 1"}]}]}}}'
        },
        # Response 2: pages 3 and 2 (out of order to test sorting)
        {
            code => 200,
            content => '{"data":{"dynamicBlock":{"totalPages":3,"pages":[' .
                       '{"page":3,"items":[{"__typename":"Playlist","id":"p3","title":"Playlist 3"}]},' .
                       '{"page":2,"items":[{"__typename":"Release","id":"r2","title":"Release 2"}]}' .
                       ']}}}'
        }
    );

    my $result;
    $api->getMusicRecommendations(sub { $result = shift }, { contentType => 'Music' });
    drain(\$result);

    is(scalar(@Slim::Networking::SimpleAsyncHTTP::POST_LOG), 2,
        "Scenario 2: exactly 2 GraphQL queries are sent when totalPages > 1");
    
    # Verify the requested pages in variables
    my $first_args = $Slim::Networking::SimpleAsyncHTTP::POST_LOG[0]{args};
    my $second_args = $Slim::Networking::SimpleAsyncHTTP::POST_LOG[1]{args};
    my $first_req_vars = decode_json($first_args->[-1]);
    my $second_req_vars = decode_json($second_args->[-1]);
    
    is($first_req_vars->{variables}{pages}[0], 1, "Scenario 2: first query requests page 1");
    is_deeply($second_req_vars->{variables}{pages}, [2, 3],
        "Scenario 2: second query requests pages [2, 3]");

    ok(defined $result && !$result->{error}, "Scenario 2 succeeds");
    is(scalar(@{$result->{allItems}}), 3, "Scenario 2: returns all 3 items from pages 1, 2, 3");
    
    # Assert correct sorting by page number (page 1, page 2, page 3)
    is($result->{allItems}[0]{id}, 'a1', "Scenario 2: item 1 is from page 1");
    is($result->{allItems}[1]{id}, 'r2', "Scenario 2: item 2 is from page 2 (sorted)");
    is($result->{allItems}[2]{id}, 'p3', "Scenario 2: item 3 is from page 3 (sorted)");
}

# ---------------------------------------------------------------------
# Scenario 3: specific page requested (e.g. page => 2)
# ---------------------------------------------------------------------
{
    %Slim::Utils::Cache::CACHE = ();
    @Slim::Utils::Timers::SCHEDULED = ();
    @Slim::Networking::SimpleAsyncHTTP::POST_LOG = ();
    @Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
        {
            code => 200,
            content => '{"data":{"dynamicBlock":{"totalPages":3,"pages":[{"page":2,"items":[{"__typename":"Release","id":"r2","title":"Release 2"}]}]}}}'
        }
    );

    my $result;
    $api->getMusicRecommendations(sub { $result = shift }, { contentType => 'Music', page => 2 });
    drain(\$result);

    is(scalar(@Slim::Networking::SimpleAsyncHTTP::POST_LOG), 1,
        "Scenario 3: only 1 query is sent when a specific page is requested");
    
    my $req_args = $Slim::Networking::SimpleAsyncHTTP::POST_LOG[0]{args};
    my $req_vars = decode_json($req_args->[-1]);
    is($req_vars->{variables}{pages}[0], 2, "Scenario 3: query requests page 2");
    
    ok(defined $result && !$result->{error}, "Scenario 3 succeeds");
    is(scalar(@{$result->{allItems}}), 1, "Scenario 3: returns exactly 1 item");
    is($result->{allItems}[0]{id}, 'r2', "Scenario 3: returned item is correct");
}

done_testing();
