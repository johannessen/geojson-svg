TODO
====

- General cleanup/refactoring is in order.

- The config options are largely undocumented and many combinations are untested.

- The SVG grouping feature is still hard coded to fit the initial special case.

- The SVG parser is hard-coded to the peculiarities of the Illustrator CS6 SVG export.

- Line strings coded as SVG paths are not supported.

- Bézier paths are not supported.

- Compound paths / hole polygons (MultiLineStrings) are not supported.

- Other ways to parse CRS of source dataset are not supported (e. g. as used by QGIS export; see also <https://github.com/Phrogz/svg2geojson>).

- SVG transformations are not supported.

- SVG is pretty complex. Might be better to try and use an existing rendering lib after all and work off of the drawing coordinates produced by that.
