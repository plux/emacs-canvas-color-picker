# Release validation

Run these commands from the color-picker repository. Use a matching graphical Emacs 32 build with canvas support. The workflow builds a Linux x86_64 module but does not run Emacs. An `act` run does not replace the hosted build or the graphical test.

This document describes the `v0.3.0` two-file release contract: the renamed `.so` module and its `.sha256` checksum. The release tag identifies the package version. Native API version `2` is checked after loading. The published `v0.1.0` and `v0.2.0` releases retain their original names and native bindings. Use their tagged checkouts for historical checks.

## Before the tag push

1. Run the package tests and lint checks.
2. Run the version mismatch regression test.
3. If `act` and a suitable Docker context are available, run the optional local artifact check. Follow the local environment setup before Docker commands.

```bash
make test EMACS=/path/to/emacs32
make lint EMACS=/path/to/emacs32 ZIG=/path/to/zig-0.17.0
bash scripts/test-version-sync.sh
# Optional: make test-release-local
```

The batch ERT suite skips its graphical child-frame test. Run that test with the hosted module below.

## Validate the hosted artifact before publication

1. Set `VERSION` and `RUN_ID` to the proposed tag version and its successful tag-workflow run ID.
2. Check that the run passed on the intended commit.
3. Download the Actions artifact ZIP into a new temporary directory.
4. Check the ZIP before extraction.

```bash
VERSION=0.3.0
RUN_ID=<RUN_ID>
gh run view "$RUN_ID" -R plux/emacs-canvas-color-picker \
  --json conclusion,headSha,url
ARTIFACT_ID=$(gh api "repos/plux/emacs-canvas-color-picker/actions/runs/$RUN_ID/artifacts" \
  --jq '.artifacts[] | select(.name == "linux-x86_64" and .expired == false) | .id')
test -n "$ARTIFACT_ID"
DIR=$(mktemp -d /tmp/color-picker-release.XXXXXX)
gh api "repos/plux/emacs-canvas-color-picker/actions/artifacts/$ARTIFACT_ID/zip" > "$DIR/linux-x86_64.zip"
bash scripts/test-release-local.sh --check-artifact "$DIR/linux-x86_64.zip"
```

The checker uses the version in `canvas-color-picker.el`. For an older release, use its tagged checkout. It checks two exact names, a 1 MiB bound, the binary checksum, and the Linux x86_64 ELF header.

Extract only after the ZIP check passes:

```bash
mkdir "$DIR/assets"
python3 - "$DIR/linux-x86_64.zip" "$DIR/assets" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    archive.extractall(sys.argv[2])
PY
MODULE="$DIR/assets/canvas-color-picker-module-v${VERSION}-linux-x86_64.so"
test -f "$MODULE"
(cd "$DIR/assets" && sha256sum --check "$(basename "$MODULE").sha256")
```

Run the existing child-frame ERT test in graphical Emacs. Do not pass `--batch`: that mode skips the test. This command writes a result file because graphical Emacs does not print ERT output to the invoking shell.

```bash
EMACS=/path/to/emacs32
COLOR_PICKER_RELEASE_MODULE="$MODULE" COLOR_PICKER_RELEASE_RESULT="$DIR/graphical-test.txt" \
  "$EMACS" -Q -L "$PWD" -l "$PWD/canvas-color-picker-test.el" \
  --eval '(progn (setq canvas-color-picker-native-module-file (getenv "COLOR_PICKER_RELEASE_MODULE")) (unless (and (display-graphic-p) (image-type-available-p (quote canvas))) (error "Graphical canvas support unavailable")) (let ((result (ert-run-test (ert-get-test (quote canvas-color-picker-test-child-frame-shows-canvas))))) (write-region (format "%S\n" (type-of result)) nil (getenv "COLOR_PICKER_RELEASE_RESULT")) (kill-emacs (if (ert-test-passed-p result) 0 1))))'
cat "$DIR/graphical-test.txt"
```

Make sure that the process exits with status zero and the file contains `ert-test-passed`. This test opens the picker, calls the hosted native renderer, checks the child frame, and closes it. If Emacs stalls, inspect the process and result file; do not treat a timeout as a pass.

## Validate the published release

Publish only after the hosted checks pass and publication receives explicit approval. Check the release text and two asset names with `gh release view`. Then fetch the public URLs without GitHub credentials:

```bash
VERSION=0.3.0
DIR=$(mktemp -d /tmp/color-picker-public.XXXXXX)
ASSET="canvas-color-picker-module-v${VERSION}-linux-x86_64.so"
BASE="https://github.com/plux/emacs-canvas-color-picker/releases/download/v${VERSION}/$ASSET"
for suffix in '' .sha256; do
  curl --fail --show-error --location --proto '=https' --proto-redir '=https' \
    --output "$DIR/$ASSET$suffix" "$BASE$suffix" || exit 1
done
(cd "$DIR" && sha256sum --check "$ASSET.sha256")
```

Compare both public files with the files from the validated hosted ZIP. The two directories must contain identical bytes.

Use a fresh Emacs process to exercise the picker's real HTTPS download, verification, installation, and native API check. Use a new destination outside the repository:

```bash
EMACS=/path/to/emacs32
INSTALL_DIR=$(mktemp -d /tmp/color-picker-install.XXXXXX)
COLOR_PICKER_RELEASE_DEST="$INSTALL_DIR/canvas-color-picker-module.so" \
  "$EMACS" --batch -Q -L "$PWD" -l "$PWD/canvas-color-picker.el" \
  --eval '(let ((canvas-color-picker-native-module-file (getenv "COLOR_PICKER_RELEASE_DEST"))) (unless (canvas-color-picker-download-module) (error "Download failed")) (unless (and canvas-color-picker--native-loaded (= (canvas-color-picker-native-api-version) 2)) (error "Native API check failed")) (princ "Picker download and native API check passed\n"))'
sha256sum "$INSTALL_DIR/canvas-color-picker-module.so" "$DIR/$ASSET"
cmp "$INSTALL_DIR/canvas-color-picker-module.so" "$DIR/$ASSET"
```

Make sure that both hashes match and `cmp` exits with status zero. This confirms that the picker installed the public binary. Keep the temporary files until the validation result is recorded.
