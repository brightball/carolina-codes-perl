#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/local/lib/perl5";
use JSON;

require "$FindBin::Bin/app.pl";
our ($SQL_COUNT, $CONNECT_COUNT, $CONNECT_FN, $QUERY_FN, $DBH);

my $failed = 0;

sub expect {
    my ($cond, $msg) = @_;
    if ($cond) {
        warn "ok: $msg\n";
    }
    else {
        warn "FAIL: $msg\n";
        $failed = 1;
    }
}

sub assert_years_desc {
    my ($speakers, $label) = @_;
    my $found_multi = 0;
    for my $sp (@$speakers) {
        my $years = $sp->{years} // [];
        next if @$years < 2;
        $found_multi = 1;
        for (my $i = 1; $i < @$years; $i++) {
            if ($years->[ $i - 1 ] < $years->[$i]) {
                expect(0, "$label years not DESC for $sp->{slug}: [@$years]");
                return;
            }
        }
    }
    expect($found_multi, "$label expected a speaker with >=2 years");
}

my $src = do {
    open my $fh, "<", "$FindBin::Bin/app.pl" or die $!;
    local $/;
    <$fh>;
};

expect(listen_host() eq "::", "listen host is ::");
expect($src !~ /LocalAddr\s*=>\s*"0\.0\.0\.0"/, "source does not bind 0.0.0.0");
expect($src =~ /listen_host\(\)/,               "daemon uses listen_host()");
expect($src =~ /sslmode=disable/,               "DSN keeps sslmode=disable");
expect($src =~ /V6Only\s*=>\s*0/,               "IPv6 bind is dual-stack (V6Only => 0)");

my ($dsn) = parse_db_url("postgres://postgres:postgres\@127.0.0.1:5432/carolina_dev");
expect($dsn =~ /sslmode=disable/, "parse_db_url adds sslmode=disable");

my $reg = index($src, "sub register_with_elixir");
expect($reg >= 0, "register_with_elixir exists");
if ($reg >= 0) {
    my $fn = substr($src, $reg);
    $fn = $1 if $fn =~ /^(sub register_with_elixir.*?)^sub /ms;
    expect($fn !~ /open_connection/, "register-once does not open Postgres");
    expect($fn !~ /db_query/,        "register-once does not run catalog SQL");
    expect($fn !~ /DBI->connect/,    "register-once does not open DBI");
}

reset_counts();
my ($hstatus, $hbody) = route("/health", ["health"], {});
expect($hstatus == 200,                        "/health returns 200");
expect($hbody->{ok},                           "/health body is ok JSON");
expect($SQL_COUNT == 0,                        "/health does not run SQL");
expect($CONNECT_COUNT == 0,                    "/health does not open Postgres");

my $live = eval { dbh(); 1 };
if (!$live) {
    warn "postgres unavailable, using query hook: $@\n";
    $CONNECT_FN = sub { die "fake connect" };
    $QUERY_FN   = sub {
        my ($sql, $bind) = @_;
        if ($sql =~ /FROM v1_speakers/) {
            return [ map { { slug => "s$_", first_name => "A", last_name => "B" } } 0 .. 2 ];
        }
        if ($sql =~ /IN \(/ && $sql =~ /speaker_slug/) {
            return [ { speaker_slug => "s0", year => 2026 }, { speaker_slug => "s0", year => 2024 } ];
        }
        if ($sql =~ /FROM v1_talks/) {
            return [
                {
                    slug         => "t0",
                    title        => "Talk",
                    speaker_slug => "s0",
                    year         => 2026,
                    languages    => ["perl"],
                    topics       => [],
                }
            ];
        }
        return [];
    };
    $CONNECT_COUNT = 1;
}

my $boot = $CONNECT_COUNT;
$SQL_COUNT = 0;

my ($status, $payload) = route("/v1/speakers", [ "v1", "speakers" ], { year => "2026" });
my $speakers = ($payload && ref $payload->{data} eq "ARRAY") ? $payload->{data} : [];
my $n        = scalar @$speakers;
my $sql      = $SQL_COUNT;
warn "year list status=$status sql=$sql speakers=$n connects=$CONNECT_COUNT\n";

if ($live && $status != 200) {
    expect(0, "live year listing status $status");
}

if ($status == 200) {
    expect($n >= 3,              "year listing returns N>=3 speakers");
    expect($sql > 0,             "listing runs SQL through shipped query wrapper");
    expect($sql < 2 * $n,        "SQL count does not grow as ~2N");
    expect($sql <= 4,            "year listing SQL is bounded (speakers + talks + years)");
    assert_years_desc($speakers, "handler");
    expect($CONNECT_COUNT == $boot, "listing reuses the process DBI handle");

    my $rows = list_speakers(2026);
    assert_years_desc($rows, "list_speakers");

    $SQL_COUNT = 0;
    my ($status2) = route("/v1/speakers", [ "v1", "speakers" ], { year => "2026" });
    expect($status2 == 200,            "second catalog request succeeds");
    expect($CONNECT_COUNT == $boot,    "second catalog request reuses handle (no extra connect)");
}
else {
    expect($sql < 2 * 3, "failed listing did not run per-row SQL for N=3");
}

if ($failed) {
    warn "perf_test failed\n";
    exit 1;
}
warn "perf_test passed\n";
