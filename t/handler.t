#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../local/lib/perl5";
use Test::More;
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use HTTP::Tiny;
use IO::Select;
use IO::Socket::INET;
use JSON        qw(decode_json);
use POSIX       qw(_exit);
use Time::HiRes qw(sleep time);
use URI;

require "$FindBin::Bin/../app.pl";
our ($SQL_COUNT, $CONNECT_COUNT, $CONNECT_FN, $QUERY_FN, $DBH);

my @CLEANUP;
my $ACCEPT_COUNT = 0;

END {
    for my $pid (@CLEANUP) {
        reap($pid);
    }
}

my @DOCUMENTED = (
    "/",                  "/health",
    "/v1/years",          "/v1/speakers",
    "/v1/speakers/:slug", "/v1/speakers/:year/:slug",
    "/v1/sponsors",       "/v1/sponsors/:slug",
    "/v1/sponsors/:year/:slug",
);

my @SPEAKERS = (
    speaker("ada",       "Ada",       "Lovelace", 1),
    speaker("grace",     "Grace",     "Hopper",   0),
    speaker("alan",      "Alan",      "Turing",   0),
    speaker("linus",     "Linus",     "Torvalds", 0),
    speaker("katherine", "Katherine", "Johnson",  1),
    speaker("quiet",     "Quiet",     "Gallery",  0),
);

my @TALKS = (
    talk("ada-note",     "ada",       2026, "perl",    "math"),
    talk("ada-engine",   "ada",       2024, "raku",    "hardware"),
    talk("ada-poem",     "ada",       2022, "perl",    "math"),
    talk("grace-cobol",  "grace",     2026, "cobol",   "compilers"),
    talk("alan-machine", "alan",      2026, "perl",    "theory"),
    talk("linus-git",    "linus",     2026, "c",       "vcs"),
    talk("kj-orbit",     "katherine", 2026, "fortran", "space"),
);

my @SPONSORS =
    (sponsor("acme", "Acme"), sponsor("globex", "Globex"), sponsor("initech", "Initech"),);

my @YEAR_SPONSORS = (
    year_sponsor("acme",   "Acme",   2026, "gold",   1, "we launch"),
    year_sponsor("acme",   "Acme",   2024, "silver", 0, "we launched"),
    year_sponsor("globex", "Globex", 2026, "bronze", 0, "all"),
);

my @SPONSORSHIPS = (
    { sponsor_slug => "acme",   year => 2026, tier => "gold" },
    { sponsor_slug => "acme",   year => 2024, tier => "silver" },
    { sponsor_slug => "globex", year => 2026, tier => "bronze" },
);

my $src = slurp("$FindBin::Bin/../app.pl");

is(listen_host(), "::", "listen host is ::");
unlike($src, qr/LocalAddr\s*=>\s*"0\.0\.0\.0"/, "source does not bind 0.0.0.0");
like($src, qr/listen_host\(\)/,           "daemon uses listen_host()");
like($src, qr/sslmode=disable/,           "DSN keeps sslmode=disable");
like($src, qr/V6Only\s*=>\s*0/,           "IPv6 bind is dual-stack (V6Only => 0)");
like($src, qr/GetAddrInfoFlags\s*=>\s*0/, "passive lookup does not set AI_ADDRCONFIG");

my ($dsn) = parse_db_url("postgres://postgres:postgres\@127.0.0.1:5432/carolina_dev");
like($dsn, qr/sslmode=disable/, "parse_db_url adds sslmode=disable");
my ($dsn_override) =
    parse_db_url("postgres://postgres:postgres\@127.0.0.1:5432/carolina_dev?sslmode=require");
like($dsn_override, qr/sslmode=require/, "explicit sslmode is preserved");
my ($dbi_dsn) = parse_db_url("dbi:Pg:dbname=carolina_dev");
like($dbi_dsn, qr/sslmode=disable/, "dbi DSN gains sslmode=disable");

my $reg = index($src, "sub register_with_elixir");
ok($reg >= 0, "register_with_elixir exists");
if ($reg >= 0) {
    my $fn = substr($src, $reg);
    $fn = $1 if $fn =~ /^(sub register_with_elixir.*?)^sub /ms;
    unlike($fn, qr/open_connection/, "register-once does not open Postgres");
    unlike($fn, qr/db_query/,        "register-once does not run catalog SQL");
    unlike($fn, qr/DBI->connect/,    "register-once does not open DBI");
    like(
        $fn,
        qr/HTTP::Tiny->new\(\s*timeout\s*=>\s*(\d+(?:\.\d+)?)\s*\)/,
        "registration sets a client timeout"
    );
    my ($timeout) = $fn =~ /HTTP::Tiny->new\(\s*timeout\s*=>\s*(\d+(?:\.\d+)?)\s*\)/;
    ok(defined $timeout && $timeout > 1, "registration client timeout is longer than one second");
}

my $main_at = index($src, "sub main");
ok($main_at >= 0, "main exists");
if ($main_at >= 0) {
    my $main    = substr($src, $main_at);
    my $bind_at = index($main, "HTTP::Daemon->new");
    my $reg_at  = index($main, "spawn_registration");
    my $acc_at  = index($main, '$daemon->accept');
    ok($bind_at >= 0 && $reg_at > $bind_at, "listener is created before registration is spawned");
    ok($acc_at > $reg_at,                   "registration is spawned before accept");
    unlike($main, qr/register_with_elixir\(/, "main does not register on the accept path");
}

my $fly = slurp("$FindBin::Bin/../fly.toml");
like($fly, qr/app\s*=\s*"carolina-codes-perl"/, "fly app name");
like($fly, qr/primary_region\s*=\s*"iad"/,      "fly primary region is iad");
like($fly, qr/internal_port\s*=\s*8080/,        "fly internal port is 8080");
like($fly, qr/auto_start_machines\s*=\s*true/,  "fly autostart stays on");
like($fly, qr/method\s*=\s*"GET"/,              "fly health check is GET");
like($fly, qr/path\s*=\s*"\/health"/,           "fly health check path");
fly_floor_ok($fly);

my $docker = slurp("$FindBin::Bin/../Dockerfile");
like($docker, qr/\bcpanm\b/, "image installs CPAN modules at build time");
like(
    $docker,
    qr/CMD\s*\[\s*"perl"\s*,\s*"app\.pl"\s*\]/,
    "image starts the shipped entrypoint with perl"
);
my $cpan_at  = index($docker, "cpanm");
my $purge_at = index($docker, "apt-get purge");
ok($cpan_at >= 0 && $purge_at > $cpan_at, "compiler packages are purged after the CPAN build");
like($docker, qr/apt-get purge\b[^\n]*\bgcc\b/, "image purge removes the C compiler");

my $parsed = parse_query(URI->new("http://127.0.0.1/v1/speakers?year=2026&x=a%20b"));
is($parsed->{year}, "2026", "parse_query reads year");
is($parsed->{x},    "a b",  "parse_query unescapes values");
is_deeply(parse_query(URI->new("http://127.0.0.1/health")), {},
    "parse_query allows an empty query");

use_fake_catalog();
my ($hstatus, $hbody) = route("/health", [ "health" ], {});
is($hstatus, 200, "/health returns 200");
ok($hbody->{ok}, "/health body is ok JSON");
is($SQL_COUNT,     0, "/health does not run SQL");
is($CONNECT_COUNT, 0, "/health does not open Postgres");

my ($root_status, $root) = route("/", [ "/" ], {});
is($root_status,       200,            "GET / returns 200");
is($root->{language},  "Perl",         "GET / language is Perl");
is($root->{framework}, "HTTP::Daemon", "GET / framework is HTTP::Daemon");
is($SQL_COUNT,         0,              "GET / does not run SQL");
is($CONNECT_COUNT,     0,              "GET / does not open Postgres");
my %listed = map { $_->{path} => $_->{method} } @{ $root->{endpoints} || [] };
for my $path (@DOCUMENTED) {
    is($listed{$path}, "GET", "GET / lists $path");
}

my ($ystatus, $years_payload) = route("/v1/years", [ "v1", "years" ], {});
is($ystatus, 200, "GET /v1/years returns 200");
my $years = $years_payload->{data};
is(ref $years,          "ARRAY", "GET /v1/years body is {data: ...}");
is($years->[ 0 ]{year}, 2026,    "years start at the newest year");
assert_years_numbers([ map { $_->{year} } @$years ], "v1/years");

$SQL_COUNT = 0;
my ($status, $payload) = route("/v1/speakers", [ "v1", "speakers" ], { year => "2026" });
my $speakers = ($payload && ref $payload->{data} eq "ARRAY") ? $payload->{data} : [];
my $n        = scalar @$speakers;
my $sql      = $SQL_COUNT;
diag("year list status=$status sql=$sql speakers=$n connects=$CONNECT_COUNT");

is($status,              200,     "year-scoped speaker list returns 200");
is(ref $payload->{data}, "ARRAY", "year-scoped speakers body is {data: ...}");
ok($n >= 3,       "year listing returns N>=3 speakers");
ok($sql > 0,      "listing runs SQL through the shipped query wrapper");
ok($sql <= 4,     "year listing SQL is bounded by 4 statements");
ok($sql < 2 * $n, "SQL count does not grow as ~2N");
is($CONNECT_COUNT, 1, "year listing opens one DBI connection");
assert_years_desc($speakers, "handler");

my ($ada) = grep { $_->{slug} eq "ada" } @$speakers;
ok($ada, "year list includes ada");
is_deeply($ada->{years}, [ 2026, 2024, 2022 ], "ada years are descending");
is($ada->{year}, 2026, "year-scoped speaker carries the requested year");
ok(ref $ada->{talks} eq "ARRAY" && @{ $ada->{talks} } >= 1, "year-scoped speaker includes talks");
is_deeply($ada->{languages}, [ "perl" ], "year-scoped languages come from that year's talks");
my $quiet_in_year = grep { $_->{slug} eq "quiet" } @$speakers;
ok(!$quiet_in_year, "speakers with no talk in the year are excluded");

my $listed_rows = list_speakers(2026);
assert_years_desc($listed_rows, "list_speakers");
ok(scalar @$listed_rows >= 3, "list_speakers returns N>=3");

my $connects = $CONNECT_COUNT;
$SQL_COUNT = 0;
my ($status2, $payload2) = route("/v1/speakers", [ "v1", "speakers" ], { year => "2026" });
is($status2,              200,     "second catalog request succeeds");
is(ref $payload2->{data}, "ARRAY", "second catalog body is {data: ...}");
ok($SQL_COUNT > 0 && $SQL_COUNT <= 4, "second year list stays bounded");
is($CONNECT_COUNT, $connects, "second catalog request does not open another DBI connection");

my ($all_status, $all_payload) = route("/v1/speakers", [ "v1", "speakers" ], {});
is($all_status, 200, "GET /v1/speakers returns 200");
my %all_slugs = map { $_->{slug} => 1 } @{ $all_payload->{data} };
ok($all_slugs{quiet}, "unfiltered speakers include a speaker with no talks");
ok($all_slugs{ada},   "unfiltered speakers include ada");
is($CONNECT_COUNT, $connects, "unfiltered speakers reuse the DBI handle");

my ($empty_status, $empty_payload) = route("/v1/speakers", [ "v1", "speakers" ], { year => "" });
is($empty_status, 200, "blank year lists speakers");
ok((grep { $_->{slug} eq "quiet" } @{ $empty_payload->{data} }),
    "blank year does not apply the year filter");

my ($one_status, $one) = route("/v1/speakers/ada", [ "v1", "speakers", "ada" ], {});
is($one_status,        200,   "GET /v1/speakers/:slug returns 200");
is($one->{data}{slug}, "ada", "speaker slug matches");
is_deeply($one->{data}{years}, [ 2026, 2024, 2022 ], "speaker years are descending");
is(scalar @{ $one->{data}{talks} }, 3, "speaker includes every talk");

my ($miss_status, $miss) = route("/v1/speakers/missing", [ "v1", "speakers", "missing" ], {});
is($miss_status,   404,         "missing speaker is 404");
is($miss->{error}, "not_found", "missing speaker error is not_found");

my ($yr_status, $yr) = route("/v1/speakers/2026/ada", [ "v1", "speakers", "2026", "ada" ], {});
is($yr_status,                     200,   "GET /v1/speakers/:year/:slug returns 200");
is($yr->{data}{slug},              "ada", "year speaker slug matches");
is($yr->{data}{year},              2026,  "year speaker year matches");
is(scalar @{ $yr->{data}{talks} }, 1,     "year speaker talks are limited to that year");
is_deeply($yr->{data}{other_years}, [ 2024, 2022 ], "other_years omits the requested year");
is_deeply($yr->{data}{languages},   [ "perl" ],     "year speaker languages");

my ($no_talk_status, $no_talk) =
    route("/v1/speakers/1999/ada", [ "v1", "speakers", "1999", "ada" ], {});
is($no_talk_status,   404,         "speaker with no talk that year is 404");
is($no_talk->{error}, "not_found", "speaker with no talk that year is not_found");

my ($bad_sp_status, $bad_sp) =
    route("/v1/speakers/2026/missing", [ "v1", "speakers", "2026", "missing" ], {});
is($bad_sp_status,   404,         "unknown year speaker is 404");
is($bad_sp->{error}, "not_found", "unknown year speaker is not_found");

my ($spon_status, $spon) = route("/v1/sponsors", [ "v1", "sponsors" ], {});
is($spon_status, 200, "GET /v1/sponsors returns 200");
my %spon_slugs = map { $_->{slug} => 1 } @{ $spon->{data} };
ok($spon_slugs{acme} && $spon_slugs{globex} && $spon_slugs{initech},
    "sponsor list includes every sponsor");

my ($sy_status, $sy) = route("/v1/sponsors", [ "v1", "sponsors" ], { year => "2026" });
is($sy_status, 200, "GET /v1/sponsors?year returns 200");
my %year_slugs = map { $_->{slug} => 1 } @{ $sy->{data} };
ok($year_slugs{acme} && $year_slugs{globex}, "year sponsors include the 2026 rows");
ok(!$year_slugs{initech},                    "year sponsors omit a sponsor with no row that year");
my ($acme_year) = grep { $_->{slug} eq "acme" } @{ $sy->{data} };
is($acme_year->{year}, 2026, "year sponsor year is numeric");
ok($acme_year->{featured}, "featured year sponsor is true");

my ($sp_status, $sp) = route("/v1/sponsors/acme", [ "v1", "sponsors", "acme" ], {});
is($sp_status,                            200,    "GET /v1/sponsors/:slug returns 200");
is($sp->{data}{slug},                     "acme", "sponsor slug matches");
is(scalar @{ $sp->{data}{sponsorships} }, 2,      "sponsor includes sponsorships");

my ($sp_miss_status, $sp_miss) = route("/v1/sponsors/missing", [ "v1", "sponsors", "missing" ], {});
is($sp_miss_status,   404,         "missing sponsor is 404");
is($sp_miss->{error}, "not_found", "missing sponsor is not_found");

my ($spy_status, $spy) = route("/v1/sponsors/2026/acme", [ "v1", "sponsors", "2026", "acme" ], {});
is($spy_status,        200,    "GET /v1/sponsors/:year/:slug returns 200");
is($spy->{data}{tier}, "gold", "year sponsor tier matches");
is_deeply($spy->{data}{years},       [ 2026, 2024 ], "sponsor years are descending");
is_deeply($spy->{data}{other_years}, [ 2024 ], "sponsor other_years omits the requested year");

my ($spy_miss_status, $spy_miss) =
    route("/v1/sponsors/2026/missing", [ "v1", "sponsors", "2026", "missing" ], {});
is($spy_miss_status,   404,         "missing year sponsor is 404");
is($spy_miss->{error}, "not_found", "missing year sponsor is not_found");

my ($unknown_status, $unknown) = route("/v1/nope", [ "v1", "nope" ], {});
is($unknown_status,   404,         "unknown GET is 404");
is($unknown->{error}, "not_found", "unknown GET is not_found");

my $sql_before     = $SQL_COUNT;
my $connect_before = $CONNECT_COUNT;
my ($h2_status, $h2) = route("/health", [ "health" ], {});
is($h2_status, 200, "/health still returns 200 after catalog reads");
ok($h2->{ok}, "/health stays ok after catalog reads");
is($SQL_COUNT,     $sql_before,     "/health still runs zero SQL");
is($CONNECT_COUNT, $connect_before, "/health still opens zero connections");
is($CONNECT_COUNT, 1,               "the process kept a single DBI connection");

launch_contract();
launch_accept_concurrency();

done_testing();

sub launch_contract {
    local $SIG{ALRM} = sub { die "stalling-registration launch timed out\n" };
    alarm 25;

    my ($stall_pid, $stall_port, $stall_fh) = start_stall();
    my $probe = HTTP::Tiny->new(timeout => 0.4);
    my $began = time();
    my $pres  = $probe->get("http://127.0.0.1:$stall_port/");
    my $held  = time() - $began;
    ok($held >= 0.3, "stall peer accepts and holds the connection (${held}s)");
    like($pres->{content} // "", qr/timed out|Timeout/i, "stall peer never answers HTTP");
    my $baseline = take_accepts($stall_fh);
    ok($baseline >= 1, "stall peer recorded the probe accept");

    my @health_bodies;
    for my $n (1, 2) {
        my $port    = free_port();
        my $started = time();
        my $pid     = start_app($port, $stall_port);
        my $health  = fetch_until("http://127.0.0.1:$port/health", $started + 1);
        my $elapsed = time() - $started;
        ok($health,      "launch $n GET /health responded");
        ok($elapsed < 1, "launch $n GET /health finished in under one second (${elapsed}s)");
        if ($health) {
            my $json = decode_json($health->{content});
            ok($json->{ok}, "launch $n /health JSON ok");
            like($health->{content}, qr/"ok"\s*:\s*true/, "launch $n /health body is {ok: true}");
            header_is($health, "X-Polyglot-Language", "Perl", "launch $n health language header");
            header_is($health, "X-Polyglot-Framework", "HTTP::Daemon",
                "launch $n health framework header");
            push @health_bodies, $health->{content};

            my $root_res = HTTP::Tiny->new(timeout => 1)->get("http://127.0.0.1:$port/");
            ok($root_res->{success}, "launch $n GET / responded");
            my $root_json = decode_json($root_res->{content});
            is($root_json->{language},  "Perl",         "launch $n / language");
            is($root_json->{framework}, "HTTP::Daemon", "launch $n / framework");
            my %paths = map { $_->{path} => $_->{method} } @{ $root_json->{endpoints} || [] };
            for my $path (@DOCUMENTED) {
                is($paths{$path}, "GET", "launch $n / lists $path");
            }
            header_is($root_res, "X-Polyglot-Language", "Perl", "launch $n / language header");
            header_is(
                $root_res,      "X-Polyglot-Framework",
                "HTTP::Daemon", "launch $n / framework header"
            );

            my $slash = HTTP::Tiny->new(timeout => 1)->get("http://127.0.0.1:$port/health/");
            ok($slash->{success}, "launch $n trailing slash still serves /health");

            my $post =
                HTTP::Tiny->new(timeout => 1)->request("POST", "http://127.0.0.1:$port/health");
            is($post->{status}, 404, "launch $n non-GET is 404");
            my $post_json = decode_json($post->{content});
            is($post_json->{error}, "not_found", "launch $n non-GET body is {error: not_found}");
        }

        my $seen     = $baseline;
        my $deadline = time() + 1;
        while (time() < $deadline) {
            $seen = take_accepts($stall_fh);
            last if $seen >= $baseline + 1;
            sleep 0.02;
        }
        sleep 0.35;
        $seen = take_accepts($stall_fh);
        is(
            $seen,
            $baseline + 1,
            "launch $n registration contacts CMS once and does not open Postgres"
        );
        $baseline = $seen;
        reap($pid);
    }

    is($health_bodies[ 0 ], $health_bodies[ 1 ], "both launches return the same /health body");
    reap($stall_pid);
    alarm 0;
    return;
}

sub launch_accept_concurrency {
    local $SIG{ALRM} = sub { die "accept concurrency launch timed out\n" };
    alarm 20;

    my ($stall_pid, $stall_port, $stall_fh) = start_stall();
    for my $n (1, 2) {
        my $port = free_port();
        my $pid  = start_app($port, $stall_port);
        my $up   = fetch_until("http://127.0.0.1:$port/health", time() + 2);
        ok($up, "accept $n server answered /health");

        my $held = IO::Socket::INET->new(
            PeerAddr => "127.0.0.1",
            PeerPort => $port,
            Timeout  => 2,
        ) or die "held connect: $!";
        $held->autoflush(1);
        print $held "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n";
        my $held_body = read_raw_body($held, 2);
        like($held_body // "", qr/\A\{"ok":true\}\z/, "accept $n held socket got /health");

        my $began   = time();
        my $second  = HTTP::Tiny->new(timeout => 1)->get("http://127.0.0.1:$port/health");
        my $elapsed = time() - $began;
        is($second->{status}, 200,
            "accept $n second /health status while the first socket stays open");
        is($second->{content}, '{"ok":true}',
            "accept $n second /health body while the first socket stays open");
        ok($elapsed < 1, "accept $n second /health finished in under one second (${elapsed}s)");

        my $idle = IO::Socket::INET->new(
            PeerAddr => "127.0.0.1",
            PeerPort => $port,
            Timeout  => 2,
        ) or die "idle connect: $!";
        $idle->autoflush(1);
        print $idle "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n";

        $began = time();
        my $third = HTTP::Tiny->new(timeout => 1)->get("http://127.0.0.1:$port/health");
        $elapsed = time() - $began;
        is($third->{status}, 200,
            "accept $n /health status while a peer sends no complete request");
        is($third->{content}, '{"ok":true}',
            "accept $n /health body while a peer sends no complete request");
        ok($elapsed < 1, "accept $n incomplete peer did not stall /health (${elapsed}s)");

        close $held;
        close $idle;
        reap($pid);
    }
    reap($stall_pid);
    alarm 0;
    return;
}

sub read_raw_body {
    my ($sock, $timeout) = @_;
    my $buf      = "";
    my $sel      = IO::Select->new($sock);
    my $deadline = time() + $timeout;
    while (time() < $deadline) {
        my $remain = $deadline - time();
        last if $remain <= 0;
        last unless $sel->can_read($remain);
        my $n = sysread($sock, $buf, 8192, length $buf);
        last if !defined $n || $n == 0;
        next unless $buf =~ /\r\n\r\n/;
        my ($headers, $body) = split /\r\n\r\n/, $buf, 2;
        my ($len) = $headers =~ /Content-Length:\s*(\d+)/i;
        next unless defined $len;
        return substr($body // "", 0, $len) if length($body // "") >= $len;
    }
    return;
}

sub start_stall {
    my $sock = IO::Socket::INET->new(
        LocalAddr => "127.0.0.1",
        LocalPort => 0,
        Listen    => 64,
        ReuseAddr => 1,
    ) or die "stall listen: $!";
    my $port = $sock->sockport;
    pipe(my $rd, my $wr) or die "pipe: $!";
    my $pid = fork();
    die "fork stall: $!" unless defined $pid;
    if ($pid == 0) {
        setpgrp(0, 0);
        close $rd;
        my @hold;
        while (my $client = $sock->accept) {
            syswrite($wr, ".");
            push @hold, $client;
        }
        _exit(0);
    }
    close $wr;
    close $sock;
    my $flags = fcntl($rd, F_GETFL, 0);
    fcntl($rd, F_SETFL, $flags | O_NONBLOCK);
    push @CLEANUP, $pid;
    return ($pid, $port, $rd);
}

sub start_app {
    my ($port, $stall_port) = @_;
    my $pid = fork();
    die "fork app: $!" unless defined $pid;
    if ($pid == 0) {
        setpgrp(0, 0);
        $ENV{PORT}                    = $port;
        $ENV{CAROLINA_URL}            = "http://127.0.0.1:$stall_port";
        $ENV{POLYGLOT_REGISTER_TOKEN} = "dev-token";
        $ENV{DATABASE_URL}    = "postgres://postgres:postgres\@127.0.0.1:$stall_port/carolina_dev";
        $ENV{PUBLIC_BASE_URL} = "http://127.0.0.1:$port";
        exec $^X, "$FindBin::Bin/../app.pl" or _exit(1);
    }
    push @CLEANUP, $pid;
    return $pid;
}

sub fetch_until {
    my ($url, $deadline) = @_;
    while (time() < $deadline) {
        my $res = HTTP::Tiny->new(timeout => 0.2)->get($url);
        if ($res->{success} && defined $res->{content} && length $res->{content}) {
            return $res;
        }
        sleep 0.02;
    }
    return;
}

sub take_accepts {
    my ($fh) = @_;
    my $sel = IO::Select->new($fh);
    while ($sel->can_read(0)) {
        my $buf = "";
        my $n   = sysread($fh, $buf, 1024);
        last unless $n;
        $ACCEPT_COUNT += length $buf;
    }
    return $ACCEPT_COUNT;
}

sub header_is {
    my ($res, $name, $want, $label) = @_;
    my $got = $res->{headers}{ lc $name };
    $got = $got->[ 0 ] if ref $got eq "ARRAY";
    is($got, $want, $label);
    return;
}

sub free_port {
    my $sock = IO::Socket::INET->new(
        LocalAddr => "127.0.0.1",
        LocalPort => 0,
        Listen    => 1,
        ReuseAddr => 1,
    ) or die "free port: $!";
    my $port = $sock->sockport;
    close $sock;
    return $port;
}

sub reap {
    my ($pid) = @_;
    return unless defined $pid && $pid > 1;
    kill "TERM", $pid;
    kill "TERM", -$pid;
    for (1 .. 25) {
        last if waitpid($pid, 1) > 0;
        sleep 0.04;
    }
    kill "KILL", $pid;
    kill "KILL", -$pid;
    waitpid($pid, 0);
    @CLEANUP = grep { $_ != $pid } @CLEANUP;
    return;
}

sub fly_floor_ok {
    my ($text)    = @_;
    my ($min)     = $text =~ /min_machines_running\s*=\s*(\d+)/;
    my ($stop)    = $text =~ /auto_stop_machines\s*=\s*"([^"]+)"/;
    my $autostart = $text =~ /auto_start_machines\s*=\s*true/;
    my $warm      = (defined $min && $min >= 1 && $autostart) || (defined $stop && $stop eq "off");
    ok($warm, "fly keeps a machine running when idle");
    return;
}

sub use_fake_catalog {
    $QUERY_FN = undef;
    $DBH      = undef;
    reset_counts();
    $CONNECT_FN = sub { return bless {}, "CarolinaFakeDBH" };
    return;
}

sub assert_years_desc {
    my ($speakers, $label) = @_;
    my $found_multi = 0;
    for my $sp (@$speakers) {
        my $years = $sp->{years} // [];
        next if @$years < 2;
        $found_multi = 1;
        for (my $i = 1; $i < @$years; $i++) {
            if ($years->[ $i - 1 ] < $years->[ $i ]) {
                fail("$label years not DESC for $sp->{slug}: [@$years]");
                return;
            }
        }
    }
    ok($found_multi, "$label expected a speaker with >=2 years");
    return;
}

sub assert_years_numbers {
    my ($years, $label) = @_;
    ok(@$years >= 2, "$label has multiple years");
    for (my $i = 1; $i < @$years; $i++) {
        if ($years->[ $i - 1 ] < $years->[ $i ]) {
            fail("$label years not DESC: [@$years]");
            return;
        }
    }
    ok(1, "$label years are descending");
    return;
}

sub fake_rows {
    my ($sql, $bind) = @_;
    $bind ||= [];

    if ($sql =~ /FROM v1_years\b/) {
        my @rows = (
            { year => 2024, slug => "y2024", name => "2024", status => "past" },
            { year => 2026, slug => "y2026", name => "2026", status => "active" },
            { year => 2025, slug => "y2025", name => "2025", status => "past" },
        );
        if ($sql =~ /ORDER BY year DESC/) {
            @rows = sort { $b->{year} <=> $a->{year} } @rows;
        }
        return \@rows;
    }
    if ($sql =~ /FROM v1_year_sponsors WHERE year = \? AND slug = \?/) {
        my ($year, $slug) = @$bind;
        return [ grep { $_->{year} == $year && $_->{slug} eq $slug } @YEAR_SPONSORS ];
    }
    if ($sql =~ /FROM v1_year_sponsors WHERE year = \?/) {
        my ($year) = @$bind;
        my @rows = grep { $_->{year} == $year } @YEAR_SPONSORS;
        if ($sql =~ /ORDER BY name/) {
            @rows = sort { $a->{name} cmp $b->{name} } @rows;
        }
        return \@rows;
    }
    if ($sql =~ /FROM v1_sponsors WHERE slug = \?/) {
        my ($slug) = @$bind;
        return [ grep { $_->{slug} eq $slug } @SPONSORS ];
    }
    if ($sql =~ /FROM v1_sponsors\b/) {
        my @rows = @SPONSORS;
        if ($sql =~ /ORDER BY name/) {
            @rows = sort { $a->{name} cmp $b->{name} } @rows;
        }
        return \@rows;
    }
    if ($sql =~ /SELECT DISTINCT year FROM v1_sponsorships/) {
        my ($slug) = @$bind;
        my %seen;
        my @years;
        for my $row (@SPONSORSHIPS) {
            next unless $row->{sponsor_slug} eq $slug;
            next if $seen{ $row->{year} }++;
            push @years, $row->{year};
        }
        if ($sql =~ /ORDER BY year DESC/) {
            @years = sort { $b <=> $a } @years;
        }
        return [ map { { year => $_ } } @years ];
    }
    if ($sql =~ /FROM v1_sponsorships WHERE sponsor_slug = \?/) {
        my ($slug) = @$bind;
        return [ grep { $_->{sponsor_slug} eq $slug } @SPONSORSHIPS ];
    }
    if ($sql =~ /FROM v1_speakers WHERE slug = \?/) {
        my ($slug) = @$bind;
        return [ grep { $_->{slug} eq $slug } @SPEAKERS ];
    }
    if ($sql =~ /FROM v1_speakers WHERE slug IN/) {
        my ($year) = @$bind;
        my %slugs  = map  { $_->{speaker_slug} => 1 } grep { $_->{year} == $year } @TALKS;
        my @rows   = grep { $slugs{ $_->{slug} } } @SPEAKERS;
        if ($sql =~ /ORDER BY last_name/) {
            @rows = sort {
                $a->{last_name} cmp $b->{last_name} || $a->{first_name} cmp $b->{first_name}
            } @rows;
        }
        return \@rows;
    }
    if ($sql =~ /FROM v1_speakers\b/) {
        my @rows = @SPEAKERS;
        if ($sql =~ /ORDER BY last_name/) {
            @rows = sort {
                $a->{last_name} cmp $b->{last_name} || $a->{first_name} cmp $b->{first_name}
            } @rows;
        }
        return \@rows;
    }
    if ($sql =~ /SELECT DISTINCT speaker_slug, year FROM v1_talks/) {
        my %want = map { $_ => 1 } @$bind;
        my @pairs;
        my %seen;
        for my $talk (@TALKS) {
            next unless $want{ $talk->{speaker_slug} };
            my $key = $talk->{speaker_slug} . ":" . $talk->{year};
            next if $seen{$key}++;
            push @pairs, { speaker_slug => $talk->{speaker_slug}, year => $talk->{year} };
        }
        if ($sql =~ /year DESC/) {
            @pairs = sort { $a->{speaker_slug} cmp $b->{speaker_slug} || $b->{year} <=> $a->{year} }
                @pairs;
        }
        else {
            @pairs = sort { $a->{speaker_slug} cmp $b->{speaker_slug} || $a->{year} <=> $b->{year} }
                @pairs;
        }
        return \@pairs;
    }
    if ($sql =~ /SELECT DISTINCT year FROM v1_talks WHERE speaker_slug/) {
        my ($slug) = @$bind;
        my %seen;
        my @years;
        for my $talk (@TALKS) {
            next unless $talk->{speaker_slug} eq $slug;
            next if $seen{ $talk->{year} }++;
            push @years, $talk->{year};
        }
        if ($sql =~ /ORDER BY year DESC/) {
            @years = sort { $b <=> $a } @years;
        }
        return [ map { { year => $_ } } @years ];
    }
    if ($sql =~ /FROM v1_talks WHERE year = \?/) {
        my ($year) = @$bind;
        return [ grep { $_->{year} == $year } @TALKS ];
    }
    if ($sql =~ /FROM v1_talks WHERE speaker_slug = \?/) {
        my ($slug, $year) = @$bind;
        my @rows = grep { $_->{speaker_slug} eq $slug } @TALKS;
        if (defined $year && $sql =~ /AND year = \?/) {
            @rows = grep { $_->{year} == $year } @rows;
        }
        if ($sql =~ /ORDER BY year DESC/) {
            @rows = sort { $b->{year} <=> $a->{year} } @rows;
        }
        return \@rows;
    }
    die "unexpected SQL: $sql";
}

sub speaker {
    my ($slug, $first, $last, $featured) = @_;
    return {
        slug         => $slug,
        first_name   => $first,
        last_name    => $last,
        name         => "$first $last",
        tagline      => $slug,
        bio          => $slug,
        company      => $slug,
        location     => $slug,
        photo_path   => "/$slug",
        twitter_url  => "",
        linkedin_url => "",
        website_url  => "",
        github_url   => "",
        featured     => $featured,
    };
}

sub talk {
    my ($slug, $who, $year, $lang, $topic) = @_;
    return {
        slug         => $slug,
        title        => $slug,
        description  => $slug,
        format       => "talk",
        youtube_id   => "",
        year         => $year,
        speaker_slug => $who,
        languages    => [ $lang ],
        topics       => [ $topic ],
    };
}

sub sponsor {
    my ($slug, $name) = @_;
    return {
        slug          => $slug,
        name          => $name,
        website       => "https://$slug.example",
        logo_path     => "/$slug",
        description   => $slug,
        twitter_url   => "",
        linkedin_url  => "",
        youtube_url   => "",
        instagram_url => "",
        facebook_url  => "",
    };
}

sub year_sponsor {
    my ($slug, $name, $year, $tier, $featured, $blurb) = @_;
    my $row = sponsor($slug, $name);
    $row->{blurb}    = $blurb;
    $row->{tier}     = $tier;
    $row->{featured} = $featured;
    $row->{year}     = $year;
    return $row;
}

sub slurp {
    my ($path) = @_;
    open my $fh, "<", $path or die "read $path: $!";
    local $/;
    my $text = <$fh>;
    close $fh;
    return $text;
}

package CarolinaFakeDBH;

sub ping { return 1 }

sub selectall_arrayref {
    my ($self, $sql, $attr, @bind) = @_;
    return main::fake_rows($sql, \@bind);
}
