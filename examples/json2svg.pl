#! /usr/bin/env perl

use strict;
use warnings;
use 5.016;

our $VERSION = 0.03;

use lib 'lib';
use Convert::GeoJSON_SVG;

use File::Slurper;
use List::Util qw();
use Math::Round qw();


die "Missing required input file name" if ! scalar @ARGV;
my $file = $ARGV[0];


sub mod ($$) {
	my ($m, $n) = @_;
	return $m - Math::Round::nlowmult($n, $m);
}
sub hsv2rgb ($$$) {
	my ($h, $s, $v) = @_;
	$h = mod $h, 360;
	my $c = $v * $s;  # (usually 1)
	my $x = $c * (1 - abs( (mod $h / 60, 2) - 1 ));
	my $m = $v - $c;  # (usually 0)
	($c, $x) = ($c + $m, $x + $m);
	return ($c, $x, $m) if   0 <= $h && $h <  60;
	return ($x, $c, $m) if  60 <= $h && $h < 120;
	return ($m, $c, $x) if 120 <= $h && $h < 180;
	return ($m, $x, $c) if 180 <= $h && $h < 240;
	return ($x, $m, $c) if 240 <= $h && $h < 300;
	return ($c, $m, $x) if 300 <= $h && $h < 360;
	die;
}
sub colour ($) {
	my ($h) = @_;
#	$h = ($h - $scale_max) / ($scale_min - $scale_max) if $scale_reverse;
	my ($r, $g, $b) = hsv2rgb $h * 300, 1, 1;
	return sprintf "#%.2x%.2x%.2x", $r * 255, $g * 255, $b * 255;
}


my $json = File::Slurper::read_text($file);
my $converter = Convert::GeoJSON_SVG->new();
$converter->{svg_crs} = "+proj=merc +lat_ts=51 +ellps=WGS84 +datum=WGS84 +to_meter=2 +x_0=-529516 +y_0=-4163806 +no_defs";
$converter->{json_crs} = "+init=epsg:25832";
$converter->{sheet_width} = 1022;
$converter->{sheet_height} = 1022;
$converter->{special_styling} = " .dm0 *,.dm5 *{stroke:red}";  # special styling for Job 1721

my $scale_colouring = 1;
#my $scale_reverse = 0;
my ($scale_min, $scale_max);
$scale_min = -.5;
$scale_max = 8;
$converter->{feature_callback} = sub {
	my ($element, $feature, $all_features, $texts) = @_;
	return unless $scale_colouring && $feature->{properties}->{depth};
	$scale_min //= List::Util::min map {$_->{properties}->{depth}} @$all_features;
	$scale_max //= List::Util::max map {$_->{properties}->{depth}} @$all_features;
	my $depth = List::Util::max $scale_min, List::Util::min $scale_max, $feature->{properties}->{depth};
	my $value = ($depth - $scale_min) / ($scale_max - $scale_min);
	$element->setAttribute("style", "fill:" . colour $value);
	if ($feature->{geometry}->{type} eq "Point") {
		my $text = sprintf "%.2f", $feature->{properties}->{depth};
		$text = sprintf "%.1f", $feature->{properties}->{depth} if $text >= 10;
		push @$texts, {
			text => $text,
			text_x => $element->getAttribute("cx"),
			text_y => $element->getAttribute("cy"),
		};
	}
};

my $svg = $converter->json2svg($json);
print $svg;


exit 0;

__END__
