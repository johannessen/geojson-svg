#! /usr/bin/env perl

use strict;
use warnings;
use 5.016;

our $VERSION = 0.02;

# use Getopt::Long 2.33 qw( :config posix_default gnu_getopt auto_version auto_help );
use Pod::Usage;
#use File::Slurper;
use Geo::JSON;
use Geo::JSON::CRS;
use Geo::JSON::Feature;
use Geo::JSON::FeatureCollection;
use Geo::JSON::LineString;
use Geo::JSON::Polygon;
use Data::Dumper;

use Geo::Proj4 qw();
#use Geo::Proj qw();
#use Geo::Point qw();
use XML::LibXML qw();
use URI;


my $verbose = 0;
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
#my $json_crs = "+init=epsg:4326";
my $json_crs = "+init=epsg:25832";
my $svg_crs = "+proj=merc +lat_ts=51 +ellps=WGS84 +datum=WGS84 +to_meter=2 +x_0=-529516 +y_0=-4163806 +no_defs";
my $json_number = "%.3f";
# the map sheet uses millimetres, but Illustrator uses points for SVG, wrongly labelling them as px
my %svg_to_mm = (mm => 1);
$svg_to_mm{in} = $svg_to_mm{mm} * 25.4;
$svg_to_mm{pt} = $svg_to_mm{in} / 72;
$svg_to_mm{px} = $svg_to_mm{pt};
$svg_to_mm{pc} = $svg_to_mm{pt} * 12;
$svg_to_mm{cm} = $svg_to_mm{mm} * 10;
#my $svg_initial_unit = "pt";
#my $svg_units = 72 / 25.4;
my $svg_px = 1;
my $svg_initial_unit = "mm";
#my $svg_units = 1;
my $svg_scale_x = 1;
my $svg_scale_y = -1;  # we expect the projected map coordinates to be oriented upwards, but the SVG sheet is oriented downwards
my $feature_type_polygon = 1 ? "Polygon" : "LineString";  # set to 0 if only interested in the outlines
my $feature_types = {
	polygon => $feature_type_polygon,
	polyline => "LineString",
	rect => $feature_type_polygon,
	line => "LineString",
	circle => "Point",
};



my $parser = XML::LibXML->new(pedantic_parser => 1, load_ext_dtd => 0);

print STDERR "Parsing XML file $file ..." if $verbose >= 1;

# Initialise the XPath context with the namespace used for GPX files.
# We use 'svg' as namespace prefix, since XML::LibXML doesn't
# support XPath 2.0's default namespaces.
my $doc = $parser->load_xml(location => $file);
my $context = XML::LibXML::XPathContext->new($doc);
my $xmlns_svg = "http://www.w3.org/2000/svg";
my $xmlns_rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#";
my $xmlns_crs = "http://www.ogc.org/crs";
$context->registerNs("svg", $xmlns_svg);
$context->registerNs("rdf", $xmlns_rdf);
$context->registerNs("crs", $xmlns_crs);

print STDERR " done\nObtaining meta data\n" if $verbose >= 2;
sub svg_length {
	# parse SVG length
	return [0, ''] unless my $length = shift;  # assume '0' is default value
	$length =~ m/^([\.0-9]+)([^0-9]*)$/ or die "Unparseable SVG length '$length'";
	return [$1, $2];
}
my $root = $doc->documentElement;
my $svg_width = svg_length($root->getAttribute("width"));
my $svg_height = svg_length($root->getAttribute("height"));
die "Required width and height attrs missing or zero on svg element" if ! $svg_width->[0] || ! $svg_height->[0];
die "Different SVG units for width and height not implemented" if $svg_width->[1] ne $svg_height->[1];
my $svg_units = $svg_to_mm{$svg_width->[1]};
print STDERR "SVG user unit scale factor: $svg_units\n" if $verbose >= 2;
my $svg_viewbox = $root->getAttribute("viewBox");
$svg_viewbox =~ m/^0 0 ([\.0-9]+) ([\.0-9]+)$/ or die "Couldn't parse viewBox attr on svg element (min-x/min-y are expected to be '0' and width/height are expected to be in user units)";
die "SVG viewport scaling not implemented" if $svg_width->[0] != $1 || $svg_height->[0] != $2;
die "Don't know how to deal with non-zero x and y attrs on svg element" if svg_length($root->getAttribute("x"))->[0] || svg_length($root->getAttribute("y"))->[0];

my $svg_crs_resource = $context->findnodes('/svg:svg/svg:metadata//crs:CoordinateReferenceSystem/@rdf:resource')->string_value;
if ($svg_crs_resource) {
	my $crs_uri = URI->new($svg_crs_resource);
	if ($crs_uri && $crs_uri->scheme eq 'data') {
		$svg_crs = $crs_uri->data;
	}
	else {
		warn "Unable to parse SVG CRS (only proj4 data: RDF URIs and scale() transformations are supported)";
	}
}
my $svg_crs_transform = $context->findnodes('/svg:svg/svg:metadata//crs:CoordinateReferenceSystem/@svg:transform')->string_value;
if ($svg_crs_transform && $svg_crs_transform =~ m/scale\(([-+0-9\.e]+),([-+0-9\.e]+)\)/i) {
	$svg_scale_x = $1;
	$svg_scale_y = $2;
}
my $svg_proj = Geo::Proj4->new($svg_crs) or die "libproj error: " . Geo::Proj4->error;
my $json_proj = Geo::Proj4->new($json_crs) or die "libproj error: " . Geo::Proj4->error;
sub cs2cs {
	my ($from_proj, $to_proj, $x, $y) = @_;
	my $p = $from_proj->transform($to_proj, [$x * $svg_units / $svg_scale_x, $y * $svg_units / $svg_scale_y]);
	return [ map {0 + sprintf "$json_number", $_} @$p ];
}

print STDERR "Converting features\n" if $verbose >= 2;
my @bbox = undef;
my @features = ();
foreach my $node ( $context->findnodes('/svg:svg//svg:polyline | /svg:svg//svg:polygon | /svg:svg//svg:rect | /svg:svg//svg:line | /svg:svg//svg:circle') ) {
	$context->setContextNode($node);
	
	my %properties = ();
	my @points = ();
	if ($node->nodeName eq "polyline" || $node->nodeName eq "polygon") {
		foreach my $point ( split m/\s+/, $context->findnodes('@points')->string_value ) {
			next unless $point;
			push @points, [ split m/,/, $point ];
		}
	}
	elsif ($node->nodeName eq "rect") {
		my ($left, $top) = map {$context->findnodes($_)->string_value} ('@x', '@y');
		my $right = $left + $context->findnodes('@width')->string_value;
		my $bottom = $top + $context->findnodes('@height')->string_value;
		@points = ([$left, $top], [$right, $top], [$right, $bottom], [$left, $bottom]);
	}
	elsif ($node->nodeName eq "line") {
		my @p1 = map {$context->findnodes($_)->string_value} ('@x1', '@y1');
		my @p2 = map {$context->findnodes($_)->string_value} ('@x2', '@y2');
		@points = (\@p1, \@p2);
	}
	elsif ($node->nodeName eq "circle") {
		my ($x, $y) = map {$context->findnodes($_)->string_value} ('@cx', '@cy');
		@points = ([$x, $y]);
		# calculate approx. size in world units to enable attribute-based styling
		my $radius = $context->findnodes('@r')->string_value;
		my $p1 = cs2cs $svg_proj => $json_proj, $x - $radius, $y;
		my $p2 = cs2cs $svg_proj => $json_proj, $x + $radius, $y;
		$properties{svg_size} = 0 + sprintf "$json_number", $p2->[0] - $p1->[0];
	}
	else {
		die "svg:" . $node->nodeName . " not implemented";
	}
#print STDERR Dumper \@points, $node->nodeName;
	
	@points = map { cs2cs $svg_proj => $json_proj, @$_ } @points;
	@points = @{$points[0]} if $feature_types->{$node->nodeName} eq "Point";
	@points = ([( @points, $points[0] )]) if $feature_types->{$node->nodeName} eq "Polygon";  # GeoJSON polygons may include multiple linear rings to define holes, which SVG can only represent using paths
	
	for (my $n = $node; $n; $n = $n->parentNode) {
		last unless $n->can('getAttribute');
		next unless my $id = $n->getAttribute("id");
		$properties{svg_id} = $id;
		last;
	}
	my @properties = scalar keys %properties ? (properties => \%properties) : ();
	
	my @coordinates = (coordinates => \@points);
#	my $geometry = Geo::JSON::LineString->new({@coordinates});
	my $geometry = Geo::JSON->load({ type => $feature_types->{$node->nodeName}, @coordinates });
	push @features, Geo::JSON::Feature->new({ geometry => $geometry, @properties });
}

print STDERR scalar(@features), " feature(s) parsed\n" if $verbose >= 1;

my $meta_crs_uri = URI->new("data:");
$meta_crs_uri->data($json_crs);

my $json = Geo::JSON::FeatureCollection->new({
	 features => \@features,
	 crs => Geo::JSON::CRS->new({ type => 'link', properties => { href => "$meta_crs_uri", type => "proj4" } }),
});
#$json->{bbox} = $json->compute_bbox;  # bug in module: requires at least 2 positions
Geo::JSON->codec->canonical(1)->pretty;  # debug only due to file size
print $json->to_json, "\n";


exit 0;

__END__
