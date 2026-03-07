# Release Process

1. Switch to (or create) a `vx.y` branch.
2. If applicable, cherry-pick the relevant commits from `main` onto the `vx.y` branch.
3. Update `version` in `mix.exs` and finalize `CHANGELOG.md` (move items from `[Unreleased]` to the new version section).
4. Run `mix hex.build` as a sanity check.
5. `git tag vx.y.z && git push --tags`
6. Run `mix hex.publish`.
7. Publish a GitHub release with the changelog notes for that version.
8. If you created a branch in step 1, update `main`'s `CHANGELOG.md` to point to the branch and bump `mix.exs` version with a `-dev` suffix.
