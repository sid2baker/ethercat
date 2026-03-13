# Release Process

1. Update `version` in `mix.exs` and move `[Unreleased]` items to the new version
   section in `CHANGELOG.md`.
2. Ensure the changelog heading matches the release version exactly:
   `## [x.y.z] - YYYY-MM-DD`.
3. Push `main` to GitHub so hexdocs source links resolve: `git push origin main`
4. Preview docs locally: `mix docs && xdg-open doc/index.html`
5. Sanity check the package: `mix hex.build`
6. Tag and push: `git tag vx.y.z && git push --tags`
7. The `Release` GitHub Actions workflow runs on the pushed tag. It verifies that
   the tag matches `mix.exs`, runs tests, builds docs, runs `mix hex.build`, and
   creates a draft GitHub release from the matching `CHANGELOG.md` section.
8. Publish to Hex manually: `mix hex.publish`
9. Review and publish the draft GitHub release created by the workflow.

> If you need to backport a fix to an older minor version, create a `vx.y` branch,
> cherry-pick the relevant commits, then follow steps 5–9 from that branch.
