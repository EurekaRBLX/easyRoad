# Existing solutions survey: intersections & roundabouts

Answering "are there open-source solutions we can make use of instead of
hand-rolling the buggy corner geometry." Short version: **no drop-in
library generates arbitrary-N-way road-intersection *mesh*** (they all
either template it, or output an abstract network, not pavement). But there
IS a robust *primitive* we can use — 2D polygon boolean/union — that
removes the entire class of faults we keep hitting. Findings below, most
useful first.

## The core insight

Every fault we've reported live (5-way spikes, through-pair notches,
mouth-crossing bands, self-intersecting sidewalk) comes from ONE thing:
our pad builder decides *topology* (which approach edges pair, in what
order, convex or reflex) and *rounds corners* in the same pass. Any
approach that **first gets a provably-valid pad outline, then rounds it**
eliminates the whole class, because rounding a known-simple polygon is
well-conditioned. That's what the options below give us.

## Option A — Pure-Lua 2D polygon boolean (RECOMMENDED to prototype)

Treat each approach's footprint (its trimmed end quad, extended to the
junction centre) as a 2D polygon. **Union all of them** → the pad outline.
The union of simple polygons is always a valid simple polygon: no pairing
decision, no self-intersection possible, any leg count, any angles. Then
triangulate the outline (ear-clipping) for asphalt, and round the reflex/
convex vertices with our existing `Fillet.Compute` — now safe, because the
outline is guaranteed simple.

- **Libraries (pure Lua, Luau-portable, no FFI/DLL):**
  - `Bigfoot71/2d-polygon-boolean-lua` — 460 lines, Greiner-Hormann, zero
    host deps (only needs `unpack`→`table.unpack`). Cloned & verified
    clean. Weakness: Greiner-Hormann is shaky on *degenerate* input
    (shared vertices / collinear overlapping edges — exactly what road
    quads meeting at a shared centre produce), so inputs need a tiny jitter
    or a more robust variant.
  - `PolyBool` (devforum "PolyBool Lua Library") — port of velipso/polybool,
    uses the more degenerate-robust sweep approach. Better base if we hit
    Greiner-Hormann's edge cases.
- **Pros:** synchronous, pure Lua, no watertight-solid requirement, keeps
  our per-Part editable output, MIT-ish licensed, small. Separates
  "valid outline" from "rounded corners" cleanly.
- **Cons:** need to pick/harden a robust boolean impl; triangulation +
  rounding is new code (but on clean input). Roundabout still separate.
- **Roundabout fit:** ring = an annulus polygon (outer circle minus inner
  circle); each feeder mouth = subtract the spoke's footprint from the
  sidewalk band, union its asphalt. Same primitive does both.

## Option B — Roblox engine CSG (`GeometryService:UnionAsync`)

Build each approach/ring as a *watertight solid*, `UnionAsync` them; the
engine computes the boolean pad. Roundabout = ring solid `SubtractAsync`
island. Robust boolean geometry, zero hand-rolled corner math, any
topology.

- **Pros:** the engine does the hard part; genuinely robust; handles
  junctions AND roundabouts with the same call.
- **Cons:** async (100s of ms per op — fine for a click-to-build step, not
  live preview); requires watertight/manifold input (our thin-strip build
  isn't — we'd build purpose-made solid prisms); output is a Union/MeshPart
  (loses our per-component Parts → per-lane markings/editing get harder,
  must be overlaid separately); corners come out **sharp** (union of boxes)
  — rounded curb returns would need pre-rounded input solids, back to
  fillet math. Confirmed available in Studio plugins & at runtime (2026).

## Option C — RoadHelper fixed T/X template (already vendored)

`reference/roadhelper/RoadIntersectionGenerator.lua`. Robust *because* it's
a fixed 2-axis box (analytic corner points, space-bounded fillet), but only
T and X, ±10° angle. Good for a "snap to a clean T/X" mode; not a general
N-way answer. **No roundabout in RoadHelper at all.**

## Option D — SUMO `NBNodeShapeComputer` (reference algorithm only)

Eclipse SUMO's `netconvert` computes arbitrary-N-way junction *boundary*
shapes from road edges — the most battle-tested version of this. But it's
C++/EPL (port the algorithm, not the code), and conceptually it's the SAME
approach we already have (order approaches by angle, intersect adjacent
facing edges, special-case the rest). Porting it = a more edge-case-hardened
version of our current node model, not a different paradigm. Worth mining
for its special-case handling if we stay with the current approach.

## What does NOT exist

- No open-source library that **generates roundabout pavement mesh**
  procedurally. SUMO models a roundabout as one-way edges + junctions (no
  mesh); RoadHelper has none; OpenDRIVE/RoadRunner author them by hand.
  Our roundabout stays bespoke regardless — Option A or B are the only ways
  to make it more robust.

## Recommendation

Prototype **Option A** as a standalone `src/Geometry/PolygonBoolean.lua`
primitive (harden a Greiner-Hormann/PolyBool union for degenerate road
input) + a small ear-clip triangulator. It's the smallest change that kills
the whole fault class, stays synchronous and pure-Lua, keeps editable
output, and serves junctions and roundabouts with one primitive. Building
the *primitive* is non-colliding groundwork (new module); wiring it into
`JunctionBuilder`/`RoundaboutBuilder` is a later, coordinated step (those
files are being actively worked). Option B is the fallback if per-vertex
rounding on the union proves fiddly and we're willing to accept async +
sharp corners + non-editable unions.
