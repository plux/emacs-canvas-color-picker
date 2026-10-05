# Emacs canvas color picker

This color picker uses Emacs Lisp for input, color conversion, and previews. A Zig dynamic module draws its canvas pixels. It requires a graphical Emacs 32 build with canvas image support, Zig, and the Emacs source tree that provides `src/emacs-module.h`. The repository includes the GPL-3.0 license in `LICENSE`.

## Build and run

Set `EMACS_SOURCE_DIR` to your Emacs source tree. Set `EMACS` and `ZIG` if their defaults are not suitable:

```bash
make build EMACS_SOURCE_DIR=/path/to/emacs-source
make run EMACS=/path/to/emacs EMACS_SOURCE_DIR=/path/to/emacs-source
```

The build installs `zig-out/lib/libcolor-picker.so`. The picker loads that file by default. Set `emacs-canvas-color-picker-native-module-file` to a different path if needed. The picker reports an error and cleans up if the module is missing or cannot load. `make run` builds the module before it opens the picker.

Alternatively, load `color-picker.el` from this directory into a graphical Emacs frame. Use these commands:

```text
M-x emacs-canvas-color-picker-copy
M-x emacs-canvas-color-picker-insert
M-x emacs-canvas-color-picker-at-point
```

The picker opens in a child frame near point by default. Set `emacs-canvas-color-picker-display` to `buffer` to use a window instead. In buffer mode, the canvas fits the window and adjusts after a resize. Both modes require graphical canvas support.

Use the mouse on the saturation/value square or the hue strip. The two swatches show the selected color and the initial color. Press `TAB` to move keyboard focus between the square and the strip. Arrow keys and `p`, `n`, `b`, `f` adjust the active region. Ctrl+Arrow and `C-p`, `C-n`, `C-b`, `C-f` use larger steps. `M-p` and `M-n` adjust hue directly. Press `RET` to accept, or `q` to cancel.

`emacs-canvas-color-picker-inline-preview` controls temporary source-buffer previews for insert and at-point. The original text stays unchanged until accept. Copy, insert, and read-color support CSS RGB, CSS RGBA, Emacs RGB, Emacs ARGB, and C RGB output formats through their optional Lisp arguments. See the function documentation for argument order.

## Tests and benchmark

```bash
make test EMACS=/path/to/emacs
make native-benchmark EMACS=/path/to/emacs EMACS_SOURCE_DIR=/path/to/emacs-source
```

The ERT suite runs in batch Emacs. Its graphical child-frame test skips in batch mode. The benchmark runs native base, marker, and full rendering in batch Emacs. Set `COLOR_PICKER_BENCHMARK_SIZES`, `COLOR_PICKER_BENCHMARK_ITERATIONS`, and `COLOR_PICKER_BENCHMARK_BASE_ITERATIONS` to adjust its run.

Use `make run-trace` to write drag diagnostics to `COLOR_PICKER_TRACE_FILE`. Its default path is `/tmp/color-picker-trace.log`.
