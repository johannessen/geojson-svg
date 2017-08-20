#! /usr/bin/env perl

use strict;
use warnings;
use 5.016;

our $VERSION = 0.02;

# use Getopt::Long 2.33 qw( :config posix_default gnu_getopt auto_version auto_help );
use Pod::Usage;
use File::Slurper;
use Geo::JSON;
use Geo::JSON::CRS;  # required for loading files that contain a CRS def ... this seems like a bug in Geo::JSON
use List::Util qw();
use Math::Round qw();
use Data::Dumper;

use Geo::Proj4 qw();
use XML::LibXML qw();
use URI;


# my $verbose = 0;
# my %options = (
# 	man => undef,
# 	test => undef,
# 	dev => undef,
# 	mandate_file => undef,
# #	cypher_file => 'out.cypher.txt',
# 	resources_file => undef,
# 	roles_file => undef,
# 	roles_dev_file => undef,
# 	wiki_init_file => undef,
# 	intern_dir => 'conf',
# 	create_paradox => undef,
# 	paradox_no_privacy => undef,
# 	paradox_file => undef,
# );
# GetOptions(
# 	'verbose|v+' => \$verbose,
# 	'man' => \$options{man},
# 	'mandates|m' => \$options{mandate_file},
# #	'cypher|c=s' => \$options{cypher_file},
# 	'resources|s=s' => \$options{resources_file},
# 	'roles|r=s' => \$options{roles_file},
# 	'roles-dev-file=s' => \$options{roles_dev_file},
# 	'wiki-init-file=s' => \$options{wiki_init_file},
# 	'intern|i=s' => \$options{intern_dir},
# 	'gs-verein' => \$options{create_paradox},
# 	'no-gs-verein-privacy' => \$options{paradox_no_privacy},
# 	'gs-verein-file=s' => \$options{paradox_file},
# 	'test|t' => \$options{test},
# 	'dev|d' => \$options{dev},
# ) or pod2usage(2);
# pod2usage(-exitstatus => 0, -verbose => 2) if $options{man};

if (1 > scalar @ARGV) {
	pod2usage(-exitstatus => 1, -verbose => 0, -message => 'Missing required input file name.');
}
my $file = $ARGV[0];
#my $json_crs = "+proj=latlon +ellps=WGS84 +datum=WGS84 +no_defs";
my $json_crs = "+init=epsg:4326";
#my $json_crs = "+init=epsg:25832";
my $svg_crs = "+proj=merc +lat_ts=51 +ellps=WGS84 +datum=WGS84 +to_meter=2 +x_0=-529516 +y_0=-4163806 +no_defs";
my $svg_number = "%.3f";
# the map sheet uses millimetres, but Illustrator uses points for SVG, wrongly labelling them as px
#my $svg_initial_unit = "pt";
#my $svg_units = 72 / 25.4;
my $svg_initial_unit = "mm";
my $svg_units = 1;
my $svg_scale_x = 1;
my $svg_scale_y = -1;  # we expect the projected map coordinates to be oriented upwards, but the SVG sheet is oriented downwards
my $sheet_width = 1022;
my $sheet_height = 1022;
my $svg_line_style = sprintf "fill:none;stroke:black;stroke-width:$svg_number", 0.2 * $svg_units;
my $svg_circle_radius = .5;  # in 1/2000, this equates to a diameter of 2 metres in the world, exactly
my $element_types = {
	Polygon => "polygon",
	MultiLineString => "polyline",
	LineString => "polyline",
	Point => "circle",
};
my $special_styling = "";
$special_styling = " .dm0 *,.dm5 *{stroke:red}";  # special styling for Job 1721
my $group_prop = "ELEV";
my ($scale_min, $scale_max);
$scale_min = -.5;
$scale_max = 8;
#my $scale_reverse = 0;
my $scale_colouring = 1;


my $json = Geo::JSON->from_json( File::Slurper::read_text($file) );
if (my $crs = $json->{crs}) {
	my $crs_href = $crs->{type} eq "link" && $crs->{properties}->{type} eq 'proj4' ? $crs->{properties}->{href} : "";
	my $crs_uri = URI->new($crs_href);
	if ($crs_uri && $crs_uri->scheme eq 'data') {
		$json_crs = $crs_uri->data;
	}
	else {
		warn "Unable to parse GeoJSON CRS (only proj4 data: URIs are supported); falling back to WGS84";
	}
}
my $json_proj = Geo::Proj4->new($json_crs) or die "libproj error: " . Geo::Proj4->error;
my $svg_proj = Geo::Proj4->new($svg_crs) or die "libproj error: " . Geo::Proj4->error;

my $doc = XML::LibXML::Document->new;
$doc->createInternalSubset("svg", "-//W3C//DTD SVG 1.1//EN", "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd");
my $xmlns_svg = "http://www.w3.org/2000/svg";
my $root = $doc->createElementNS($xmlns_svg, "svg");
#$root->setAttribute("x", "0$svg_initial_unit");
#$root->setAttribute("y", "0$svg_initial_unit");
$root->setAttribute("width", sprintf("$svg_number$svg_initial_unit", $sheet_width * $svg_units));
$root->setAttribute("height", sprintf("$svg_number$svg_initial_unit", $sheet_height * $svg_units));
$root->setAttribute("viewBox", sprintf("0 0 $svg_number $svg_number", $sheet_width * $svg_units, $sheet_height * $svg_units));
$doc->setDocumentElement($root);

my $xml_meta = $root->addChild($doc->createElement("metadata"));
my $meta_rdf = $xml_meta->addChild($doc->createElement("RDF"));
my $xmlns_rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#";
my $xmlns_crs = "http://www.ogc.org/crs";
$meta_rdf->setNamespace($xmlns_rdf, "rdf");
$meta_rdf->setNamespace($xmlns_crs, "crs", 0);
$meta_rdf->setNamespace("http://www.w3.org/2000/svg", "svg", 0);
my $meta_desc = $meta_rdf->addChild($doc->createElement("Description"));
$meta_desc->setNamespace($xmlns_rdf, "rdf");
my $meta_crs = $meta_desc->addChild($doc->createElement("CoordinateReferenceSystem"));
$meta_crs->setNamespace($xmlns_crs, "crs");
$meta_crs->setAttributeNS($xmlns_svg, "transform", "scale($svg_scale_x,$svg_scale_y)");
my $meta_svg_crs = URI->new("data:");
$meta_svg_crs->data($svg_crs);
$meta_crs->setAttributeNS($xmlns_rdf, "resource", "$meta_svg_crs");

my $xml_defs = $root->addChild($doc->createElement("defs"));
my $xml_style = $xml_defs->addChild($doc->createElement("style"));
$xml_style->setAttribute("type", "text/css");  # this is the default, but Illustrator CS6 requires it to be specified
$xml_style->addChild(XML::LibXML::CDATASection->new( "polygon,polyline{$svg_line_style} circle{fill:black;opacity:1} text{font-family:'Helvetica';font-size:.18mm;text-anchor:middle}" . $special_styling ));

$scale_min //= List::Util::min map {$_->{properties}->{depth}} @{$json->{features}};
$scale_max //= List::Util::max map {$_->{properties}->{depth}} @{$json->{features}};
sub mod {
	my ($m, $n) = @_;
	return $m - Math::Round::nlowmult($n, $m);
}
sub hsv2rgb {
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
sub colour {
	my ($value) = @_;
	$value = List::Util::max $scale_min, List::Util::min $scale_max, $value;
	my $h = ($value - $scale_min) / ($scale_max - $scale_min);
#	$h = ($value - $scale_max) / ($scale_min - $scale_max) if $scale_reverse;
	my ($r, $g, $b) = hsv2rgb $h * 300, 1, 1;
	return sprintf "#%.2x%.2x%.2x", $r * 255, $g * 255, $b * 255;
}


my $groups = {};
my @text = ();

sub point2svg {
	my ($point) = @_;
	my $p = $json_proj->transform($svg_proj, $point);
	my @p = ($p->[0] * $svg_units * $svg_scale_x, $p->[1] * $svg_units * $svg_scale_y);
	return map {0 + sprintf "$svg_number", $_} @p;
}

foreach my $feature ( @{$json->{features}} ) {
	my $geometry_type = $feature->{geometry}->{type};
	next unless my $element_type = $element_types->{$geometry_type};
	
	my $group = $root;
	if ($group_prop && $feature->{properties}->{$group_prop}) {
		my $group_id = "" . $feature->{properties}->{$group_prop};
		if (! $groups->{$group_id}) {
			$groups->{$group_id} = $doc->createElement("g");
			my $group_xml_id = "_$group_id";
			$group_xml_id =~ s/ /_/g;
			if ($special_styling && sprintf("%.1f", $feature->{properties}->{ELEV}) =~ m/(3[0-9]{2})\.([0-9])/) {
				$groups->{$group_id}->setAttribute("class", "dm$2");
				$group_xml_id = sprintf "_%.1f_m", $feature->{properties}->{ELEV};
			}
			$groups->{$group_id}->setAttribute("id", $group_xml_id);
		}
		$group = $groups->{$group_id};
	}
	
	my $coordinates = $feature->{geometry}->{coordinates};
	$coordinates = [$coordinates] if $geometry_type eq "LineString" || $geometry_type eq "Point";
#	$coordinates = [[$coordinates]] if $geometry_type eq "Point";
	foreach my $line ( @$coordinates ) {
		my $element = $group->addChild($doc->createElement($element_type));
		
		if ($element_type eq "polyline" || $element_type eq "polygon") {
			pop @$line if $geometry_type eq "Polygon";  # we should probably make sure the first and last points really are the same
			my @points = map { join ",", point2svg $_ } @$line;
			$element->setAttribute("points", join " ", @points);
		}
		elsif ($geometry_type eq "Point") {
			my @point = point2svg $line;
			$element->setAttribute("cx", $point[0]);
			$element->setAttribute("cy", $point[1]);
			$element->setAttribute("r", $svg_circle_radius);
			my $xml_id = "";
			$xml_id .= "s" . $feature->{properties}->{id} if $feature->{properties}->{id};
			$xml_id .= "_pt_" . $feature->{properties}->{ref} if $feature->{properties}->{ref};
			$xml_id =~ s/ /_/g;
			$element->setAttribute("id", $xml_id) if $xml_id;
			my $text = sprintf "%.2f", $feature->{properties}->{depth};
			$text = sprintf "%.1f", $feature->{properties}->{depth} if $text >= 10;
			push @text, {text => $text, text_x => $point[0], text_y => $point[1]};
			$element->setAttribute("style", "fill:" . colour $feature->{properties}->{depth}) if $scale_colouring && $feature->{properties}->{depth};
		}
		else {
			die "feature type not implemented";
		}
	}
}

foreach my $group_id (sort keys %$groups) {
	my $group = $groups->{$group_id};
	$group->insertBefore(XML::LibXML::Comment->new( $group_id ), $group->firstChild);
	$root->addChild($group);
}

my $text_group = $root->addChild($doc->createElement("g"));
$text_group->setAttribute("id", "text");
$text_group->setAttribute("transform", "translate(0,.182)");  # center text vertically on the circles (the .18 is dependant upon, but obviously not equal to the font size)
foreach my $text (@text) {
	my $element = $text_group->addChild($doc->createElement("text"));
	$element->addChild(XML::LibXML::Text->new( $text->{text} ));
	$element->setAttribute("x", $text->{text_x});
	$element->setAttribute("y", $text->{text_y});
}

print $doc->toString(1);



exit 0;

__END__
