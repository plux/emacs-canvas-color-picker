#!/usr/bin/env bash
set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_dir"

version=$(sed -n 's/^;; Version: \([0-9][0-9.]*\)$/\1/p' color-picker.el)
download_version=$(sed -n 's/^(defconst emacs-canvas-color-picker-version "\([0-9][0-9.]*\)"$/\1/p' color-picker.el)
if [[ -z "$version" || -z "$download_version" ]]; then
  echo 'Cannot read the color picker release versions' >&2
  exit 1
fi
if [[ "$version" != "$download_version" ]]; then
  echo 'Version header and downloader version differ' >&2
  exit 1
fi
asset="libcolor-picker-v${version}-linux-x86_64.so"

if [[ "${1:-}" == --check-artifact && $# -eq 2 ]]; then
  artifact=$2
elif [[ $# -eq 0 ]]; then
  for command in act docker python3; do
    command -v "$command" >/dev/null || { echo "Missing command: $command" >&2; exit 1; }
  done
  docker_host=$(docker context inspect --format '{{.Endpoints.docker.Host}}')
  if [[ -z "$docker_host" ]]; then
    echo 'The current Docker context has no endpoint' >&2
    exit 1
  fi
  run_dir=$(mktemp -d /tmp/color-picker-act-run.XXXXXX)
  trap 'rm -rf -- "$run_dir"' EXIT
  printf '{"ref":"refs/tags/v%s","repository":{"full_name":"plux/emacs-canvas-color-picker","name":"emacs-canvas-color-picker","owner":{"login":"plux"}}}\n' "$version" > "$run_dir/event.json"
  mkdir "$run_dir/artifacts"
  DOCKER_HOST="$docker_host" act push \
    -W .github/workflows/release.yml -e "$run_dir/event.json" \
    -P ubuntu-24.04=ghcr.io/catthehacker/ubuntu:act-24.04 \
    --container-architecture linux/amd64 --container-daemon-socket - \
    --artifact-server-path "$run_dir/artifacts" --pull=false
  artifact=$run_dir/artifacts
else
  echo "Usage: $0 [--check-artifact ZIP]" >&2
  exit 2
fi

python3 - "$artifact" "$asset" <<'PY'
import hashlib
from pathlib import Path
import re
import sys
import zipfile

source = Path(sys.argv[1])
asset = sys.argv[2]
if source.is_dir():
    matches = list(source.glob('*/linux-x86_64/linux-x86_64.zip'))
    if len(matches) != 1:
        raise SystemExit(f'Expected one linux-x86_64 artifact ZIP, found {len(matches)}')
    source = matches[0]

with zipfile.ZipFile(source) as archive:
    names = archive.namelist()
    if len(names) != 2 or set(names) != {asset, asset + '.sha256'}:
        raise SystemExit(f'Unexpected artifact files: {names}')
    if any(info.file_size > 1024 * 1024 for info in archive.infolist()):
        raise SystemExit('Artifact file exceeds 1 MiB')
    module = archive.read(asset)
    checksum = archive.read(asset + '.sha256').decode('ascii')

if not re.fullmatch(r'[0-9a-f]{64}  ' + re.escape(asset) + r'\n', checksum):
    raise SystemExit('Invalid artifact checksum file')
actual = hashlib.sha256(module).hexdigest()
if checksum[:64] != actual:
    raise SystemExit('Artifact checksum mismatch')
if module[:4] != b'\x7fELF' or module[4:6] != b'\x02\x01' or module[18:20] != b'\x3e\x00':
    raise SystemExit('Artifact is not a Linux x86_64 ELF module')
print(f'Validated {source}: {asset} SHA-256 {actual}')
PY
