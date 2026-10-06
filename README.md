# Emacs canvas color picker

This color picker uses Emacs Lisp for input, color conversion, and previews. A Zig dynamic module draws its canvas pixels. The repository includes the GPL-3.0 license in `LICENSE`.

## Requirements

- A graphical Emacs 32 build with canvas image support and dynamic module support.
- Zig 0.17.0 for local builds. Release downloads do not require Zig.
- GNU Make for the commands below. The optional `make lint` target also requires `zlint` on `PATH`.
- `curl` for release downloads.

The repository includes `vendor/emacs-module.h` from GNU Emacs 32 source commit `ed1fc1b6be1bb7f9365577527d13b8045b232160`. The header provides `canvas_data`. Its GNU GPL notice remains in the file.

## Build and run

Set `EMACS_INCLUDE_DIR` to `vendor` for the included Emacs 32 header. Set `EMACS` to an Emacs 32 executable for tests and interactive use.

```bash
make build EMACS_INCLUDE_DIR=vendor
make run EMACS=/path/to/emacs32 EMACS_INCLUDE_DIR=vendor
```

To use another Emacs 32 header, set `EMACS_INCLUDE_DIR` to its directory. An older Emacs header cannot build this canvas module. For personal paths, use an ignored `local.mk`:

```makefile
EMACS = /path/to/emacs32
EMACS_INCLUDE_DIR = vendor
```

The build installs `zig-out/lib/libcolor-picker.so`. The picker loads that file by default. Set `emacs-canvas-color-picker-native-module-file` to another path if needed. Existing modules do not rebuild automatically. `make run` builds the module before it opens the picker.

## Use with use-package

Add this declaration to your Emacs configuration:

```emacs-lisp
(use-package color-picker
  :vc (:url "https://github.com/plux/emacs-canvas-color-picker" :rev :newest)
  :commands (emacs-canvas-color-picker-copy
             emacs-canvas-color-picker-insert
             emacs-canvas-color-picker-at-point))
```

For local builds, set the include directory to `vendor` or another Emacs 32 header directory. When the module is missing, interactive Emacs offers a release download or a Zig build on Linux x86_64. Other platforms offer the Zig build. Batch Emacs builds locally without a prompt or network request. The picker does not switch methods after a failure. If Zig fails, the picker shows `*color-picker-build*` and leaves no picker open. `make build` remains available for manual builds.

Version `0.1.0` selects only `v0.1.0` release assets named `libcolor-picker-v0.1.0-linux-x86_64.so`, `libcolor-picker-v0.1.0-linux-x86_64.so.sha256`, and `libcolor-picker-v0.1.0-linux-x86_64.so.api`. The download checks the binary checksum and the API metadata against the same bytes before loading. It then checks that the new module registered both native functions and reports live API version `1`. If a check or installation fails after `module-load`, restart Emacs before another attempt. No GitHub release exists yet, so the download choice currently reports that its asset is unavailable. Select the local build instead. A GitHub Actions artifact is not a public release asset.

Alternatively, load `color-picker.el` from this directory into a graphical Emacs frame. Use these commands:

```text
M-x emacs-canvas-color-picker-copy
M-x emacs-canvas-color-picker-insert
M-x emacs-canvas-color-picker-at-point
```

The picker opens in a child frame near point by default. Set `emacs-canvas-color-picker-display` to `buffer` to use a window instead. In buffer mode, the canvas fits the window and adjusts after a resize. Both modes require graphical canvas support.

Use the mouse on the saturation/value square or the hue strip. The two swatches show the selected color and the initial color. Press `TAB` to move keyboard focus between the square and the strip. Arrow keys and `p`, `n`, `b`, `f` adjust the active region. Ctrl+Arrow and `C-p`, `C-n`, `C-b`, `C-f` use larger steps. `M-p` and `M-n` adjust hue directly. Press `RET` to accept, or `q` to cancel.

`emacs-canvas-color-picker-inline-preview` controls temporary source-buffer previews for insert and at-point. The original text stays unchanged until accept. Copy, insert, and read-color support CSS RGB, CSS RGBA, Emacs RGB, Emacs ARGB, and C RGB output formats through their optional Lisp arguments. See the function documentation for argument order.

## Customization

Run `M-x customize-group RET emacs-canvas-color-picker RET` to change these options:

| Option | Default | Purpose |
| --- | --- | --- |
| `emacs-canvas-color-picker-default-color` | `"#3399cc"` | Initial color when none is supplied. |
| `emacs-canvas-color-picker-scale` | `1.0` | Positive scale factor for the child-frame layout. Buffer mode fits its window instead. |
| `emacs-canvas-color-picker-display` | `child-frame` | Display in a child frame or set to `buffer` for a window. |
| `emacs-canvas-color-picker-inline-preview` | `t` | Show a temporary preview in the source buffer for insert and at-point. |
| `emacs-canvas-color-picker-native-module-file` | `zig-out/lib/libcolor-picker.so` | Native module path, relative to this checkout by default. |
| `emacs-canvas-color-picker-zig-command` | `"zig"` | Zig executable for automatic builds. |
| `emacs-canvas-color-picker-emacs-include-dir` | `vendor` in this package | Directory with Emacs 32 `emacs-module.h` for local builds. |
| `emacs-canvas-color-picker-trace-file` | `COLOR_PICKER_TRACE_FILE` or nil | File for drag trace logs. Leave nil to disable tracing. |

For example, set buffer display and disable inline previews with `use-package`:

```emacs-lisp
(use-package color-picker
  :vc (:url "https://github.com/plux/emacs-canvas-color-picker" :rev :newest)
  :commands (emacs-canvas-color-picker-copy
             emacs-canvas-color-picker-insert
             emacs-canvas-color-picker-at-point)
  :custom
  (emacs-canvas-color-picker-display 'buffer)
  (emacs-canvas-color-picker-inline-preview nil))
```

## CI artifact and release

The tag workflow builds a Linux x86_64 module and uploads the binary, SHA-256 file, and API metadata file as a GitHub Actions artifact. Keep the `Version:` header and `emacs-canvas-color-picker-version` equal when you change the release version. The workflow and local release test reject a mismatch. The workflow downloads the official Zig 0.17.0 archive and checks its pinned SHA-256. It uses the vendored Emacs 32 header. CI does not build or run Emacs and does not publish a GitHub release. No additional Emacs packages are installed for the artifact build.

A later release needs a separate approval, a successful runner build, and an Emacs 32 runtime check before publication. Publish all three matching files from the artifact under the exact version tag. Test the public URLs, checksum, and API metadata after publication.

To test the artifact job locally, install `act`, Docker, and Python 3. Select a reachable Docker context. Then run this command from the repository:

```bash
make test-release-local
```

The target runs the workflow in an Ubuntu 24.04 container and checks the local artifact ZIP, checksum, API metadata, and Linux x86_64 module format. It uses local files, including uncommitted changes. An artifact URL printed by `act` is simulated. The command does not create a GitHub tag, artifact, or release. A successful local run does not replace a GitHub runner check.

## Tests and benchmark

```bash
make test EMACS=/path/to/emacs32
make lint EMACS=/path/to/emacs32
make native-benchmark EMACS=/path/to/emacs32 EMACS_INCLUDE_DIR=vendor
```

`make lint` checks Zig formatting, runs zlint, and byte-compiles the picker, tests, and benchmark. Byte compilation writes to `/dev/null` and treats warnings as errors.

The ERT suite runs in batch Emacs. Its graphical child-frame test skips in batch mode. The benchmark runs native base, marker, and full rendering in batch Emacs. Set `COLOR_PICKER_BENCHMARK_SIZES`, `COLOR_PICKER_BENCHMARK_ITERATIONS`, and `COLOR_PICKER_BENCHMARK_BASE_ITERATIONS` to adjust its run.

Use `make run-trace` to write drag diagnostics to `COLOR_PICKER_TRACE_FILE`. Its default path is `/tmp/color-picker-trace.log`.
