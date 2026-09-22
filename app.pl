#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/local/lib/perl5";
use HTTP::Daemon;
use HTTP::Status;
use HTTP::Response;
use HTTP::Tiny;
use DBI;
use JSON;
use URI::Escape qw(uri_unescape);

use constant LANGUAGE         => "Perl";
use constant API_VERSION      => "0.2.0";
use constant FRAMEWORK        => "HTTP::Daemon";
use constant CREATED_YEAR     => 2026;
use constant SCHEMA_VERSION   => 1;
use constant LANGUAGE_VERSION => sprintf("%vd", $^V);

my $JSON = JSON->new->utf8->allow_nonref->canonical(0);

my @ENDPOINTS = (
    { method => "GET", path => "/",                        query => [] },
    { method => "GET", path => "/health",                  query => [] },
    { method => "GET", path => "/v1/years",                query => [] },
    { method => "GET", path => "/v1/speakers",             query => [ "year" ] },
    { method => "GET", path => "/v1/speakers/:slug",       query => [] },
    { method => "GET", path => "/v1/speakers/:year/:slug", query => [] },
    { method => "GET", path => "/v1/sponsors",             query => [ "year" ] },
    { method => "GET", path => "/v1/sponsors/:slug",       query => [] },
    { method => "GET", path => "/v1/sponsors/:year/:slug", query => [] },
);

my $SPEAKER_COLS =
      "slug, first_name, last_name, name, tagline, bio, company, location, "
    . "photo_path, twitter_url, linkedin_url, website_url, github_url, featured";
my $YEAR_SPONSOR_COLS =
      "slug, name, website, logo_path, description, blurb, tier, featured, year, "
    . "twitter_url, linkedin_url, youtube_url, instagram_url, facebook_url";
my $SPONSOR_COLS =
      "slug, name, website, logo_path, description, twitter_url, linkedin_url, "
    . "youtube_url, instagram_url, facebook_url";
my $TALK_COLS =
    "slug, title, description, format, youtube_id, year, speaker_slug, languages, topics";

our $DBH;
our $SQL_COUNT     = 0;
our $CONNECT_COUNT = 0;
our $CONNECT_FN;
our $QUERY_FN;

sub listen_host { "::" }

sub reset_counts {
    $SQL_COUNT     = 0;
    $CONNECT_COUNT = 0;
}

sub parse_db_url {
    my ($url) = @_;
    $url ||= "postgres://postgres:postgres\@127.0.0.1:5432/carolina_dev";
    if ($url =~ m{^dbi:}) {
        $url .= ";sslmode=disable" unless $url =~ /sslmode=/;
        return ($url, undef, undef);
    }
    if (
        $url =~ m{^postgres(?:ql)?://
                  (?:([^:@/]+)(?::([^@/]*))?@)?
                  ([^:/]+)
                  (?::(\d+))?
                  /([^?]+)
                  (?:\?(.*))?
                 }x
    ) {
        my ($user, $pass, $host, $port, $db, $query) = ($1, $2, $3, $4, $5, $6);
        $user = defined $user ? uri_unescape($user) : "postgres";
        $pass = defined $pass ? uri_unescape($pass) : "postgres";
        $port ||= 5432;
        $db =~ s/[?#].*//;
        my $dsn     = "dbi:Pg:host=$host;port=$port;dbname=$db";
        my $sslmode = "disable";
        if ($query) {
            my %q = map { split /=/, $_, 2 } split /&/, $query;
            $sslmode = $q{sslmode} if $q{sslmode};
        }
        $dsn .= ";sslmode=$sslmode";
        return ($dsn, $user, $pass);
    }
    return ("dbi:Pg:dbname=$url;sslmode=disable", undef, undef);
}

sub open_connection {
    $CONNECT_COUNT++;
    return $CONNECT_FN->() if $CONNECT_FN;
    my $url = $ENV{DATABASE_URL} // "postgres://postgres:postgres\@127.0.0.1:5432/carolina_dev";
    my ($dsn, $user, $pass) = parse_db_url($url);
    return DBI->connect(
        $dsn, $user, $pass,
        {
            RaiseError     => 1,
            AutoCommit     => 1,
            pg_enable_utf8 => 1,
            PrintError     => 0,
        }
    );
}

sub dbh {
    if ($DBH && $DBH->ping) {
        return $DBH;
    }
    $DBH = open_connection();
    return $DBH;
}

sub db_query {
    my ($sql, @bind) = @_;
    $SQL_COUNT++;
    return $QUERY_FN->($sql, \@bind) if $QUERY_FN;
    return dbh()->selectall_arrayref($sql, { Slice => {} }, @bind);
}

sub db_query_one {
    my ($sql, @bind) = @_;
    my $rows = db_query($sql, @bind);
    return $rows && @$rows ? $rows->[ 0 ] : undef;
}

sub as_string_array {
    my ($value) = @_;
    return [] unless defined $value;
    if (ref $value eq "ARRAY") {
        return [ grep { length } map { "$_" } @$value ];
    }
    my $stripped = $value;
    $stripped =~ s/^\s+|\s+$//g;
    return [] if $stripped eq "" || $stripped eq "{}";
    if ($stripped =~ /^\{(.*)\}$/) {
        $stripped = $1;
    }
    return [ grep { length } map { s/^"|"$//g; $_ } split /,/, $stripped ];
}

sub clean {
    my ($row) = @_;
    return undef unless $row;
    my %out;
    for my $key (keys %$row) {
        my $v = $row->{$key};
        if (!defined $v) {
            $out{$key} = undef;
        }
        elsif ($key eq "languages" || $key eq "topics") {
            $out{$key} = as_string_array($v);
        }
        elsif ($key eq "featured") {
            $out{$key} = $v ? JSON::true : JSON::false;
        }
        elsif ($key eq "year") {
            $out{$key} = 0 + $v;
        }
        elsif (ref $v eq "ARRAY") {
            $out{$key} = [ map { "$_" } @$v ];
        }
        else {
            $out{$key} = $v;
        }
    }
    return \%out;
}

sub uniq_tags {
    my ($talks, $key) = @_;
    my %seen;
    my @out;
    for my $talk (@$talks) {
        for my $val (@{ as_string_array($talk->{$key}) }) {
            next if $seen{$val}++;
            push @out, $val;
        }
    }
    return \@out;
}

sub talks_for {
    my ($slug, $year) = @_;
    my $sql  = "SELECT $TALK_COLS FROM v1_talks WHERE speaker_slug = ?";
    my @bind = ($slug);
    if (defined $year) {
        $sql .= " AND year = ?";
        push @bind, $year;
    }
    $sql .= " ORDER BY year DESC";
    my $rows = db_query($sql, @bind);
    return [ map { clean($_) } @$rows ];
}

sub talk_years {
    my ($slug) = @_;
    my $rows =
        db_query("SELECT DISTINCT year FROM v1_talks WHERE speaker_slug = ? ORDER BY year DESC",
        $slug);
    return [ map { 0 + $_->{year} } @$rows ];
}

sub sponsor_years {
    my ($slug) = @_;
    my $rows = db_query(
        "SELECT DISTINCT year FROM v1_sponsorships WHERE sponsor_slug = ? ORDER BY year DESC",
        $slug);
    return [ map { 0 + $_->{year} } @$rows ];
}

sub load_speaker {
    my ($slug) = @_;
    my $row = db_query_one("SELECT $SPEAKER_COLS FROM v1_speakers WHERE slug = ?", $slug);
    return clean($row);
}

sub list_speakers {
    my ($year) = @_;
    if (!defined $year) {
        my $rows = db_query("SELECT $SPEAKER_COLS FROM v1_speakers ORDER BY last_name, first_name");
        return [ map { clean($_) } @$rows ];
    }
    my $rows = db_query(
        "SELECT $SPEAKER_COLS FROM v1_speakers "
            . "WHERE slug IN (SELECT speaker_slug FROM v1_talks WHERE year = ?) "
            . "ORDER BY last_name, first_name",
        $year
    );
    return attach_year_tags([ map { clean($_) } @$rows ], $year);
}

sub attach_year_tags {
    my ($speakers, $year) = @_;
    return $speakers unless @$speakers;
    my @slugs    = map { $_->{slug} } @$speakers;
    my $talks_by = load_talks_for_year($year);
    my $years_by = load_years_for_slugs(\@slugs);
    for my $sp (@$speakers) {
        my $slug  = $sp->{slug};
        my $talks = $talks_by->{$slug} // [];
        my $years = $years_by->{$slug} // [];
        $sp->{year}      = $year;
        $sp->{talks}     = $talks;
        $sp->{languages} = uniq_tags($talks, "languages");
        $sp->{topics}    = uniq_tags($talks, "topics");
        $sp->{years}     = $years;
    }
    return $speakers;
}

sub load_talks_for_year {
    my ($year) = @_;
    my $rows =
        db_query("SELECT $TALK_COLS FROM v1_talks WHERE year = ? ORDER BY speaker_slug, year DESC",
        $year);
    my %by;
    for my $row (@$rows) {
        my $talk = clean($row);
        my $slug = $talk->{speaker_slug} // "";
        push @{ $by{$slug} }, $talk;
    }
    return \%by;
}

sub load_years_for_slugs {
    my ($slugs) = @_;
    return {} unless @$slugs;
    my $placeholders = join ",", ("?") x @$slugs;
    my $rows         = db_query(
        "SELECT DISTINCT speaker_slug, year FROM v1_talks WHERE speaker_slug IN ($placeholders) ORDER BY speaker_slug, year DESC",
        @$slugs
    );
    my %by;
    for my $row (@$rows) {
        push @{ $by{ $row->{speaker_slug} } }, 0 + $row->{year};
    }
    return \%by;
}

sub send_json {
    my ($client, $status, $payload) = @_;
    my $body = $JSON->encode($payload);
    my $resp = HTTP::Response->new($status);
    $resp->header("Content-Type"         => "application/json");
    $resp->header("X-Polyglot-Language"  => LANGUAGE);
    $resp->header("X-Polyglot-Framework" => FRAMEWORK);
    $resp->header("Content-Length"       => length($body));
    $resp->content($body);
    $client->send_response($resp);
}

sub parse_query {
    my ($uri) = @_;
    my %q;
    my $query = eval { $uri->query } // "";
    return \%q unless defined $query && length $query;
    for my $pair (split /&/, $query) {
        my ($k, $v) = split /=/, $pair, 2;
        next unless defined $k;
        $q{ uri_unescape($k) } = defined $v ? uri_unescape($v) : "";
    }
    return \%q;
}

sub route {
    my ($path, $parts, $qs) = @_;
    if ($path eq "/") {
        return (
            200,
            {
                language         => LANGUAGE,
                language_version => LANGUAGE_VERSION,
                api_version      => API_VERSION,
                framework        => FRAMEWORK,
                created_year     => CREATED_YEAR,
                schema_version   => SCHEMA_VERSION,
                endpoints        => \@ENDPOINTS,
            }
        );
    }
    if ($path eq "/health") {
        return (200, { ok => JSON::true });
    }
    if ($path eq "/v1/years") {
        my $rows = db_query("SELECT year, slug, name, status FROM v1_years ORDER BY year DESC");
        return (200, { data => [ map { clean($_) } @$rows ] });
    }
    if ($path eq "/v1/speakers") {
        my $year;
        if (defined $qs->{year} && length $qs->{year}) {
            $year = 0 + $qs->{year};
        }
        return (200, { data => list_speakers($year) });
    }
    if (   @$parts == 4
        && $parts->[ 0 ] eq "v1"
        && $parts->[ 1 ] eq "speakers"
        && $parts->[ 2 ] =~ /^\d+$/) {
        my $year    = 0 + $parts->[ 2 ];
        my $slug    = $parts->[ 3 ];
        my $speaker = load_speaker($slug);
        return (404, { error => "not_found" }) unless $speaker;
        my $talks = talks_for($slug, $year);
        return (404, { error => "not_found" }) unless @$talks;
        my $years = talk_years($slug);
        $speaker->{year}        = $year;
        $speaker->{years}       = $years;
        $speaker->{other_years} = [ grep { $_ != $year } @$years ];
        $speaker->{talks}       = $talks;
        $speaker->{languages}   = uniq_tags($talks, "languages");
        $speaker->{topics}      = uniq_tags($talks, "topics");
        return (200, { data => $speaker });
    }
    if (@$parts == 3 && $parts->[ 0 ] eq "v1" && $parts->[ 1 ] eq "speakers") {
        my $slug    = $parts->[ 2 ];
        my $speaker = load_speaker($slug);
        return (404, { error => "not_found" }) unless $speaker;
        $speaker->{talks} = talks_for($slug);
        $speaker->{years} = talk_years($slug);
        return (200, { data => $speaker });
    }
    if ($path eq "/v1/sponsors") {
        my $rows;
        if (defined $qs->{year} && length $qs->{year}) {
            $rows = db_query(
                "SELECT $YEAR_SPONSOR_COLS FROM v1_year_sponsors WHERE year = ? ORDER BY name",
                0 + $qs->{year});
        }
        else {
            $rows = db_query("SELECT $SPONSOR_COLS FROM v1_sponsors ORDER BY name");
        }
        return (200, { data => [ map { clean($_) } @$rows ] });
    }
    if (   @$parts == 4
        && $parts->[ 0 ] eq "v1"
        && $parts->[ 1 ] eq "sponsors"
        && $parts->[ 2 ] =~ /^\d+$/) {
        my $year = 0 + $parts->[ 2 ];
        my $slug = $parts->[ 3 ];
        my $row  = db_query_one(
            "SELECT $YEAR_SPONSOR_COLS FROM v1_year_sponsors WHERE year = ? AND slug = ?",
            $year, $slug);
        $row = clean($row);
        return (404, { error => "not_found" }) unless $row;
        my $years = sponsor_years($slug);
        $row->{years}       = $years;
        $row->{other_years} = [ grep { $_ != $year } @$years ];
        return (200, { data => $row });
    }
    if (@$parts == 3 && $parts->[ 0 ] eq "v1" && $parts->[ 1 ] eq "sponsors") {
        my $slug = $parts->[ 2 ];
        my $row  = db_query_one("SELECT $SPONSOR_COLS FROM v1_sponsors WHERE slug = ?", $slug);
        $row = clean($row);
        return (404, { error => "not_found" }) unless $row;
        my $sponsorships = db_query("SELECT * FROM v1_sponsorships WHERE sponsor_slug = ?", $slug);
        $row->{sponsorships} = [ map { clean($_) } @$sponsorships ];
        return (200, { data => $row });
    }
    return (404, { error => "not_found" });
}

sub register_with_elixir {
    my ($port) = @_;
    my $url    = $ENV{CAROLINA_URL};
    my $token  = $ENV{POLYGLOT_REGISTER_TOKEN};
    return unless defined $url && length $url && defined $token && length $token;
    my $base = $ENV{PUBLIC_BASE_URL} // "http://127.0.0.1:$port";
    $url =~ s{/$}{};
    my $http = HTTP::Tiny->new(timeout => 5);
    my $resp = $http->post(
        "$url/internal/api-endpoints/register",
        {
            headers => {
                Authorization  => "Bearer $token",
                "Content-Type" => "application/json",
            },
            content => $JSON->encode(
                {
                    language         => LANGUAGE,
                    language_version => LANGUAGE_VERSION,
                    api_version      => API_VERSION,
                    framework        => FRAMEWORK,
                    created_year     => CREATED_YEAR,
                    schema_version   => SCHEMA_VERSION,
                    base_url         => $base,
                    endpoints        => \@ENDPOINTS,
                }
            ),
        }
    );

    if ($resp->{success}) {
        warn "registered with elixir: $resp->{status}\n";
    }
    else {
        warn "register: $resp->{status} $resp->{reason}\n";
    }
}

# Bind first. A hung CMS must not sit on the accept path.
sub spawn_registration {
    my ($port, $daemon) = @_;
    my $url   = $ENV{CAROLINA_URL};
    my $token = $ENV{POLYGLOT_REGISTER_TOKEN};
    return unless defined $url && length $url && defined $token && length $token;

    my $pid = fork();
    if (!defined $pid) {
        warn "register fork failed: $!\n";
        return;
    }
    if ($pid == 0) {
        eval { $daemon->close if $daemon };
        eval { register_with_elixir($port) };
        require POSIX;
        POSIX::_exit(0);
    }
    return;
}

sub main {
    my $port = $ENV{PORT} // "4006";

    # AI_ADDRCONFIG drops :: when the host has no global IPv6 address, so the
    # passive lookup has to ask for the address we named.
    my $daemon = HTTP::Daemon->new(
        LocalAddr        => listen_host(),
        LocalPort        => $port,
        ReuseAddr        => 1,
        Listen           => 16,
        V6Only           => 0,
        GetAddrInfoFlags => 0,
    ) or die "HTTP::Daemon: $!";
    warn "carolina-codes-perl listening on :$port\n";

    local $SIG{CHLD} = "IGNORE";
    spawn_registration($port, $daemon);

    while (1) {
        my $client = $daemon->accept;
        if (!$client) {
            next if $!{EINTR};
            last;
        }
        eval {
            while (my $req = $client->get_request) {
                if ($req->method ne "GET") {
                    send_json($client, 404, { error => "not_found" });
                    next;
                }
                my $uri  = $req->uri;
                my $path = $uri->path // "/";
                $path =~ s{/+$}{} unless $path eq "/";
                $path = "/" unless length $path;
                my @parts = grep { length } split m{/}, $path;
                my $qs    = parse_query($uri);
                my ($status, $payload) = route($path, \@parts, $qs);
                send_json($client, $status, $payload);
            }
            1;
        } or do {
            my $err = $@ || "unknown error";
            eval { send_json($client, 500, { error => "$err" }) };
        };
        $client->close;
        undef $client;
    }
}

main() unless caller;
1;
