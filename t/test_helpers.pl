#!/usr/bin/env perl
# Fake LMS client + fake raw-HTTP-request objects for t/reproduce_p0_multiaccount_bugs.pl
use strict;
use warnings;

unless (caller) {
    require Test::More;
    Test::More::plan(skip_all => 'Helper library, not a standalone test');
}

package Test::FakeClient;
no warnings 'once';
my $next_id = 1;
sub new {
    my ($class, %args) = @_;
    my $self = bless {
        id          => $args{id} || ('fakeclient' . $next_id++),
        name        => $args{name} || 'FakeClient',
        _pluginData => {},
    }, $class;
    $Slim::Player::Client::CLIENTS{$self->{id}} = $self;
    return $self;
}
sub id   { return $_[0]->{id}; }
sub name { return $_[0]->{name}; }
sub pluginData {
    my $self = shift;
    if (@_ == 2) {
        my ($key, $val) = @_;
        $self->{_pluginData}{$key} = $val;
        return $val;
    }
    elsif (@_ == 1) {
        return $self->{_pluginData}{$_[0]};
    }
    return $self->{_pluginData};
}

package Test::FakeURI;
sub new { my ($class, %params) = @_; return bless { params => { %params } }, $class; }
sub query_param { my ($self, $key) = @_; return $self->{params}{$key}; }

package Test::FakeRequest;
sub new {
    my ($class, %args) = @_;
    return bless {
        client  => $args{client},
        cmd     => $args{cmd} || [],
        uri     => Test::FakeURI->new(%{ $args{query} || {} }),
        headers => $args{headers} || {},
        content => $args{content},
    }, $class;
}
sub client         { return $_[0]->{client}; }
sub getRequest     { my ($self, $idx) = @_; return $self->{cmd}[$idx]; }
sub uri            { return $_[0]->{uri}; }
sub header         { my ($self, $name) = @_; return $self->{headers}{$name}; }
sub content_ref    { my $c = $_[0]->{content}; return \$c; }

package Test::FakeResponse;
sub new { my ($class, $request) = @_; return bless { request => $request }, $class; }
sub request      { return $_[0]->{request}; }
sub code         { my $self = shift; $self->{code} = shift if @_; return $self->{code}; }
sub content_type { my $self = shift; $self->{content_type} = shift if @_; return $self->{content_type}; }
sub content_length { my $self = shift; $self->{content_length} = shift if @_; return $self->{content_length}; }

package Test::FakeTrack;
sub new { my ($class, $url) = @_; return bless { url => $url }, $class; }
sub url { return $_[0]->{url}; }
sub content_type { my $self = shift; $self->{content_type} = shift if @_; return $self->{content_type}; }

package Test::FakeSong;
sub new {
    my ($class, %args) = @_;
    return bless {
        track      => Test::FakeTrack->new($args{url}),
        client     => $args{client},
        pluginData => {},
    }, $class;
}
sub track      { return $_[0]->{track}; }
sub master     { return $_[0]->{client}; }
sub duration   { my $self = shift; $self->{duration} = shift if @_; return $self->{duration}; }
sub streamUrl  { my $self = shift; $self->{streamUrl} = shift if @_; return $self->{streamUrl}; }
sub pluginData {
    my $self = shift;
    if (@_ == 2) { $self->{pluginData}{$_[0]} = $_[1]; return $_[1]; }
    elsif (@_ == 1) { return $self->{pluginData}{$_[0]}; }
    return $self->{pluginData};
}

1;
