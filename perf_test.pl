#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
exec $^X, "-I$FindBin::Bin/local/lib/perl5", "$FindBin::Bin/t/handler.t", @ARGV;
