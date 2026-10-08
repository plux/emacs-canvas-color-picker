# Emacs canvas color picker

This color picker uses Emacs Lisp for input, color conversion, and previews. A Zig dynamic module draws its canvas pixels. The project is licensed under GPL-3.0-or-later. The GPLv3 text is in `LICENSE`.

## Requirements

- A graphical Emacs 32 build with canvas image support and dynamic module support.
- Zig 0.17.0 for local builds. Release downloads do not require Zig.
- GNU Make for the commands below. The optional `make lint` target also requires `zlint` on `PATH`.

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

The build installs `zig-out/lib/canvas-color-picker-module.so`. The picker loads that file by default. Set `canvas-color-picker-native-module-file` to another path if needed. Existing modules do not rebuild automatically. `make run` builds the module before it opens the picker.

## Use with use-package

Add this declaration to your Emacs configuration:

```emacs-lisp
(use-package canvas-color-picker
  :vc (:url "https://github.com/plux/emacs-canvas-color-picker" :rev :newest)
  :commands (canvas-color-picker-copy
             canvas-color-picker-insert
             canvas-color-picker-at-point))
```

For local builds, set the include directory to `vendor` or another Emacs 32 header directory. When the module is missing, interactive Emacs offers download, compile, or skip. Linux x86_64 shows the exact release URL; other platforms offer compile or skip. Skip closes the picker without changing the source buffer. Batch Emacs builds locally without a prompt or network request. The picker does not switch methods after a failure. If Zig fails, the picker shows `*color-picker-build*` and leaves no picker open. `make build` remains available for manual builds.

The package selects only release assets from the tag that matches `canvas-color-picker-version`. It expects `canvas-color-picker-module-v<VERSION>-linux-x86_64.so` and its `.sha256` file. The download checks the binary checksum before loading. It then checks that the new module registered both native functions and reports live API version `2`. If a check or installation fails after `module-load`, restart Emacs before another attempt. If the matching release asset is unavailable, choose the local Zig build. Earlier releases remain unchanged. A GitHub Actions artifact is not a public release asset.

Alternatively, load `canvas-color-picker.el` from this directory into a graphical Emacs frame. Use these commands:

```text
M-x canvas-color-picker-copy
M-x canvas-color-picker-insert
M-x canvas-color-picker-at-point
```

The picker opens in a child frame near point by default. Set `canvas-color-picker-display` to `buffer` to use a window instead. In buffer mode, the canvas fits the window, adjusts after a resize, and keeps its modeline. Both modes require graphical canvas support.

Use the mouse on the saturation/value square or the hue strip. While you drag outside a control in the picker frame, the selection stays at its edge and tracks movement along that edge. The two swatches show the selected color and the initial color. Press `TAB` to move keyboard focus between the square and the strip. Arrow keys and `p`, `n`, `b`, `f` adjust the active region. Ctrl+Arrow and `C-p`, `C-n`, `C-b`, `C-f` use larger steps. `M-p` and `M-n` adjust hue directly. Press `RET` to accept, or `q` to cancel.

`canvas-color-picker-at-point` uses an active region before the color at point. The region must contain one complete supported color. Accept replaces the selected text and keeps its format. Cancel leaves the text unchanged. An invalid selection produces an error.

If Embark is installed, run `embark-act` on a supported color or a valid selected color. Press `C-c p` to open `canvas-color-picker-at-point`, or run `embark-dwim` to open it as the default action. The action does not appear for other text. Embark is not required to use the picker.

To use another Embark action key, add this to your Emacs configuration. This example replaces `C-c p` with `C-c c`:

```emacs-lisp
(with-eval-after-load 'canvas-color-picker
  (define-key canvas-color-picker--embark-color-map (kbd "C-c p") nil)
  (define-key canvas-color-picker--embark-color-map (kbd "C-c c")
              #'canvas-color-picker-at-point))
```

`canvas-color-picker-inline-preview` controls temporary source-buffer previews for insert and at-point. The original text stays unchanged until accept. Copy, insert, and read-color support CSS RGB, CSS RGBA, Emacs RGB, Emacs ARGB, and C RGB output formats through their optional Lisp arguments. See the function documentation for argument order.

## Customization

Run `M-x customize-group RET canvas-color-picker RET` to change these options:

| Option | Default | Purpose |
| --- | --- | --- |
| `canvas-color-picker-default-color` | `"#3399cc"` | Initial color when none is supplied. |
| `canvas-color-picker-scale` | `1.0` | Positive scale factor for the child-frame layout. Buffer mode fits its window instead. |
| `canvas-color-picker-display` | `child-frame` | Display in a child frame or set to `buffer` for a window. |
| `canvas-color-picker-inline-preview` | `t` | Show a temporary preview in the source buffer for insert and at-point. |
| `canvas-color-picker-native-module-file` | `zig-out/lib/canvas-color-picker-module.so` | Native module path, relative to this checkout by default. |
| `canvas-color-picker-zig-command` | `"zig"` | Zig executable for automatic builds. |
| `canvas-color-picker-emacs-include-dir` | `vendor` in this package | Directory with Emacs 32 `emacs-module.h` for local builds. |
| `canvas-color-picker-trace-file` | `COLOR_PICKER_TRACE_FILE` or nil | File for drag trace logs. Leave nil to disable tracing. |

For example, set buffer display and disable inline previews with `use-package`:

```emacs-lisp
(use-package canvas-color-picker
  :vc (:url "https://github.com/plux/emacs-canvas-color-picker" :rev :newest)
  :commands (canvas-color-picker-copy
             canvas-color-picker-insert
             canvas-color-picker-at-point)
  :custom
  (canvas-color-picker-display 'buffer)
  (canvas-color-picker-inline-preview nil))
```

## CI artifact and release

The tag workflow builds a Linux x86_64 module. It uploads the binary and SHA-256 file as a GitHub Actions artifact. Keep the `Version:` header and `canvas-color-picker-version` equal when you change the release version. The workflow and local release test reject a mismatch.

The workflow installs Zig 0.17.0 through a pinned `mlugg/setup-zig` action with a Zig build cache. It builds with a fixed Linux target and baseline CPU against the vendored Emacs 32 header. Cache restoration does not guarantee a faster build. Tag-triggered runs do not establish cache sharing across tags.

CI does not build or run Emacs. It does not publish a GitHub release. No additional Emacs packages are installed for the artifact build.

A later release needs a separate approval, a successful runner build, and an Emacs 32 runtime check before publication. Publish both matching files from the artifact under the exact version tag. Test the public URLs, checksum, and picker download after publication.

To test the artifact job locally, install `act`, Docker, and Python 3. Select a reachable Docker context. Then run this command from the repository:

```bash
make test-release-local
```

The target runs the workflow in an Ubuntu 24.04 container and checks the local artifact ZIP, checksum, and Linux x86_64 module format. It uses local files, including uncommitted changes. An artifact URL printed by `act` is simulated. The command does not create a GitHub tag, artifact, or release. A successful local run does not replace a GitHub runner check.

## Tests and benchmark

```bash
make test EMACS=/path/to/emacs32
make lint EMACS=/path/to/emacs32
make native-benchmark EMACS=/path/to/emacs32 EMACS_INCLUDE_DIR=vendor
```

`make lint` checks Zig formatting, runs zlint, and byte-compiles the picker, tests, and benchmark. Byte compilation writes to `/dev/null` and treats warnings as errors.

The ERT suite runs in batch Emacs. Its graphical child-frame test skips in batch mode. The benchmark runs native base, marker, and full rendering in batch Emacs. Set `COLOR_PICKER_BENCHMARK_SIZES`, `COLOR_PICKER_BENCHMARK_ITERATIONS`, and `COLOR_PICKER_BENCHMARK_BASE_ITERATIONS` to adjust its run.

Use `make run-trace` to write drag diagnostics to `COLOR_PICKER_TRACE_FILE`. Its default path is `/tmp/color-picker-trace.log`.
