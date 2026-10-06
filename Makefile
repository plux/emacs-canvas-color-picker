PROJECT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
-include $(PROJECT_DIR)/local.mk

EMACS ?= emacs
ZIG ?= zig
ZLINT ?= zlint
ZIG_OPTIMIZE ?= ReleaseFast
EMACS_HEADER_FLAGS = $(if $(EMACS_INCLUDE_DIR),-Demacs-include-dir="$(EMACS_INCLUDE_DIR)")
COLOR_PICKER_TRACE_FILE ?= /tmp/color-picker-trace.log
COLOR_PICKER_BENCHMARK_SIZES ?= 64x64 128x128 256x256
COLOR_PICKER_BENCHMARK_ITERATIONS ?= 50
COLOR_PICKER_BENCHMARK_BASE_ITERATIONS ?= 10

.PHONY: help build test lint run run-trace native-benchmark test-release-local

help:
	@printf '%s\n' \
		'make build              Build zig-out/lib/canvas-color-picker-module.so' \
		'make test               Run the color picker ERT suite in batch Emacs' \
		'make test-release-local Run the artifact workflow with act and check its output' \
		'make lint               Check Zig formatting, zlint, and Elisp byte compilation' \
		'make run                Open the picker in graphical Emacs' \
		'make run-trace          Open the picker with drag trace logging' \
		'make native-benchmark   Build and benchmark the native renderer'

build:
	"$(ZIG)" build -Doptimize=$(ZIG_OPTIMIZE) $(EMACS_HEADER_FLAGS)

test:
	"$(EMACS)" --batch -Q --eval '(setq load-prefer-newer t)' -L "$(PROJECT_DIR)" -l "$(PROJECT_DIR)/canvas-color-picker-test.el" -f ert-run-tests-batch-and-exit

test-release-local:
	bash "$(PROJECT_DIR)/scripts/test-release-local.sh"

lint:
	"$(ZIG)" fmt --check "$(PROJECT_DIR)/build.zig" "$(PROJECT_DIR)/src/module.zig"
	printf '%s\n' "$(PROJECT_DIR)/src/module.zig" | "$(ZLINT)" -f json --deny-warnings -S
	"$(EMACS)" --batch -Q -L "$(PROJECT_DIR)" --eval '(progn (setq load-prefer-newer t byte-compile-error-on-warn t byte-compile-dest-file-function (lambda (_file) "/dev/null")) (dolist (file (list "$(PROJECT_DIR)/canvas-color-picker.el" "$(PROJECT_DIR)/canvas-color-picker-test.el" "$(PROJECT_DIR)/canvas-color-picker-benchmark.el")) (unless (byte-compile-file file) (error "Compilation failed: %s" file))))'

run: build
	"$(EMACS)" -Q --eval '(setq load-prefer-newer t)' -L "$(PROJECT_DIR)" -l "$(PROJECT_DIR)/canvas-color-picker.el" --eval '(canvas-color-picker-copy)'

run-trace: build
	COLOR_PICKER_TRACE_FILE="$(COLOR_PICKER_TRACE_FILE)" "$(EMACS)" -Q --eval '(setq load-prefer-newer t)' -L "$(PROJECT_DIR)" -l "$(PROJECT_DIR)/canvas-color-picker.el" --eval '(canvas-color-picker-copy)'

native-benchmark: build
	COLOR_PICKER_BENCHMARK_SIZES="$(COLOR_PICKER_BENCHMARK_SIZES)" \
	COLOR_PICKER_BENCHMARK_ITERATIONS="$(COLOR_PICKER_BENCHMARK_ITERATIONS)" \
	COLOR_PICKER_BENCHMARK_BASE_ITERATIONS="$(COLOR_PICKER_BENCHMARK_BASE_ITERATIONS)" \
	"$(EMACS)" --batch -Q --eval '(setq load-prefer-newer t)' -L "$(PROJECT_DIR)" -l "$(PROJECT_DIR)/canvas-color-picker-benchmark.el"
