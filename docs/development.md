# Development guide

## Requirements

- Git, to obtain and review the source.
- Python 3.10 or later, for the XML builder and headless checks.
- Roblox Studio on Windows or macOS, for live plugin checks.
- Rojo 7.6.1, only if you need a binary `.rbxm` build.
- A Luau compiler and StyLua, for source parsing and formatting checks.

The Python tools use the standard library. The repository includes the
`Packages` source required by the plugin build. Do not replace those packages
without reviewing their versions and notices.

## Obtain the source

Run:

```sh
git clone https://github.com/EurekaRBLX/easyRoad.git
cd easyRoad
```

Private preparation requires repository access. Authenticate with GitHub using
your normal Git credential setup.

## Build an XML model

Run from the repository root:

```sh
python3 tools/build_rbxmx.py
python3 tools/check_distribution.py
```

The builder updates `dist/EasyRoad.rbxmx` and `dist/EasyRoad-OSS.rbxmx` with
the same AGPL build. The distribution check verifies the license mode, bundled
license texts, and both artifacts. The explicit compatibility command is:

```sh
python3 tools/build_rbxmx.py --license oss
```

The compatibility command also updates both files. Commercial mode is not
supported in this repository. To write only one output, supply its path as the
last argument.

On Windows, use `python` in place of `python3` if necessary. The builder uses
stable instance ordering and LF line endings across platforms.

## Build a binary model with Rojo

The repository's `aftman.toml` pins Rojo 7.6.1. With Aftman installed, run:

```sh
aftman install
rojo build default.project.json -o EasyRoad.rbxm
```

The project maps `src`, `Packages`, and `loader.server.lua` into the plugin
model. Rojo reads the source license mode directly. This source defaults to
the AGPL build.

To inspect the license and notices in a Rojo XML build, run:

```sh
rojo build default.project.json -o /tmp/EasyRoad-rojo.rbxmx
python3 tools/check_distribution.py --rojo-xml /tmp/EasyRoad-rojo.rbxmx
```

On Windows, replace `/tmp/EasyRoad-rojo.rbxmx` with a path in your temporary
directory.

Install one built model through **Plugins → Plugins Folder** in Studio.
Restart Studio after replacing the file. Remove duplicate installed builds.

## Validation

List the headless checks:

```sh
python3 tools/preview/validate.py --list
```

Run the standard set:

```sh
python3 tools/preview/validate.py
```

Run the extended roundabout cases:

```sh
python3 tools/preview/validate.py --full
```

These commands can take several minutes. The checks model geometry in Python
and inspect selected source contracts. They do not execute the Luau plugin.
A passing result does not confirm all Studio behavior. See
[tools/preview/README.md](../tools/preview/README.md) for individual scenarios,
rendered output, and coverage limits.

On Windows, fetch the local Luau tools and run the local gate:

```powershell
powershell -ExecutionPolicy Bypass -File tools\fetch-luau.ps1
powershell -ExecutionPolicy Bypass -File tools\ci.ps1
```

The gate parses project source, runs the supported checks, rebuilds the plugin,
and checks for changes in `dist`. Commit rebuilt artifacts with packaged source
changes. The optional hook installer, `tools/install-hooks.ps1`, requires
Windows PowerShell.

For changed Luau files, use the repository's StyLua configuration:

```sh
stylua --verify src/YourChangedFile.lua
stylua --check src/YourChangedFile.lua
```

Replace the example path with each file you changed. Do not reformat unrelated
source.

## Check the plugin in Studio

Use a separate test place. Install the build produced from the source you are
reviewing. Check the behaviors affected by your change. A general smoke check
includes:

1. Open and close the plugin.
2. Complete or reopen Quick Setup.
3. Place a straight road and a curved road.
4. Cancel placement with Escape and the middle mouse button.
5. Change elevation with R and F.
6. Undo and redo placement.
7. Edit a road profile and rebuild a placed road.
8. Connect roads at a junction.
9. Create and edit a roundabout.
10. Inspect curve seams and roundabout connections from low and high angles.
11. Test an imported asset if structure code changed.
12. Back up and restore test presets if settings code changed.

Check Studio Output for errors. Record the build and settings in the pull
request. Inspect collision and surface flicker for geometry changes.

## Review a change

Keep source, artifacts, and documentation consistent. Review license notices
when you add a dependency or copy an algorithm. See
[CONTRIBUTING.md](../CONTRIBUTING.md),
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md), and the
[architecture guide](architecture.md).
