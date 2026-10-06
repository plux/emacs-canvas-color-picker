# Release procedure

This procedure describes the current Linux x86_64 artifact workflow. Read [VALIDATION.md](VALIDATION.md) for the checks before and after publication.

Starting with `v0.2.0`, release the `.so` module and its `.sha256` checksum. The downloader checks the live native API after it loads the verified module. The published `v0.1.0` release remains unchanged. Its downloader requires the historical `.api` asset.

## Prepare the version

1. Set the `Version:` header and `emacs-canvas-color-picker-version` in `color-picker.el` to the same release version.
2. Make sure that the tag name is `v` followed by that version. Do not reuse or move a published tag.
3. Run the package tests and the checks in [VALIDATION.md](VALIDATION.md).
4. Review the diff, commit the release changes, and push the commit only after approval.
5. Check that the proposed tag does not exist locally or remotely. Push a new tag only after approval.

```bash
git status --short --branch
git diff --check
git tag -l v<VERSION>
git ls-remote --tags origin refs/tags/v<VERSION>
git tag v<VERSION> <COMMIT>
git push origin refs/tags/v<VERSION>
```

Replace `<VERSION>` and `<COMMIT>` with the intended version and tested commit. Do not run the tag commands if either tag check finds a match. A tag push starts `.github/workflows/release.yml`. This workflow uploads an Actions artifact; it does not publish a GitHub release.

## Inspect the hosted artifact

1. Wait for the tag workflow to pass on the intended commit.
2. Download the `linux-x86_64` Actions artifact to a new directory outside the repository.
3. Run the ZIP, checksum, and graphical Emacs checks in [VALIDATION.md](VALIDATION.md).
4. Stop if any check fails. Do not publish untested files.

## Publish after validation

Get explicit approval before creating the public release. Use the exact files from the validated hosted artifact. Set the release note to the approved text; do not infer it from earlier releases.

```bash
gh release create v<VERSION> -R plux/emacs-canvas-color-picker \
  --verify-tag --title v<VERSION> --notes-file /path/to/approved-notes.txt \
  /path/to/libcolor-picker-v<VERSION>-linux-x86_64.so \
  /path/to/libcolor-picker-v<VERSION>-linux-x86_64.so.sha256
```

Check the asset names and release text with `gh release view v<VERSION> -R plux/emacs-canvas-color-picker`. Then run the public URL and picker download checks in [VALIDATION.md](VALIDATION.md). The `0.2.0` downloader requires both files at the exact version tag.
