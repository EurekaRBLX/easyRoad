<a id="readme-top"></a>



<!-- PROJECT SHIELDS -->
<!-- Static badges remain available while this repository is private. -->
[![Contributors][contributors-shield]][contributors-url]
[![Forks][forks-shield]][forks-url]
[![Stargazers][stars-shield]][stars-url]
[![Issues][issues-shield]][issues-url]
[![AGPL-3.0-only License][license-shield]][license-url]
[![Discord][discord-shield]][discord-url]



<!-- PROJECT LOGO -->
<br />
<div align="center">
  <a href="https://github.com/EurekaRBLX/easyRoad">
    <img src="https://avatars.githubusercontent.com/u/340591808?v=4" alt="Eureka organization avatar" width="80" height="80">
  </a>

  <h3 align="center">easyRoad</h3>

  <p align="center">
    Build and edit roads in Roblox Studio.
    <br />
    <a href="https://github.com/EurekaRBLX/easyRoad/tree/main/docs"><strong>Explore the docs »</strong></a>
    <br />
    <br />
    <a href="https://github.com/EurekaRBLX/easyRoad/blob/main/docs/usage.md">View Usage</a>
    &middot;
    <a href="https://github.com/EurekaRBLX/easyRoad/issues/new?template=bug_report.yml">Report Bug</a>
    &middot;
    <a href="https://github.com/EurekaRBLX/easyRoad/issues/new?template=feature_request.yml">Request Feature</a>
    <br />
    <br />
    <strong>Private release preparation · AGPL-3.0-only</strong>
  </p>
</div>



<!-- TABLE OF CONTENTS -->
<details>
  <summary>Table of Contents</summary>
  <ol>
    <li>
      <a href="#about-the-project">About The Project</a>
      <ul>
        <li><a href="#built-with">Built With</a></li>
      </ul>
    </li>
    <li>
      <a href="#getting-started">Getting Started</a>
      <ul>
        <li><a href="#prerequisites">Prerequisites</a></li>
        <li><a href="#installation">Installation</a></li>
      </ul>
    </li>
    <li><a href="#usage">Usage</a></li>
    <li><a href="#roadmap">Roadmap</a></li>
    <li><a href="#contributing">Contributing</a></li>
    <li><a href="#license">License</a></li>
    <li><a href="#contact">Contact</a></li>
    <li><a href="#acknowledgments">Acknowledgments</a></li>
  </ol>
</details>



<!-- ABOUT THE PROJECT -->
## About The Project

| Curved avenue | Divided highway |
| :---: | :---: |
| [![Curved avenue Python geometry preview][product-screenshot]](images/screenshot.png) | [![Divided highway Python geometry preview][highway-render]](images/highway.png) |
| **Parallel roadways** | **Turbo roundabout** |
| [![Parallel roadways Python geometry preview][parallel-render]](images/parallel-roadways.png) | [![Turbo roundabout Python geometry preview][roundabout-render]](images/roundabout.png) |

*Python geometry previews from the project's validation tools. Select an image
to view the full render. See the [rendering and validation limits](tools/preview/README.md).*

easyRoad is a Roblox Studio plugin. Use it to place roads, connect junctions,
and edit road cross-sections.

The plugin includes:

* Straight, Curve, Freeform, and Roundabout placement tools.
* Road widening and narrowing with a fixed center or edge.
* Profiles with lanes, sidewalks, medians, shoulders, cycle lanes, and parking.
* Region presets for the US, UK, EU, Japan, and Australia.
* Automatic or manual road banking, also called superelevation.
* Parallel roads, editable junctions, and connected roundabouts.
* Custom ground road models, viaducts, and tunnel shells.
* Local settings and preset backup through JSON.

Region presets are design defaults for game development. They do not establish
compliance with road design standards.

The repository remains private during open-source preparation. There is no
public release date. Review the [release checklist](docs/release-readiness.md)
before publication.

<p align="right">(<a href="#readme-top">back to top</a>)</p>



### Built With

* [![Luau][Luau]][Luau-url]
* [![Roblox Studio][Roblox-Studio]][Roblox-Studio-url]
* [![React Lua][React-Lua]][React-Lua-url]
* [![Python][Python]][Python-url]
* [![Rojo][Rojo]][Rojo-url]

<p align="right">(<a href="#readme-top">back to top</a>)</p>



<!-- GETTING STARTED -->
## Getting Started

Follow these steps to build and install a local copy of the plugin.

### Prerequisites

* Roblox Studio on a supported Windows or macOS system.
* Repository access during private preparation.
* Git and Python 3.10 or later, if you build from source.

The Python builder uses the standard library. It does not need additional
Python packages.

### Installation

1. Clone the repository.
   ```sh
   git clone https://github.com/EurekaRBLX/easyRoad.git
   cd easyRoad
   ```
2. Build and check the plugin.
   ```sh
   python3 tools/build_rbxmx.py
   python3 tools/check_distribution.py
   ```
3. Open Roblox Studio.
4. Open **Plugins → Plugins Folder**.
5. Copy `dist/EasyRoad.rbxmx` into that folder.
6. Restart Roblox Studio.
7. Click **easyRoad** in the Plugins toolbar.

To install without Python, download [EasyRoad.rbxmx](dist/EasyRoad.rbxmx)
and complete steps 3–7. Install one copy of the plugin.
`EasyRoad-OSS.rbxmx` is a compatibility filename for the same AGPL build.

On Windows, use `python` in place of `python3` if necessary. See the
[development guide](docs/development.md) for Rojo builds and validation.

<p align="right">(<a href="#readme-top">back to top</a>)</p>



<!-- USAGE EXAMPLES -->
## Usage

1. Click **easyRoad** in the Plugins toolbar.
2. Complete Quick Setup for region, terminology, traffic side, and units.
3. Open **Road Tools**.
4. Select a road profile.
5. Select **Straight**.
6. Click the start point in the viewport.
7. Click the end point to place the road.

Use **R** to raise placement elevation. Use **F** to lower it.
Press **Escape** or the **middle mouse button** to cancel placement.
Change these default bindings in **Settings → Keybinds**.

Check [known issues](KNOWN_ISSUES.md) before using a new build in an existing place.

_For more examples, please refer to the [Documentation](docs/usage.md)._

<p align="right">(<a href="#readme-top">back to top</a>)</p>



<!-- ROADMAP -->
## Roadmap

- [x] Prepare AGPL-3.0-only builds and bundled license notices.
- [x] Add public usage, development, and contribution guides.
- [ ] Complete the asset-rights and retained-history review.
- [ ] Add intersection controls, crossings, and lane guidance.
- [ ] Add terrain operations for tunnels.
- [ ] Expand Studio validation and performance benchmarks.

See the [open issues](https://github.com/EurekaRBLX/easyRoad/issues) for proposed
features and known issues. See [ROADMAP.md](ROADMAP.md) for the current plans.
Planned items have no promised delivery date.

<p align="right">(<a href="#readme-top">back to top</a>)</p>



<!-- CONTRIBUTING -->
## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) before you change the project.
During private preparation, contribution access is limited to invited
collaborators.

If you have a suggestion, open a feature request or submit a pull request.
Follow [SECURITY.md](SECURITY.md) to report a vulnerability privately.

1. Obtain repository access during private preparation.
2. Create your feature branch (`git checkout -b feature/road-improvement`).
3. Commit your changes (`git commit -m 'Improve road placement'`).
4. Push to the branch (`git push origin feature/road-improvement`).
5. Open a pull request.

### Top contributors:

<a href="https://github.com/EurekaRBLX/easyRoad/graphs/contributors">
  <img src="https://avatars.githubusercontent.com/u/79436209?v=4" alt="gamesonrblx; view all contributors" width="64" height="64" />
</a>

<p align="right">(<a href="#readme-top">back to top</a>)</p>



<!-- LICENSE -->
## License

Distributed under the **GNU Affero General Public License, version 3 only**
(`AGPL-3.0-only`). See [LICENSE](LICENSE) for the complete terms.

Third-party code and reference material retain their own license terms.
See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Preserve those notices
when you distribute the software. The commercial EULA does not apply to this build.

<p align="right">(<a href="#readme-top">back to top</a>)</p>



<!-- CONTACT -->
## Contact

Eureka — [Eureka Discord](https://discord.gg/srGUZ25jrz)

Use [Issues](https://github.com/EurekaRBLX/easyRoad/issues) for project questions.
Repository links require access during private preparation.

Project Link: [https://github.com/EurekaRBLX/easyRoad](https://github.com/EurekaRBLX/easyRoad)

<p align="right">(<a href="#readme-top">back to top</a>)</p>



<!-- ACKNOWLEDGMENTS -->
## Acknowledgments

* Eureka and the easyRoad contributors.
* [Best-README-Template](https://github.com/othneildrew/Best-README-Template)
  for this README format.
* [GoodSignal](https://github.com/stravant/goodsignal) and the dependency authors
  listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
* The RoadCreator, RoadHelper, and GapFill authors for their reference work.
* ASD-STE-100 as the technical writing reference. See the
  [writing guide](docs/writing-guide.md).

<p align="right">(<a href="#readme-top">back to top</a>)</p>



<!-- MARKDOWN LINKS & IMAGES -->
<!-- https://www.markdownguide.org/basic-syntax/#reference-style-links -->
[contributors-shield]: https://img.shields.io/badge/Contributors-Eureka-2ea44f?style=for-the-badge
[contributors-url]: https://github.com/EurekaRBLX/easyRoad/graphs/contributors
[forks-shield]: https://img.shields.io/badge/Forks-Private-555?style=for-the-badge
[forks-url]: https://github.com/EurekaRBLX/easyRoad/network/members
[stars-shield]: https://img.shields.io/badge/Stargazers-Private-555?style=for-the-badge
[stars-url]: https://github.com/EurekaRBLX/easyRoad/stargazers
[issues-shield]: https://img.shields.io/badge/Issues-GitHub-24292f?style=for-the-badge
[issues-url]: https://github.com/EurekaRBLX/easyRoad/issues
[license-shield]: https://img.shields.io/badge/License-AGPL--3.0--only-blue?style=for-the-badge
[license-url]: https://github.com/EurekaRBLX/easyRoad/blob/main/LICENSE
[discord-shield]: https://img.shields.io/badge/Discord-Eureka-5865F2?style=for-the-badge&logo=discord&logoColor=white
[discord-url]: https://discord.gg/srGUZ25jrz
[product-screenshot]: images/screenshot.png
[highway-render]: images/highway.png
[parallel-render]: images/parallel-roadways.png
[roundabout-render]: images/roundabout.png
[Luau]: https://img.shields.io/badge/Luau-00A2FF?style=for-the-badge&logo=luau&logoColor=white
[Luau-url]: https://luau.org/
[Roblox-Studio]: https://img.shields.io/badge/Roblox_Studio-006FFF?style=for-the-badge&logo=robloxstudio&logoColor=white
[Roblox-Studio-url]: https://create.roblox.com/
[React-Lua]: https://img.shields.io/badge/React_Lua-20232A?style=for-the-badge&logo=react&logoColor=61DAFB
[React-Lua-url]: https://github.com/jsdotlua/react-lua
[Python]: https://img.shields.io/badge/Python-3776AB?style=for-the-badge&logo=python&logoColor=white
[Python-url]: https://www.python.org/
[Rojo]: https://img.shields.io/badge/Rojo-E13835?style=for-the-badge
[Rojo-url]: https://rojo.space/
