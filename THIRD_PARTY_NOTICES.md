# Third-party notices

The easyRoad source in this repository uses `AGPL-3.0-only`.
Third-party code keeps the license and copyright notices below.
The root [LICENSE](LICENSE) does not replace those notices.

## Plugin dependencies

The repository includes these packages under `Packages/`.
Keep their license files and source headers when you distribute them.

| Package | License | Full notice |
| --- | --- | --- |
| `jsdotlua/boolean@1.2.7` | MIT | [License](Packages/_Index/jsdotlua_boolean@1.2.7/boolean/LICENSE) |
| `jsdotlua/collections@1.2.7` | MIT | [License](Packages/_Index/jsdotlua_collections@1.2.7/collections/LICENSE) |
| `jsdotlua/console@1.2.7` | MIT | [License](Packages/_Index/jsdotlua_console@1.2.7/console/LICENSE) |
| `jsdotlua/es7-types@1.2.7` | MIT | [License](Packages/_Index/jsdotlua_es7-types@1.2.7/es7-types/LICENSE) |
| `jsdotlua/instance-of@1.2.7` | MIT | [License](Packages/_Index/jsdotlua_instance-of@1.2.7/instance-of/LICENSE) |
| `jsdotlua/luau-polyfill@1.2.7` | MIT | [License](Packages/_Index/jsdotlua_luau-polyfill@1.2.7/luau-polyfill/LICENSE) |
| `jsdotlua/math@1.2.7` | MIT | [License](Packages/_Index/jsdotlua_math@1.2.7/math/LICENSE) |
| `jsdotlua/number@1.2.7` | MIT | [License](Packages/_Index/jsdotlua_number@1.2.7/number/LICENSE) |
| `jsdotlua/promise@3.5.2` | MIT | [License](Packages/_Index/jsdotlua_promise@3.5.2/promise/LICENSE) |
| `jsdotlua/react-reconciler@17.2.1` | MIT | [License](Packages/_Index/jsdotlua_react-reconciler@17.2.1/react-reconciler/LICENSE) |
| `jsdotlua/react-roblox@17.2.1` | MIT | [License](Packages/_Index/jsdotlua_react-roblox@17.2.1/react-roblox/LICENSE) |
| `jsdotlua/react@17.2.1` | MIT | [License](Packages/_Index/jsdotlua_react@17.2.1/react/LICENSE) |
| `jsdotlua/scheduler@17.2.1` | MIT | [License](Packages/_Index/jsdotlua_scheduler@17.2.1/scheduler/LICENSE) |
| `jsdotlua/shared@17.2.1` | MIT | [License](Packages/_Index/jsdotlua_shared@17.2.1/shared/LICENSE) |
| `jsdotlua/string@1.2.7` | MIT | [License](Packages/_Index/jsdotlua_string@1.2.7/string/LICENSE) |
| `jsdotlua/symbol-luau@1.0.1` | MIT | [License](Packages/_Index/jsdotlua_symbol-luau@1.0.1/symbol-luau/LICENSE.txt) |
| `jsdotlua/timers@1.2.7` | MIT | [License](Packages/_Index/jsdotlua_timers@1.2.7/timers/LICENSE) |
| `stravant/goodsignal@0.3.1` | MIT | [License](Packages/_Index/stravant_goodsignal@0.3.1/goodsignal/LICENSE) |

## Adapted code and reference material

| Project | Use in this repository | License and notice |
| --- | --- | --- |
| [RoadCreator](https://github.com/MarcusElg/roadcreator) | Reference files in `reference/roadcreator/`; translated corner algorithm in `src/Geometry/BezierCorner.lua`. Reference commit: `ba42880192d366febb92da87fd09ba985e923b68`. | MIT. Copyright (c) 2019 MCrafterzz. [Full notice](reference/roadcreator/LICENSE-roadcreator.md). |
| [RoadHelper](https://github.com/stravant/roblox-roadhelper) | Reference files in `reference/roadhelper/`. These files are outside the plugin build. Reference commit: `bfa5c5dde79a2927bb758b17abbc6f878af508fb`. | MIT. Copyright 2025 Mark Langen (@stravant). [Full notice](reference/roadhelper/LICENSE-roadhelper). |
| [GapFill](https://github.com/stravant/roblox-gapfill) | Adapted triangle fill algorithm in `src/Mesh/FillTriangle.lua`. | MIT. Copyright 2023 Mark Langen (@stravant). [Full notice](legal/LICENSE-GapFill.txt). Upstream license blob: `f46d2c96f13d6cc3c370cd3fda520d8372ffea98`. |

The Roblox model files built by Python and Rojo include
[`src/LicenseNotices.lua`](src/LicenseNotices.lua).
That module contains the full AGPL text and all notices listed above.
Update the module when a license file or dependency changes.

## Other resources

The README structure follows
[Best-README-Template](https://github.com/othneildrew/Best-README-Template).
That template is released under the Unlicense.

The repository uses Roblox Studio and Roblox-hosted image assets.
Roblox Studio is supplied separately and is subject to Roblox terms.
An asset identifier does not establish permission to redistribute the asset.
Before a public release, verify the rights and availability of the hosted icons
and the five model files in `hardware/`.

## Source location

The Eureka repository is [EurekaRBLX/easyRoad](https://github.com/EurekaRBLX/easyRoad).
It is private while the maintainers prepare the public release.
The Wally manifest retains the existing `gamesonrblx/easyroad` package scope.
Moving the repository does not establish ownership of a new Wally registry scope.
