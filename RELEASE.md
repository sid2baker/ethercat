# Release Process

1. Update `version` in `mix.exs` and move `[Unreleased]` items to the new version section in `CHANGELOG.md`.
2. Push `main` to GitHub so hexdocs source links resolve: `git push origin main`
3. Preview docs locally: `mix docs && xdg-open doc/index.html`
4. Sanity check the package: `mix hex.build`
5. Tag and push: `git tag vx.y.z && git push --tags`
6. Publish: `mix hex.publish`
7. Create a GitHub release using the changelog notes for that version.

> If you need to backport a fix to an older minor version, create a `vx.y` branch,
> cherry-pick the relevant commits, then follow steps 4–7 from that branch.
