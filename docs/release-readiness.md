# Open-source release preparation

This copy is prepared for `EurekaRBLX/easyRoad`. Keep the GitHub repository private
until the release review is complete. This document does not authorize a change
to repository visibility.

## Copy baseline

- Source repository: `gamesonrblx/easyRoad`.
- Source commit: `86dce4faee8653b5242a02e2ba721396afd95641`.
- The copy retains the Git history. Uncommitted changes from the source checkout
  are not included.
- The license for this distribution is GNU AGPL version 3 only
  (`AGPL-3.0-only`). Third-party files retain their stated licenses.
- Both XML distribution names contain the same OSS build. Python and Rojo use
  the same OSS source mode. The commercial EULA does not apply to this copy.

## Before public release

- [ ] Create or verify `EurekaRBLX/easyRoad` as a **private** repository. Confirm
  that the correct maintainers can access it.
- [ ] Confirm that the copyright holders authorize AGPL-3.0-only distribution
  of the project code, documentation, and original assets.
- [ ] Confirm redistribution rights for the five `hardware/*.rbxmx` reference
  models. Record their authors, source, and license terms.
- [ ] Confirm ownership and public use of the Roblox icon assets referenced by
  `loader.server.lua`, `src/UI/Icons.lua`, and `src/UI/BuildBar.lua`.
- [ ] Review all retained Git history, tags, and branches for credentials,
  private information, and material that cannot be published. Internal planning
  documents were removed from the current tree. They remain in prior commits.
  Agree on any history changes before publication.
  A bounded review found a personal contact address in historical versions of
  `HANDOFF.md`, including commit `421984da9be5fa5d65d79a7c758d5c8e3ab2cf36`.
  Review that content before making the retained history public.
- [ ] Review the third-party inventory and all included license texts. Add
  notices for any later dependency or copied algorithm.
- [ ] Enable a private vulnerability reporting route. Verify the instructions
  in `SECURITY.md` before accepting public reports.
- [ ] Review repository settings, access rules, issue forms, and CI results.
- [ ] Build with Python and Rojo. Confirm that each package contains the full
  AGPL text, third-party notices, and the correct source repository URL.
- [ ] Run the documented automated checks and complete the Roblox Studio smoke
  test in [development.md](development.md). Record the tested commit and Studio
  version. Python geometry checks do not execute the plugin.
- [ ] Publish corresponding source for each distributed build. Include the
  license and notices with the release artifacts.
- [ ] Confirm the release scope and repository visibility with the owner.

These checks track work that remains before publication. They do not add terms
to the licenses in [LICENSE](../LICENSE) or the third-party notices.
