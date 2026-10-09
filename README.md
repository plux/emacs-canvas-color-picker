# Emacs canvas color picker

This color picker lets you select colors with a canvas interface in
Emacs 32. It can copy, insert, or replace colors in your buffer.

https://github.com/user-attachments/assets/76bcc93a-4725-4b04-86c7-01aeee0fb7a5

## Install

Add this declaration to your Emacs configuration:

```emacs-lisp
(use-package canvas-color-picker
  :vc (:url "https://github.com/plux/emacs-canvas-color-picker" :rev :newest)
  :defer t)
```

### Requirements

- A graphical Emacs 32 build with canvas image support and dynamic
  module support.
- Zig 0.17.0 if you build the module locally. A release download does
  not require Zig.

The picker needs a native module. If the module is missing, Emacs offers
a matching release download on Linux x86_64 and macOS ARM64 when the
release includes that asset. Other platforms can build locally with Zig.
If a matching release asset is unavailable, choose the local build.

## Use

Run one of these commands:

```text
M-x canvas-color-picker-copy
M-x canvas-color-picker-insert
M-x canvas-color-picker-at-point
```

The picker opens in a child frame near point by default.

Use these controls to select a color:

- Click or drag on the saturation/value square or the hue strip.
- Press `TAB` to switch keyboard focus between the square and strip.
- Use the arrow keys or `p`, `n`, `b`, `f` to adjust the active control.
  Use Ctrl+Arrow or `C-p`, `C-n`, `C-b`, `C-f` for larger steps.
- Use `M-p` and `M-n` to adjust hue directly.
- Press `RET` to accept the color, or `q` to cancel.

`canvas-color-picker-at-point` acts on the buffer content:

- If a region is active, it must contain one complete supported color value.
  The picker starts with that color value and replaces the region on accept.
  An invalid selection produces an error.
- If no region is active and point is on a color value, the picker starts
  with that color and replaces it on accept.
- If no region is active and there is no color at point, the picker
  inserts the selected color at point on accept.

Replacement keeps the original color format, including any alpha
value. Cancel leaves the buffer unchanged.

Supported colors at point or in a selected region:

- CSS RGB: `#112233` (`#RRGGBB`).
- CSS RGBA: `#11223344` (`#RRGGBBAA`).
- Emacs RGB: `#x112233` (`#xRRGGBB`).
- Emacs ARGB: `#x44112233` (`#xAARRGGBB`).
- C RGB: `0x112233` (`0xRRGGBB`).
- Bare RGB: `112233` (`RRGGBB`).

If Embark is installed, run `embark-act` on a color value.
Press `C-c p` to open the picker, or run
`embark-dwim` to open it as the default action. The action does not
appear for other text. Embark is not required to use the picker.

## Customization

Run `M-x customize-group RET canvas-color-picker RET` to change these
options, or set them in your Emacs init file.

- `canvas-color-picker-default-color`: `"#3399cc"`.
  Initial color when none is supplied.
- `canvas-color-picker-scale`: `1.0`.
  Scale factor for the child-frame layout. Buffer mode fits its window.
- `canvas-color-picker-display`: `child-frame`.
  Set to `buffer` to display the picker in a window.
- `canvas-color-picker-inline-preview`: `t`.
  Show a temporary preview in the source buffer for insert and at-point.
- `canvas-color-picker-native-module-file`:
  `zig-out/lib/canvas-color-picker-module.so` relative to this checkout.
- `canvas-color-picker-zig-command`: `"zig"`.
  Zig executable for automatic builds.
- `canvas-color-picker-emacs-include-dir`: `vendor` in this package.
  Directory with Emacs 32 `emacs-module.h` for local builds.

Set `canvas-color-picker-display` to `buffer` to use a window instead
of a child frame.

`canvas-color-picker-inline-preview` controls temporary previews in
the source buffer for insert and at-point. The original text stays
unchanged until you accept the color.

For example, set buffer display and disable inline previews with
`use-package`:

```emacs-lisp
(use-package canvas-color-picker
  :vc (:url "https://github.com/plux/emacs-canvas-color-picker" :rev :newest)
  :defer t
  :custom
  (canvas-color-picker-display 'buffer)
  (canvas-color-picker-inline-preview nil))
```

To use another Embark action key, add this to your Emacs
configuration. This example replaces `C-c p` with `C-c c`:

```emacs-lisp
(with-eval-after-load 'canvas-color-picker
  (define-key canvas-color-picker--embark-color-map (kbd "C-c p") nil)
  (define-key canvas-color-picker--embark-color-map (kbd "C-c c")
              #'canvas-color-picker-at-point))
```

## Development

The picker uses Emacs Lisp for input and previews. A Zig module draws
the canvas. The project uses GPL-3.0-or-later. See `LICENSE` for the
GPLv3 text.

To build from this checkout, install Zig 0.17.0 and GNU Make. Set
`EMACS` to an Emacs 32 executable. The included header lives in
`vendor`:

```bash
make build EMACS_INCLUDE_DIR=vendor
make run EMACS=/path/to/emacs32 EMACS_INCLUDE_DIR=vendor
```

Use `EMACS_INCLUDE_DIR` to select another Emacs 32 header directory.
Older Emacs headers cannot build the canvas module. Set personal paths
in an ignored `local.mk`:

```makefile
EMACS = /path/to/emacs32
EMACS_INCLUDE_DIR = vendor
```

The build installs `zig-out/lib/canvas-color-picker-module.so`.
The picker loads this path by default. Existing modules do not rebuild
automatically. `make run` builds the module before it opens the picker.

Batch Emacs builds locally without a prompt or network request. If a
build fails, inspect `*color-picker-build*`.

The repository includes `vendor/emacs-module.h` from GNU Emacs 32
source commit `ed1fc1b6be1bb7f9365577527d13b8045b232160`. The
header provides `canvas_data`. Its GNU GPL notice remains in the file.

### Tests and benchmark

```bash
make test EMACS=/path/to/emacs32
make lint EMACS=/path/to/emacs32
make native-benchmark EMACS=/path/to/emacs32 EMACS_INCLUDE_DIR=vendor
```

`make lint` requires `zlint` on `PATH`. It checks Zig formatting,
runs zlint, and byte-compiles the picker, tests, and benchmark. Byte
compilation writes to `/dev/null` and treats warnings as errors.

The ERT suite runs in batch Emacs. Its graphical child-frame test skips
in batch mode. The benchmark runs native base, marker, and full
rendering in batch Emacs.

Set `COLOR_PICKER_BENCHMARK_SIZES`, `COLOR_PICKER_BENCHMARK_ITERATIONS`,
and `COLOR_PICKER_BENCHMARK_BASE_ITERATIONS` to adjust its run.

Use `make run-trace` to write drag diagnostics to
`COLOR_PICKER_TRACE_FILE`. Its default path is
`/tmp/color-picker-trace.log`.

### CI artifact and release

The tag workflow builds Linux x86_64 and macOS ARM64 modules with
Zig 0.17.0 and the vendored header. It uploads each module and its
SHA-256 file as a separate GitHub Actions artifact. It does not run
Emacs or publish a GitHub release. Keep the `Version:` header and
`canvas-color-picker-version` equal. The temporary
`hn/color-picker-macos-arm64-ci` branch also runs this matrix for
GitHub runner validation.

The package uses release assets from its matching version tag. It
checks the binary checksum and native API before use. A GitHub Actions
artifact is not a public release asset.

Release publication needs approval, a successful runner build, and an
Emacs 32 runtime check. Publish the matching binary and `.sha256` file
under the exact tag. Test their public URLs, checksum, and picker
download.

To test the artifact job locally, install `act`, Docker, and Python 3.
Select a reachable Docker context. Then run:

```bash
make test-release-local
```

The target runs only the Linux matrix build in `act`. It checks the
artifact ZIP, checksum, and ELF format. It uses local files, including
uncommitted changes. It does not publish a release.

Use `bash scripts/test-release-local.sh --check-artifact macos-aarch64 ZIP`
to check a macOS artifact's names, checksum, and Mach-O format. Neither
check proves that the module loads on macOS.
