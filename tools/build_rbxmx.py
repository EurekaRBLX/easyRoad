#!/usr/bin/env python3
"""Build EasyRoad.rbxmx without Rojo.

Replicates the subset of Rojo's file-to-instance mapping that this project
uses, so the plugin can be built anywhere Python runs:

  * default.project.json trees (including the nested project files inside
    wally packages under Packages/_Index)
  * directories -> Folder
  * directories containing init.lua / init.luau -> ModuleScript
  * X.lua / X.luau -> ModuleScript named X
  * X.server.lua -> Script named X

Output is Roblox's XML model format (.rbxmx), which Studio loads from the
local plugins folder exactly like a binary .rbxm.

Usage: python3 tools/build_rbxmx.py [output-path]
"""

import json
import sys
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parent.parent

_referent = 0


def next_referent() -> str:
	global _referent
	_referent += 1
	return "RBX%d" % _referent


def instance(class_name: str, name: str, source: str | None = None, children=None) -> str:
	parts = ['<Item class="%s" referent="%s">' % (class_name, next_referent())]
	parts.append("<Properties>")
	parts.append('<string name="Name">%s</string>' % escape(name))
	if source is not None:
		parts.append('<ProtectedString name="Source">%s</ProtectedString>' % escape(source))
	parts.append("</Properties>")
	for child in children or []:
		parts.append(child)
	parts.append("</Item>")
	return "".join(parts)


def read_source(path: Path) -> str:
	return path.read_text(encoding="utf-8")


def script_name(filename: str) -> str:
	# Strip only the final .lua/.luau extension: "None.roblox.luau" -> "None.roblox"
	for extension in (".server.lua", ".server.luau", ".lua", ".luau"):
		if filename.endswith(extension):
			return filename[: -len(extension)]
	return filename


def build_file(path: Path) -> str | None:
	name = path.name
	if name.endswith((".server.lua", ".server.luau")):
		return instance("Script", script_name(name), read_source(path))
	if name.endswith((".lua", ".luau")):
		return instance("ModuleScript", script_name(name), read_source(path))
	# Non-script files (LICENSE, *.toml, *.md, project jsons) are not synced
	return None


def build_dir(path: Path, name: str) -> str:
	project_file = path / "default.project.json"
	if project_file.exists():
		project = json.loads(project_file.read_text(encoding="utf-8"))
		return build_project_node(path, project["tree"], name)

	init = None
	for candidate in ("init.lua", "init.luau", "init.server.lua"):
		if (path / candidate).exists():
			init = path / candidate
			break

	children = []
	# Sort by the raw name string rather than by Path. WindowsPath ordering is
	# case-insensitive while PosixPath ordering is case-sensitive, which moved
	# lowercase modules ahead of uppercase folders on Windows and reordered most
	# of the generated instance tree. Python strings have the same case-sensitive
	# ordering on both hosts.
	for entry in sorted(path.iterdir(), key=lambda item: item.name):
		if init is not None and entry == init:
			continue
		if entry.is_dir():
			children.append(build_dir(entry, entry.name))
		else:
			built = build_file(entry)
			if built is not None:
				children.append(built)

	if init is not None:
		class_name = "Script" if init.name.endswith(".server.lua") else "ModuleScript"
		return instance(class_name, name, read_source(init), children)
	return instance("Folder", name, None, children)


def build_project_node(base: Path, node: dict, name: str) -> str:
	node_path = node.get("$path")
	if node_path is not None:
		target = base / node_path
		if target.is_dir():
			return build_dir(target, name)
		built = build_file(target)
		if built is None:
			raise RuntimeError("Cannot map project path: %s" % target)
		# Rename to the tree key name (e.g. loader.server.lua -> "Loader")
		return built.replace(
			'<string name="Name">%s</string>' % escape(script_name(target.name)),
			'<string name="Name">%s</string>' % escape(name),
			1,
		)

	class_name = node.get("$className", "Folder")
	children = []
	for key, child in node.items():
		if not key.startswith("$"):
			children.append(build_project_node(base, child, key))
	return instance(class_name, name, None, children)


def main() -> None:
	output = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "dist" / "EasyRoad.rbxmx"
	project = json.loads((ROOT / "default.project.json").read_text(encoding="utf-8"))
	root = build_project_node(ROOT, project["tree"], project.get("name", "EasyRoad"))
	document = '<roblox version="4">%s</roblox>' % root
	output.parent.mkdir(parents=True, exist_ok=True)
	# Force LF on every host. Path.write_text() uses the platform text default,
	# which turned every embedded source newline into CRLF on native Windows and
	# produced a 40k-line artifact diff against the otherwise-identical Linux
	# build. Roblox accepts LF, and deterministic output is what lets a rebuilt
	# dist file prove it contains only the source changes from this round.
	with output.open("w", encoding="utf-8", newline="\n") as stream:
		stream.write(document)
	print("Wrote %s (%d bytes)" % (output, output.stat().st_size))


if __name__ == "__main__":
	main()
