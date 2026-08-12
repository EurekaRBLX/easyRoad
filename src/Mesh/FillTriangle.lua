--!strict
-- Fills a triangular gap with 1-2 Wedge parts, exactly - adapted from
-- stravant/roblox-gapfill's fillTriangle.lua (MIT License, Mark Langen /
-- @stravant, https://github.com/stravant/roblox-gapfill), which is a real
-- Studio plugin for closing gaps between arbitrary geometry the same way.
--
-- Kept: the edge-selection logic (finds the edge whose opposite vertex
-- projects closest to its own midpoint, splitting there to avoid thin
-- sliver wedges) and the exact CFrame.fromMatrix + Wedge construction,
-- which is the tricky, easy-to-get-subtly-wrong part.
--
-- Simplified from the original: that tool fills gaps between arbitrary,
-- not-necessarily-related pieces of geometry, so it has to *guess* which
-- side of the triangle's plane the fill material should extrude into
-- (a `desiredSurfaceNormal` / reference-part-position heuristic). Every
-- triangle we fill is a gap in the road surface at a curve joint, where we
-- already know exactly which way is down (the curve's own frame at that
-- point) - so that heuristic is replaced with a direct `downVector`
-- argument instead of guessed.
local TOP_VERTEX_COUNT_ATTRIBUTE = "RW_FillTriangleTopVertexCount"
local TOP_VERTEX_ATTRIBUTES = {
	"RW_FillTriangleTopVertex1",
	"RW_FillTriangleTopVertex2",
	"RW_FillTriangleTopVertex3",
}
local DEPTH_ATTRIBUTE = "RW_FillTriangleDepthStuds"
local DOWN_VECTOR_ATTRIBUTE = "RW_FillTriangleDownVector"

-- A Wedge Part's Size/CFrame describe its bounding box, not the triangular
-- source surface passed to this helper. Keep that exact world-space surface and
-- extrusion contract on every generated wedge so later ownership/clipping
-- passes can reason about the geometry without reconstructing it approximately.
local function stampSourceGeometry(
	part: Part,
	v1: Vector3,
	v2: Vector3,
	v3: Vector3,
	depth: number,
	downVector: Vector3
)
	part:SetAttribute(TOP_VERTEX_COUNT_ATTRIBUTE, 3)
	part:SetAttribute(TOP_VERTEX_ATTRIBUTES[1], v1)
	part:SetAttribute(TOP_VERTEX_ATTRIBUTES[2], v2)
	part:SetAttribute(TOP_VERTEX_ATTRIBUTES[3], v3)
	part:SetAttribute(DEPTH_ATTRIBUTE, depth)
	part:SetAttribute(DOWN_VECTOR_ATTRIBUTE, downVector)
end

local function fillTriangle(
	a: Vector3,
	b: Vector3,
	c: Vector3,
	depth: number,
	downVector: Vector3,
	makePart: () -> Part,
	parent: Instance
)
	local ab, bc, ca = b - a, c - b, a - c
	local abm, bcm, cam = ab.Magnitude, bc.Magnitude, ca.Magnitude
	if abm < 1e-4 or bcm < 1e-4 or cam < 1e-4 then
		return
	end

	local e1 = ca:Dot(ab) / (abm * abm)
	local e2 = ab:Dot(bc) / (bcm * bcm)
	local e3 = bc:Dot(ca) / (cam * cam)
	local edg1 = math.abs(0.5 + e1)
	local edg2 = math.abs(0.5 + e2)
	local edg3 = math.abs(0.5 + e3)
	-- Find the edge onto which the opposite vertex's projection falls
	-- closest to the midpoint - that's the edge to split on, avoiding
	-- slivers with one very small dimension relative to the other.
	if math.abs(e1) > 0.0001 and math.abs(e2) > 0.0001 and math.abs(e3) > 0.0001 then
		if edg1 < edg2 then
			if edg1 < edg3 then
				-- min is edg1: nothing to change
			else
				-- min is edg3: rotate verts twice
				a, b, c = c, a, b
				ab, bc, ca = ca, ab, bc
				abm = cam
			end
		else
			if edg2 < edg3 then
				-- min is edg2: rotate verts once
				a, b, c = b, c, a
				ab, bc, ca = bc, ca, ab
				abm = bcm
			else
				-- min is edg3: rotate verts twice
				a, b, c = c, a, b
				ab, bc, ca = ca, ab, bc
				abm = cam
			end
		end
	else
		if math.abs(e1) <= 0.0001 then
			-- nothing to do
		elseif math.abs(e2) <= 0.0001 then
			a, b, c = b, c, a
			ab, bc, ca = bc, ca, ab
			abm = bcm
		else
			a, b, c = c, a, b
			ab, bc, ca = ca, ab, bc
			abm = cam
		end
	end

	local len1 = -ca:Dot(ab) / abm
	local len2 = abm - len1
	local width = (ca + ab.Unit * len1).Magnitude
	if width < 0.02 then
		return
	end

	local normal = ab:Cross(bc).Unit
	local maincf = CFrame.fromMatrix(a, normal:Cross(-ab.Unit), normal, -ab.Unit)

	-- We always know which way is down here (unlike the original tool's
	-- ambiguous general case) - extrude the depth that way.
	local flip = if normal:Dot(downVector) > 0 then 1 else -1
	local split = a + ab.Unit * len1

	if len1 > 0.001 then
		local part1 = makePart()
		part1.Shape = Enum.PartType.Wedge
		part1.Size = Vector3.new(depth, width, len1)
		part1.CFrame = maincf
			* CFrame.Angles(math.pi, 0, math.pi / 2)
			* CFrame.new(flip * (-depth / 2), width / 2, len1 / 2)
		stampSourceGeometry(part1, a, split, c, depth, downVector)
		part1.Parent = parent
	end
	if len2 > 0.001 then
		local part2 = makePart()
		part2.Shape = Enum.PartType.Wedge
		part2.Size = Vector3.new(depth, width, len2)
		part2.CFrame = maincf
			* CFrame.Angles(math.pi, math.pi, -math.pi / 2)
			* CFrame.new(flip * (depth / 2), width / 2, -len1 - len2 / 2)
		stampSourceGeometry(part2, split, b, c, depth, downVector)
		part2.Parent = parent
	end
end

return fillTriangle
