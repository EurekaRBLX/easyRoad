# Contributing to easyRoad

This repository is private while Eureka prepares an AGPL-3.0-only release.
Only invited collaborators can contribute during this stage.

## Report a problem

Search [Issues](https://github.com/EurekaRBLX/easyRoad/issues) and
[known issues](KNOWN_ISSUES.md) before you create an issue. Include:

- The plugin build shown in **Settings → Software**.
- Your operating system and Roblox Studio version.
- The region, traffic side, units, and road profile.
- Steps that reproduce the problem in a small test place.
- The expected result and the actual result.
- Relevant Output messages and screenshots.

Remove credentials, personal information, and private assets from attachments.
For a security vulnerability, follow [SECURITY.md](SECURITY.md).

## Propose a feature

Describe the task that you need to complete. Explain the current limitation
and the result that you want. Include a small example when it helps. Check
[ROADMAP.md](ROADMAP.md) for related work.

## Make a change

1. Create a branch from the current default branch.
2. Make one focused change.
3. Keep the existing source style in the files that you edit.
4. Update the documentation when behavior changes.
5. Run the checks relevant to the change.
6. Rebuild both tracked plugin files when packaged source changes.
7. Review the diff for unrelated changes and private information.
8. Open a pull request.

See [docs/development.md](docs/development.md) for build and validation commands.
Use the repository's current default branch as the pull request base.

For geometry changes, add or update a case that demonstrates the behavior.
Confirm that the check rejects the defect it is intended to detect. Test the
built plugin in Roblox Studio. Python geometry checks do not execute Luau.

Format changed Luau files with the repository's `.stylua.toml` settings. Avoid
formatting files unrelated to your change.

## Write the pull request

Describe the problem and the resulting behavior. Include the checks you ran
and any remaining limitations. Add screenshots for visible changes. State
whether you tested the built plugin in Studio.

Do not include private place files or assets unless you have permission to
share them with every repository recipient.

## License and attribution

Submit only work that you have the right to contribute. Contributions to the
project are under AGPL-3.0-only, except for separately identified third-party
material. Preserve existing copyright and license notices.

If you add a dependency or copy code, record its source, version, license, and
required notices in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Include
the license text required by that dependency. Ask the maintainers before you
add code whose license compatibility is unclear.

## Documentation

Use short sentences, active voice, and the exact interface labels. Give one
action per numbered step. Follow [docs/writing-guide.md](docs/writing-guide.md).

Keep discussion respectful. Explain the behavior and evidence when you review
a change. Avoid personal criticism.
