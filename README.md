Convert::GeoJSON_SVG
====================

Creating a GeoPDF map with vector graphics editors requires exact positioning
of the map contents with respect to the GeoPDF registration. A reliable way to
achieve this is to define the map projection using [Proj4][] with a scale and
custom easting and northing that exactly fit the map sheet. World coordinates
can then easily be converted to map coordinates.

Given a Proj4 definition, this software allows converting [GeoJSON][] data to
[SVG][] suitable for direct import into the vector editor. Notably, it also
has limited support for converting SVG exported from the vector editor back
to GeoJSON. This feature allows digitising geospatial data in a vector editor
instead of a GIS.

However, the coordinate calculations performed by Proj4 are *not guaranteed*
to be numerically stable. *Repeated* conversion of the same dataset back
and forth between SVG and GeoJSON therefore *might* result in unacceptable
degradation of precision and should be avoided, particularly for maps drawn
at larger scales.

This software has pre-release quality. There is little documentation and no
schedule for further development.

The module name is a work in progress. Options under consideration:
- `Convert::GeoJSON_SVG`
- `Geo::JSON::Convert::SVG`
- `Geo::JSON::Render::SVG`

[Proj4]: https://proj4.org/
[GeoJSON]: http://geojson.org/geojson-spec.html
[SVG]: https://www.w3.org/Graphics/SVG/


Proj4 Projection Definition
---------------------------

Pretty straight-forward for a new map: Simply define the projection as usual.
Make sure you define the map scale using `+to_meter`. Avoid using `+units`,
as it conflicts with `+to_meter`. Finally, provide custom values for false
easting and false northing (in metres) such that the resulting map coordinates
are directly usable as sheet coordinates in millimetres in the vector editor.
This software automatically inverts the ordinal axis to fit the SVG coordinate
orientation; the `+axis` parameter is not required.

For example, the following definition would declare a normal-aspect Mercator
projection with a natural scale of 1:2000 at latitude 51°. The origin of the
SVG coordinate system is located at 529516 m east and 4163806 m north on the
projected Mercator map (which is somewhere in western Germany).

	+proj=merc +lat_ts=51 +to_meter=2
	+x_0=-529516 +y_0=-4163806

The `cs2cs` tool can help with determining the SVG coordinate origin.

```sh
echo 7.54322 51.08437 |
cs2cs +proj=lonlat +to +proj=merc +lat_ts=51
# output: 529516.53 4163806.12
```

Providing a Proj4 definition for an existing map is also possible. Other units
such as points or pixels can also be used in principle, but have not really
been tested as this software has been developed with only millimetres in mind.

The output of this module includes the Proj4 definition of the destination
dataset. This information can be automatically applied if the output is used
with this module later. Other kinds of CRS definitions are not supported.


Installation
------------

 1. `git clone https://github.com/johannessen/geojson-svg && cd geojson-svg`
 2. `dzil build` (requires [Dist::Zilla][])
 3. `cpanm <archive>.tar.gz`

[Dist::Zilla]: https://metacpan.org/release/Dist-Zilla
