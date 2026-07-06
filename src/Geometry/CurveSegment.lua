--!strict
-- Curve segment primitives: Line, Quadratic Bezier, Cubic Bezier.
--
-- All segments are 3D (control points carry elevation), but curvature is
-- measured on the ground-plane projection since that is what matters for
-- superelevation and marking layout.
--
-- Every segment carries a precomputed arc-length table so that callers can
-- work in distance-along-curve (s) rather than parameter space (t), which is
-- essential for evenly-spaced cross sections and dash patterns.

export type SegmentKind = "Line" | "Quadratic" | "Cubic"

export type Segment = {
	Kind: SegmentKind,
	P0: Vector3,
	P1: Vector3,
	P2: Vector3?,
	P3: Vector3?,
	-- Arc length lookup: ArcLengths[i] = length from t=0 to t=(i-1)/(n-1)
	ArcLengths: { number },
	Length: number,
}

local ARC_SAMPLES = 64

local CurveSegment = {}

-- Raw parametric evaluation --------------------------------------------------

local function evaluate(segment: Segment, t: number): Vector3
	if segment.Kind == "Line" then
		return segment.P0:Lerp(segment.P1, t)
	elseif segment.Kind == "Quadratic" then
		local p2 = segment.P2 :: Vector3
		local u = 1 - t
		return segment.P0 * (u * u)
			+ segment.P1 * (2 * u * t)
			+ p2 * (t * t)
	else
		local p2 = segment.P2 :: Vector3
		local p3 = segment.P3 :: Vector3
		local u = 1 - t
		return segment.P0 * (u * u * u)
			+ segment.P1 * (3 * u * u * t)
			+ p2 * (3 * u * t * t)
			+ p3 * (t * t * t)
	end
end

local function derivative(segment: Segment, t: number): Vector3
	if segment.Kind == "Line" then
		return segment.P1 - segment.P0
	elseif segment.Kind == "Quadratic" then
		local p2 = segment.P2 :: Vector3
		return (segment.P1 - segment.P0) * (2 * (1 - t))
			+ (p2 - segment.P1) * (2 * t)
	else
		local p2 = segment.P2 :: Vector3
		local p3 = segment.P3 :: Vector3
		local u = 1 - t
		return (segment.P1 - segment.P0) * (3 * u * u)
			+ (p2 - segment.P1) * (6 * u * t)
			+ (p3 - p2) * (3 * t * t)
	end
end

local function secondDerivative(segment: Segment, t: number): Vector3
	if segment.Kind == "Line" then
		return Vector3.zero
	elseif segment.Kind == "Quadratic" then
		local p2 = segment.P2 :: Vector3
		return (p2 - segment.P1 * 2 + segment.P0) * 2
	else
		local p2 = segment.P2 :: Vector3
		local p3 = segment.P3 :: Vector3
		return (p2 - segment.P1 * 2 + segment.P0) * (6 * (1 - t))
			+ (p3 - p2 * 2 + segment.P1) * (6 * t)
	end
end

-- Construction ----------------------------------------------------------------

local function buildArcLengths(segment: Segment)
	local lengths = table.create(ARC_SAMPLES)
	lengths[1] = 0
	local previous = evaluate(segment, 0)
	local total = 0
	for i = 2, ARC_SAMPLES do
		local t = (i - 1) / (ARC_SAMPLES - 1)
		local point = evaluate(segment, t)
		total += (point - previous).Magnitude
		lengths[i] = total
		previous = point
	end
	segment.ArcLengths = lengths
	segment.Length = total
end

function CurveSegment.Line(p0: Vector3, p1: Vector3): Segment
	local segment: Segment = {
		Kind = "Line" :: SegmentKind,
		P0 = p0,
		P1 = p1,
		ArcLengths = {},
		Length = 0,
	}
	buildArcLengths(segment)
	return segment
end

function CurveSegment.Quadratic(p0: Vector3, p1: Vector3, p2: Vector3): Segment
	local segment: Segment = {
		Kind = "Quadratic" :: SegmentKind,
		P0 = p0,
		P1 = p1,
		P2 = p2,
		ArcLengths = {},
		Length = 0,
	}
	buildArcLengths(segment)
	return segment
end

function CurveSegment.Cubic(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3): Segment
	local segment: Segment = {
		Kind = "Cubic" :: SegmentKind,
		P0 = p0,
		P1 = p1,
		P2 = p2,
		P3 = p3,
		ArcLengths = {},
		Length = 0,
	}
	buildArcLengths(segment)
	return segment
end

-- Arc-length parameterization --------------------------------------------------

-- Convert distance-along-segment s (0..Length) to parameter t (0..1)
function CurveSegment.TAtS(segment: Segment, s: number): number
	local lengths = segment.ArcLengths
	local n = #lengths
	if s <= 0 then
		return 0
	elseif s >= segment.Length then
		return 1
	end
	-- Binary search for the bracketing samples
	local lo, hi = 1, n
	while hi - lo > 1 do
		local mid = math.floor((lo + hi) / 2)
		if lengths[mid] <= s then
			lo = mid
		else
			hi = mid
		end
	end
	local span = lengths[hi] - lengths[lo]
	local frac = if span > 1e-9 then (s - lengths[lo]) / span else 0
	return ((lo - 1) + frac) / (n - 1)
end

function CurveSegment.PosAtS(segment: Segment, s: number): Vector3
	return evaluate(segment, CurveSegment.TAtS(segment, s))
end

function CurveSegment.TangentAtS(segment: Segment, s: number): Vector3
	local d = derivative(segment, CurveSegment.TAtS(segment, s))
	if d.Magnitude < 1e-9 then
		-- Degenerate (coincident control points); fall back to chord direction
		local endPoint = if segment.Kind == "Line" then segment.P1
			elseif segment.Kind == "Quadratic" then segment.P2 :: Vector3
			else segment.P3 :: Vector3
		local chord = endPoint - segment.P0
		return if chord.Magnitude > 1e-9 then chord.Unit else Vector3.zAxis
	end
	return d.Unit
end

-- Signed curvature of the ground-plane (XZ) projection at distance s, in
-- 1/studs. Positive = curving left relative to the direction of travel.
function CurveSegment.CurvatureAtS(segment: Segment, s: number): number
	local t = CurveSegment.TAtS(segment, s)
	local d1 = derivative(segment, t)
	local d2 = secondDerivative(segment, t)
	local x1, z1 = d1.X, d1.Z
	local x2, z2 = d2.X, d2.Z
	local speedSq = x1 * x1 + z1 * z1
	if speedSq < 1e-9 then
		return 0
	end
	-- 2D signed curvature in the XZ plane. Note Roblox is left-handed when
	-- viewed from +Y looking down at XZ with -Z forward; the sign convention
	-- here yields positive for left turns.
	local cross = x1 * z2 - z1 * x2
	return -cross / (speedSq ^ 1.5)
end

CurveSegment.Evaluate = evaluate
CurveSegment.Derivative = derivative

return CurveSegment
