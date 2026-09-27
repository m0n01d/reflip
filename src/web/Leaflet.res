// Typed externals for the Leaflet calls the Map view uses
// (docs/spec-haul-map.md "The code"). Only the calls the spec names: map,
// setView, fitBounds, invalidateSize and remove for the map; tileLayer,
// circleMarker, layerGroup, addTo, setStyle and clearLayers for the
// layers; and on for a click. No %raw, no Obj.magic, no untyped @val
// shortcut around the type system.
//
// leaflet 1.9.4's ESM build (node_modules/leaflet/dist/leaflet-src.esm.js)
// exports these as named bindings (`createMap as map`, `tileLayer`,
// `circleMarker`, `layerGroup`, ...), so a plain @module import works the
// same way idb-keyval's bindings already do in WebApi.res.

type map
type tileLayer
type circleMarker
type layerGroup

// The object Leaflet hands a click handler: only the one field the view
// reads. `{"lat": float, "lng": float}` is ReScript's structural JS object
// type, not an escape hatch — it types the shape, it does not bypass it.
type latLng = {"lat": float, "lng": float}
type mouseEvent = {"latlng": latLng}

type tileLayerOptions = {attribution: string}

type circleMarkerOptions = {
  radius: float,
  color: string,
  fillColor: string,
  fillOpacity: float,
  weight: float,
  fill: bool,
}

type fitBoundsOptions = {padding: (float, float)}

@module("leaflet") external map: string => map = "map"
@send external setView: (map, (float, float), int) => unit = "setView"
@send external fitBounds: (map, array<(float, float)>, fitBoundsOptions) => unit = "fitBounds"
@send external invalidateSize: map => unit = "invalidateSize"
@send external remove: map => unit = "remove"
@send external onMapClick: (map, string, mouseEvent => unit) => unit = "on"

@module("leaflet") external tileLayer: (string, tileLayerOptions) => tileLayer = "tileLayer"
@send external addTileLayerTo: (tileLayer, map) => unit = "addTo"

@module("leaflet")
external circleMarker: ((float, float), circleMarkerOptions) => circleMarker = "circleMarker"
@send external setMarkerStyle: (circleMarker, circleMarkerOptions) => unit = "setStyle"
@send external addMarkerTo: (circleMarker, layerGroup) => unit = "addTo"
@send external onMarkerClick: (circleMarker, string, mouseEvent => unit) => unit = "on"

@module("leaflet") external layerGroup: unit => layerGroup = "layerGroup"
@send external addGroupTo: (layerGroup, map) => unit = "addTo"
@send external clearLayers: layerGroup => unit = "clearLayers"
