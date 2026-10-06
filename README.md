# Emacs canvas color picker

This color picker uses Emacs Lisp for input, color conversion, and previews. A Zig dynamic module draws its canvas pixels. The repository includes the GPL-3.0 license in `LICENSE`.

## Requirements

- A graphical Emacs 32 build with canvas image support and dynamic module support.
- An Emacs 32 `emacs-module.h` header that provides `canvas_data`.
- Zig compatible with `build.zig` (tested with Zig 0.17.0-dev.1811+6716bf52e).
- GNU Make for the commands below. The optional `make lint` target also requires `zlint` on `PATH`.

## Build and run

Set `EMACS_INCLUDE_DIR` to the directory that contains `emacs-module.h`. Set `EMACS` to the Emacs 32 executable for tests and interactive use. These paths can refer to the same source-build directory.

Pass paths on the command line:

```bash
make build EMACS_INCLUDE_DIR=/path/to/emacs-source/src
make run EMACS=/path/to/emacs-source/src/emacs EMACS_INCLUDE_DIR=/path/to/emacs-source/src
```

For personal paths, create an ignored `local.mk` in the repository root:

```makefile
EMACS = /path/to/emacs-source/src/emacs
EMACS_INCLUDE_DIR = /path/to/emacs-source/src
```

Then run `make build` and `make run`. A system-installed Emacs header from an older version cannot build this canvas module.

The build installs `zig-out/lib/libcolor-picker.so`. The picker loads that file by default and builds it if missing. Set `emacs-canvas-color-picker-native-module-file` to a different path if needed. Existing modules do not rebuild automatically. `make run` builds the module before it opens the picker.

## Use with use-package

Add this declaration to your Emacs configuration:

```emacs-lisp
(use-package color-picker
  :vc (:url "https://github.com/plux/emacs-canvas-color-picker" :rev :newest)
  :commands (emacs-canvas-color-picker-copy
             emacs-canvas-color-picker-insert
             emacs-canvas-color-picker-at-point)
  :custom
  (emacs-canvas-color-picker-emacs-include-dir "/path/to/emacs-source/src"))
```

Replace the header path with the directory that contains your Emacs 32 `emacs-module.h`. The first picker command builds the native module if it is missing. Later commands load the existing module without a rebuild. If Zig fails, the picker shows `*color-picker-build*` and leaves no picker open. `make build` remains available for manual builds.

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
| `emacs-canvas-color-picker-emacs-include-dir` | nil | Directory with Emacs 32 `emacs-module.h`. Set this for automatic builds. |
| `emacs-canvas-color-picker-trace-file` | `COLOR_PICKER_TRACE_FILE` or nil | File for drag trace logs. Leave nil to disable tracing. |

For example, set buffer display and disable inline previews with `use-package`:

```emacs-lisp
(use-package color-picker
  :vc (:url "https://github.com/plux/emacs-canvas-color-picker" :rev :newest)
  :commands (emacs-canvas-color-picker-copy
             emacs-canvas-color-picker-insert
             emacs-canvas-color-picker-at-point)
  :custom
  (emacs-canvas-color-picker-emacs-include-dir "/path/to/emacs-source/src")
  (emacs-canvas-color-picker-display 'buffer)
  (emacs-canvas-color-picker-inline-preview nil))
```

## Tests and benchmark

```bash
make test EMACS=/path/to/emacs
make lint EMACS=/path/to/emacs
make native-benchmark EMACS=/path/to/emacs EMACS_INCLUDE_DIR=/path/to/emacs-source/src
```

`make lint` checks Zig formatting, runs zlint, and byte-compiles the picker, tests, and benchmark. Byte compilation writes to `/dev/null` and treats warnings as errors.

The ERT suite runs in batch Emacs. Its graphical child-frame test skips in batch mode. The benchmark runs native base, marker, and full rendering in batch Emacs. Set `COLOR_PICKER_BENCHMARK_SIZES`, `COLOR_PICKER_BENCHMARK_ITERATIONS`, and `COLOR_PICKER_BENCHMARK_BASE_ITERATIONS` to adjust its run.

Use `make run-trace` to write drag diagnostics to `COLOR_PICKER_TRACE_FILE`. Its default path is `/tmp/color-picker-trace.log`.
