# Release Process

1. Update `version` in `mix.exs` and move `[Unreleased]` items to the new version
   section in `CHANGELOG.md`.
2. Ensure the changelog heading matches the release version exactly:
   `## [x.y.z] - YYYY-MM-DD`.
3. Validate the release tree locally:
   - `mix compile --warnings-as-errors`
   - `mix docs --warnings-as-errors --formatter html`
   - `mix test`
   - `mix hex.publish --dry-run`
4. Push `main` to GitHub so HexDocs source links resolve:
   `git push origin main`
5. Tag and push: `git tag vx.y.z && git push origin vx.y.z`
6. The `Release` GitHub Actions workflow runs on the pushed tag. It verifies
   that the tag matches `mix.exs`, runs tests, builds docs, dry-runs the Hex
   publish, and then publishes the package plus HexDocs using `HEX_API_KEY`.
7. Verify the release on Hex.pm and HexDocs.

> If you need to backport a fix to an older minor version, create a `vx.y`
> branch, cherry-pick the relevant commits, then follow steps 3–7 from that
> branch.
