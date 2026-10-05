PROJECT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
EMACS ?= emacs
ZIG ?= zig
EMACS_SOURCE_DIR ?= $(HOME)/git/emacs-source
ZIG_OPTIMIZE ?= ReleaseFast
COLOR_PICKER_TRACE_FILE ?= /tmp/color-picker-trace.log
COLOR_PICKER_BENCHMARK_SIZES ?= 64x64 128x128 256x256
COLOR_PICKER_BENCHMARK_ITERATIONS ?= 50
COLOR_PICKER_BENCHMARK_BASE_ITERATIONS ?= 10

.PHONY: help build test run run-trace native-benchmark

help:
	@printf '%s\n' \
		'make build              Build zig-out/lib/libcolor-picker.so' \
		'make test               Run the color picker ERT suite in batch Emacs' \
		'make run                Open the picker in graphical Emacs' \
		'make run-trace          Open the picker with drag trace logging' \
		'make native-benchmark   Build and benchmark the native renderer'

build:
	"$(ZIG)" build -Doptimize=$(ZIG_OPTIMIZE) -Demacs-source-dir="$(EMACS_SOURCE_DIR)"

test:
	"$(EMACS)" --batch -Q --eval '(setq load-prefer-newer t)' -L "$(PROJECT_DIR)" -l "$(PROJECT_DIR)/color-picker-test.el" -f ert-run-tests-batch-and-exit

run: build
	"$(EMACS)" -Q --eval '(setq load-prefer-newer t)' -L "$(PROJECT_DIR)" -l "$(PROJECT_DIR)/color-picker.el" --eval '(emacs-canvas-color-picker-copy)'

run-trace: build
	COLOR_PICKER_TRACE_FILE="$(COLOR_PICKER_TRACE_FILE)" "$(EMACS)" -Q --eval '(setq load-prefer-newer t)' -L "$(PROJECT_DIR)" -l "$(PROJECT_DIR)/color-picker.el" --eval '(emacs-canvas-color-picker-copy)'

native-benchmark: build
	COLOR_PICKER_BENCHMARK_SIZES="$(COLOR_PICKER_BENCHMARK_SIZES)" \
	COLOR_PICKER_BENCHMARK_ITERATIONS="$(COLOR_PICKER_BENCHMARK_ITERATIONS)" \
	COLOR_PICKER_BENCHMARK_BASE_ITERATIONS="$(COLOR_PICKER_BENCHMARK_BASE_ITERATIONS)" \
	"$(EMACS)" --batch -Q --eval '(setq load-prefer-newer t)' -L "$(PROJECT_DIR)" -l "$(PROJECT_DIR)/color-picker-benchmark.el"
