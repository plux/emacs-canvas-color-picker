;;; color-picker.el --- Canvas color picker widget -*- lexical-binding: t; -*-

;;; Commentary:
;; Pure Emacs Lisp color picker experiment for the Emacs 32 canvas image type.

;;; Code:

(require 'cl-lib)

(defgroup emacs-canvas-color-picker nil
  "Canvas-backed color picker widget."
  :group 'faces)

(defcustom emacs-canvas-color-picker-default-color "#3399cc"
  "Default color used when no initial color is supplied."
  :type 'string)

(defcustom emacs-canvas-color-picker-scale 1.0
  "Multiply the picker width of ten parent-frame character heights.
The picker keeps its layout proportions at other scale values."
  :type 'number)

(defcustom emacs-canvas-color-picker-native-module-file
  (expand-file-name "../zig-out/lib/libcolor-picker.so"
                    (file-name-directory (or load-file-name buffer-file-name default-directory)))
  "Native module file used for accelerated color picker rendering."
  :type 'file)

(defcustom emacs-canvas-color-picker-use-native t
  "Whether to use the native renderer when it can be loaded."
  :type 'boolean)

(defcustom emacs-canvas-color-picker-trace-file
  (getenv "COLOR_PICKER_TRACE_FILE")
  "File path for color picker drag trace logs, or nil to disable tracing."
  :type '(choice (const nil) file))

(defconst emacs-canvas-color-picker--buffer-name "*emacs-canvas-color-picker*")
(defconst emacs-canvas-color-picker--marker-black #xFF000000)
(defconst emacs-canvas-color-picker--marker-white #xFFFFFFFF)
(defconst emacs-canvas-color-picker--background #xFF4D4D4D)

(defvar emacs-canvas-color-picker--native-loaded nil
  "Non-nil when the native color picker renderer is loaded.")

(declare-function emacs-canvas-color-picker-native-render-base nil
                  (canvas width height hue padding gap hue-width swatch-width swatch-height swatch-gap marker-radius))
(declare-function emacs-canvas-color-picker-native-render-markers nil
                  (canvas width height hue saturation value padding gap hue-width swatch-width swatch-height swatch-gap marker-radius))
(declare-function emacs-canvas-color-picker-native-render-full nil
                  (canvas width height hue saturation value padding gap hue-width swatch-width swatch-height swatch-gap marker-radius initial-hue initial-saturation initial-value))

(defun emacs-canvas-color-picker--trace (event &rest properties)
  "Append trace EVENT with PROPERTIES when tracing is enabled."
  (when (and (stringp emacs-canvas-color-picker-trace-file)
             (> (length emacs-canvas-color-picker-trace-file) 0))
    (let ((line (prin1-to-string
                 (append (list :time (float-time) :event event) properties))))
      (ignore-errors
        (write-region (concat line "\n") nil emacs-canvas-color-picker-trace-file 'append 'silent)))))

(defun emacs-canvas-color-picker--trace-position (position)
  "Return compact trace data for mouse POSITION."
  (condition-case nil
      (let* ((window (and position (posn-window position)))
             (object-x-y (and position (posn-object-x-y position)))
             (actual-x-y (and position (posn-x-y position))))
        (list :window-live (and (window-live-p window) t)
              :window-buffer (and (window-live-p window) (buffer-name (window-buffer window)))
              :object-x-y object-x-y
              :x-y actual-x-y))
    (error (list :invalid-position position))))

(defun emacs-canvas-color-picker--trace-event (event)
  "Return compact trace data for mouse EVENT."
  (append (list :event-type (car-safe event))
          (list :start (emacs-canvas-color-picker--trace-position (event-start event)))
          (list :end (emacs-canvas-color-picker--trace-position (event-end event)))))

(cl-defstruct (emacs-canvas-color-picker--geometry
               (:constructor emacs-canvas-color-picker--geometry-create))
  padding
  sv-width
  sv-height
  gap
  hue-width
  hue-height
  marker-radius
  width
  height
  sv-left
  sv-top
  hue-left
  hue-top
  swatch-top
  swatch-width
  swatch-height
  swatch-gap
  new-swatch-left
  current-swatch-left)

(cl-defstruct (emacs-canvas-color-picker--state
               (:constructor emacs-canvas-color-picker--state-create))
  frame
  parent-frame
  buffer
  canvas
  base-canvas
  data
  base-data
  geometry
  status-marker
  hue
  saturation
  value
  initial-hue
  initial-saturation
  initial-value
  callback
  replace-start
  replace-end
  replace-prefixed
  done)

(defvar-local emacs-canvas-color-picker--state nil
  "Current color picker state for this buffer.")

(defvar emacs-canvas-color-picker--mouse-map
  (let ((map (make-sparse-keymap)))
    (define-key map [down-mouse-1] #'emacs-canvas-color-picker--mouse-down)
    (define-key map [mouse-1] #'emacs-canvas-color-picker--mouse-click)
    (define-key map [drag-mouse-1] #'emacs-canvas-color-picker--mouse-drag)
    map)
  "Mouse map attached to the canvas display string.")

(defun emacs-canvas-color-picker--clamp (value low high)
  "Clamp VALUE between LOW and HIGH."
  (min high (max low value)))

(defun emacs-canvas-color-picker--clamp01 (value)
  "Clamp VALUE to the inclusive range 0.0 to 1.0."
  (emacs-canvas-color-picker--clamp (float value) 0.0 1.0))

(defun emacs-canvas-color-picker--clamp-byte (value)
  "Clamp VALUE to an integer byte."
  (truncate (emacs-canvas-color-picker--clamp (round value) 0 255)))

(defun emacs-canvas-color-picker--hsv-to-rgb (hue saturation value)
  "Convert HUE, SATURATION, and VALUE to 8-bit RGB components."
  (let* ((h (mod (float hue) 1.0))
         (s (emacs-canvas-color-picker--clamp01 saturation))
         (v (emacs-canvas-color-picker--clamp01 value))
         (sector (* h 6.0))
         (i (floor sector))
         (f (- sector i))
         (p (* v (- 1.0 s)))
         (q (* v (- 1.0 (* s f))))
         (tv (* v (- 1.0 (* s (- 1.0 f)))))
         rgb)
    (setq rgb
          (pcase (mod i 6)
            (0 (list v tv p))
            (1 (list q v p))
            (2 (list p v tv))
            (3 (list p q v))
            (4 (list tv p v))
            (_ (list v p q))))
    (mapcar (lambda (component)
              (emacs-canvas-color-picker--clamp-byte (* component 255.0)))
            rgb)))

(defun emacs-canvas-color-picker--rgb-to-hex (red green blue)
  "Format RED, GREEN, and BLUE as lowercase #rrggbb."
  (format "#%02x%02x%02x"
          (emacs-canvas-color-picker--clamp-byte red)
          (emacs-canvas-color-picker--clamp-byte green)
          (emacs-canvas-color-picker--clamp-byte blue)))

(defun emacs-canvas-color-picker--rgb-to-hsv (red green blue)
  "Convert RED, GREEN, and BLUE byte components to HSV."
  (let* ((r (/ (float (emacs-canvas-color-picker--clamp-byte red)) 255.0))
         (g (/ (float (emacs-canvas-color-picker--clamp-byte green)) 255.0))
         (b (/ (float (emacs-canvas-color-picker--clamp-byte blue)) 255.0))
         (max-component (max r g b))
         (min-component (min r g b))
         (delta (- max-component min-component))
         (hue 0.0))
    (when (> delta 0.0)
      (setq hue
            (cond
             ((= max-component r)
              (/ (mod (/ (- g b) delta) 6.0) 6.0))
             ((= max-component g)
              (/ (+ (/ (- b r) delta) 2.0) 6.0))
             (t
              (/ (+ (/ (- r g) delta) 4.0) 6.0)))))
    (list (mod hue 1.0)
          (if (= max-component 0.0)
              0.0
            (/ delta max-component))
          max-component)))

(defun emacs-canvas-color-picker--hex-to-rgb (color)
  "Parse COLOR as #RRGGBB or RRGGBB and return RGB byte components."
  (unless (stringp color)
    (error "Color must be a string"))
  (let ((hex (if (string-prefix-p "#" color)
                 (substring color 1)
               color)))
    (unless (string-match-p "\\`[[:xdigit:]]\\{6\\}\\'" hex)
      (error "Invalid hex color: %S" color))
    (list (string-to-number (substring hex 0 2) 16)
          (string-to-number (substring hex 2 4) 16)
          (string-to-number (substring hex 4 6) 16))))

(defun emacs-canvas-color-picker--hex-to-hsv (color)
  "Parse COLOR and return HSV values."
  (apply #'emacs-canvas-color-picker--rgb-to-hsv
         (emacs-canvas-color-picker--hex-to-rgb color)))

(defun emacs-canvas-color-picker--argb (red green blue)
  "Compose an opaque ARGB32 pixel from RED, GREEN, and BLUE."
  (logior #xFF000000
          (ash (emacs-canvas-color-picker--clamp-byte red) 16)
          (ash (emacs-canvas-color-picker--clamp-byte green) 8)
          (emacs-canvas-color-picker--clamp-byte blue)))

(defun emacs-canvas-color-picker--make-geometry (&optional plist parent-frame)
  "Return picker geometry with base overrides from PLIST.
When PARENT-FRAME is non-nil, target ten of its character heights in width."
  (let ((scale emacs-canvas-color-picker-scale))
    (unless (and (or (integerp scale) (floatp scale)) (> scale 0)
                 (not (isnan (float scale))) (< (float scale) 1.0e+INF))
      (error "Picker scale must be a finite positive number"))
    (let* ((base-padding (or (plist-get plist :padding) 12))
           (base-sv-width (or (plist-get plist :sv-width) 256))
           (base-sv-height (or (plist-get plist :sv-height) 256))
           (base-gap (or (plist-get plist :gap) 12))
           (base-hue-width (or (plist-get plist :hue-width) 24))
           (base-hue-height (or (plist-get plist :hue-height) base-sv-height))
           (base-swatch-width (or (plist-get plist :swatch-width) 64))
           (base-swatch-height (or (plist-get plist :swatch-height) 28))
           (base-swatch-gap (or (plist-get plist :swatch-gap) 16)))
      (dolist (value (list base-padding base-sv-width base-sv-height base-gap
                           base-hue-width base-hue-height base-swatch-width
                           base-swatch-height base-swatch-gap))
        (unless (and (integerp value) (>= value 0))
          (error "Geometry values must be non-negative integers")))
      (when parent-frame
        (let ((base-width (+ (* 2 base-padding) base-sv-width base-gap
                             base-hue-width)))
          (unless (> base-width 0)
            (error "Base picker width must be positive"))
          (setq scale (* scale (/ (* 10.0 (frame-char-height parent-frame))
                                  base-width)))))
      (let* ((padding (round (* base-padding scale)))
             (sv-width (round (* base-sv-width scale)))
             (sv-height (round (* base-sv-height scale)))
             (gap (round (* base-gap scale)))
             (hue-width (round (* base-hue-width scale)))
             (hue-height (round (* base-hue-height scale)))
             (swatch-width (round (* base-swatch-width scale)))
             (swatch-height (round (* base-swatch-height scale)))
             (swatch-gap (round (* base-swatch-gap scale)))
             (marker-radius (max 1 (round (* 5 scale))))
             (sv-left padding)
             (sv-top padding)
             (hue-left (+ sv-left sv-width gap))
             (hue-top padding)
             (palette-height (max sv-height hue-height))
             (swatch-top (+ padding palette-height padding))
             (new-swatch-left padding)
             (current-swatch-left (+ new-swatch-left swatch-width swatch-gap))
             (width (+ padding sv-width gap hue-width padding))
             (height (+ padding palette-height padding swatch-height padding)))
        (when (or (zerop sv-width) (zerop sv-height) (zerop hue-width) (zerop hue-height)
                  (zerop swatch-width) (zerop swatch-height))
          (error "Palette dimensions must be positive"))
        (emacs-canvas-color-picker--geometry-create
         :padding padding
         :sv-width sv-width
         :sv-height sv-height
         :gap gap
         :hue-width hue-width
         :hue-height hue-height
         :marker-radius marker-radius
         :width width
         :height height
         :sv-left sv-left
         :sv-top sv-top
         :hue-left hue-left
         :hue-top hue-top
         :swatch-top swatch-top
         :swatch-width swatch-width
         :swatch-height swatch-height
         :swatch-gap swatch-gap
         :new-swatch-left new-swatch-left
         :current-swatch-left current-swatch-left)))))

(defun emacs-canvas-color-picker--within-rect-p (x y left top width height)
  "Return non-nil when X and Y are inside rectangle LEFT TOP WIDTH HEIGHT."
  (and (>= x left)
       (< x (+ left width))
       (>= y top)
       (< y (+ top height))))

(defun emacs-canvas-color-picker--position-fraction (offset size)
  "Return OFFSET as a fraction across SIZE pixels."
  (if (<= size 1)
      0.0
    (/ (float offset) (float (1- size)))))

(defun emacs-canvas-color-picker--hit-test (geometry x y)
  "Return palette hit information for GEOMETRY at X and Y, or nil."
  (let ((sv-left (emacs-canvas-color-picker--geometry-sv-left geometry))
        (sv-top (emacs-canvas-color-picker--geometry-sv-top geometry))
        (sv-width (emacs-canvas-color-picker--geometry-sv-width geometry))
        (sv-height (emacs-canvas-color-picker--geometry-sv-height geometry))
        (hue-left (emacs-canvas-color-picker--geometry-hue-left geometry))
        (hue-top (emacs-canvas-color-picker--geometry-hue-top geometry))
        (hue-width (emacs-canvas-color-picker--geometry-hue-width geometry))
        (hue-height (emacs-canvas-color-picker--geometry-hue-height geometry)))
    (cond
     ((emacs-canvas-color-picker--within-rect-p x y sv-left sv-top sv-width sv-height)
      (list :region 'sv
            :s (emacs-canvas-color-picker--position-fraction (- x sv-left) sv-width)
            :v (- 1.0 (emacs-canvas-color-picker--position-fraction (- y sv-top) sv-height))))
     ((emacs-canvas-color-picker--within-rect-p x y hue-left hue-top hue-width hue-height)
      (list :region 'hue
            :h (emacs-canvas-color-picker--position-fraction (- y hue-top) hue-height))))))

(defun emacs-canvas-color-picker-load-native (&optional noerror)
  "Load the native color picker renderer.

When NOERROR is non-nil, return nil instead of signaling load errors."
  (interactive)
  (cond
   (emacs-canvas-color-picker--native-loaded t)
   ((not emacs-canvas-color-picker-use-native) nil)
   ((not (file-exists-p emacs-canvas-color-picker-native-module-file))
    (unless noerror
      (user-error "Native color picker module does not exist: %s"
                  emacs-canvas-color-picker-native-module-file))
    nil)
   (t
    (condition-case error
        (progn
          (module-load emacs-canvas-color-picker-native-module-file)
          (setq emacs-canvas-color-picker--native-loaded t))
      (error
       (unless noerror
         (signal (car error) (cdr error)))
       nil)))))

(defun emacs-canvas-color-picker--native-available-p ()
  "Return non-nil when native rendering is available."
  (and (emacs-canvas-color-picker-load-native t)
       (fboundp 'emacs-canvas-color-picker-native-render-full)))

(defun emacs-canvas-color-picker--pixel-index (geometry x y)
  "Return vector index for GEOMETRY pixel X Y."
  (+ x (* y (emacs-canvas-color-picker--geometry-width geometry))))

(defun emacs-canvas-color-picker--set-pixel (data geometry x y color)
  "Set DATA pixel for GEOMETRY at X Y to COLOR when inside bounds."
  (when (and (>= x 0)
             (< x (emacs-canvas-color-picker--geometry-width geometry))
             (>= y 0)
             (< y (emacs-canvas-color-picker--geometry-height geometry)))
    (aset data (emacs-canvas-color-picker--pixel-index geometry x y) color)))

(defun emacs-canvas-color-picker--draw-circle-outline (data geometry cx cy radius color)
  "Draw a circle outline in DATA at CX CY with RADIUS and COLOR."
  (let ((r2 (* radius radius))
        (inner2 (* (max 0 (1- radius)) (max 0 (1- radius)))))
    (dotimes (dy (1+ (* 2 radius)))
      (dotimes (dx (1+ (* 2 radius)))
        (let* ((x (+ cx (- dx radius)))
               (y (+ cy (- dy radius)))
               (local-x (- x cx))
               (local-y (- y cy))
               (distance2 (+ (* local-x local-x) (* local-y local-y))))
          (when (and (<= distance2 r2) (> distance2 inner2))
            (emacs-canvas-color-picker--set-pixel data geometry x y color)))))))

(defun emacs-canvas-color-picker--draw-horizontal-line (data geometry x1 x2 y color)
  "Draw a horizontal line from X1 to X2 at Y with COLOR."
  (let ((start (min x1 x2))
        (end (max x1 x2)))
    (dotimes (offset (1+ (- end start)))
      (emacs-canvas-color-picker--set-pixel data geometry (+ start offset) y color))))

(defun emacs-canvas-color-picker--fill-rect (data geometry left top width height color)
  "Fill rectangle LEFT TOP WIDTH HEIGHT in DATA with COLOR."
  (dotimes (y height)
    (dotimes (x width)
      (emacs-canvas-color-picker--set-pixel data geometry (+ left x) (+ top y) color))))

(defun emacs-canvas-color-picker--hsv-pixel (hue saturation value)
  "Return an opaque ARGB pixel for HUE SATURATION VALUE."
  (apply #'emacs-canvas-color-picker--argb
         (emacs-canvas-color-picker--hsv-to-rgb hue saturation value)))

(defun emacs-canvas-color-picker--draw-swatches (data geometry hue saturation value initial-hue initial-saturation initial-value)
  "Draw new and current color swatches."
  (let ((top (emacs-canvas-color-picker--geometry-swatch-top geometry))
        (width (emacs-canvas-color-picker--geometry-swatch-width geometry))
        (height (emacs-canvas-color-picker--geometry-swatch-height geometry)))
    (emacs-canvas-color-picker--fill-rect
     data geometry
     (emacs-canvas-color-picker--geometry-new-swatch-left geometry)
     top width height
     (emacs-canvas-color-picker--hsv-pixel hue saturation value))
    (emacs-canvas-color-picker--fill-rect
     data geometry
     (emacs-canvas-color-picker--geometry-current-swatch-left geometry)
     top width height
     (emacs-canvas-color-picker--hsv-pixel initial-hue initial-saturation initial-value))))

(defun emacs-canvas-color-picker--draw-selection-markers (data geometry hue saturation value)
  "Draw selection markers into DATA for GEOMETRY and HSV values."
  (let* ((sv-left (emacs-canvas-color-picker--geometry-sv-left geometry))
         (sv-top (emacs-canvas-color-picker--geometry-sv-top geometry))
         (sv-width (emacs-canvas-color-picker--geometry-sv-width geometry))
         (sv-height (emacs-canvas-color-picker--geometry-sv-height geometry))
         (hue-left (emacs-canvas-color-picker--geometry-hue-left geometry))
         (hue-top (emacs-canvas-color-picker--geometry-hue-top geometry))
         (hue-width (emacs-canvas-color-picker--geometry-hue-width geometry))
         (hue-height (emacs-canvas-color-picker--geometry-hue-height geometry))
         (radius (or (emacs-canvas-color-picker--geometry-marker-radius geometry) 5))
         (s (emacs-canvas-color-picker--clamp01 saturation))
         (v (emacs-canvas-color-picker--clamp01 value))
         (h (mod (float hue) 1.0))
         (sv-x (+ sv-left (round (* s (max 0 (1- sv-width))))))
         (sv-y (+ sv-top (round (* (- 1.0 v) (max 0 (1- sv-height))))))
         (hue-y (+ hue-top (round (* h (max 0 (1- hue-height)))))))
    (emacs-canvas-color-picker--draw-circle-outline data geometry sv-x sv-y radius emacs-canvas-color-picker--marker-black)
    (emacs-canvas-color-picker--draw-circle-outline data geometry sv-x sv-y (max 0 (1- radius)) emacs-canvas-color-picker--marker-white)
    (emacs-canvas-color-picker--draw-horizontal-line
     data geometry (1- hue-left) (+ hue-left hue-width) hue-y emacs-canvas-color-picker--marker-black)
    (emacs-canvas-color-picker--draw-horizontal-line
     data geometry hue-left (1- (+ hue-left hue-width)) hue-y emacs-canvas-color-picker--marker-white)))

(defun emacs-canvas-color-picker--validate-data-size (data geometry)
  "Signal an error unless DATA length matches GEOMETRY."
  (let ((expected-size (* (emacs-canvas-color-picker--geometry-width geometry)
                         (emacs-canvas-color-picker--geometry-height geometry))))
    (unless (= (length data) expected-size)
      (error "Palette vector size does not match geometry"))))

(defun emacs-canvas-color-picker--blend-channel (base white-factor black-factor)
  "Blend one BASE color channel with white and black factors."
  (let* ((toward-white (+ base (/ (* (- 255 base) white-factor) 255)))
         (toward-black (/ (* toward-white black-factor) 255)))
    (emacs-canvas-color-picker--clamp-byte toward-black)))

(defun emacs-canvas-color-picker--draw-base-palette (data geometry hue)
  "Draw the marker-free base palette for HUE into DATA."
  (emacs-canvas-color-picker--validate-data-size data geometry)
  (dotimes (index (length data))
    (aset data index emacs-canvas-color-picker--background))
  (let* ((sv-left (emacs-canvas-color-picker--geometry-sv-left geometry))
         (sv-top (emacs-canvas-color-picker--geometry-sv-top geometry))
         (sv-width (emacs-canvas-color-picker--geometry-sv-width geometry))
         (sv-height (emacs-canvas-color-picker--geometry-sv-height geometry))
         (hue-left (emacs-canvas-color-picker--geometry-hue-left geometry))
         (hue-top (emacs-canvas-color-picker--geometry-hue-top geometry))
         (hue-width (emacs-canvas-color-picker--geometry-hue-width geometry))
         (hue-height (emacs-canvas-color-picker--geometry-hue-height geometry))
         (hue-rgb (emacs-canvas-color-picker--hsv-to-rgb hue 1.0 1.0))
         (hue-red (nth 0 hue-rgb))
         (hue-green (nth 1 hue-rgb))
         (hue-blue (nth 2 hue-rgb)))
    (dotimes (y sv-height)
      (let ((black-factor (if (<= sv-height 1)
                              255
                            (- 255 (/ (* y 255) (1- sv-height))))))
        (dotimes (x sv-width)
          (let* ((white-factor (if (<= sv-width 1)
                                   0
                                 (- 255 (/ (* x 255) (1- sv-width)))))
                 (red (emacs-canvas-color-picker--blend-channel hue-red white-factor black-factor))
                 (green (emacs-canvas-color-picker--blend-channel hue-green white-factor black-factor))
                 (blue (emacs-canvas-color-picker--blend-channel hue-blue white-factor black-factor)))
            (emacs-canvas-color-picker--set-pixel
             data geometry (+ sv-left x) (+ sv-top y)
             (emacs-canvas-color-picker--argb red green blue))))))
    (dotimes (y hue-height)
      (let* ((h (emacs-canvas-color-picker--position-fraction y hue-height))
             (rgb (emacs-canvas-color-picker--hsv-to-rgb h 1.0 1.0))
             (pixel (apply #'emacs-canvas-color-picker--argb rgb)))
        (dotimes (x hue-width)
          (emacs-canvas-color-picker--set-pixel
           data geometry (+ hue-left x) (+ hue-top y) pixel))))))

(defun emacs-canvas-color-picker--copy-vector (destination source)
  "Copy SOURCE vector contents into DESTINATION."
  (dotimes (index (length source))
    (aset destination index (aref source index))))

(defun emacs-canvas-color-picker--refresh-markers
    (data base-data geometry hue saturation value &optional initial-hue initial-saturation initial-value)
  "Copy BASE-DATA into DATA and draw selection markers and swatches."
  (emacs-canvas-color-picker--validate-data-size data geometry)
  (emacs-canvas-color-picker--validate-data-size base-data geometry)
  (emacs-canvas-color-picker--copy-vector data base-data)
  (emacs-canvas-color-picker--draw-selection-markers data geometry hue saturation value)
  (emacs-canvas-color-picker--draw-swatches
   data geometry hue saturation value
   (or initial-hue hue)
   (or initial-saturation saturation)
   (or initial-value value)))

(defun emacs-canvas-color-picker--native-render-full
    (canvas geometry hue saturation value &optional initial-hue initial-saturation initial-value)
  "Render full picker into CANVAS through the native renderer."
  (and (emacs-canvas-color-picker--native-available-p)
       (emacs-canvas-color-picker-native-render-full
        canvas
        (emacs-canvas-color-picker--geometry-width geometry)
        (emacs-canvas-color-picker--geometry-height geometry)
        (float hue)
        (float saturation)
        (float value)
        (emacs-canvas-color-picker--geometry-padding geometry)
        (emacs-canvas-color-picker--geometry-gap geometry)
        (emacs-canvas-color-picker--geometry-hue-width geometry)
        (emacs-canvas-color-picker--geometry-swatch-width geometry)
        (emacs-canvas-color-picker--geometry-swatch-height geometry)
        (emacs-canvas-color-picker--geometry-swatch-gap geometry)
        (emacs-canvas-color-picker--geometry-marker-radius geometry)
        (float (or initial-hue hue))
        (float (or initial-saturation saturation))
        (float (or initial-value value)))))

(defun emacs-canvas-color-picker--draw-palette
    (data geometry hue saturation value &optional canvas initial-hue initial-saturation initial-value)
  "Draw the palette for HUE, SATURATION, and VALUE into DATA.

When CANVAS is non-nil and the native module is loaded, render through the
native module. Otherwise use the pure Elisp renderer."
  (unless (and canvas
               (emacs-canvas-color-picker--native-render-full
                canvas geometry hue saturation value initial-hue initial-saturation initial-value))
    (let ((base-data (make-vector (length data) nil)))
      (emacs-canvas-color-picker--draw-base-palette base-data geometry hue)
      (emacs-canvas-color-picker--refresh-markers
       data base-data geometry hue saturation value initial-hue initial-saturation initial-value))))

(defun emacs-canvas-color-picker--hex-at-point ()
  "Return a hex color near point, or nil."
  (let ((bounds (bounds-of-thing-at-point 'symbol)))
    (when bounds
      (let ((text (buffer-substring-no-properties (car bounds) (cdr bounds))))
        (when (string-match-p "\\`#?[[:xdigit:]]\\{6\\}\\'" text)
          text)))))

(defun emacs-canvas-color-picker--initial-hsv (initial-color)
  "Return initial HSV from INITIAL-COLOR or defaults."
  (emacs-canvas-color-picker--hex-to-hsv
   (or initial-color
       (emacs-canvas-color-picker--hex-at-point)
       emacs-canvas-color-picker-default-color)))

(defun emacs-canvas-color-picker--current-hex (state)
  "Return current hex color for STATE."
  (apply #'emacs-canvas-color-picker--rgb-to-hex
         (emacs-canvas-color-picker--hsv-to-rgb
          (emacs-canvas-color-picker--state-hue state)
          (emacs-canvas-color-picker--state-saturation state)
          (emacs-canvas-color-picker--state-value state))))

(defun emacs-canvas-color-picker--status-text (state)
  "Return status text for STATE."
  (format "%s    RET accept, q cancel" (emacs-canvas-color-picker--current-hex state)))

(defun emacs-canvas-color-picker--update-status (state)
  "Update the status line for STATE."
  (when-let* ((marker (emacs-canvas-color-picker--state-status-marker state))
              (buffer (marker-buffer marker)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (start (marker-position marker)))
        (save-excursion
          (goto-char start)
          (delete-region start (line-end-position))
          (insert (emacs-canvas-color-picker--status-text state))
          (set-marker marker start buffer))))))

(defun emacs-canvas-color-picker--native-refresh (state rebuild-base)
  "Refresh STATE through native rendering when possible."
  (when (emacs-canvas-color-picker--native-available-p)
    (let* ((geometry (emacs-canvas-color-picker--state-geometry state))
           (width (emacs-canvas-color-picker--geometry-width geometry))
           (height (emacs-canvas-color-picker--geometry-height geometry))
           (hue (float (emacs-canvas-color-picker--state-hue state)))
           (saturation (float (emacs-canvas-color-picker--state-saturation state)))
           (value (float (emacs-canvas-color-picker--state-value state)))
           (base-canvas (emacs-canvas-color-picker--state-base-canvas state))
           (canvas (emacs-canvas-color-picker--state-canvas state))
           (padding (emacs-canvas-color-picker--geometry-padding geometry))
           (gap (emacs-canvas-color-picker--geometry-gap geometry))
           (hue-width (emacs-canvas-color-picker--geometry-hue-width geometry))
           (swatch-width (emacs-canvas-color-picker--geometry-swatch-width geometry))
           (swatch-height (emacs-canvas-color-picker--geometry-swatch-height geometry))
           (swatch-gap (emacs-canvas-color-picker--geometry-swatch-gap geometry))
           (marker-radius (emacs-canvas-color-picker--geometry-marker-radius geometry)))
      (when rebuild-base
        (emacs-canvas-color-picker-native-render-base
         base-canvas width height hue padding gap hue-width swatch-width swatch-height swatch-gap marker-radius))
      (emacs-canvas-color-picker-native-render-full
       canvas width height hue saturation value padding gap hue-width swatch-width swatch-height swatch-gap marker-radius
       (float (or (emacs-canvas-color-picker--state-initial-hue state) hue))
       (float (or (emacs-canvas-color-picker--state-initial-saturation state) saturation))
       (float (or (emacs-canvas-color-picker--state-initial-value state) value))))))

(defun emacs-canvas-color-picker--refresh (state &optional rebuild-base)
  "Redraw and refresh STATE.

When REBUILD-BASE is non-nil, regenerate the marker-free base palette."
  (let ((native-rendered (emacs-canvas-color-picker--native-refresh state rebuild-base)))
    (emacs-canvas-color-picker--trace
     "refresh-render"
     :native native-rendered
     :rebuild-base rebuild-base
     :hue (emacs-canvas-color-picker--state-hue state)
     :saturation (emacs-canvas-color-picker--state-saturation state)
     :value (emacs-canvas-color-picker--state-value state))
    (unless native-rendered
      (when rebuild-base
        (emacs-canvas-color-picker--draw-base-palette
         (emacs-canvas-color-picker--state-base-data state)
         (emacs-canvas-color-picker--state-geometry state)
         (emacs-canvas-color-picker--state-hue state)))
      (emacs-canvas-color-picker--refresh-markers
       (emacs-canvas-color-picker--state-data state)
       (emacs-canvas-color-picker--state-base-data state)
       (emacs-canvas-color-picker--state-geometry state)
       (emacs-canvas-color-picker--state-hue state)
       (emacs-canvas-color-picker--state-saturation state)
       (emacs-canvas-color-picker--state-value state)
       (emacs-canvas-color-picker--state-initial-hue state)
       (emacs-canvas-color-picker--state-initial-saturation state)
       (emacs-canvas-color-picker--state-initial-value state)))
    (when (fboundp 'canvas-refresh)
      (let ((reload-data (and (not native-rendered) t)))
        (emacs-canvas-color-picker--trace
         "canvas-refresh"
         :reload-data reload-data)
        (canvas-refresh (emacs-canvas-color-picker--state-canvas state)
                        reload-data)))))

(defun emacs-canvas-color-picker--apply-hit (state hit)
  "Apply HIT to STATE and refresh the picker."
  (let ((rebuild-base nil))
    (pcase (plist-get hit :region)
      ('sv
       (setf (emacs-canvas-color-picker--state-saturation state) (plist-get hit :s)
             (emacs-canvas-color-picker--state-value state) (plist-get hit :v)))
      ('hue
       (setf (emacs-canvas-color-picker--state-hue state) (plist-get hit :h)
             rebuild-base t)))
    (emacs-canvas-color-picker--refresh state rebuild-base)
    (emacs-canvas-color-picker--update-status state)))

(defun emacs-canvas-color-picker--event-position (event)
  "Return the position to use for mouse EVENT."
  (let ((end (event-end event)))
    (if (and end (posn-object-x-y end))
        end
      (event-start event))))

(defun emacs-canvas-color-picker--event-coordinates (event)
  "Return canvas-relative coordinates from mouse EVENT, or nil."
  (let* ((position (emacs-canvas-color-picker--event-position event))
         (object-x-y (and position (posn-object-x-y position)))
         (coordinates (when (and (consp object-x-y)
                                 (numberp (car object-x-y))
                                 (numberp (cdr object-x-y)))
                        (cons (truncate (car object-x-y))
                              (truncate (cdr object-x-y))))))
    (emacs-canvas-color-picker--trace
     "event-coordinates"
     :event-type (car-safe event)
     :object-x-y object-x-y
     :coordinates coordinates)
    coordinates))

(defun emacs-canvas-color-picker--state-for-event (event)
  "Return color picker state associated with EVENT."
  (let* ((position (event-start event))
         (window (and position (posn-window position)))
         (buffer (and (windowp window) (window-buffer window))))
    (or (and (buffer-live-p buffer)
             (buffer-local-value 'emacs-canvas-color-picker--state buffer))
        emacs-canvas-color-picker--state)))

(defun emacs-canvas-color-picker--handle-coordinates (state coordinates)
  "Handle canvas-relative COORDINATES for STATE."
  (let ((hit (emacs-canvas-color-picker--hit-test
              (emacs-canvas-color-picker--state-geometry state)
              (car coordinates)
              (cdr coordinates))))
    (emacs-canvas-color-picker--trace
     "handle-coordinates"
     :coordinates coordinates
     :hit hit)
    (when hit
      (emacs-canvas-color-picker--apply-hit state hit))))

(defun emacs-canvas-color-picker--handle-event (state event)
  "Handle mouse EVENT for STATE."
  (when-let* ((coordinates (emacs-canvas-color-picker--event-coordinates event)))
    (emacs-canvas-color-picker--handle-coordinates state coordinates)))

(defun emacs-canvas-color-picker--status-pixel-height (window)
  "Return the status line height in pixels for WINDOW."
  (frame-char-height (window-frame window)))

(defun emacs-canvas-color-picker--current-pointer-coordinates (window)
  "Return current mouse coordinates relative to the picker canvas in WINDOW."
  (when (and (window-live-p window)
             (fboundp 'mouse-pixel-position))
    (let* ((mouse (mouse-pixel-position))
           (frame (car-safe mouse))
           (position (cdr-safe mouse))
           (x (cond
               ((and (consp position) (numberp (car position))) (car position))
               (t (cadr mouse))))
           (y (cond
               ((and (consp position) (numberp (cdr position))) (cdr position))
               ((and (consp position) (numberp (cadr position))) (cadr position))
               (t (caddr mouse))))
           (edges (window-inside-pixel-edges window))
           (left (nth 0 edges))
           (top (nth 1 edges))
           (coordinates (when (and (or (not frame) (eq frame (window-frame window)))
                                   (numberp x)
                                   (numberp y)
                                   (numberp left)
                                   (numberp top))
                          (cons (- x left)
                                (- y top (emacs-canvas-color-picker--status-pixel-height window))))))
      (emacs-canvas-color-picker--trace
       "current-pointer"
       :raw mouse
       :frame frame
       :x x
       :y y
       :edges edges
       :coordinates coordinates)
      coordinates)))

(defun emacs-canvas-color-picker--track-current-pointer (state window &optional last-coordinates)
  "Update STATE from the current mouse pointer in WINDOW.

When LAST-COORDINATES is non-nil, skip the update if the pointer did not move.
Return the current coordinates when they are available."
  (when-let* ((coordinates (emacs-canvas-color-picker--current-pointer-coordinates window)))
    (emacs-canvas-color-picker--trace
     "track-current-pointer"
     :coordinates coordinates
     :last-coordinates last-coordinates
     :changed (not (equal coordinates last-coordinates)))
    (unless (equal coordinates last-coordinates)
      (emacs-canvas-color-picker--handle-coordinates state coordinates))
    coordinates))

(defun emacs-canvas-color-picker--accept (&optional state)
  "Accept the current color for STATE."
  (interactive)
  (let ((state (or state emacs-canvas-color-picker--state)))
    (when (and state (not (emacs-canvas-color-picker--state-done state)))
      (setf (emacs-canvas-color-picker--state-done state) t)
      (let ((callback (emacs-canvas-color-picker--state-callback state))
            (hex (emacs-canvas-color-picker--current-hex state)))
        (emacs-canvas-color-picker--cleanup state)
        (funcall callback hex)))))

(defun emacs-canvas-color-picker--cancel (&optional state)
  "Cancel color picker STATE."
  (interactive)
  (let ((state (or state emacs-canvas-color-picker--state)))
    (when state
      (setf (emacs-canvas-color-picker--state-done state) t)
      (emacs-canvas-color-picker--cleanup state))))

(defun emacs-canvas-color-picker--cleanup (state)
  "Delete frame and buffer resources for STATE."
  (let ((frame (emacs-canvas-color-picker--state-frame state))
        (buffer (emacs-canvas-color-picker--state-buffer state)))
    (when (frame-live-p frame)
      (delete-frame frame t))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setq emacs-canvas-color-picker--state nil)))))

(defun emacs-canvas-color-picker--mouse-click (event)
  "Handle single click EVENT."
  (interactive "e")
  (when-let* ((state (emacs-canvas-color-picker--state-for-event event)))
    (emacs-canvas-color-picker--handle-event state event)))

(defun emacs-canvas-color-picker--mouse-drag (event)
  "Handle drag EVENT."
  (interactive "e")
  (when-let* ((state (emacs-canvas-color-picker--state-for-event event)))
    (emacs-canvas-color-picker--handle-event state event)))

(defun emacs-canvas-color-picker--mouse-down (event)
  "Track a color picker mouse gesture from down EVENT."
  (interactive "e")
  (emacs-canvas-color-picker--trace "mouse-down" :event-data (emacs-canvas-color-picker--trace-event event))
  (when-let* ((state (emacs-canvas-color-picker--state-for-event event)))
    (emacs-canvas-color-picker--handle-event state event)
    (let ((mouse-fine-grained-tracking t)
          (tracking-window (posn-window (event-start event)))
          (last-coordinates nil))
      (track-mouse
        (catch 'done
          (while (not (emacs-canvas-color-picker--state-done state))
            (emacs-canvas-color-picker--trace
             "drag-poll-before-read"
             :last-coordinates last-coordinates)
            (setq last-coordinates
                  (or (emacs-canvas-color-picker--track-current-pointer
                       state tracking-window last-coordinates)
                      last-coordinates))
            (let ((next-event (read-event nil nil 0.02)))
              (emacs-canvas-color-picker--trace
               "drag-read-event"
               :event-data (and next-event (emacs-canvas-color-picker--trace-event next-event)))
              (cond
               ((null next-event)
                nil)
               ((memq (car-safe next-event) '(mouse-movement switch-frame))
                nil)
               ((memq (car-safe next-event) '(mouse-1 drag-mouse-1))
                (emacs-canvas-color-picker--trace "drag-release" :event-data (emacs-canvas-color-picker--trace-event next-event))
                (emacs-canvas-color-picker--handle-event state next-event)
                (throw 'done t))
               (t
                (emacs-canvas-color-picker--trace "drag-unread" :event-data (emacs-canvas-color-picker--trace-event next-event))
                (push next-event unread-command-events)
                (throw 'done nil))))))))))

(defun emacs-canvas-color-picker--make-canvas (geometry data)
  "Return a canvas image spec for GEOMETRY and DATA."
  (list 'image
        :type 'canvas
        :id (gensym "emacs-canvas-color-picker-")
        :data-width (emacs-canvas-color-picker--geometry-width geometry)
        :data-height (emacs-canvas-color-picker--geometry-height geometry)
        :data data))

(defun emacs-canvas-color-picker--display-string (canvas)
  "Return the display string for CANVAS."
  (propertize " "
              'display canvas
              'local-map emacs-canvas-color-picker--mouse-map
              'pointer 'arrow
              'rear-nonsticky t))

(defun emacs-canvas-color-picker--setup-buffer (state)
  "Prepare the picker buffer for STATE."
  (let ((buffer (emacs-canvas-color-picker--state-buffer state))
        (canvas (emacs-canvas-color-picker--state-canvas state)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (setq-local emacs-canvas-color-picker--state state
                    cursor-type nil
                    mode-line-format nil
                    truncate-lines t)
        (use-local-map (let ((map (make-sparse-keymap)))
                         (define-key map (kbd "RET") #'emacs-canvas-color-picker--accept)
                         (define-key map (kbd "C-m") #'emacs-canvas-color-picker--accept)
                         (define-key map (kbd "C-c C-c") #'emacs-canvas-color-picker--accept)
                         (define-key map (kbd "C-g") #'emacs-canvas-color-picker--cancel)
                         (define-key map (kbd "q") #'emacs-canvas-color-picker--cancel)
                         (define-key map (kbd "<escape>") #'emacs-canvas-color-picker--cancel)
                         (define-key map (kbd "C-c C-k") #'emacs-canvas-color-picker--cancel)
                         map))
        (let ((status-start (point)))
          (insert (emacs-canvas-color-picker--status-text state) "\n")
          (setf (emacs-canvas-color-picker--state-status-marker state)
                (copy-marker status-start nil)))
        (insert (emacs-canvas-color-picker--display-string canvas))
        (goto-char (point-min))
        (setq buffer-read-only t)
        (set-buffer-modified-p nil)))))

(defun emacs-canvas-color-picker--frame-size (geometry parent-frame)
  "Return child-frame pixel size for GEOMETRY and PARENT-FRAME."
  (cons (emacs-canvas-color-picker--geometry-width geometry)
        (+ (emacs-canvas-color-picker--geometry-height geometry)
           (frame-char-height parent-frame)
           ;; The child frame can be one pixel shorter than its requested height.
           1)))

(defun emacs-canvas-color-picker--frame-position (parent width height)
  "Return a child-frame position inside PARENT for WIDTH and HEIGHT."
  (let* ((parent-width (frame-pixel-width parent))
         (parent-height (frame-pixel-height parent))
         (left (max 0 (min (- parent-width width) 40)))
         (top (max 0 (min (- parent-height height) 40))))
    (cons left top)))

(defun emacs-canvas-color-picker--focus-frame (frame)
  "Select FRAME and its root window for keyboard input."
  (when (frame-live-p frame)
    (select-frame-set-input-focus frame)
    (select-window (frame-root-window frame))))

(defun emacs-canvas-color-picker--set-window-minimal-fringes (window buffer)
  "Use minimal fringes for WINDOW when it displays BUFFER."
  (when (and (window-live-p window)
             (not (window-minibuffer-p window))
             (eq (window-buffer window) buffer))
    (set-window-fringes window 1 1 nil)))

(defun emacs-canvas-color-picker--frame-parameters (parent width height left top)
  "Return child frame parameters for PARENT and geometry WIDTH HEIGHT LEFT TOP."
  `((parent-frame . ,parent)
    (minibuffer . nil)
    (undecorated . t)
    (vertical-scroll-bars . nil)
    (horizontal-scroll-bars . nil)
    (menu-bar-lines . 0)
    (tool-bar-lines . 0)
    (internal-border-width . 0)
    (left . ,left)
    (top . ,top)
    (width . (text-pixels . ,width))
    (height . (text-pixels . ,height))))

(defun emacs-canvas-color-picker--make-frame (state)
  "Create and show a child frame for STATE."
  (let* ((geometry (emacs-canvas-color-picker--state-geometry state))
         (parent (emacs-canvas-color-picker--state-parent-frame state))
         (frame-size (emacs-canvas-color-picker--frame-size geometry parent))
         (width (car frame-size))
         (height (cdr frame-size))
         (position (emacs-canvas-color-picker--frame-position parent width height))
         (frame (make-frame
                 (emacs-canvas-color-picker--frame-parameters
                  parent width height (car position) (cdr position)))))
    (setf (emacs-canvas-color-picker--state-frame state) frame)
    (set-window-buffer (frame-root-window frame)
                       (emacs-canvas-color-picker--state-buffer state))
    (emacs-canvas-color-picker--set-window-minimal-fringes
     (frame-root-window frame)
     (emacs-canvas-color-picker--state-buffer state))
    (emacs-canvas-color-picker--focus-frame frame)
    frame))

(defun emacs-canvas-color-picker--ensure-canvas-available ()
  "Signal a user error unless canvas images are available."
  (unless (and (display-graphic-p) (image-type-available-p 'canvas))
    (user-error "Emacs 32 canvas support in a graphical frame is required")))

(defun emacs-canvas-color-picker--open-state (state)
  "Open the color picker for STATE."
  (emacs-canvas-color-picker--ensure-canvas-available)
  (emacs-canvas-color-picker--refresh state t)
  (emacs-canvas-color-picker--setup-buffer state)
  (emacs-canvas-color-picker--make-frame state)
  state)

(defun emacs-canvas-color-picker--make-state (callback &optional initial-color buffer)
  "Return a new picker state for CALLBACK and INITIAL-COLOR."
  (unless (functionp callback)
    (error "Callback must be callable"))
  (let* ((hsv (emacs-canvas-color-picker--initial-hsv initial-color))
         (parent-frame (selected-frame))
         (geometry (emacs-canvas-color-picker--make-geometry nil parent-frame))
         (data (make-vector (* (emacs-canvas-color-picker--geometry-width geometry)
                               (emacs-canvas-color-picker--geometry-height geometry))
                            emacs-canvas-color-picker--background))
         (base-data (make-vector (length data) emacs-canvas-color-picker--background))
         (canvas (emacs-canvas-color-picker--make-canvas geometry data))
         (base-canvas (emacs-canvas-color-picker--make-canvas geometry base-data))
         (buffer (or buffer (get-buffer-create emacs-canvas-color-picker--buffer-name))))
    (emacs-canvas-color-picker--state-create
     :parent-frame parent-frame
     :buffer buffer
     :canvas canvas
     :base-canvas base-canvas
     :data data
     :base-data base-data
     :geometry geometry
     :hue (nth 0 hsv)
     :saturation (nth 1 hsv)
     :value (nth 2 hsv)
     :initial-hue (nth 0 hsv)
     :initial-saturation (nth 1 hsv)
     :initial-value (nth 2 hsv)
     :callback callback
     :done nil)))

;;;###autoload
(defun emacs-canvas-color-picker-read-color (callback &optional initial-color)
  "Open a canvas color picker and call CALLBACK with the selected color.

INITIAL-COLOR, when non-nil, must be a string in #RRGGBB or RRGGBB form."
  (emacs-canvas-color-picker--open-state
   (emacs-canvas-color-picker--make-state callback initial-color)))

(defun emacs-canvas-color-picker--hex-token-char-p (char)
  "Return non-nil when CHAR belongs to an alphanumeric token."
  (and char (string-match-p "[[:alnum:]]" (char-to-string char))))

(defun emacs-canvas-color-picker--hex-boundary-before-p (position)
  "Return non-nil when the character before POSITION is not alphanumeric."
  (or (<= position (point-min))
      (not (emacs-canvas-color-picker--hex-token-char-p (char-before position)))))

(defun emacs-canvas-color-picker--hex-boundary-after-p (position)
  "Return non-nil when the character after POSITION is not alphanumeric."
  (or (>= position (point-max))
      (not (emacs-canvas-color-picker--hex-token-char-p (char-after position)))))

(defun emacs-canvas-color-picker--hex-at-point-bounds ()
  "Return plist for a complete hex color at point, or nil."
  (let ((pos (point))
        result)
    (save-excursion
      (goto-char (point-min))
      (while (and (not result)
                  (re-search-forward
                   "\\(?:#x[[:xdigit:]]\\{8\\}\\|#x[[:xdigit:]]\\{6\\}\\|0x[[:xdigit:]]\\{6\\}\\|#[[:xdigit:]]\\{8\\}\\|#[[:xdigit:]]\\{6\\}\\|[[:xdigit:]]\\{6\\}\\)"
                   nil t))
        (let* ((start (match-beginning 0))
               (end (match-end 0))
               (text (match-string 0)))
          (when (and (>= pos start)
                     (< pos end)
                     (emacs-canvas-color-picker--hex-boundary-before-p start)
                     (emacs-canvas-color-picker--hex-boundary-after-p end))
            (let* ((emacs-hex (string-prefix-p "#x" text))
                   (c-hex (string-prefix-p "0x" text))
                   (css-hex (and (not emacs-hex) (string-prefix-p "#" text)))
                   (alpha (cond ((and emacs-hex (= (length text) 10)) (substring text 2 4))
                                ((and css-hex (= (length text) 9)) (substring text 7 9))))
                   (rgb (cond ((and emacs-hex alpha) (substring text 4))
                              ((or emacs-hex c-hex) (substring text 2))
                              (css-hex (substring text 1 7))
                              (t text)))
                   (format (cond ((and emacs-hex alpha) 'emacs-argb)
                                 (emacs-hex 'emacs-rgb)
                                 (c-hex 'c-rgb)
                                 (alpha 'css-rgba)
                                 (css-hex 'css-rgb)
                                 (t 'bare))))
              (setq result (list :start start :end end :text text
                                 :prefixed css-hex :rgb rgb :alpha alpha
                                 :format format)))))))
    result))

(defun emacs-canvas-color-picker--validate-output-format (format)
  "Signal an error unless FORMAT names a supported output format."
  (unless (memq format '(nil css-rgb css-rgba emacs-argb emacs-rgb c-rgb))
    (error "Unsupported color output format: %S" format)))

(defun emacs-canvas-color-picker--format-hex (hex format &optional alpha)
  "Format selected HEX in FORMAT, preserving existing ALPHA when supplied."
  (let ((rgb (substring hex 1)))
    (pcase format
      ((or 'nil 'css-rgb) hex)
      ('bare rgb)
      ('css-rgba (concat hex (or alpha "ff")))
      ('emacs-argb (concat "#x" (or alpha "ff") rgb))
      ('emacs-rgb (concat "#x" rgb))
      ('c-rgb (concat "0x" rgb))
      (_ (error "Unsupported color output format: %S" format)))))

(defun emacs-canvas-color-picker--make-insert-state (target-buffer &optional initial-color output-format)
  "Return insert-only picker state for TARGET-BUFFER."
  (let ((marker (copy-marker (point) t)))
    (emacs-canvas-color-picker--make-state
     (lambda (hex)
       (when (buffer-live-p target-buffer)
         (with-current-buffer target-buffer
           (save-excursion
             (goto-char marker)
             (insert (emacs-canvas-color-picker--format-hex hex output-format)))))
       (set-marker marker nil))
     initial-color)))

(defun emacs-canvas-color-picker--make-at-point-state (target-buffer)
  "Return at-point picker state for TARGET-BUFFER."
  (let* ((match (emacs-canvas-color-picker--hex-at-point-bounds))
         (initial-color (and match (plist-get match :rgb)))
         (insert-marker (copy-marker (point) t))
         (state (emacs-canvas-color-picker--make-state
                 (lambda (hex)
                   (when (buffer-live-p target-buffer)
                     (with-current-buffer target-buffer
                       (save-excursion
                         (if match
                             (progn
                               (goto-char (plist-get match :start))
                               (delete-region (plist-get match :start) (plist-get match :end))
                               (insert (emacs-canvas-color-picker--format-hex
                                        hex (plist-get match :format)
                                        (plist-get match :alpha))))
                           (goto-char insert-marker)
                           (insert hex)))))
                   (set-marker insert-marker nil))
                 initial-color)))
    (when match
      (setf (emacs-canvas-color-picker--state-replace-start state) (plist-get match :start)
            (emacs-canvas-color-picker--state-replace-end state) (plist-get match :end)
            (emacs-canvas-color-picker--state-replace-prefixed state) (plist-get match :prefixed)))
    state))

;;;###autoload
(defun emacs-canvas-color-picker-copy (&optional initial-color output-format)
  "Open the color picker and copy the selected hex color.

INITIAL-COLOR, when non-nil, must be a string in #RRGGBB or RRGGBB form.
OUTPUT-FORMAT selects `css-rgb', `css-rgba', `emacs-argb',
`emacs-rgb', or `c-rgb'; nil uses `css-rgb'."
  (interactive)
  (emacs-canvas-color-picker--validate-output-format output-format)
  (emacs-canvas-color-picker-read-color
   (lambda (hex)
     (let ((formatted (emacs-canvas-color-picker--format-hex hex output-format)))
       (kill-new formatted)
       (message "Copied color %s" formatted)))
   initial-color))

;;;###autoload
(defun emacs-canvas-color-picker-insert (&optional initial-color output-format)
  "Open the color picker and insert the selected hex color at point.

INITIAL-COLOR, when non-nil, must be a string in #RRGGBB or RRGGBB form.
OUTPUT-FORMAT selects `css-rgb', `css-rgba', `emacs-argb',
`emacs-rgb', or `c-rgb'; nil uses `css-rgb'."
  (interactive)
  (emacs-canvas-color-picker--validate-output-format output-format)
  (emacs-canvas-color-picker--open-state
   (emacs-canvas-color-picker--make-insert-state
    (current-buffer) initial-color output-format)))

;;;###autoload
(defun emacs-canvas-color-picker-at-point ()
  "Open the color picker and replace a hex color at point when present."
  (interactive)
  (emacs-canvas-color-picker--open-state
   (emacs-canvas-color-picker--make-at-point-state (current-buffer))))

(provide 'color-picker)

;;; color-picker.el ends here
