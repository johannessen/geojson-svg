use 5.016;
use strict;
use warnings;
use utf8;

package Convert::GeoJSON_SVG;
# ABSTRACT: Convert geospatial data between GeoJSON and an SVG map sheet


use Geo::JSON;
use Geo::JSON::CRS;  # required for loading files that contain a CRS def ... this seems like a bug in Geo::JSON
use Geo::JSON::Feature;
use Geo::JSON::FeatureCollection;
#use Geo::JSON::LineString;
#use Geo::JSON::Polygon;
use Geo::LibProj::cs2cs 1.02;
use Geo::LibProj::FFI;
use XML::LibXML qw();
use URI;

use Carp qw(croak carp);
use Scalar::Util qw(blessed);
#use Data::Dumper;



sub new {
	my ($class, @options) = @_;
	
#	my %options = @options == 1 ? %{$options[0]} : (@options);
	my $svg_units = 1;
	my $svg_line_style = sprintf "fill:none;stroke:black;stroke-width:%.3f", 0.2 * $svg_units;
	my $instance = {
		json_default_crs => "+proj=latlon +ellps=WGS84 +datum=WGS84 +no_defs",  # EPSG 4326; see RFC 7946
		svg_number => "%.3f",
		json_number => "%.8f",
		svg_px => 1,
		svg_initial_unit => "mm",
		svg_units => $svg_units,
		svg_to_mm => {
			mm => 1,
			in => 25.4,
			pt => 25.4 / 72,
			px => 25.4 / 72,  # the map sheet uses millimetres, but Illustrator uses points for SVG, wrongly labelling them as px
			pc => 25.4 / 72 * 12,
			cm => 10,
		},
		svg_scale_x => 1,
		svg_scale_y => -1,  # we expect the projected map coordinates to be oriented upwards, but the SVG sheet is oriented downwards
		sheet_width => 297,
		sheet_height => 210,
		svg_line_style => $svg_line_style,
		svg_circle_radius => .5,  # in 1/2000, radius .5 equates to a diameter of 2 metres in the world, exactly
		element_types => {  # GeoJSON --> SVG
			MultiPolygon => "polygon",
			Polygon => "polygon",
			MultiLineString => "polyline",
			LineString => "polyline",
			MultiPoint => "circle",
			Point => "circle",
		},
		feature_types => {  # SVG --> GeoJSON
			polygon => "Polygon",
			polyline => "LineString",
			rect => "Polygon",
			line => "LineString",
			circle => "Point",
		},
		stylesheet => "polygon,polyline{$svg_line_style} circle{fill:black;opacity:1} text{font-family:'Helvetica';font-size:.18mm;text-anchor:middle}",
		special_styling => "",
		group_prop => "ELEV",
		feature_callback => undef,
		text_transform => "translate(0,.182)",  # center text vertically on the circles (the .18 is dependant upon, but obviously not equal to the font size)
		verbose => 0,
	};
	
	return bless $instance, $class;
}



sub json2svg {
	my ($self, $json) = @_;
	
	my $svg_crs = $self->{svg_crs} or croak "required value 'svg_crs' undefined";
	
	$json = Geo::JSON->from_json($json) if ! ref $json;
	my $json_crs = $self->{json_crs};
	if (! $json_crs and my $crs = $json->{crs}) {
		my $crs_href = $crs->{type} eq "link" && $crs->{properties}->{type} eq 'proj4' ? $crs->{properties}->{href} : "";
		my $crs_uri = URI->new($crs_href);
		if ($crs_uri && $crs_uri->scheme eq 'data') {
			$json_crs = $crs_uri->data;
		}
		carp "Unable to parse GeoJSON CRS (only proj4 data: URIs are supported); falling back to defaults" if ! $json_crs;
	}
	$json_crs = $self->{json_default_crs} if ! $json_crs;
	$self->{_cs2cs} = Geo::LibProj::cs2cs->new($json_crs => $svg_crs, {XS => 1});
	
	my $doc = $self->create_svg_document;
	my $root = $doc->getDocumentElement;
	
	
	my $groups = {};
	my @text = ();
	
	foreach my $feature ( @{$json->{features}} ) {
		my $geometry_type = $feature->{geometry}->{type};
		next unless my $element_type = $self->{element_types}->{$geometry_type};
		
		my $group = $root;
		if ($self->{group_prop} && $feature->{properties}->{$self->{group_prop}}) {
			my $group_id = "" . $feature->{properties}->{$self->{group_prop}};
			if (! $groups->{$group_id}) {
				$groups->{$group_id} = $doc->createElement("g");
				my $group_xml_id = "_$group_id";
				$group_xml_id =~ s/ /_/g;
				if ($self->{special_styling} && sprintf("%.1f", $feature->{properties}->{$self->{group_prop}}) =~ m/(3[0-9]{2})\.([0-9])/) {
					$groups->{$group_id}->setAttribute("class", "dm$2");
					$group_xml_id = sprintf "_%.1f_m", $feature->{properties}->{$self->{group_prop}};
				}
				$groups->{$group_id}->setAttribute("id", $group_xml_id);
			}
			$group = $groups->{$group_id};
		}
		
		my $coordinates = $feature->{geometry}->{coordinates};
		$coordinates = [$coordinates] if $geometry_type eq "LineString" || $geometry_type eq "Point";
#		$coordinates = [[$coordinates]] if $geometry_type eq "Point";
		if ($geometry_type eq "MultiPolygon") {
			die "MultiPolygon features are not implemented (except if they have exactly one polygon)" unless @$coordinates == 1;
			$coordinates = $coordinates->[0];
		}
		foreach my $line ( @$coordinates ) {
			my $element = $group->addChild($doc->createElement($element_type));
			
			if ($element_type eq "polyline" || $element_type eq "polygon") {
				pop @$line if $geometry_type =~ m/Polygon$/;  # we should probably confirm if the first and last points really are the same
				my @points = map { join ",", $self->point2svg($_) } @$line;
				$element->setAttribute("points", join " ", @points);
			}
			elsif ($geometry_type =~ m/Point$/) {
				my @point = $self->point2svg($line);
				$element->setAttribute("cx", $point[0]);
				$element->setAttribute("cy", $point[1]);
				$element->setAttribute("r", $self->{svg_circle_radius});
				my $xml_id = "";
				$xml_id .= "s" . $feature->{properties}->{id} if $feature->{properties}->{id};
				$xml_id .= "_pt_" . $feature->{properties}->{ref} if $feature->{properties}->{ref};
				$xml_id =~ s/ /_/g;
				$element->setAttribute("id", $xml_id) if $xml_id;
# 				my $text = sprintf "%.2f", $feature->{properties}->{depth};
# 				$text = sprintf "%.1f", $feature->{properties}->{depth} if $text >= 10;
# 				push @text, {text => $text, text_x => $point[0], text_y => $point[1]};
			}
			else {
				die "feature type not implemented";
			}
			$self->{feature_callback}->($element, $feature, $json->{features}, \@text) if $self->{feature_callback};
		}
	}
	
	foreach my $group_id (sort keys %$groups) {
		my $group = $groups->{$group_id};
		$group->insertBefore(XML::LibXML::Comment->new( $group_id ), $group->firstChild);
		$root->addChild($group);
	}
	
	if (@text) {
		my $text_group = $root->addChild($doc->createElement("g"));
		$text_group->setAttribute("id", "text");
		$text_group->setAttribute("transform", "$self->{text_transform}");
		foreach my $text (@text) {
			my $element = $text_group->addChild($doc->createElement("text"));
			$element->addChild(XML::LibXML::Text->new( $text->{text} ));
			$element->setAttribute("x", $text->{text_x});
			$element->setAttribute("y", $text->{text_y});
		}
	}
	
	return $doc->toString(1);
}



sub create_svg_document {
	my ($self) = @_;
	
	my $doc = XML::LibXML::Document->new;
	$doc->createInternalSubset("svg", "-//W3C//DTD SVG 1.1//EN", "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd");
	my $xmlns_svg = "http://www.w3.org/2000/svg";
	my $root = $doc->createElementNS($xmlns_svg, "svg");
#	$root->setAttribute("x", "0$self->{svg_initial_unit}");
#	$root->setAttribute("y", "0$self->{svg_initial_unit}");
	$root->setAttribute("width", sprintf("$self->{svg_number}$self->{svg_initial_unit}", $self->{sheet_width} * $self->{svg_units}));
	$root->setAttribute("height", sprintf("$self->{svg_number}$self->{svg_initial_unit}", $self->{sheet_height} * $self->{svg_units}));
	$root->setAttribute("viewBox", sprintf("0 0 $self->{svg_number} $self->{svg_number}", $self->{sheet_width} * $self->{svg_units}, $self->{sheet_height} * $self->{svg_units}));
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
	$meta_crs->setAttributeNS($xmlns_svg, "transform", "scale($self->{svg_scale_x},$self->{svg_scale_y})");
	my $meta_svg_crs = URI->new("data:");
	$meta_svg_crs->data($self->{_svg_crs});
	$meta_crs->setAttributeNS($xmlns_rdf, "resource", "$meta_svg_crs");
	
	my $xml_defs = $root->addChild($doc->createElement("defs"));
	my $xml_style = $xml_defs->addChild($doc->createElement("style"));
	$xml_style->setAttribute("type", "text/css");  # this is the default, but Illustrator CS6 requires it to be specified
	$xml_style->addChild(XML::LibXML::CDATASection->new( $self->{stylesheet} . $self->{special_styling} ));
	
	return $doc;
}



sub svg2json {
	my ($self, $svg) = @_;
	
	my $parser = XML::LibXML->new(pedantic_parser => 1, load_ext_dtd => 0);
	
	print STDERR "Parsing XML ..." if $self->{verbose} >= 1;
	
	# Initialise the XPath context with the namespace used for GPX files.
	# We use 'svg' as namespace prefix, since XML::LibXML doesn't
	# support XPath 2.0's default namespaces.
	my $doc = $parser->load_xml(string => $svg);
	my $context = XML::LibXML::XPathContext->new($doc);
	my $xmlns_svg = "http://www.w3.org/2000/svg";
	my $xmlns_rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#";
	my $xmlns_crs = "http://www.ogc.org/crs";
	$context->registerNs("svg", $xmlns_svg);
	$context->registerNs("rdf", $xmlns_rdf);
	$context->registerNs("crs", $xmlns_crs);
	
	print STDERR " done\nObtaining meta data\n" if $self->{verbose} >= 2;
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
	my $svg_units = $self->{svg_to_mm}->{$svg_width->[1]};
	print STDERR "SVG user unit scale factor: $svg_units\n" if $self->{verbose} >= 2;
	my $svg_viewbox = $root->getAttribute("viewBox");
	$svg_viewbox =~ m/^0 0 ([\.0-9]+) ([\.0-9]+)$/ or die "Couldn't parse viewBox attr on svg element (min-x/min-y are expected to be '0' and width/height are expected to be in user units)";
	die "SVG viewport scaling not implemented" if $svg_width->[0] != $1 || $svg_height->[0] != $2;
	die "Don't know how to deal with non-zero x and y attrs on svg element" if svg_length($root->getAttribute("x"))->[0] || svg_length($root->getAttribute("y"))->[0];
	
	my ($svg_scale_x, $svg_scale_y) = ($self->{svg_scale_x}, $self->{svg_scale_y});
	my $svg_crs = $self->{svg_crs};
	my $svg_crs_resource = $context->findnodes('/svg:svg/svg:metadata//crs:CoordinateReferenceSystem/@rdf:resource')->string_value;
	if (! $svg_crs && $svg_crs_resource) {
		my $crs_uri = URI->new($svg_crs_resource);
		if ($crs_uri && $crs_uri->scheme eq 'data') {
			$svg_crs = $crs_uri->data;
		}
		else {
			carp "Unable to parse SVG CRS (only proj4 data: RDF URIs and scale() transformations are supported)";
		}
	}
	croak "required value 'svg_crs' undefined" unless $svg_crs;
	my $json_crs = $self->{json_crs} || $self->{json_default_crs};
	my $svg_crs_transform = $context->findnodes('/svg:svg/svg:metadata//crs:CoordinateReferenceSystem/@svg:transform')->string_value;
	if ($svg_crs_transform && $svg_crs_transform =~ m/scale\(([-+0-9\.e]+),([-+0-9\.e]+)\)/i) {
		$svg_scale_x = $1;
		$svg_scale_y = $2;
	}
	$self->{_svg_units} = $svg_units;
	$self->{_svg_scale} = [$svg_scale_x, $svg_scale_y];
	$self->{_cs2cs} = Geo::LibProj::cs2cs->new($svg_crs => $json_crs, {XS => 1});
	
	print STDERR "Converting features\n" if $self->{verbose} >= 2;
	my @bbox = undef;
	my @features = ();
	foreach my $node ( $context->findnodes('/svg:svg//svg:polyline | /svg:svg//svg:polygon | /svg:svg//svg:rect | /svg:svg//svg:line | /svg:svg//svg:circle') ) {
		$context->setContextNode($node);
		push @features, $self->handle_svg_node($node, $context);
	}
	
	print STDERR scalar(@features), " feature(s) parsed\n" if $self->{verbose} >= 1;
	
	my $meta_crs_uri = URI->new("data:");
	$meta_crs_uri->data($json_crs);
	
	my $json = Geo::JSON::FeatureCollection->new({
		 features => \@features,
		 crs => Geo::JSON::CRS->new({ type => 'link', properties => { href => "$meta_crs_uri", type => "proj4" } }),
	});
#	$json->{bbox} = $json->compute_bbox;  # bug in module: requires at least 2 positions
#	Geo::JSON->codec->canonical(1)->pretty;  # debug only due to file size
	return $json->to_json . "\n";
}



sub handle_svg_node {
	my ($self, $node, $context) = @_;
	
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
		my $p1 = $self->point2json([$x - $radius, $y]);
		my $p2 = $self->point2json([$x + $radius, $y]);
		$properties{svg_size} = 0 + sprintf "$self->{json_number}", $p2->[0] - $p1->[0];
	}
	else {
		die "svg:" . $node->nodeName . " not implemented";
	}
#print STDERR Dumper \@points, $node->nodeName;
	
	@points = map { $self->point2json($_) } @points;
	@points = @{$points[0]} if $self->{feature_types}->{$node->nodeName} eq "Point";
	@points = ([( @points, $points[0] )]) if $self->{feature_types}->{$node->nodeName} eq "Polygon";  # GeoJSON polygons may include multiple linear rings to define holes, which SVG can only represent using paths
	
	for (my $n = $node; $n; $n = $n->parentNode) {
		last unless $n->can('getAttribute');
		next unless my $id = $n->getAttribute("id");
		$properties{svg_id} = $id;
		last;
	}
	my @properties = scalar keys %properties ? (properties => \%properties) : ();
	
	my @coordinates = (coordinates => \@points);
#	my $geometry = Geo::JSON::LineString->new({@coordinates});
	my $geometry = Geo::JSON->load({ type => $self->{feature_types}->{$node->nodeName}, @coordinates });
	my $feature = Geo::JSON::Feature->new({ geometry => $geometry, @properties });
	return ($feature) unless $self->{feature_callback};
	my @callback_return = ($self->{feature_callback}->($node, $feature));
	return () if @callback_return == 0 || ! defined $callback_return[0];
	my @features = ();
	foreach my $return (@callback_return) {
		next if ! blessed $return || "Geo::JSON::Feature" ne blessed $return;
		push @features, $return;
	}
	return @features > 0 ? @features : ($feature);
}



sub point2svg {
	my ($self, $point) = @_;
	my $scale_x = $self->{svg_units} * $self->{svg_scale_x};
	my $scale_y = $self->{svg_units} * $self->{svg_scale_y};
	
	my $p = $self->{_cs2cs}->transform($point);
	my @p = ($p->[0] * $scale_x, $p->[1] * $scale_y);
	return map {0 + sprintf "$self->{svg_number}", $_} @p;
}



sub point2json {
	my ($self, $point) = @_;
	my $scale_x = $self->{_svg_units} / $self->{_svg_scale}->[0];
	my $scale_y = $self->{_svg_units} / $self->{_svg_scale}->[1];
	
	my @p = ($point->[0] * $scale_x, $point->[1] * $scale_y);
	my $p = $self->{_cs2cs}->transform($point);
	return [ map {0 + sprintf "$self->{json_number}", $_} @$p[0..1] ];
}



1;

__END__



=pod

=head1 SYNOPSIS

 my $converter = Convert::GeoJSON_SVG->new();
 
 $converter->{svg_crs} = "+proj=merc +lat_ts=51 +ellps=WGS84 +datum=WGS84 +to_meter=2 +x_0=-529516 +y_0=-4163806";
 $converter->{json_crs} = "+init=epsg:25832";
 my $svg = $converter->json2svg( $geojson );
 
 my $geojson = $converter->svg2json( $svg );

=cut
