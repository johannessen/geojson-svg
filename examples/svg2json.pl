#! /usr/bin/env perl

use strict;
use warnings;
use 5.016;

our $VERSION = 0.03;

use lib 'lib';
use Convert::GeoJSON_SVG;

use File::Slurper;


die "Missing required input file name" if ! scalar @ARGV;
my $file = $ARGV[0];


my $svg = File::Slurper::read_text($file);
my $converter = Convert::GeoJSON_SVG->new();
$converter->{svg_crs} = "+proj=merc +lat_ts=51 +ellps=WGS84 +datum=WGS84 +to_meter=2 +x_0=-529516 +y_0=-4163806 +no_defs";
$converter->{json_crs} = "+init=epsg:25832";
$converter->{json_number} = "%.3f";

if (0) {  # set to 1 if only interested in the outlines
	$converter->{feature_types}->{polygon} = "LineString";
	$converter->{feature_types}->{rect} = "LineString";
}

my $json = $converter->svg2json($svg);
print $json;


exit 0;

__END__
