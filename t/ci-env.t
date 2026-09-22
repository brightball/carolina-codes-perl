#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../local/lib/perl5";
use Test::More;
use Digest::MD5 qw(md5 md5_hex);
use File::Path  qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use HTTP::Daemon;
use HTTP::Response;
use MIME::Base64 qw(encode_base64);

my $helper = "$FindBin::Bin/../.gitea/ci/env.pl";
ok(-f $helper, "shipped helper exists at .gitea/ci/env.pl");
require $helper;

{
    local $ENV{ACTIONS_RUNTIME_URL} = "https://gitea.example/api/actions_pipeline";
    local $ENV{GITHUB_RUN_ID}       = "99";
    is(
        artifact_index_url(),
        "https://gitea.example/api/actions_pipeline/_apis/pipelines/workflows/99/artifacts?api-version=6.0-preview",
        "artifact index URL uses ACTIONS_RUNTIME_URL and GITHUB_RUN_ID"
    );
}

{
    local $ENV{ACTIONS_RUNTIME_URL} = "";
    local $ENV{GITHUB_SERVER_URL}   = "https://gitea.example";
    local $ENV{GITHUB_RUN_ID}       = "7";
    is(
        artifact_index_url(),
        "https://gitea.example/api/actions_pipeline/_apis/pipelines/workflows/7/artifacts?api-version=6.0-preview",
        "artifact index URL falls back to GITHUB_SERVER_URL"
    );
}

my $list_json = <<'JSON';
{"count":1,"value":[{"name":"prepared","fileContainerResourceUrl":"https://gitea.example/api/actions_pipeline/_apis/pipelines/workflows/1/artifacts/abc/download_url"}]}
JSON
is(
    json_named_field($list_json, "prepared", "fileContainerResourceUrl"),
    "https://gitea.example/api/actions_pipeline/_apis/pipelines/workflows/1/artifacts/abc/download_url",
    "json_named_field reads Gitea list-artifact payload"
);
is(
    json_string($list_json, "fileContainerResourceUrl"),
    "https://gitea.example/api/actions_pipeline/_apis/pipelines/workflows/1/artifacts/abc/download_url",
    "json_string reads fileContainerResourceUrl"
);

my $src = tempdir(CLEANUP => 1);
my $dst = tempdir(CLEANUP => 1);
write_tree($src);
my $packed = File::Spec->catfile(tempdir(CLEANUP => 1), "tree.tar.gz");
pack_tree($src, $packed);
ok(-s $packed, "pack_tree writes a tarball");
unpack_tree($packed, $dst);
tree_ok($dst, "pack/unpack roundtrip");

my $store  = File::Spec->catfile(tempdir(CLEANUP => 1), "artifact.bin");
my $daemon = HTTP::Daemon->new(LocalAddr => "127.0.0.1", LocalPort => 0, ReuseAddr => 1)
    or die "HTTP::Daemon: $!";
my $origin = $daemon->url;
$origin =~ s{/$}{};
my $pid = fork;
die "fork: $!" unless defined $pid;
if ($pid == 0) {
    eval { mock_gitea($daemon, $store) };
    exit 0;
}

my $up_src  = tempdir(CLEANUP => 1);
my $up_dst  = tempdir(CLEANUP => 1);
my $tarball = File::Spec->catfile(tempdir(CLEANUP => 1), "prepared.tar.gz");
write_tree($up_src);

{
    local $ENV{ACTIONS_RUNTIME_URL}   = "$origin/api/actions_pipeline/";
    local $ENV{GITHUB_SERVER_URL}     = $origin;
    local $ENV{GITHUB_RUN_ID}         = "42";
    local $ENV{ACTIONS_RUNTIME_TOKEN} = "test-token";
    local $ENV{CI_WORKSPACE}          = $up_src;
    local $ENV{CI_TARBALL}            = $tarball;
    upload_prepared();
}

ok(-s $store, "upload_prepared PUT the packed tree to the artifact API");

{
    local $ENV{ACTIONS_RUNTIME_URL}   = "$origin/api/actions_pipeline/";
    local $ENV{GITHUB_SERVER_URL}     = $origin;
    local $ENV{GITHUB_RUN_ID}         = "42";
    local $ENV{ACTIONS_RUNTIME_TOKEN} = "test-token";
    local $ENV{CI_WORKSPACE}          = $up_dst;
    local $ENV{CI_TARBALL}            = $tarball;
    restore_prepared();
}

tree_ok($up_dst, "upload/restore against Gitea-shaped artifact API");

kill "TERM", $pid;
waitpid $pid, 0;

done_testing();

sub write_tree {
    my ($dir) = @_;
    make_path("$dir/.git", "$dir/local/bin");
    write_file("$dir/.git/HEAD",          "ref: refs/heads/main\n");
    write_file("$dir/local/bin/gitleaks", "#!/bin/sh\necho fake-gitleaks\n");
    write_file("$dir/app.pl",             "print qq{ok\\n};\n");
    write_file("$dir/Makefile",           "test:\n\ttrue\n");
}

sub tree_ok {
    my ($dir, $label) = @_;
    ok(-f "$dir/.git/HEAD",          "$label keeps git history (.git/HEAD)");
    ok(-f "$dir/local/bin/gitleaks", "$label keeps gitleaks on PATH under local/bin");
    ok(-f "$dir/app.pl",             "$label keeps the repo tree");
    is(read_file("$dir/.git/HEAD"), "ref: refs/heads/main\n", "$label git HEAD matches");
}

sub write_file {
    my ($path, $body) = @_;
    open my $fh, ">", $path or die "write $path: $!";
    print {$fh} $body;
    close $fh;
}

sub read_file {
    my ($path) = @_;
    open my $fh, "<", $path or die "read $path: $!";
    local $/;
    my $body = <$fh>;
    close $fh;
    return $body;
}

sub mock_gitea {
    my ($d, $blob) = @_;
    my $confirmed = 0;
    my $uploaded  = 0;
    my $hash      = md5_hex("prepared");
    $SIG{TERM} = $SIG{INT} = sub { exit 0 };
    while (my $c = $d->accept) {
        while (my $r = $c->get_request) {
            my $auth = $r->header("Authorization") || "";
            if ($auth ne "Bearer test-token") {
                $c->send_response(HTTP::Response->new(401, "Unauthorized", undef, "bad token"));
                next;
            }
            my $path = $r->uri->path;
            my %q    = $r->uri->query_form;
            if ($r->method eq "POST" && $path =~ m{/artifacts$} && $path !~ m{/artifacts/}) {
                my $body = $r->content || "";
                unless ($body =~ /"Name"\s*:\s*"prepared"/) {
                    $c->send_response(HTTP::Response->new(400, "Bad Request", undef, "bad name"));
                    next;
                }
                my $url = $d->url;
                $url =~ s{/$}{};
                my $json =
                      '{"fileContainerResourceUrl":"'
                    . $url
                    . "/api/actions_pipeline/_apis/pipelines/workflows/42/artifacts/$hash/upload\"}";
                $c->send_response(
                    HTTP::Response->new(200, "OK", [ "Content-Type" => "application/json" ], $json)
                );
                next;
            }
            if ($r->method eq "PUT" && $path =~ m{/artifacts/$hash/upload$}) {
                %q = $r->uri->query_form;
                my $item = $q{itemPath} || "";
                unless ($item eq "prepared/prepared.tar.gz") {
                    $c->send_response(
                        HTTP::Response->new(400, "Bad Request", undef, "bad itemPath $item"));
                    next;
                }
                my $bytes  = $r->content;
                my $md5    = $r->header("x-actions-results-md5") || "";
                my $expect = encode_base64(md5($bytes), "");
                unless ($md5 eq $expect) {
                    $c->send_response(HTTP::Response->new(400, "Bad Request", undef, "bad md5"));
                    next;
                }
                open my $fh, ">:raw", $blob or die $!;
                print {$fh} $bytes;
                close $fh;
                $uploaded = 1;
                $c->send_response(
                    HTTP::Response->new(
                        200, "OK", [ "Content-Type" => "application/json" ],
                        '{"message":"success"}'
                    )
                );
                next;
            }
            if ($r->method eq "PATCH" && $path =~ m{/artifacts$}) {
                %q = $r->uri->query_form;
                unless (($q{artifactName} || "") eq "prepared" && $uploaded) {
                    $c->send_response(
                        HTTP::Response->new(400, "Bad Request", undef, "not uploaded"));
                    next;
                }
                $confirmed = 1;
                $c->send_response(
                    HTTP::Response->new(
                        200, "OK", [ "Content-Type" => "application/json" ],
                        '{"message":"success"}'
                    )
                );
                next;
            }
            if ($r->method eq "GET" && $path =~ m{/artifacts$} && $path !~ m{/artifacts/}) {
                unless ($confirmed) {
                    $c->send_response(HTTP::Response->new(404, "Not Found", undef, "none"));
                    next;
                }
                my $url = $d->url;
                $url =~ s{/$}{};
                my $json =
                      '{"count":1,"value":[{"name":"prepared","fileContainerResourceUrl":"'
                    . $url
                    . "/api/actions_pipeline/_apis/pipelines/workflows/42/artifacts/$hash/download_url\"}]}";
                $c->send_response(
                    HTTP::Response->new(200, "OK", [ "Content-Type" => "application/json" ], $json)
                );
                next;
            }
            if ($r->method eq "GET" && $path =~ m{/artifacts/$hash/download_url$}) {
                %q = $r->uri->query_form;
                unless (($q{itemPath} || "") eq "prepared") {
                    $c->send_response(HTTP::Response->new(400, "Bad Request", undef, "itemPath"));
                    next;
                }
                my $url = $d->url;
                $url =~ s{/$}{};
                my $json =
                    '{"value":[{"path":"prepared/prepared.tar.gz","itemType":"file","contentLocation":"'
                    . $url
                    . "/api/actions_pipeline/_apis/pipelines/workflows/42/artifacts/1/download\"}]}";
                $c->send_response(
                    HTTP::Response->new(200, "OK", [ "Content-Type" => "application/json" ], $json)
                );
                next;
            }
            if ($r->method eq "GET" && $path =~ m{/artifacts/1/download$}) {
                unless ($confirmed && -f $blob) {
                    $c->send_response(HTTP::Response->new(404, "Not Found", undef, "missing"));
                    next;
                }
                open my $fh, "<:raw", $blob or die $!;
                local $/;
                my $bytes = <$fh>;
                close $fh;
                $c->send_response(
                    HTTP::Response->new(
                        200, "OK", [ "Content-Type" => "application/octet-stream" ], $bytes
                    )
                );
                next;
            }
            $c->send_response(HTTP::Response->new(404, "Not Found", undef, "no $path"));
        }
        $c->close;
        undef $c;
    }
}
