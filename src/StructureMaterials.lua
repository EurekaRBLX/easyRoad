--!strict
-- Curated Roblox materials for procedural viaduct/tunnel finishes. Keeping
-- the persisted name and Enum mapping in one module prevents Settings,
-- RoadInstance migration, StructureBuilder, and both UIs from drifting.

export type MaterialName =
	"Concrete"
	| "Asphalt"
	| "Brick"
	| "Cobblestone"
	| "Slate"
	| "Limestone"
	| "Granite"
	| "Marble"
	| "Rock"
	| "Metal"
	| "CorrodedMetal"
	| "DiamondPlate"

export type MaterialEntry = {
	Id: MaterialName,
	Text: string,
	Material: Enum.Material,
}

local entries: { MaterialEntry } = {
	{ Id = "Concrete", Text = "Concrete", Material = Enum.Material.Concrete },
	{ Id = "Asphalt", Text = "Asphalt", Material = Enum.Material.Asphalt },
	{ Id = "Brick", Text = "Brick", Material = Enum.Material.Brick },
	{ Id = "Cobblestone", Text = "Cobblestone", Material = Enum.Material.Cobblestone },
	{ Id = "Slate", Text = "Slate", Material = Enum.Material.Slate },
	{ Id = "Limestone", Text = "Limestone", Material = Enum.Material.Limestone },
	{ Id = "Granite", Text = "Granite", Material = Enum.Material.Granite },
	{ Id = "Marble", Text = "Marble", Material = Enum.Material.Marble },
	{ Id = "Rock", Text = "Rock", Material = Enum.Material.Rock },
	{ Id = "Metal", Text = "Metal", Material = Enum.Material.Metal },
	{ Id = "CorrodedMetal", Text = "Corroded metal", Material = Enum.Material.CorrodedMetal },
	{ Id = "DiamondPlate", Text = "Diamond plate", Material = Enum.Material.DiamondPlate },
}

local byId: { [string]: MaterialEntry } = {}
for _, entry in entries do
	byId[entry.Id] = entry
end

local StructureMaterials = {
	Entries = entries,
}

function StructureMaterials.Sanitize(value: any): MaterialName
	if typeof(value) == "string" and byId[value] then
		return value :: MaterialName
	end
	return "Concrete"
end

function StructureMaterials.Resolve(value: string?): Enum.Material
	return byId[StructureMaterials.Sanitize(value)].Material
end

return StructureMaterials
