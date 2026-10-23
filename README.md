<a id="readme-top"></a>

# easyRoad

Build and edit roads in Roblox Studio.

**Status:** This repository is private while Eureka prepares an open-source
release under **AGPL-3.0-only**. There is no release date.

[User guide](docs/usage.md) · [Development guide](docs/development.md) ·
[Known issues](KNOWN_ISSUES.md) · [Contribute](CONTRIBUTING.md)

## Contents

- [About the project](#about-the-project)
- [Built with](#built-with)
- [Getting started](#getting-started)
- [Usage](#usage)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [License](#license)
- [Contact](#contact)
- [Acknowledgments](#acknowledgments)

## About the project

easyRoad is a Roblox Studio plugin. Use it to place straight roads and curves,
connect intersections, and edit road cross-sections.

The plugin includes:

- Straight, Curve, Freeform, and Roundabout placement tools.
- Road widening and narrowing with a fixed center or edge.
- Road profiles with lanes, sidewalks, medians, shoulders, cycle lanes, and parking.
- Region presets for the US, UK, EU, Japan, and Australia.
- Automatic or manual road banking, also called superelevation.
- Parallel roads with separate travel directions.
- Editable junctions and connected roundabouts.
- Custom ground road models, viaducts, and tunnel shells.
- Material and color settings for generated road surfaces.
- Local settings and preset backup through JSON.

The plugin generates Roblox geometry. Region presets are design defaults for
game development. They do not establish compliance with road design standards.

## Built with

- [Luau](https://luau.org/) and [Roblox Studio](https://create.roblox.com/).
- [React Lua](https://github.com/jsdotlua/react-lua) for the interface.
- [GoodSignal](https://github.com/stravant/goodsignal) for signals.
- Python for the XML model builder and geometry checks.
- [Rojo](https://rojo.space/) as an alternative model builder.

## Getting started

### Prerequisites

To use the plugin, install Roblox Studio on a supported Windows or macOS system.
You also need repository access during private preparation.

To build the XML model, install Python 3.10 or later. The Python builder uses
the standard library. It does not need additional Python packages.

### Installation

1. Download [EasyRoad.rbxmx](dist/EasyRoad.rbxmx) from this repository.
2. Open Roblox Studio.
3. Open **Plugins → Plugins Folder**.
4. Copy `EasyRoad.rbxmx` into that folder.
5. Restart Roblox Studio.
6. Click **easyRoad** in the Plugins toolbar.

Install one copy of the plugin. `EasyRoad-OSS.rbxmx` is a compatibility filename
for the same AGPL build.

To build from source, run this command from the repository root:

```sh
python3 tools/build_rbxmx.py
python3 tools/check_distribution.py
```

The builder updates both filenames in `dist` with the same AGPL build.
On Windows, use `python` in place of `python3` if that is the installed command. See the
[development guide](docs/development.md) for Rojo builds and validation.

## Usage

1. Click **easyRoad** in the Plugins toolbar.
2. Complete Quick Setup for region, terminology, traffic side, and units.
3. Open **Road Tools**.
4. Select a road profile.
5. Select **Straight**.
6. Click the start point in the viewport.
7. Click the end point to place the road.

Use **R** to raise placement elevation. Use **F** to lower it. Press **Escape**
or the **middle mouse button** to cancel placement. These are the default
bindings; change them in **Settings → Keybinds**.

See the [user guide](docs/usage.md) for curves, connections, custom roads,
structures, editing, and backups. Check [known issues](KNOWN_ISSUES.md) before
using a new build in an existing place.

## Roadmap

Planned work includes intersection control markings, crossings, signals,
terrain operations for tunnels, and further performance work. See
[ROADMAP.md](ROADMAP.md). Planned items have no promised delivery date.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) before you change the project. During
private preparation, contribution access is limited to invited collaborators.

Use [Issues](https://github.com/EurekaRBLX/easyRoad/issues) for bugs and feature
requests. Use the private reporting procedure in [SECURITY.md](SECURITY.md)
for security vulnerabilities.

## License

The project is prepared for release under the
**GNU Affero General Public License, version 3 only** (`AGPL-3.0-only`).
See [LICENSE](LICENSE) for the complete terms.

Third-party code and reference material retain their own license terms. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Preserve those notices when
you distribute the software. The commercial EULA does not apply to this build.

## Contact

Use [Issues](https://github.com/EurekaRBLX/easyRoad/issues) for project questions.
Eureka also maintains the [Eureka Discord](https://discord.gg/srGUZ25jrz).

Project: [EurekaRBLX/easyRoad](https://github.com/EurekaRBLX/easyRoad).
Repository links require access during private preparation.

## Acknowledgments

- Eureka and the easyRoad contributors.
- The authors of the dependencies and reference projects listed in
  [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- [Best-README-Template](https://github.com/othneildrew/Best-README-Template)
  for the README structure.
- ASD-STE-100 as the writing reference for clear technical instructions. See
  the [writing guide](docs/writing-guide.md) for the project's review rules.

[Back to top](#readme-top)
