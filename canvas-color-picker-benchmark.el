;;; canvas-color-picker-benchmark.el --- Color picker draw benchmark -*- lexical-binding: t; -*-
;; Copyright (c) 2026 Håkan Nilsson
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Batch benchmark for native color picker rendering helpers.

;;; Code:

(require 'cl-lib)

(defconst canvas-color-picker-benchmark--project-dir
  (file-name-directory (or load-file-name buffer-file-name default-directory)))

(add-to-list 'load-path canvas-color-picker-benchmark--project-dir)
(require 'canvas-color-picker)

(declare-function canvas-color-picker-native-render-base nil
                  (canvas width height hue padding gap hue-width swatch-width swatch-height swatch-gap marker-radius))
(declare-function canvas-color-picker-native-render-markers nil
                  (canvas width height hue saturation value padding gap hue-width swatch-width swatch-height swatch-gap marker-radius))
(declare-function canvas-color-picker-native-render-full nil
                  (canvas width height hue saturation value padding gap hue-width swatch-width swatch-height swatch-gap marker-radius initial-hue initial-saturation initial-value focus-region))

(defvar canvas-color-picker-benchmark-sizes
  (or (getenv "COLOR_PICKER_BENCHMARK_SIZES") "64x64 128x128 256x256")
  "Space-separated saturation/value sizes measured by the benchmark.")

(defvar canvas-color-picker-benchmark-iterations
  (string-to-number (or (getenv "COLOR_PICKER_BENCHMARK_ITERATIONS") "50"))
  "Number of marker and full draw iterations measured by the benchmark.")

(defvar canvas-color-picker-benchmark-base-iterations
  (string-to-number (or (getenv "COLOR_PICKER_BENCHMARK_BASE_ITERATIONS") "10"))
  "Number of base palette iterations measured by the benchmark.")

(defun canvas-color-picker-benchmark--parse-size (text)
  "Parse TEXT as WIDTHxHEIGHT."
  (unless (string-match "\\`\\([0-9]+\\)x\\([0-9]+\\)\\'" text)
    (error "Invalid benchmark size: %S" text))
  (cons (string-to-number (match-string 1 text))
        (string-to-number (match-string 2 text))))

(defun canvas-color-picker-benchmark--sizes ()
  "Return benchmark sizes."
  (mapcar #'canvas-color-picker-benchmark--parse-size
          (split-string canvas-color-picker-benchmark-sizes "[[:space:]]+" t)))

(defun canvas-color-picker-benchmark--time (iterations function)
  "Return elapsed milliseconds for running FUNCTION ITERATIONS times."
  (let ((start (float-time)))
    (dotimes (_ iterations)
      (funcall function))
    (* 1000.0 (- (float-time) start))))

(defun canvas-color-picker-benchmark--geometry (width height)
  "Return benchmark geometry for WIDTH and HEIGHT."
  (canvas-color-picker--make-geometry
   (list :padding 8
         :sv-width width
         :sv-height height
         :gap 8
         :hue-width 16
         :hue-height height)))

(defun canvas-color-picker-benchmark--make-canvas (geometry data)
  "Return a canvas spec for GEOMETRY and DATA."
  (list 'image
        :type 'canvas
        :id (gensym "color-picker-benchmark-")
        :data-width (canvas-color-picker--geometry-width geometry)
        :data-height (canvas-color-picker--geometry-height geometry)
        :data data))

(defun canvas-color-picker-benchmark--maybe-load-native ()
  "Load the required native module."
  (canvas-color-picker-load-native))

(defun canvas-color-picker-benchmark--run-size (size)
  "Run benchmark for SIZE."
  (let* ((width (car size))
         (height (cdr size))
         (geometry (canvas-color-picker-benchmark--geometry width height))
         (canvas-width (canvas-color-picker--geometry-width geometry))
         (canvas-height (canvas-color-picker--geometry-height geometry))
         (pixels (* canvas-width canvas-height))
         (base (make-vector pixels 0))
         (data (make-vector pixels 0))
         (base-canvas (canvas-color-picker-benchmark--make-canvas geometry base))
         (canvas (canvas-color-picker-benchmark--make-canvas geometry data))
         (padding (canvas-color-picker--geometry-padding geometry))
         (gap (canvas-color-picker--geometry-gap geometry))
         (hue-width (canvas-color-picker--geometry-hue-width geometry))
         (swatch-width (canvas-color-picker--geometry-swatch-width geometry))
         (swatch-height (canvas-color-picker--geometry-swatch-height geometry))
         (swatch-gap (canvas-color-picker--geometry-swatch-gap geometry))
         (marker-radius (canvas-color-picker--geometry-marker-radius geometry))
         (base-ms (canvas-color-picker-benchmark--time
                   canvas-color-picker-benchmark-base-iterations
                   (lambda ()
                     (canvas-color-picker-native-render-base base-canvas canvas-width canvas-height 0.55 padding gap hue-width swatch-width swatch-height swatch-gap marker-radius))))
         (marker-ms (canvas-color-picker-benchmark--time
                     canvas-color-picker-benchmark-iterations
                     (lambda ()
                       (canvas-color-picker-native-render-markers canvas canvas-width canvas-height 0.55 0.75 0.8 padding gap hue-width swatch-width swatch-height swatch-gap marker-radius))))
         (full-ms (canvas-color-picker-benchmark--time
                   canvas-color-picker-benchmark-iterations
                   (lambda ()
                     (canvas-color-picker-native-render-full canvas canvas-width canvas-height 0.55 0.75 0.8 padding gap hue-width swatch-width swatch-height swatch-gap marker-radius 0.55 0.75 0.8 0)))))
    (princ
     (format (concat "%s size=%dx%d canvas=%dx%d pixels=%d "
                     "base-avg=%.3fms marker-avg=%.3fms full-avg=%.3fms\n")
             "color-picker-native-benchmark"
             width
             height
             canvas-width
             canvas-height
             pixels
             (/ base-ms canvas-color-picker-benchmark-base-iterations)
             (/ marker-ms canvas-color-picker-benchmark-iterations)
             (/ full-ms canvas-color-picker-benchmark-iterations)))))

(defun canvas-color-picker-benchmark-run ()
  "Run the color picker draw benchmark."
  (interactive)
  (canvas-color-picker-benchmark--maybe-load-native)
  (dolist (size (canvas-color-picker-benchmark--sizes))
    (canvas-color-picker-benchmark--run-size size)))

(when noninteractive
  (canvas-color-picker-benchmark-run))

(provide 'canvas-color-picker-benchmark)

;;; canvas-color-picker-benchmark.el ends here
