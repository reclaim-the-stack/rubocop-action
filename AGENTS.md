# AGENTS.md

## Releasing

Users reference the action as `reclaim-the-stack/rubocop-action@v1`, so every release must also move the `v1` major tag. Forgetting this leaves `@v1` users on the previous release.

1. Make sure the README documents any new or changed inputs in `action.yml` and that the changes are merged to `master`.
2. Pick the next version following semver. Tags use the `vX.Y.Z` format (`1.0.1` and `1.0.2` are legacy tags without the `v` prefix).
3. Create the release. `--target` must be a branch name or a full commit SHA; a short SHA is rejected with "Release.target_commitish is invalid".

   ```sh
   gh release create vX.Y.Z --target master --title vX.Y.Z --notes "..."
   ```

   Release notes are a bullet list of changes with PR numbers. Credit external contributors with "Thanks @<login>".

4. Move the `v1` tag to the new release:

   ```sh
   git fetch --tags
   git tag -f v1 vX.Y.Z
   git push -f origin v1
   ```

5. Verify both tags point at the same commit:

   ```sh
   git ls-remote --tags origin v1 vX.Y.Z
   ```

A breaking change requires a new major version: release `v2.0.0`, create a new `v2` tag and update the README examples to `@v2`. Leave `v1` where it is.
