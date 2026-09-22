#!/usr/bin/env perl
use strict;
use warnings;
use Cwd          qw(getcwd);
use Digest::MD5  qw(md5);
use MIME::Base64 qw(encode_base64);

use constant ARTIFACT_NAME => "prepared";
use constant TAR_NAME      => "prepared.tar.gz";

sub workspace {
    return $ENV{CI_WORKSPACE} || $ENV{GITHUB_WORKSPACE} || getcwd();
}

sub tarball_path {
    return $ENV{CI_TARBALL} || "/tmp/" . TAR_NAME;
}

sub job_token {
    my $t = $ENV{ACTIONS_RUNTIME_TOKEN} || $ENV{GITHUB_TOKEN} || $ENV{GITEA_TOKEN} || "";
    die "missing job token for artifact API\n" unless length $t;
    return $t;
}

sub runtime_url {
    my $u = $ENV{ACTIONS_RUNTIME_URL} || "";
    if (length $u) {
        $u =~ s{/*$}{/};
        return $u;
    }
    my $server = $ENV{GITHUB_SERVER_URL} || "";
    die "missing ACTIONS_RUNTIME_URL or GITHUB_SERVER_URL\n" unless length $server;
    $server =~ s{/*$}{};
    return "$server/api/actions_pipeline/";
}

sub run_id {
    my $id = $ENV{GITHUB_RUN_ID} || "";
    die "missing GITHUB_RUN_ID\n" unless length $id;
    return $id;
}

sub artifact_index_url {
    my ($runtime, $id) = @_;
    $runtime = runtime_url() unless defined $runtime;
    $id      = run_id()      unless defined $id;
    $runtime =~ s{/*$}{/};
    return "${runtime}_apis/pipelines/workflows/${id}/artifacts?api-version=6.0-preview";
}

sub json_unescape {
    my ($v) = @_;
    $v =~ s/\\u([0-9a-fA-F]{4})/chr hex $1/eg;
    $v =~ s/\\n/\n/g;
    $v =~ s/\\r/\r/g;
    $v =~ s/\\t/\t/g;
    $v =~ s/\\"/"/g;
    $v =~ s{\\/}{/}g;
    $v =~ s/\\\\/\\/g;
    return $v;
}

sub json_string {
    my ($json, $key) = @_;
    return unless defined $json;
    if ($json =~ /"$key"\s*:\s*"((?:\\.|[^"\\])*)"/) {
        return json_unescape($1);
    }
    return;
}

sub json_named_field {
    my ($json, $name, $field) = @_;
    return unless defined $json;
    while ($json =~ /\{([^{}]+)\}/g) {
        my $obj = "{$1}";
        my $n   = json_string($obj, "name");
        next unless defined $n && $n eq $name;
        return json_string($obj, $field);
    }
    return;
}

sub absolute_url {
    my ($url) = @_;
    return $url if $url =~ m{^https?://}i;
    my $runtime = runtime_url();
    if ($url =~ m{^/}) {
        if ($runtime =~ m{^(https?://[^/]+)}i) {
            return $1 . $url;
        }
        my $server = $ENV{GITHUB_SERVER_URL} || "";
        $server =~ s{/*$}{};
        return $server . $url;
    }
    $runtime =~ s{/*$}{/};
    return $runtime . $url;
}

sub toward_runtime {
    my ($url) = @_;
    $url = absolute_url($url);
    my $runtime = $ENV{ACTIONS_RUNTIME_URL} || "";
    if ($runtime =~ m{^(https?://[^/]+)}i) {
        my $origin = $1;
        $url =~ s{^https?://[^/]+}{$origin}i;
    }
    return $url;
}

sub capture {
    my @cmd = @_;
    open my $fh, "-|", @cmd or die "cannot run $cmd[0]: $!\n";
    local $/;
    my $out = <$fh>;
    my $ok  = close $fh;
    if (!$ok && !defined $out) {
        die "$cmd[0] failed to start\n";
    }
    return defined $out ? $out : "";
}

sub http {
    my ($method, $url, %opt) = @_;
    my @cmd = (
        qw(curl -sS -X),
        $method, "-H", "Authorization: Bearer " . job_token(),
        "-H",    "Accept: application/json",
    );
    if ($opt{content_type}) {
        push @cmd, "-H", "Content-Type: $opt{content_type}";
    }
    for my $h (@{ $opt{headers} || [] }) {
        push @cmd, "-H", $h;
    }
    if (defined $opt{data_file}) {
        push @cmd, "--data-binary", "@" . $opt{data_file};
    }
    elsif (defined $opt{data}) {
        push @cmd, "--data-binary", $opt{data};
    }
    if ($opt{save}) {
        push @cmd, "-o", $opt{save}, "-w", "%{http_code}";
    }
    else {
        push @cmd, "-w", "\n%{http_code}";
    }
    push @cmd, $url;

    my $raw = capture(@cmd);
    my ($body, $code);
    if ($opt{save}) {
        $code = $raw;
        $code =~ s/\s+//g;
        $body = "";
    }
    else {
        die "curl produced no HTTP status for $method $url\n" unless defined $raw;
        if ($raw =~ s/\n(\d{3})\s*\z//) {
            $code = $1;
            $body = $raw;
        }
        else {
            $code = $raw;
            $code =~ s/\s+//g;
            $body = "";
        }
    }
    unless ($code =~ /^2/) {
        die "HTTP $code $method $url\n$body\n";
    }
    return ($code, $body);
}

sub pack_tree {
    my ($dir, $tarball) = @_;
    $dir     ||= workspace();
    $tarball ||= tarball_path();
    my @cmd = ("tar", "-C", $dir, "-czf", $tarball, ".");
    system(@cmd) == 0 or die "pack tar failed: $?\n";
    return $tarball;
}

sub unpack_tree {
    my ($tarball, $dir) = @_;
    $tarball ||= tarball_path();
    $dir     ||= workspace();
    mkdir $dir or die "mkdir $dir: $!\n" unless -d $dir;
    my @cmd = ("tar", "-C", $dir, "-xzf", $tarball, "--no-same-owner");
    system(@cmd) == 0 or die "unpack tar failed: $?\n";
    return $dir;
}

sub file_md5_b64 {
    my ($path) = @_;
    open my $fh, "<:raw", $path or die "read $path: $!\n";
    local $/;
    my $data = <$fh>;
    close $fh;
    return encode_base64(md5($data), "");
}

sub upload_prepared {
    my $dir     = workspace();
    my $tarball = tarball_path();
    pack_tree($dir, $tarball);
    my $size = -s $tarball;
    die "packed tree is empty\n" unless $size;
    my $end = $size - 1;
    my $md5 = file_md5_b64($tarball);

    my $index = artifact_index_url();
    my ($create_code, $created) = http(
        "POST", $index,
        content_type => "application/json",
        data         => '{"Type":"actions_storage","Name":"' . ARTIFACT_NAME . '"}',
    );
    my $upload = json_string($created, "fileContainerResourceUrl");
    die "create artifact: missing fileContainerResourceUrl ($create_code)\n$created\n"
        unless defined $upload && length $upload;
    $upload = toward_runtime($upload);
    my $item = ARTIFACT_NAME . "/" . TAR_NAME;
    $item =~ s{/}{%2F}g;
    my $sep = $upload =~ /\?/ ? "&" : "?";
    $upload .= $sep . "itemPath=" . $item;

    http(
        "PUT", $upload,
        content_type => "application/octet-stream",
        data_file    => $tarball,
        headers      => [
            "Content-Range: bytes 0-$end/$size",
            "x-tfs-filelength: $size",
            "x-actions-results-md5: $md5",
        ],
    );

    my $confirm = $index;
    $confirm .= ($confirm =~ /\?/ ? "&" : "?") . "artifactName=" . ARTIFACT_NAME;
    http("PATCH", $confirm);
    return $tarball;
}

sub restore_prepared {
    my $dir     = workspace();
    my $tarball = tarball_path();
    my $index   = artifact_index_url();
    my ($list_code, $listed) = http("GET", $index);
    my $container = json_named_field($listed, ARTIFACT_NAME, "fileContainerResourceUrl");
    $container = json_string($listed, "fileContainerResourceUrl") unless defined $container;
    die "list artifacts: missing fileContainerResourceUrl ($list_code)\n$listed\n"
        unless defined $container && length $container;
    $container = toward_runtime($container);
    my $sep = $container =~ /\?/ ? "&" : "?";
    $container .= $sep . "itemPath=" . ARTIFACT_NAME;

    my ($dl_code, $files) = http("GET", $container);
    my $content = json_string($files, "contentLocation");
    die "download_url: missing contentLocation ($dl_code)\n$files\n"
        unless defined $content && length $content;
    $content = toward_runtime($content);

    http("GET", $content, save => $tarball);
    unpack_tree($tarball, $dir);
    return $dir;
}

sub main {
    my ($cmd) = @_;
    $cmd = "" unless defined $cmd;
    if ($cmd eq "upload") {
        upload_prepared();
        return 0;
    }
    if ($cmd eq "restore") {
        restore_prepared();
        return 0;
    }
    die "usage: $0 upload|restore\n";
}

main(@ARGV) unless caller;
1;
