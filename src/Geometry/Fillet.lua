--!strict
-- 2D (ground-plane) circular fillet construction, shared by the junction
-- corner rounding (JunctionBuilder) and the roundabout entry/exit flares
-- (RoundaboutBuilder). Extracted verbatim from JunctionBuilder once the
-- roundabout needed the same math - one proven implementation, not two
-- drifting copies of geometry this subtle.
--
-- The construction follows the shape of CivicArcRoadToolkit (CART)'s
-- JunctionTool.lua chooseArcCenter/sampleArc2D (a genuine tangent circle
-- sampled by angle, not a Bezier approximation), adapted to start from two
-- edge points + the directions their edge lines run in, rather than taking
-- the tangent points as a given input the way CART's helper does.

local Fillet = {}

-- The corner vertex (where the two edge lines would meet if extended) is
-- rejected as "too far to be a real corner" beyond this multiple of the
-- straight chord between the two input points - guards the near-parallel
-- case that would otherwise send the vertex (and everything derived from
-- it) arbitrarily far away. Rejecting just means "no fillet here"; every
-- caller has a safe straight-edge fallback.
local MAX_VERTEX_CHORD_RATIO = 4

-- A circular fillet between two edge lines meeting at `aKerb`/`bKerb` -
-- the callers' own edge points, which the fillet must connect to WITHOUT
-- moving them. `inwardA`/`inwardB` are each edge line's direction pointing
-- toward where the two lines would cross if extended.
--
-- Two stages, both bounded so a bad case just returns nil (caller falls
-- back to its straight edge) rather than producing anything unbounded:
--
-- 1. Find the corner VERTEX: 2D line intersection, ground plane. Rejected
--    if the lines are parallel, if either line only reaches the vertex
--    going BACKWARD (t <= 0 - the edges diverge instead of converging,
--    not a real corner), or if the vertex is unreasonably far away
--    relative to the chord between the two points (near-parallel edges).
-- 2. Derive a true circular fillet of `radiusStuds` tangent to both lines
--    at that vertex - standard "tangent length = radius / tan(half-angle)"
--    trigonometry, capped to never reach past the callers' own
--    aKerb/bKerb points (a corner tighter than the requested radius
--    needs gets a smaller effective radius instead of overshooting).
--
-- Returns (tangent point near aKerb, circle centre, tangent point near
-- bKerb, effective radius) or nil.
function Fillet.Compute(
	aKerb: Vector3,
	inwardA: Vector3,
	bKerb: Vector3,
	inwardB: Vector3,
	radiusStuds: number
): (Vector3?, Vector3?, Vector3?, number?)
	local ax, az = inwardA.X, inwardA.Z
	local bx, bz = inwardB.X, inwardB.Z
	local det = ax * -bz - az * -bx
	if math.abs(det) < 1e-6 then
		return nil, nil, nil, nil
	end
	local dx, dz = bKerb.X - aKerb.X, bKerb.Z - aKerb.Z
	local t1 = (dx * -bz - dz * -bx) / det
	local t2 = (ax * dz - dx * az) / det
	if t1 <= 1e-3 or t2 <= 1e-3 then
		return nil, nil, nil, nil -- edges diverge from these points, not a real corner
	end
	local chordLength = (bKerb - aKerb).Magnitude
	if chordLength < 1e-3 or t1 > chordLength * MAX_VERTEX_CHORD_RATIO or t2 > chordLength * MAX_VERTEX_CHORD_RATIO then
		return nil, nil, nil, nil -- vertex too far away: near-parallel edges
	end
	local vertex = aKerb + inwardA * t1
	local dirA = (-inwardA).Unit -- from vertex back toward aKerb
	local dirB = (-inwardB).Unit
	local cosTheta = math.clamp(dirA:Dot(dirB), -1, 1)
	local theta = math.acos(cosTheta)
	if theta < 1e-3 then
		return nil, nil, nil, nil -- edges nearly collinear here: no real corner to round
	end
	local tangentLength = math.min(radiusStuds / math.tan(theta / 2), t1, t2)
	if tangentLength < 1e-3 then
		return nil, nil, nil, nil
	end
	local effectiveRadius = tangentLength * math.tan(theta / 2)
	local bisector = dirA + dirB
	if bisector.Magnitude < 1e-6 then
		return nil, nil, nil, nil
	end
	bisector = bisector.Unit
	local center = vertex + bisector * (tangentLength / math.cos(theta / 2))
	local p1 = vertex + dirA * tangentLength
	local p2 = vertex + dirB * tangentLength
	return p1, center, p2, effectiveRadius
end

-- Samples `samples` interior points (excluding the endpoints) along the
-- TRUE circular arc from `p1` to `p2` around `center` with the given
-- radius - the short way around, which is always well-defined here since
-- Fillet.Compute's geometry guarantees the angle subtended is less than
-- 180 degrees. Interpolates height linearly between the two endpoints
-- (the fillet is small enough, relative to any grade change across a
-- junction, that this is visually indistinguishable from tracking the
-- true 3D surface).
function Fillet.SampleArc(center: Vector3, radiusStuds: number, p1: Vector3, p2: Vector3, samples: number): { Vector3 }
	local v1 = p1 - center
	local v2 = p2 - center
	local a1 = math.atan2(v1.Z, v1.X)
	local a2 = math.atan2(v2.Z, v2.X)
	local delta = a2 - a1
	while delta > math.pi do
		delta -= 2 * math.pi
	end
	while delta <= -math.pi do
		delta += 2 * math.pi
	end
	local points: { Vector3 } = {}
	for i = 1, samples do
		local t = i / (samples + 1)
		local angle = a1 + delta * t
		local y = p1.Y + (p2.Y - p1.Y) * t
		table.insert(
			points,
			Vector3.new(center.X + math.cos(angle) * radiusStuds, y, center.Z + math.sin(angle) * radiusStuds)
		)
	end
	return points
end

return Fillet
