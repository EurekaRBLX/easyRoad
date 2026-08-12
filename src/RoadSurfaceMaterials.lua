--!strict
-- Curated finishes for generated road surfaces. Persist the material name,
-- not Enum.Material itself, so custom road profiles stay JSON-safe.

export type MaterialName =
	"Asphalt"
	| "Concrete"
	| "Brick"
	| "Cobblestone"
	| "Slate"
	| "Limestone"
	| "Granite"
	| "Marble"
	| "Pavement"
	| "Pebble"
	| "Grass"
	| "Ground"
	| "Sand"

export type MaterialEntry = {
	Id: MaterialName,
	Text: string,
	Material: Enum.Material,
}

local entries: { MaterialEntry } = {
	{ Id = "Asphalt", Text = "Asphalt", Material = Enum.Material.Asphalt },
	{ Id = "Concrete", Text = "Concrete", Material = Enum.Material.Concrete },
	{ Id = "Brick", Text = "Brick", Material = Enum.Material.Brick },
	{ Id = "Cobblestone", Text = "Cobblestone", Material = Enum.Material.Cobblestone },
	{ Id = "Slate", Text = "Slate", Material = Enum.Material.Slate },
	{ Id = "Limestone", Text = "Limestone", Material = Enum.Material.Limestone },
	{ Id = "Granite", Text = "Granite", Material = Enum.Material.Granite },
	{ Id = "Marble", Text = "Marble", Material = Enum.Material.Marble },
	{ Id = "Pavement", Text = "Paving stones", Material = Enum.Material.Pavement },
	{ Id = "Pebble", Text = "Pebble", Material = Enum.Material.Pebble },
	{ Id = "Grass", Text = "Grass", Material = Enum.Material.Grass },
	{ Id = "Ground", Text = "Ground", Material = Enum.Material.Ground },
	{ Id = "Sand", Text = "Sand", Material = Enum.Material.Sand },
}

local byId: { [string]: MaterialEntry } = {}
for _, entry in entries do
	byId[entry.Id] = entry
end

local RoadSurfaceMaterials = {
	Entries = entries,
}

function RoadSurfaceMaterials.Sanitize(value: any): MaterialName?
	if typeof(value) == "string" and byId[value] then
		return value :: MaterialName
	end
	return nil
end

function RoadSurfaceMaterials.Resolve(value: string?): Enum.Material?
	local name = RoadSurfaceMaterials.Sanitize(value)
	return if name then byId[name].Material else nil
end

return RoadSurfaceMaterials
