#!/usr/bin/perl
use strict;

package Google::Contacts::Gravatar;
use CHI;
use Gravatar::URL;
use Any::Moose;
use Net::Google::AuthSub;
use LWP::UserAgent;
use XML::LibXML::Simple;

with any_moose('X::Getopt');

has authsub => (
    is => 'rw', isa => 'Net::Google::AuthSub',
    default => sub { Net::Google::AuthSub->new(service => 'cp') },
    lazy => 1,
);

has agent => (
    is => 'rw', isa => 'LWP::UserAgent',
    default => sub { LWP::UserAgent->new },
    lazy => 1,
);

has auth_params => (
    is => 'rw', isa => 'HashRef',
);

has email => (
    is => 'rw', isa => 'Str', required => 1,
);

has password => (
    is => 'rw', isa => 'Str', required => 1,
);

has max_results => (
    is => 'rw', isa => 'Int', default => 1000,
);

has overwrite => (
    is => 'rw', isa => 'Bool', default => 0,
);

has contacts => (
    is => 'rw', isa => 'ArrayRef',
);

has refresh => (
    is => 'rw', isa => 'Bool', default => 0,
);

has debug => (
    is => 'rw', isa => 'Bool', default => 0,
);

has captcha => (
    is => 'rw', isa => 'Str',
);

has captcha_token => (
    is => 'rw', isa => 'Str',
);

has default_icon => (
    is => 'rw', isa => 'Str', default => q(""),
);

has cache => (
    is => 'rw', isa => 'CHI::Driver', default => sub {
        CHI->new( driver => "File" ),
    },
    lazy => 1,
);

sub run {
    my $self = shift;

    $self->authorize();
    $self->retrieve_contacts();
    $self->update_contacts_photos();
}

sub authorize {
    my $self = shift;

    my @login_options = ($self->email, $self->password);
    if ($self->captcha && $self->captcha_token) {
        push @login_options, (
            logintoken   => $self->captcha_token,
            logincaptcha => $self->captcha,
        );
    }
    elsif ($self->captcha || $self->captcha_token) {
        die "You must give both the --captcha and --captcha_token options together.\n";
    }

    my $resp = $self->authsub->login(@login_options);
    if (!$resp->is_success && $resp->error eq 'CaptchaRequired') {
        warn "CAPTCHA is required. Visit https://www.google.com", $resp->captchaurl, "=", $resp->captchatoken, "\n";
        die "Run again with --captcha_token ", $resp->captchatoken, " --captcha <captcha-answer>\n";
    }
    else {
        $resp && $resp->is_success or die "Auth failed against " . $self->email . ": " . $resp->error;
        $self->auth_params({ $self->authsub->auth_params });
    }
}

sub retrieve_contacts {
    my $self = shift;

    my $feed = $self->get_feed("contacts/default/full", 'max-results' => $self->max_results);
    $self->contacts($feed->{entry});
}

sub update_contacts_photos {
    my $self = shift;

    for my $contact (@{$self->contacts}) {
        my @email = grep defined, map $_->{address}, @{$contact->{"gd:email"} || []}
            or next;

        my ($has_photo) = grep $_->{rel} eq 'http://schemas.google.com/contacts/2008/rel#photo', @{$contact->{link}};
        if ($has_photo && !$self->overwrite) {
            warn "$email[0] has a photo. Skipping.\n" if $self->debug;
            next;
        }

        my($edit) = grep $_->{rel} eq 'http://schemas.google.com/contacts/2008/rel#edit-photo', @{$contact->{link}};

        for my $email (@email) {
            my $avatar = $self->find_avatar($email) or next;
            if ($avatar) {
                warn "Gravatar found for $email. Updating the photo.\n";
                $self->update_photo($edit->{href}, $avatar);
                last;
            }
        }
    }
}

sub find_avatar {
    my($self, $email) = @_;

    warn "Finding avatar for $email\n" if $self->debug;

    # Use the cache unless they want to refresh the cache
    my $photo;
    $photo = $self->cache->get($email) unless $self->refresh;

    if (!defined $photo) {
        my $url = gravatar_url(email => $email, default => $self->default_icon);
        $photo = $self->agent->get($url)->content;
        $self->cache->set($email, $photo || 0); # cache non existent photo as 0
    }

    return $photo;
}

sub update_photo {
    my($self, $uri, $photo) = @_;

    my $req = HTTP::Request->new(PUT => $uri);
    while (my($k, $v) = each %{$self->auth_params}) {
        $req->header($k, $v);
    }
    $req->content_type("image/jpeg");
    $req->content($photo);
    $req->content_length(length $photo);

    my $res = $self->agent->request($req);

    if ($res->is_success) {
        warn "Photo update was successful.\n";
    } else {
        warn "Photo update failed: ". $res->status_line;
    }
}

sub get_feed {
    my($self, $path, %param) = @_;

    my $uri = URI->new("http://www.google.com/m8/feeds/$path");
       $uri->query_form(%param);
    my $res = $self->agent->get($uri, %{ $self->auth_params });
    $res->is_success or die "HTTP error for $uri: " . $res->status_line;

    return XML::LibXML::Simple->new->XMLin($res->content, KeyAttr => [], ForceArray => [ 'gd:email' ]);
}

package main;
Google::Contacts::Gravatar->new_with_options->run;



