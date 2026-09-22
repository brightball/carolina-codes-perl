#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use Test::More;

my $workflow = "$FindBin::Bin/../.gitea/workflows/precommit.yml";
ok(-f $workflow, "shipped workflow exists at .gitea/workflows/precommit.yml");

open my $fh, "<", $workflow or die "read $workflow: $!";
local $/;
my $yaml = <$fh>;
close $fh;
ok(defined $yaml && length $yaml, "workflow file is readable");

my $steps = $yaml;
$steps =~ s/^\s*#.*//mg;
unlike($steps, qr{^\s+uses:\s*actions/checkout}m, "workflow does not use actions/checkout");
unlike(
    $steps,
    qr{^\s+uses:\s*actions/upload-artifact}m,
    "workflow does not use actions/upload-artifact"
);
unlike(
    $steps,
    qr{^\s+uses:\s*actions/download-artifact}m,
    "workflow does not use actions/download-artifact"
);

my $jobs = jobs_from_yaml($yaml);
ok(exists $jobs->{prepare}, "prepare job exists");
for my $name (qw(tests sast audit gitleaks style)) {
    ok(exists $jobs->{$name}, "$name job exists");
}

my $prepare = $jobs->{prepare} || "";
like($prepare, qr/git clone/,      "prepare clones over git");
like($prepare, qr/x-access-token/, "prepare clone uses the job token");
like($prepare, qr/GITHUB_SHA/,     "prepare checks out GITHUB_SHA");
unlike($prepare, qr/git clone --depth/, "prepare clone is full (gitleaks needs history)");
like($prepare, qr/apt-get/,                    "prepare installs shared OS packages");
like($prepare, qr/make deps/,                  "prepare installs CPAN local-lib via make deps");
like($prepare, qr{gitleaks/gitleaks/releases}, "prepare installs gitleaks once");
like($prepare, qr{\.gitea/ci/env\.pl upload},  "prepare persists the tree via env.pl upload");

my %gate = (
    tests    => "make test",
    sast     => "make sast",
    audit    => "make audit",
    gitleaks => "make secrets",
    style    => "make lint",
);

for my $name (qw(tests sast audit gitleaks style)) {
    my $body  = $jobs->{$name} || "";
    my @needs = job_needs($body);
    ok(scalar(grep { $_ eq "prepare" } @needs), "$name declares needs: prepare");
    like($body, qr{env\.pl restore},  "$name restores the prepared tree");
    like($body, qr/\Q$gate{$name}\E/, "$name runs $gate{$name}");
    unlike($body, qr/apt-get/,                    "$name does not apt-get");
    unlike($body, qr/\bcpanm\b/,                  "$name does not cpanm");
    unlike($body, qr{gitleaks/gitleaks/releases}, "$name does not download gitleaks");
    unlike($body, qr/gitleaks_\d/,                "$name does not unpack a gitleaks tarball");
    unlike($body, qr/git clone/,                  "$name does not clone");
    unlike($body, qr/make deps/,                  "$name does not reinstall CPAN deps");
}

done_testing();

sub jobs_from_yaml {
    my ($text) = @_;
    my %jobs;
    my $in_jobs = 0;
    my $current;
    for my $line (split /\n/, $text) {
        if ($line =~ /^jobs:\s*$/) {
            $in_jobs = 1;
            next;
        }
        next unless $in_jobs;
        if ($line =~ /^  ([A-Za-z][\w-]*)\s*:\s*$/) {
            $current = $1;
            $jobs{$current} = "";
            next;
        }
        $jobs{$current} .= "$line\n" if defined $current;
    }
    return \%jobs;
}

sub job_needs {
    my ($text) = @_;
    my @needs;
    if ($text =~ /^\s+needs:\s*\[([^\]]+)\]/m) {
        my $inner = $1;
        $inner =~ s/['"]//g;
        push @needs, grep { length } split /\s*,\s*/, $inner;
    }
    elsif ($text =~ /^\s+needs:\s*\n((?:[ \t]+-[ \t]+\S+\n)+)/m) {
        my $list = $1;
        push @needs, $list =~ /-[ \t]+(\S+)/g;
        s/['"]//g for @needs;
    }
    elsif ($text =~ /^\s+needs:\s*(\S+)\s*$/m) {
        my $v = $1;
        $v =~ s/['"]//g;
        push @needs, $v if length $v && $v ne "|";
    }
    return @needs;
}
