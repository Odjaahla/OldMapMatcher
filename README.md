# Old Map Matcher

A macOS app for georeferencing historical maps of southern Stockholm (Brännkyrka/Huddinge, around
59.285 N, 17.955 E): you match features between an old map and a modern one, and the app fits a
transform so you can see where old roads, farms and fields lie in today's city.

## Getting started

```sh
brew install ghostscript          # only needed for extracting PDF scans
scripts/extract_maps.py           # maps/*.pdf (page 1) and screenshots -> images/
scripts/build_app.sh --open       # builds build/OldMapMatcher.app (no Xcode needed)
swift test                        # core math tests
```

On first launch choose this folder as the project folder (File → Open Project Folder…).

## Using it

- Click a feature on the old map (left), then the same feature on the modern map (right), or the
  other way round. Each pair becomes a numbered control point; drag a marker to adjust it.
- After a few points the app predicts where the second click belongs (purple crosshair) and pans
  there. Press ↩ to accept the prediction as-is.
- Hovering over either map shows the corresponding spot on the other (teal crosshair).
- **Model**: *Similarity* (rotation and scale), *Affine* (adds uneven paper shrinkage), or
  *Thin-plate spline* (adds smooth local bending, with smoothing picked automatically by cross-validation).
- **Residuals** draws arrows from each clicked point to where the model places it. If neighbouring
  arrows point the same way, the old map is warped and the spline is worth using. If they point in
  random directions, the errors are just noise; a stiffer model is better and a spline would overfit.
- **Left-out error** is each point's error when the fit is made without it. This is the honest
  accuracy estimate. Values in red are much larger than the rest and probably come from a misidentified
  feature; untick *Use* to exclude a point without deleting it.
- **Overlay** draws the warped old map over the modern map.

### Explore mode (⌘2)

Switch between **Match** (⌘1) and **Explore** (⌘2) at any time; the modern map keeps its position.

- Every map with at least 2 points can be shown as a layer: tick it in the sidebar and set its
  opacity. Drag rows to reorder them (the top row is drawn on top).
- **Option-drag** from a feature on the selected map's layer to where that feature is today. This adds
  a control point, and the fit and overlay update straight away. Use it for roads, buildings and
  boundaries that the overlay shows have survived.
- **Hold Space** to hide all layers so you can compare with the modern map (release to bring them back).
- The points table and statistics stay visible, so you can see whether each new point improved the fit.

Control points are saved automatically to `gcps/<image>.json`. These files are the valuable output,
so commit them.

## Layout

- `Sources/MapMatchCore`: SWEREF 99 TM projection (checked against PROJ), similarity, affine and
  thin-plate spline fitting, and leave-one-out diagnostics. Fitting is done in metres.
- `Sources/OldMapMatcher`: the SwiftUI/AppKit/MapKit app.
- `maps/` (original scans) and `images/` (extracted pages) are not committed.
