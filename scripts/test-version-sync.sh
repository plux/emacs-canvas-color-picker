#!/usr/bin/env bash
set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d /tmp/color-picker-version-test.XXXXXX)
trap 'rm -rf -- "$tmp_dir"' EXIT
mkdir "$tmp_dir/scripts"
cp "$project_dir/color-picker.el" "$tmp_dir/color-picker.el"
cp "$project_dir/scripts/test-release-local.sh" "$tmp_dir/scripts/"
sed -n '/^      - name: Match tag to package version$/,/^      - name: Install verified Zig/{ /^          /s/^          //p; }' \
  "$project_dir/.github/workflows/release.yml" > "$tmp_dir/gate.sh"
test -s "$tmp_dir/gate.sh"
(cd "$tmp_dir" && GITHUB_REF_NAME=v0.2.0 bash -e gate.sh)

# Exercise a valid header/tag but a mismatched downloader version.
sed -i 's/(defconst emacs-canvas-color-picker-version "0.2.0"/(defconst emacs-canvas-color-picker-version "0.3.0"/' "$tmp_dir/color-picker.el"
if (cd "$tmp_dir" && GITHUB_REF_NAME=v0.2.0 bash -e gate.sh > gate.log 2>&1); then
  echo 'Workflow accepted mismatched release versions' >&2
  exit 1
fi
if ! (cd "$tmp_dir" && bash scripts/test-release-local.sh --check-artifact /nonexistent.zip > local.log 2>&1); then
  if ! grep -q 'Version header and downloader version differ' "$tmp_dir/local.log"; then
    echo 'Local release check did not reject the version mismatch first' >&2
    exit 1
  fi
else
  echo 'Local release check accepted mismatched versions' >&2
  exit 1
fi
printf 'Both release-version gates rejected a mismatch\n'
