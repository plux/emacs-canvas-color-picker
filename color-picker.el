;;; color-picker.el --- Canvas color picker widget -*- lexical-binding: t; -*-
;; Copyright (c) 2026 Håkan Nilsson
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Version: 0.2.0

;;; Commentary:
;; Elisp color picker UI with native rendering for Emacs 32 canvas images.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'url)
(require 'url-http)

(defvar url-http-response-status)

;; Keep this value in sync with the Version header for matching release assets.
(defconst emacs-canvas-color-picker-version "0.2.0"
  "Release version used to select a matching native module.")

(defconst emacs-canvas-color-picker--max-download-bytes (* 1024 1024)
  "Maximum number of bytes allowed per release asset.")

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

(defcustom emacs-canvas-color-picker-display 'child-frame
  "Display the picker in a child frame or an Emacs buffer window."
  :type '(choice (const child-frame) (const buffer)))

(defcustom emacs-canvas-color-picker-inline-preview t
  "Show a temporary color preview in the source buffer for insert and at-point."
  :type 'boolean)

(defcustom emacs-canvas-color-picker-native-module-file
  (expand-file-name "zig-out/lib/libcolor-picker.so"
                    (file-name-directory (or load-file-name buffer-file-name default-directory)))
  "Native module file required for color picker rendering."
  :type 'file)

(defcustom emacs-canvas-color-picker-zig-command "zig"
  "Zig executable used to build the native color picker module."
  :type 'string)

(defcustom emacs-canvas-color-picker-emacs-include-dir
  (expand-file-name "vendor" (file-name-directory
                              (or load-file-name buffer-file-name default-directory)))
  "Directory containing the Emacs 32 `emacs-module.h' header."
  :type 'directory)

(defconst emacs-canvas-color-picker--project-dir
  (file-name-directory (or load-file-name buffer-file-name default-directory)))

(defcustom emacs-canvas-color-picker-trace-file
  (getenv "COLOR_PICKER_TRACE_FILE")
  "File path for color picker drag trace logs, or nil to disable tracing."
  :type '(choice (const nil) file))

(defconst emacs-canvas-color-picker--buffer-name "*emacs-canvas-color-picker*")
(defconst emacs-canvas-color-picker--background #xFF4D4D4D)

(defvar emacs-canvas-color-picker--native-loaded nil
  "Non-nil when the native color picker renderer is loaded.")

(defvar emacs-canvas-color-picker--native-restart-required nil
  "Non-nil after a failed module load that can leave native functions mapped.")

(defconst emacs-canvas-color-picker--native-api-version 1
  "Required API version of the native renderer.")

(declare-function emacs-canvas-color-picker-native-api-version nil ())
(declare-function emacs-canvas-color-picker-native-render-full nil
                  (canvas width height hue saturation value padding gap hue-width swatch-width swatch-height swatch-gap marker-radius initial-hue initial-saturation initial-value focus-region))

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
  parent-window
  display
  window
  previous-buffer
  created-window
  buffer
  buffer-created-p
  canvas
  geometry
  hue
  saturation
  value
  (active-region 'sv)
  initial-hue
  initial-saturation
  initial-value
  callback
  output-format
  output-alpha
  preview-buffer
  preview-window
  preview-start
  preview-end
  preview-overlay
  replace-start
  replace-end
  replace-prefixed
  done)

(defvar-local emacs-canvas-color-picker--state nil
  "Current color picker state for this buffer.")

(defvar emacs-canvas-color-picker--active-state nil
  "Picker state currently open in a frame or window.")

(defvar emacs-canvas-color-picker--mouse-map
  (let ((map (make-sparse-keymap)))
    (define-key map [down-mouse-1] #'emacs-canvas-color-picker--mouse-down)
    (define-key map [mouse-1] #'emacs-canvas-color-picker--mouse-click)
    (define-key map [drag-mouse-1] #'emacs-canvas-color-picker--mouse-drag)
    (define-key map (kbd "RET") #'emacs-canvas-color-picker--accept)
    (define-key map (kbd "C-m") #'emacs-canvas-color-picker--accept)
    (define-key map (kbd "C-c C-c") #'emacs-canvas-color-picker--accept)
    (define-key map (kbd "C-g") #'emacs-canvas-color-picker--cancel)
    (define-key map (kbd "q") #'emacs-canvas-color-picker--cancel)
    (define-key map (kbd "<escape>") #'emacs-canvas-color-picker--cancel)
    (define-key map (kbd "C-c C-k") #'emacs-canvas-color-picker--cancel)
    (dolist (binding '(("<up>" . emacs-canvas-color-picker--up)
                       ("p" . emacs-canvas-color-picker--up)
                       ("<down>" . emacs-canvas-color-picker--down)
                       ("n" . emacs-canvas-color-picker--down)
                       ("<left>" . emacs-canvas-color-picker--left)
                       ("b" . emacs-canvas-color-picker--left)
                       ("<right>" . emacs-canvas-color-picker--right)
                       ("f" . emacs-canvas-color-picker--right)
                       ("C-<up>" . emacs-canvas-color-picker--up-large)
                       ("C-p" . emacs-canvas-color-picker--up-large)
                       ("C-<down>" . emacs-canvas-color-picker--down-large)
                       ("C-n" . emacs-canvas-color-picker--down-large)
                       ("C-<left>" . emacs-canvas-color-picker--left-large)
                       ("C-b" . emacs-canvas-color-picker--left-large)
                       ("C-<right>" . emacs-canvas-color-picker--right-large)
                       ("C-f" . emacs-canvas-color-picker--right-large)
                       ("M-p" . emacs-canvas-color-picker--hue-up)
                       ("M-n" . emacs-canvas-color-picker--hue-down)
                       ("TAB" . emacs-canvas-color-picker--toggle-region)))
      (define-key map (kbd (car binding)) (cdr binding)))
    map)
  "Key and mouse map attached to the canvas display string.")

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

(defun emacs-canvas-color-picker-build-module ()
  "Build the native color picker module in its source checkout."
  (interactive)
  (unless (and (stringp emacs-canvas-color-picker-emacs-include-dir)
               (not (string-empty-p emacs-canvas-color-picker-emacs-include-dir)))
    (user-error "Set emacs-canvas-color-picker-emacs-include-dir to the Emacs 32 header directory"))
  (unless (executable-find emacs-canvas-color-picker-zig-command)
    (user-error "Zig executable not found: %s" emacs-canvas-color-picker-zig-command))
  (let ((default-directory emacs-canvas-color-picker--project-dir)
        (buffer (get-buffer-create "*color-picker-build*")))
    (with-current-buffer buffer
      (erase-buffer))
    (unless (eq 0 (call-process emacs-canvas-color-picker-zig-command nil buffer t
                                "build" "-Doptimize=ReleaseFast"
                                (concat "-Demacs-include-dir="
                                        emacs-canvas-color-picker-emacs-include-dir)))
      (display-buffer buffer)
      (user-error "Native color picker build failed; see %s" (buffer-name buffer))))
  t)

(defun emacs-canvas-color-picker--release-asset ()
  "Return the exact release asset for this host, or nil."
  (when (and (eq system-type 'gnu/linux)
             (string-prefix-p "x86_64-" system-configuration))
    (format "libcolor-picker-v%s-linux-x86_64.so" emacs-canvas-color-picker-version)))

(defun emacs-canvas-color-picker--check-native-api ()
  "Reject a native renderer with an incompatible API."
  (unless (fboundp 'emacs-canvas-color-picker-native-api-version)
    (error "Native color picker module lacks API version; rebuild or replace it"))
  (let ((version (emacs-canvas-color-picker-native-api-version)))
    (unless (equal version emacs-canvas-color-picker--native-api-version)
      (error "Native color picker API %s is incompatible with required API %s; rebuild or replace the module"
             version emacs-canvas-color-picker--native-api-version)))
  (unless (fboundp 'emacs-canvas-color-picker-native-render-full)
    (error "Native color picker module lacks full renderer")))

(defun emacs-canvas-color-picker--check-new-native-functions (previous-api previous-renderer)
  "Require the newly loaded module to replace PREVIOUS-API and PREVIOUS-RENDERER."
  (unless (and (fboundp 'emacs-canvas-color-picker-native-api-version)
               (fboundp 'emacs-canvas-color-picker-native-render-full)
               (not (eq previous-api
                        (symbol-function 'emacs-canvas-color-picker-native-api-version)))
               (not (eq previous-renderer
                        (symbol-function 'emacs-canvas-color-picker-native-render-full))))
    (error "Native color picker module did not register its API and full renderer")))

(defun emacs-canvas-color-picker--fetch-asset (url path)
  "Fetch HTTPS URL to PATH after checking redirects, status, and body size."
  (unless (string-prefix-p "https://github.com/plux/emacs-canvas-color-picker/releases/download/" url)
    (error "Unexpected release URL"))
  (let ((current url)
        (redirects 0))
    (catch 'downloaded
      (while t
        (unless (string= (url-type (url-generic-parse-url current)) "https")
          (error "Refusing non-HTTPS release URL: %s" current))
        (let* ((url-max-redirections 0)
               (url-request-method "GET")
               (buffer (url-retrieve-synchronously current t t 30)))
          (unless buffer
            (error "Release asset unavailable or download failed: %s" current))
          (unwind-protect
              (with-current-buffer buffer
                (goto-char (point-min))
                (unless (re-search-forward "\r?\n\r?\n" nil t)
                  (error "Invalid release response: %s" current))
                (let ((body-start (point))
                      (status url-http-response-status))
                  (cond
                   ((memq status '(301 302 303 307 308))
                    (goto-char (point-min))
                    (unless (re-search-forward "^Location: \\([^\r\n]+\\)\r?$" body-start t)
                      (error "Release redirect lacks a location: %s" current))
                    (setq current (url-expand-file-name (match-string 1) current))
                    (when (> (cl-incf redirects) 5)
                      (error "Too many release redirects")))
                   ((eq status 200)
                    (when (> (- (point-max) body-start)
                             emacs-canvas-color-picker--max-download-bytes)
                      (error "Release asset exceeds size limit: %s" current))
                    (let ((coding-system-for-write 'binary))
                      (write-region body-start (point-max) path nil 'silent))
                    (throw 'downloaded t))
                   (t (error "Release asset unavailable (HTTP %s): %s" status current)))))
            (kill-buffer buffer)))))))

(defun emacs-canvas-color-picker-download-module ()
  "Install the matching Linux x86_64 release module after verification."
  (interactive)
  (let* ((asset (emacs-canvas-color-picker--release-asset))
         (destination emacs-canvas-color-picker-native-module-file)
         (tag (concat "v" emacs-canvas-color-picker-version)))
    (unless asset
      (user-error "No release module for this platform; build locally with Zig"))
    (when emacs-canvas-color-picker--native-restart-required
      (user-error "Restart Emacs before loading another native color picker module"))
    (when (or emacs-canvas-color-picker--native-loaded (file-exists-p destination))
      (user-error "Native module already exists; do not replace a loaded or existing module"))
    (make-directory (file-name-directory destination) t)
    (let* ((base (format "https://github.com/plux/emacs-canvas-color-picker/releases/download/%s/" tag))
           (temporary (make-temp-file (expand-file-name ".color-picker-module-"
                                                       (file-name-directory destination)) nil ".so"))
           (checksum (make-temp-file "color-picker-checksum-")))
      (unwind-protect
          (progn
            (emacs-canvas-color-picker--fetch-asset (concat base asset ".sha256") checksum)
            (emacs-canvas-color-picker--fetch-asset (concat base asset) temporary)
            (let* ((expected (with-temp-buffer
                               (insert-file-contents checksum)
                               (goto-char (point-min))
                               (when (re-search-forward
                                      (concat "\\`\\([[:xdigit:]]\\{64\\}\\)  "
                                              (regexp-quote asset) "\n?\\'") nil t)
                                 (downcase (match-string 1)))))
                   (actual (with-temp-buffer
                             (insert-file-contents-literally temporary)
                             (secure-hash 'sha256 (current-buffer)))))
              (unless (and expected (string= expected actual))
                (error "Release module checksum mismatch")))
            (condition-case error
                (progn
                  (let ((previous-api (and (fboundp 'emacs-canvas-color-picker-native-api-version)
                                           (symbol-function 'emacs-canvas-color-picker-native-api-version)))
                        (previous-renderer (and (fboundp 'emacs-canvas-color-picker-native-render-full)
                                                (symbol-function 'emacs-canvas-color-picker-native-render-full))))
                    (setq emacs-canvas-color-picker--native-restart-required t)
                    (module-load temporary)
                    (emacs-canvas-color-picker--check-new-native-functions previous-api previous-renderer))
                  (emacs-canvas-color-picker--check-native-api)
                  (rename-file temporary destination)
                  (setq emacs-canvas-color-picker--native-loaded t
                        emacs-canvas-color-picker--native-restart-required nil))
              (error
               (error "Native module load or installation failed: %s. Restart Emacs before retrying"
                      (error-message-string error))))
            t)
        (when (file-exists-p temporary) (delete-file temporary))
        (when (file-exists-p checksum) (delete-file checksum))))))

(defun emacs-canvas-color-picker--ask-install-action (asset)
  "Ask how to install missing ASSET, or return nil to skip."
  (pcase (read-char-choice
          (concat "Color picker native module not found.\n\n"
                  (when asset
                    (format "  [d] Download pre-built binary from:\n      https://github.com/plux/emacs-canvas-color-picker/releases/download/v%s/%s\n"
                            emacs-canvas-color-picker-version asset))
                  "  [c] Compile from source via zig build\n"
                  "  [s] Skip - install manually later\n\nChoice: ")
          (if asset '(?d ?c ?s) '(?c ?s)))
    (?d 'download)
    (?c 'compile)))

(defun emacs-canvas-color-picker-load-native (&optional noerror)
  "Load the native color picker renderer, building it when missing.

When NOERROR is non-nil, return nil instead of signaling load errors."
  (interactive)
  (catch 'color-picker-skip
    (condition-case error
      (progn
        (when emacs-canvas-color-picker--native-restart-required
          (user-error "Restart Emacs before loading another native color picker module"))
        (unless emacs-canvas-color-picker--native-loaded
          (unless (file-exists-p emacs-canvas-color-picker-native-module-file)
            (if noninteractive
                (emacs-canvas-color-picker-build-module)
              (let ((asset (emacs-canvas-color-picker--release-asset)))
                (pcase (emacs-canvas-color-picker--ask-install-action asset)
                  ('download (emacs-canvas-color-picker-download-module))
                  ('compile (emacs-canvas-color-picker-build-module))
                  (_ (throw 'color-picker-skip nil))))))
          (unless emacs-canvas-color-picker--native-loaded
            (let ((previous-api (and (fboundp 'emacs-canvas-color-picker-native-api-version)
                                     (symbol-function 'emacs-canvas-color-picker-native-api-version)))
                  (previous-renderer (and (fboundp 'emacs-canvas-color-picker-native-render-full)
                                          (symbol-function 'emacs-canvas-color-picker-native-render-full))))
              (setq emacs-canvas-color-picker--native-restart-required t)
              (module-load emacs-canvas-color-picker-native-module-file)
              (emacs-canvas-color-picker--check-new-native-functions previous-api previous-renderer))))
        (emacs-canvas-color-picker--check-native-api)
        (setq emacs-canvas-color-picker--native-loaded t
              emacs-canvas-color-picker--native-restart-required nil)
        t)
    (error
     (when emacs-canvas-color-picker--native-loaded
       (setq emacs-canvas-color-picker--native-restart-required t))
     (setq emacs-canvas-color-picker--native-loaded nil)
     (unless noerror
       (user-error "Cannot load native color picker module: %s%s"
                   (error-message-string error)
                   (if emacs-canvas-color-picker--native-restart-required
                       ". Restart Emacs before retrying"
                     "")))
     nil))))

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

(defun emacs-canvas-color-picker--output-text (state)
  "Return the selected color in STATE's output format."
  (emacs-canvas-color-picker--format-hex
   (emacs-canvas-color-picker--current-hex state)
   (emacs-canvas-color-picker--state-output-format state)
   (emacs-canvas-color-picker--state-output-alpha state)))

(defun emacs-canvas-color-picker--update-preview (state)
  "Show STATE's selected color at its source location when visible."
  (let ((buffer (emacs-canvas-color-picker--state-preview-buffer state))
        (window (emacs-canvas-color-picker--state-preview-window state))
        (overlay (emacs-canvas-color-picker--state-preview-overlay state)))
    (let ((start (emacs-canvas-color-picker--state-preview-start state))
          (end (emacs-canvas-color-picker--state-preview-end state)))
      (if (and (buffer-live-p buffer) (window-live-p window)
               (eq (window-buffer window) buffer)
               (markerp start) (eq (marker-buffer start) buffer)
               (or (not end) (and (markerp end) (eq (marker-buffer end) buffer))))
          (with-current-buffer buffer
            (unless (overlayp overlay)
              (setq overlay (make-overlay start (or end start) buffer))
              (setf (emacs-canvas-color-picker--state-preview-overlay state) overlay))
            (move-overlay overlay start (or end start) buffer)
            (overlay-put overlay (if end 'display 'before-string)
                         (emacs-canvas-color-picker--output-text state)))
        (when (overlayp overlay)
          (delete-overlay overlay)
          (setf (emacs-canvas-color-picker--state-preview-overlay state) nil))))))

(defun emacs-canvas-color-picker--status-text (state &optional color-only)
  "Return status text for STATE, without hints when COLOR-ONLY is non-nil."
  (if (and (overlayp (emacs-canvas-color-picker--state-preview-overlay state))
           (overlay-buffer (emacs-canvas-color-picker--state-preview-overlay state)))
      (unless color-only "RET accept, q cancel")
    (if color-only
        (emacs-canvas-color-picker--output-text state)
      (format "%s    RET accept, q cancel" (emacs-canvas-color-picker--output-text state)))))

(defun emacs-canvas-color-picker--update-status (state &optional startup)
  "Show STATE's color in the echo area; include key hints at STARTUP."
  (emacs-canvas-color-picker--update-preview state)
  (when-let* ((text (emacs-canvas-color-picker--status-text state (not startup))))
    (let ((parent (emacs-canvas-color-picker--state-parent-frame state)))
      (with-selected-frame (if (frame-live-p parent) parent (selected-frame))
        (message "%s" text)))))

(defun emacs-canvas-color-picker--refresh (state)
  "Redraw and refresh STATE through the native renderer."
  (let* ((geometry (emacs-canvas-color-picker--state-geometry state))
         (hue (float (emacs-canvas-color-picker--state-hue state)))
         (saturation (float (emacs-canvas-color-picker--state-saturation state)))
         (value (float (emacs-canvas-color-picker--state-value state)))
         (canvas (emacs-canvas-color-picker--state-canvas state)))
    (unless (emacs-canvas-color-picker-native-render-full
             canvas
             (emacs-canvas-color-picker--geometry-width geometry)
             (emacs-canvas-color-picker--geometry-height geometry)
             hue saturation value
             (emacs-canvas-color-picker--geometry-padding geometry)
             (emacs-canvas-color-picker--geometry-gap geometry)
             (emacs-canvas-color-picker--geometry-hue-width geometry)
             (emacs-canvas-color-picker--geometry-swatch-width geometry)
             (emacs-canvas-color-picker--geometry-swatch-height geometry)
             (emacs-canvas-color-picker--geometry-swatch-gap geometry)
             (emacs-canvas-color-picker--geometry-marker-radius geometry)
             (float (or (emacs-canvas-color-picker--state-initial-hue state) hue))
             (float (or (emacs-canvas-color-picker--state-initial-saturation state) saturation))
             (float (or (emacs-canvas-color-picker--state-initial-value state) value))
             (if (eq (emacs-canvas-color-picker--state-active-region state) 'hue) 1 0))
      (error "Native color picker render failed"))
    (emacs-canvas-color-picker--trace
     "refresh-render"
     :native t
     :hue hue :saturation saturation :value value)
    (when (fboundp 'canvas-refresh)
      (emacs-canvas-color-picker--trace "canvas-refresh" :reload-data nil)
      (canvas-refresh canvas nil))))

(defun emacs-canvas-color-picker--move (direction large &optional direct-hue)
  "Move in DIRECTION by a fine or LARGE step, optionally in hue directly."
  (let ((state emacs-canvas-color-picker--state))
    (when (and state (not (emacs-canvas-color-picker--state-done state)))
      (let ((region (if direct-hue 'hue (emacs-canvas-color-picker--state-active-region state)))
            (step (if large 0.1 0.01)))
        (cond
         ((eq region 'hue)
          (when (memq direction '(up down))
            (setf (emacs-canvas-color-picker--state-hue state)
                  (mod (+ (emacs-canvas-color-picker--state-hue state)
                          (* (if (eq direction 'up) -1.0 1.0)
                             (/ (if large 15.0 1.0) 360.0))) 1.0))
            (emacs-canvas-color-picker--refresh state)
            (emacs-canvas-color-picker--update-status state)))
         (t
          (pcase direction
            ('up (setf (emacs-canvas-color-picker--state-value state)
                       (emacs-canvas-color-picker--clamp01
                        (+ (emacs-canvas-color-picker--state-value state) step))))
            ('down (setf (emacs-canvas-color-picker--state-value state)
                         (emacs-canvas-color-picker--clamp01
                          (- (emacs-canvas-color-picker--state-value state) step))))
            ('left (setf (emacs-canvas-color-picker--state-saturation state)
                         (emacs-canvas-color-picker--clamp01
                          (- (emacs-canvas-color-picker--state-saturation state) step))))
            ('right (setf (emacs-canvas-color-picker--state-saturation state)
                          (emacs-canvas-color-picker--clamp01
                           (+ (emacs-canvas-color-picker--state-saturation state) step)))))
          (emacs-canvas-color-picker--refresh state)
          (emacs-canvas-color-picker--update-status state)))))))

(defun emacs-canvas-color-picker--up () (interactive) (emacs-canvas-color-picker--move 'up nil))
(defun emacs-canvas-color-picker--down () (interactive) (emacs-canvas-color-picker--move 'down nil))
(defun emacs-canvas-color-picker--left () (interactive) (emacs-canvas-color-picker--move 'left nil))
(defun emacs-canvas-color-picker--right () (interactive) (emacs-canvas-color-picker--move 'right nil))
(defun emacs-canvas-color-picker--up-large () (interactive) (emacs-canvas-color-picker--move 'up t))
(defun emacs-canvas-color-picker--down-large () (interactive) (emacs-canvas-color-picker--move 'down t))
(defun emacs-canvas-color-picker--left-large () (interactive) (emacs-canvas-color-picker--move 'left t))
(defun emacs-canvas-color-picker--right-large () (interactive) (emacs-canvas-color-picker--move 'right t))
(defun emacs-canvas-color-picker--hue-up () (interactive) (emacs-canvas-color-picker--move 'up nil t))
(defun emacs-canvas-color-picker--hue-down () (interactive) (emacs-canvas-color-picker--move 'down nil t))

(defun emacs-canvas-color-picker--toggle-region ()
  "Switch keyboard focus between the square and the hue strip."
  (interactive)
  (when-let* ((state emacs-canvas-color-picker--state))
    (setf (emacs-canvas-color-picker--state-active-region state)
          (if (eq (emacs-canvas-color-picker--state-active-region state) 'sv) 'hue 'sv))
    (emacs-canvas-color-picker--refresh state)
    (emacs-canvas-color-picker--update-status state)))

(defun emacs-canvas-color-picker--apply-hit (state hit)
  "Apply HIT to STATE and refresh the picker."
  (pcase (plist-get hit :region)
    ('sv
     (setf (emacs-canvas-color-picker--state-saturation state) (plist-get hit :s)
           (emacs-canvas-color-picker--state-value state) (plist-get hit :v)))
    ('hue
     (setf (emacs-canvas-color-picker--state-hue state) (plist-get hit :h))))
  (emacs-canvas-color-picker--refresh state)
  (emacs-canvas-color-picker--update-status state))

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
           (state (and (windowp window)
                       (buffer-local-value 'emacs-canvas-color-picker--state
                                           (window-buffer window))))
           (edges (if (and state
                           (eq (emacs-canvas-color-picker--state-display state) 'buffer)
                           (fboundp 'window-body-pixel-edges))
                      (window-body-pixel-edges window)
                    (window-inside-pixel-edges window)))
           (left (nth 0 edges))
           (top (nth 1 edges))
           (coordinates (when (and (or (not frame) (eq frame (window-frame window)))
                                   (numberp x)
                                   (numberp y)
                                   (numberp left)
                                   (numberp top))
                          (cons (- x left)
                                (- y top)))))
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
            (text (emacs-canvas-color-picker--output-text state)))
        (emacs-canvas-color-picker--cleanup state)
        (funcall callback text)))))

(defun emacs-canvas-color-picker--cancel (&optional state)
  "Cancel color picker STATE."
  (interactive)
  (let ((state (or state emacs-canvas-color-picker--state)))
    (when state
      (setf (emacs-canvas-color-picker--state-done state) t)
      (emacs-canvas-color-picker--cleanup state))))

(defun emacs-canvas-color-picker--cleanup (state)
  "Release the frame or window and buffer owned by STATE."
  (let ((frame (emacs-canvas-color-picker--state-frame state))
        (window (emacs-canvas-color-picker--state-window state))
        (buffer (emacs-canvas-color-picker--state-buffer state))
        (overlay (emacs-canvas-color-picker--state-preview-overlay state)))
    (when (overlayp overlay)
      (delete-overlay overlay)
      (setf (emacs-canvas-color-picker--state-preview-overlay state) nil))
    (when (eq (emacs-canvas-color-picker--state-display state) 'buffer)
      (remove-hook 'window-size-change-functions #'emacs-canvas-color-picker--window-resized))
    (when (frame-live-p frame)
      (delete-frame frame t))
    (when (and (window-live-p window) (eq (window-buffer window) buffer))
      (if (and (emacs-canvas-color-picker--state-created-window state)
               (not (one-window-p t (window-frame window))))
          (delete-window window)
        (when (buffer-live-p (emacs-canvas-color-picker--state-previous-buffer state))
          (set-window-buffer window (emacs-canvas-color-picker--state-previous-buffer state)))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setq emacs-canvas-color-picker--state nil))
      (when (eq (emacs-canvas-color-picker--state-display state) 'buffer)
        (kill-buffer buffer)))
    (when (eq emacs-canvas-color-picker--active-state state)
      (setq emacs-canvas-color-picker--active-state nil))))

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
        (use-local-map emacs-canvas-color-picker--mouse-map)
        (insert (emacs-canvas-color-picker--display-string canvas))
        (goto-char (point-min))
        (setq buffer-read-only t)
        (set-buffer-modified-p nil)))))

(defun emacs-canvas-color-picker--frame-size (geometry _parent-frame)
  "Return child-frame pixel size for GEOMETRY."
  (cons (emacs-canvas-color-picker--geometry-width geometry)
        (+ (emacs-canvas-color-picker--geometry-height geometry)
           ;; The child frame can be one pixel shorter than its requested height.
           1)))

(defun emacs-canvas-color-picker--frame-position (parent width height &optional window)
  "Return child-frame position inside PARENT near point in WINDOW."
  (let* ((parent-width (frame-pixel-width parent))
         (parent-height (frame-pixel-height parent))
         (position (and window (posn-at-point (window-point window) window)))
         (edges (and position (window-inside-pixel-edges window)))
         (xy (and position (posn-x-y position)))
         (cursor-x (and xy (+ (nth 0 edges) (car xy))))
         (cursor-y (and xy (+ (nth 1 edges) (cdr xy))))
         (cursor-width (or (car (nth 9 position)) 0))
         (row-height (or (and position (cdr (nth 9 position)))
                         (and position window (frame-char-height (window-frame window)))
                         0))
         (gap 8)
         (right (and cursor-x (+ cursor-x cursor-width gap)))
         (left (cond ((and right (<= (+ right width) parent-width)) right)
                     (cursor-x (- cursor-x width gap))
                     (t 40)))
         (below (and cursor-y (+ cursor-y row-height)))
         (above (and cursor-y (- cursor-y height)))
         (top (cond ((and below (<= (+ below height) parent-height)) below)
                    ((and above (>= above 0)) above)
                    (cursor-y cursor-y)
                    (t 40))))
    (cons (max 0 (min (- parent-width width) left))
          (max 0 (min (- parent-height height) top)))))

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
         (position (emacs-canvas-color-picker--frame-position
                    parent width height
                    (emacs-canvas-color-picker--state-parent-window state)))
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

(defun emacs-canvas-color-picker--fit-window (state)
  "Fit STATE's canvas inside its window while preserving its HSV values."
  (let* ((window (emacs-canvas-color-picker--state-window state))
         (width (window-body-width window t))
         (height (window-body-height window t))
         (low 0.1)
         (high (max low (min (/ (float width) 316.0)
                             (/ (float height) 320.0))))
         geometry)
    (cl-labels ((fits (scale)
                  (let* ((emacs-canvas-color-picker-scale scale)
                         (candidate (emacs-canvas-color-picker--make-geometry)))
                    (when (and (<= (emacs-canvas-color-picker--geometry-width candidate) width)
                               (<= (emacs-canvas-color-picker--geometry-height candidate) height))
                      candidate))))
      (unless (and (>= high low) (setq geometry (fits low)))
        (user-error "Window is too small for the color picker"))
      (if-let* ((full (fits high)))
          (setq geometry full)
        (dotimes (_ 24)
          (let* ((middle (/ (+ low high) 2.0))
                 (candidate (fits middle)))
            (if candidate
                (setq low middle geometry candidate)
              (setq high middle))))))
    (unless (equal geometry (emacs-canvas-color-picker--state-geometry state))
      (let* ((size (* (emacs-canvas-color-picker--geometry-width geometry)
                      (emacs-canvas-color-picker--geometry-height geometry)))
             (data (make-vector size emacs-canvas-color-picker--background)))
        (setf (emacs-canvas-color-picker--state-geometry state) geometry
              (emacs-canvas-color-picker--state-canvas state)
              (emacs-canvas-color-picker--make-canvas geometry data))
        (emacs-canvas-color-picker--refresh state)
        (emacs-canvas-color-picker--setup-buffer state)))))

(defun emacs-canvas-color-picker--window-resized (&rest _args)
  "Refit the open buffer picker after its window changes size."
  (let ((state emacs-canvas-color-picker--active-state))
    (when (and state (eq (emacs-canvas-color-picker--state-display state) 'buffer)
               (not (emacs-canvas-color-picker--state-done state)))
      (let ((window (emacs-canvas-color-picker--state-window state)))
        (if (and (window-live-p window)
                 (eq (window-buffer window) (emacs-canvas-color-picker--state-buffer state)))
            (condition-case nil
                (emacs-canvas-color-picker--fit-window state)
              (user-error (emacs-canvas-color-picker--cancel state)))
          (emacs-canvas-color-picker--cancel state))))))

(defun emacs-canvas-color-picker--make-window (state)
  "Display STATE through Emacs window rules and select its window."
  (let ((previous nil)
        (buffer (emacs-canvas-color-picker--state-buffer state)))
    (walk-windows (lambda (window)
                    (push (cons window (window-buffer window)) previous))
                  nil t)
    (let ((window (display-buffer buffer)))
      (unless (window-live-p window)
        (error "No window available for the color picker"))
      (setf (emacs-canvas-color-picker--state-window state) window
            (emacs-canvas-color-picker--state-created-window state)
            (not (assq window previous))
            (emacs-canvas-color-picker--state-previous-buffer state)
            (cdr (assq window previous)))
      (select-window window)
      (emacs-canvas-color-picker--fit-window state)
      (add-hook 'window-size-change-functions #'emacs-canvas-color-picker--window-resized)
      window)))

(defun emacs-canvas-color-picker--ensure-canvas-available ()
  "Signal a user error unless canvas images are available."
  (unless (and (display-graphic-p) (image-type-available-p 'canvas))
    (user-error "Emacs 32 canvas support in a graphical frame is required")))

(defun emacs-canvas-color-picker--open-state (state)
  "Open the color picker for STATE."
  (when (and emacs-canvas-color-picker--active-state
             (not (emacs-canvas-color-picker--state-done
                   emacs-canvas-color-picker--active-state)))
    (user-error "A color picker is already open"))
  (setq emacs-canvas-color-picker--active-state state)
  (condition-case err
      (progn
        (emacs-canvas-color-picker--ensure-canvas-available)
        (if (not (emacs-canvas-color-picker-load-native))
            (progn
              (emacs-canvas-color-picker--cleanup state)
              (when (and (emacs-canvas-color-picker--state-buffer-created-p state)
                         (buffer-live-p (emacs-canvas-color-picker--state-buffer state)))
                (kill-buffer (emacs-canvas-color-picker--state-buffer state)))
              nil)
          (emacs-canvas-color-picker--refresh state)
          (emacs-canvas-color-picker--update-preview state)
          (emacs-canvas-color-picker--setup-buffer state)
          (if (eq (emacs-canvas-color-picker--state-display state) 'buffer)
              (emacs-canvas-color-picker--make-window state)
            (emacs-canvas-color-picker--make-frame state))
          (emacs-canvas-color-picker--update-status state t)
          state))
    (error
     (emacs-canvas-color-picker--cleanup state)
     (signal (car err) (cdr err)))))

(defun emacs-canvas-color-picker--make-state (callback &optional initial-color buffer display output-format output-alpha)
  "Return a new picker state for CALLBACK and INITIAL-COLOR."
  (unless (functionp callback)
    (error "Callback must be callable"))
  (when (and emacs-canvas-color-picker--active-state
             (not (emacs-canvas-color-picker--state-done
                   emacs-canvas-color-picker--active-state)))
    (user-error "A color picker is already open"))
  (setq display (or display emacs-canvas-color-picker-display))
  (unless (memq display '(buffer child-frame))
    (error "Unsupported color picker display: %S" display))
  (let* ((hsv (emacs-canvas-color-picker--initial-hsv initial-color))
         (parent-frame (selected-frame))
         (parent-window (selected-window))
         (geometry (emacs-canvas-color-picker--make-geometry nil parent-frame))
         (data (make-vector (* (emacs-canvas-color-picker--geometry-width geometry)
                               (emacs-canvas-color-picker--geometry-height geometry))
                            emacs-canvas-color-picker--background))
         (canvas (emacs-canvas-color-picker--make-canvas geometry data))
         (existing (and (eq display 'child-frame)
                        (get-buffer emacs-canvas-color-picker--buffer-name)))
         (provided-buffer buffer)
         (buffer (or buffer
                     (if (eq display 'buffer)
                         (generate-new-buffer emacs-canvas-color-picker--buffer-name)
                       (or existing (get-buffer-create emacs-canvas-color-picker--buffer-name))))))
    (emacs-canvas-color-picker--state-create
     :parent-frame parent-frame
     :parent-window parent-window
     :display display
     :buffer buffer
     :buffer-created-p (and (eq display 'child-frame) (not existing) (not provided-buffer))
     :canvas canvas
     :geometry geometry
     :hue (nth 0 hsv)
     :saturation (nth 1 hsv)
     :value (nth 2 hsv)
     :active-region 'sv
     :initial-hue (nth 0 hsv)
     :initial-saturation (nth 1 hsv)
     :initial-value (nth 2 hsv)
     :callback callback
     :output-format output-format
     :output-alpha output-alpha
     :done nil)))

;;;###autoload
(defun emacs-canvas-color-picker-read-color (callback &optional initial-color display output-format)
  "Open a canvas color picker and call CALLBACK with the selected color.

INITIAL-COLOR, when non-nil, must be a string in #RRGGBB or RRGGBB form.
DISPLAY overrides `emacs-canvas-color-picker-display' when non-nil.
OUTPUT-FORMAT selects the callback and preview format; nil uses `css-rgb'."
  (emacs-canvas-color-picker--validate-output-format output-format)
  (emacs-canvas-color-picker--open-state
   (emacs-canvas-color-picker--make-state callback initial-color nil display output-format)))

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

(defun emacs-canvas-color-picker--make-insert-state (target-buffer &optional initial-color output-format display preview)
  "Return insert-only picker state for TARGET-BUFFER."
  (let* ((marker (copy-marker (point) t))
         (state (emacs-canvas-color-picker--make-state
                 (lambda (text)
                   (when (buffer-live-p target-buffer)
                     (with-current-buffer target-buffer
                       (save-excursion
                         (goto-char marker)
                         (insert text))))
                   (set-marker marker nil))
                 initial-color nil display output-format)))
    (when preview
      (setf (emacs-canvas-color-picker--state-preview-buffer state) target-buffer
            (emacs-canvas-color-picker--state-preview-window state)
            (emacs-canvas-color-picker--state-parent-window state)
            (emacs-canvas-color-picker--state-preview-start state) marker))
    state))

(defun emacs-canvas-color-picker--make-at-point-state (target-buffer &optional display preview)
  "Return at-point picker state for TARGET-BUFFER."
  (let* ((match (emacs-canvas-color-picker--hex-at-point-bounds))
         (initial-color (and match (plist-get match :rgb)))
         (insert-marker (copy-marker (point) t))
         (replace-start (and match (copy-marker (plist-get match :start))))
         (replace-end (and match (copy-marker (plist-get match :end) t)))
         (state (emacs-canvas-color-picker--make-state
                 (lambda (text)
                   (when (buffer-live-p target-buffer)
                     (with-current-buffer target-buffer
                       (save-excursion
                         (if match
                             (progn
                               (goto-char replace-start)
                               (delete-region replace-start replace-end)
                               (insert text))
                           (goto-char insert-marker)
                           (insert text)))))
                   (set-marker insert-marker nil)
                   (when replace-start (set-marker replace-start nil))
                   (when replace-end (set-marker replace-end nil)))
                 initial-color nil display
                 (and match (plist-get match :format))
                 (and match (plist-get match :alpha)))))
    (when match
      (setf (emacs-canvas-color-picker--state-replace-start state) replace-start
            (emacs-canvas-color-picker--state-replace-end state) replace-end
            (emacs-canvas-color-picker--state-replace-prefixed state) (plist-get match :prefixed)))
    (when preview
      (setf (emacs-canvas-color-picker--state-preview-buffer state) target-buffer
            (emacs-canvas-color-picker--state-preview-window state)
            (emacs-canvas-color-picker--state-parent-window state)
            (emacs-canvas-color-picker--state-preview-start state)
            (or replace-start insert-marker)
            (emacs-canvas-color-picker--state-preview-end state) replace-end))
    state))

;;;###autoload
(defun emacs-canvas-color-picker-copy (&optional initial-color output-format display)
  "Open the color picker and copy the selected hex color.

INITIAL-COLOR, when non-nil, must be a string in #RRGGBB or RRGGBB form.
OUTPUT-FORMAT selects `css-rgb', `css-rgba', `emacs-argb',
`emacs-rgb', or `c-rgb'; nil uses `css-rgb'.
DISPLAY overrides `emacs-canvas-color-picker-display' when non-nil."
  (interactive)
  (emacs-canvas-color-picker--validate-output-format output-format)
  (emacs-canvas-color-picker-read-color
   (lambda (text)
     (kill-new text)
     (message "Copied color %s" text))
   initial-color display output-format))

;;;###autoload
(defun emacs-canvas-color-picker-insert (&optional initial-color output-format display &rest inline-preview)
  "Open the color picker and insert the selected hex color at point.

INITIAL-COLOR, when non-nil, must be a string in #RRGGBB or RRGGBB form.
OUTPUT-FORMAT selects `css-rgb', `css-rgba', `emacs-argb',
`emacs-rgb', or `c-rgb'; nil uses `css-rgb'.
DISPLAY overrides `emacs-canvas-color-picker-display' when non-nil.
An explicit fourth argument INLINE-PREVIEW overrides the Customize default."
  (interactive)
  (when (cdr inline-preview)
    (error "Too many inline preview arguments"))
  (emacs-canvas-color-picker--validate-output-format output-format)
  (emacs-canvas-color-picker--open-state
   (emacs-canvas-color-picker--make-insert-state
    (current-buffer) initial-color output-format display
    (if inline-preview (car inline-preview) emacs-canvas-color-picker-inline-preview))))

;;;###autoload
(defun emacs-canvas-color-picker-at-point (&optional display &rest inline-preview)
  "Open the color picker and replace a hex color at point when present.

DISPLAY overrides `emacs-canvas-color-picker-display' when non-nil.
An explicit second argument INLINE-PREVIEW overrides the Customize default."
  (interactive)
  (when (cdr inline-preview)
    (error "Too many inline preview arguments"))
  (emacs-canvas-color-picker--open-state
   (emacs-canvas-color-picker--make-at-point-state
    (current-buffer) display
    (if inline-preview (car inline-preview) emacs-canvas-color-picker-inline-preview))))

(provide 'color-picker)

;;; color-picker.el ends here
