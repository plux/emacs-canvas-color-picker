;;; color-picker-benchmark.el --- Color picker draw benchmark -*- lexical-binding: t; -*-
;; Copyright (c) 2026 Håkan Nilsson
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Batch benchmark for native color picker rendering helpers.

;;; Code:

(require 'cl-lib)

(defconst emacs-canvas-color-picker-benchmark--project-dir
  (file-name-directory (or load-file-name buffer-file-name default-directory)))

(add-to-list 'load-path emacs-canvas-color-picker-benchmark--project-dir)
(require 'color-picker)

(declare-function emacs-canvas-color-picker-native-render-base nil
                  (canvas width height hue padding gap hue-width swatch-width swatch-height swatch-gap marker-radius))
(declare-function emacs-canvas-color-picker-native-render-markers nil
                  (canvas width height hue saturation value padding gap hue-width swatch-width swatch-height swatch-gap marker-radius))
(declare-function emacs-canvas-color-picker-native-render-full nil
                  (canvas width height hue saturation value padding gap hue-width swatch-width swatch-height swatch-gap marker-radius initial-hue initial-saturation initial-value focus-region))

(defvar emacs-canvas-color-picker-benchmark-sizes
  (or (getenv "COLOR_PICKER_BENCHMARK_SIZES") "64x64 128x128 256x256")
  "Space-separated saturation/value sizes measured by the benchmark.")

(defvar emacs-canvas-color-picker-benchmark-iterations
  (string-to-number (or (getenv "COLOR_PICKER_BENCHMARK_ITERATIONS") "50"))
  "Number of marker and full draw iterations measured by the benchmark.")

(defvar emacs-canvas-color-picker-benchmark-base-iterations
  (string-to-number (or (getenv "COLOR_PICKER_BENCHMARK_BASE_ITERATIONS") "10"))
  "Number of base palette iterations measured by the benchmark.")

(defun emacs-canvas-color-picker-benchmark--parse-size (text)
  "Parse TEXT as WIDTHxHEIGHT."
  (unless (string-match "\\`\\([0-9]+\\)x\\([0-9]+\\)\\'" text)
    (error "Invalid benchmark size: %S" text))
  (cons (string-to-number (match-string 1 text))
        (string-to-number (match-string 2 text))))

(defun emacs-canvas-color-picker-benchmark--sizes ()
  "Return benchmark sizes."
  (mapcar #'emacs-canvas-color-picker-benchmark--parse-size
          (split-string emacs-canvas-color-picker-benchmark-sizes "[[:space:]]+" t)))

(defun emacs-canvas-color-picker-benchmark--time (iterations function)
  "Return elapsed milliseconds for running FUNCTION ITERATIONS times."
  (let ((start (float-time)))
    (dotimes (_ iterations)
      (funcall function))
    (* 1000.0 (- (float-time) start))))

(defun emacs-canvas-color-picker-benchmark--geometry (width height)
  "Return benchmark geometry for WIDTH and HEIGHT."
  (emacs-canvas-color-picker--make-geometry
   (list :padding 8
         :sv-width width
         :sv-height height
         :gap 8
         :hue-width 16
         :hue-height height)))

(defun emacs-canvas-color-picker-benchmark--make-canvas (geometry data)
  "Return a canvas spec for GEOMETRY and DATA."
  (list 'image
        :type 'canvas
        :id (gensym "color-picker-benchmark-")
        :data-width (emacs-canvas-color-picker--geometry-width geometry)
        :data-height (emacs-canvas-color-picker--geometry-height geometry)
        :data data))

(defun emacs-canvas-color-picker-benchmark--maybe-load-native ()
  "Load the required native module."
  (emacs-canvas-color-picker-load-native))

(defun emacs-canvas-color-picker-benchmark--run-size (size)
  "Run benchmark for SIZE."
  (let* ((width (car size))
         (height (cdr size))
         (geometry (emacs-canvas-color-picker-benchmark--geometry width height))
         (canvas-width (emacs-canvas-color-picker--geometry-width geometry))
         (canvas-height (emacs-canvas-color-picker--geometry-height geometry))
         (pixels (* canvas-width canvas-height))
         (base (make-vector pixels 0))
         (data (make-vector pixels 0))
         (base-canvas (emacs-canvas-color-picker-benchmark--make-canvas geometry base))
         (canvas (emacs-canvas-color-picker-benchmark--make-canvas geometry data))
         (padding (emacs-canvas-color-picker--geometry-padding geometry))
         (gap (emacs-canvas-color-picker--geometry-gap geometry))
         (hue-width (emacs-canvas-color-picker--geometry-hue-width geometry))
         (swatch-width (emacs-canvas-color-picker--geometry-swatch-width geometry))
         (swatch-height (emacs-canvas-color-picker--geometry-swatch-height geometry))
         (swatch-gap (emacs-canvas-color-picker--geometry-swatch-gap geometry))
         (marker-radius (emacs-canvas-color-picker--geometry-marker-radius geometry))
         (base-ms (emacs-canvas-color-picker-benchmark--time
                   emacs-canvas-color-picker-benchmark-base-iterations
                   (lambda ()
                     (emacs-canvas-color-picker-native-render-base base-canvas canvas-width canvas-height 0.55 padding gap hue-width swatch-width swatch-height swatch-gap marker-radius))))
         (marker-ms (emacs-canvas-color-picker-benchmark--time
                     emacs-canvas-color-picker-benchmark-iterations
                     (lambda ()
                       (emacs-canvas-color-picker-native-render-markers canvas canvas-width canvas-height 0.55 0.75 0.8 padding gap hue-width swatch-width swatch-height swatch-gap marker-radius))))
         (full-ms (emacs-canvas-color-picker-benchmark--time
                   emacs-canvas-color-picker-benchmark-iterations
                   (lambda ()
                     (emacs-canvas-color-picker-native-render-full canvas canvas-width canvas-height 0.55 0.75 0.8 padding gap hue-width swatch-width swatch-height swatch-gap marker-radius 0.55 0.75 0.8 0)))))
    (princ
     (format (concat "%s size=%dx%d canvas=%dx%d pixels=%d "
                     "base-avg=%.3fms marker-avg=%.3fms full-avg=%.3fms\n")
             "color-picker-native-benchmark"
             width
             height
             canvas-width
             canvas-height
             pixels
             (/ base-ms emacs-canvas-color-picker-benchmark-base-iterations)
             (/ marker-ms emacs-canvas-color-picker-benchmark-iterations)
             (/ full-ms emacs-canvas-color-picker-benchmark-iterations)))))

(defun emacs-canvas-color-picker-benchmark-run ()
  "Run the color picker draw benchmark."
  (interactive)
  (emacs-canvas-color-picker-benchmark--maybe-load-native)
  (dolist (size (emacs-canvas-color-picker-benchmark--sizes))
    (emacs-canvas-color-picker-benchmark--run-size size)))

(when noninteractive
  (emacs-canvas-color-picker-benchmark-run))

(provide 'color-picker-benchmark)

;;; color-picker-benchmark.el ends here
