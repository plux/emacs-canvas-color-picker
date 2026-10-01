;;; color-picker-test.el --- Tests for canvas color picker -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)

(defconst emacs-canvas-color-picker-test--project-dir
  (file-name-directory (or load-file-name buffer-file-name)))

(add-to-list 'load-path emacs-canvas-color-picker-test--project-dir)
(require 'color-picker)

(defun emacs-canvas-color-picker-test--close-to (actual expected &optional tolerance)
  "Return non-nil when ACTUAL is within TOLERANCE of EXPECTED."
  (<= (abs (- actual expected)) (or tolerance 0.001)))

(defun emacs-canvas-color-picker-test--small-geometry ()
  "Return a small geometry useful for deterministic tests."
  (emacs-canvas-color-picker--make-geometry
   '(:padding 1 :sv-width 4 :sv-height 4 :gap 1 :hue-width 2 :hue-height 4)))

(ert-deftest emacs-canvas-color-picker-test-hsv-to-rgb-primary-colors ()
  "HSV conversion returns expected RGB primaries and neutral colors."
  (should (equal (emacs-canvas-color-picker--hsv-to-rgb 0 1 1) '(255 0 0)))
  (should (equal (emacs-canvas-color-picker--hsv-to-rgb (/ 1.0 3.0) 1 1) '(0 255 0)))
  (should (equal (emacs-canvas-color-picker--hsv-to-rgb (/ 2.0 3.0) 1 1) '(0 0 255)))
  (should (equal (emacs-canvas-color-picker--hsv-to-rgb 0.75 0 1) '(255 255 255)))
  (should (equal (emacs-canvas-color-picker--hsv-to-rgb 0.25 1 0) '(0 0 0)))
  (should (equal (emacs-canvas-color-picker--hsv-to-rgb 1 1 1) '(255 0 0))))

(ert-deftest emacs-canvas-color-picker-test-rgb-to-hex-formats-lowercase ()
  "RGB formatting returns lowercase hex and clamps components."
  (should (equal (emacs-canvas-color-picker--rgb-to-hex 51 153 204) "#3399cc"))
  (should (equal (emacs-canvas-color-picker--rgb-to-hex 255 255 255) "#ffffff"))
  (should (equal (emacs-canvas-color-picker--rgb-to-hex 0 0 0) "#000000"))
  (should (equal (emacs-canvas-color-picker--rgb-to-hex -10 300 15) "#00ff0f")))

(ert-deftest emacs-canvas-color-picker-test-hex-to-hsv-parses-common-forms ()
  "Hex parser accepts common forms and returns expected HSV values."
  (let ((hsv (emacs-canvas-color-picker--hex-to-hsv "#3399cc")))
    (should (emacs-canvas-color-picker-test--close-to (nth 0 hsv) (/ 200.0 360.0) 0.001))
    (should (emacs-canvas-color-picker-test--close-to (nth 1 hsv) 0.75 0.001))
    (should (emacs-canvas-color-picker-test--close-to (nth 2 hsv) 0.8 0.001)))
  (let ((hsv (emacs-canvas-color-picker--hex-to-hsv "FF0000")))
    (should (emacs-canvas-color-picker-test--close-to (nth 0 hsv) 0.0 0.001))
    (should (emacs-canvas-color-picker-test--close-to (nth 1 hsv) 1.0 0.001))
    (should (emacs-canvas-color-picker-test--close-to (nth 2 hsv) 1.0 0.001))))

(ert-deftest emacs-canvas-color-picker-test-hex-to-hsv-rejects-malformed-input ()
  "Hex parser rejects malformed input."
  (should-error (emacs-canvas-color-picker--hex-to-hsv "#12345"))
  (should-error (emacs-canvas-color-picker--hex-to-hsv "#xyzxyz"))
  (should-error (emacs-canvas-color-picker--hex-to-hsv nil)))

(ert-deftest emacs-canvas-color-picker-test-argb-composes-opaque-pixels ()
  "ARGB helper composes opaque canvas pixels."
  (should (= (emacs-canvas-color-picker--argb 255 0 0) #xFFFF0000))
  (should (= (emacs-canvas-color-picker--argb 0 255 0) #xFF00FF00))
  (should (= (emacs-canvas-color-picker--argb 0 0 255) #xFF0000FF))
  (should (= (emacs-canvas-color-picker--argb -1 300 15) #xFF00FF0F)))

(ert-deftest emacs-canvas-color-picker-test-hit-test-sv-corners ()
  "SV hit tests map corners to expected saturation and value."
  (let* ((geometry (emacs-canvas-color-picker-test--small-geometry))
         (top-left (emacs-canvas-color-picker--hit-test geometry 1 1))
         (bottom-right (emacs-canvas-color-picker--hit-test geometry 4 4)))
    (should (eq (plist-get top-left :region) 'sv))
    (should (emacs-canvas-color-picker-test--close-to (plist-get top-left :s) 0.0))
    (should (emacs-canvas-color-picker-test--close-to (plist-get top-left :v) 1.0))
    (should (eq (plist-get bottom-right :region) 'sv))
    (should (emacs-canvas-color-picker-test--close-to (plist-get bottom-right :s) 1.0))
    (should (emacs-canvas-color-picker-test--close-to (plist-get bottom-right :v) 0.0))))

(ert-deftest emacs-canvas-color-picker-test-hit-test-hue-strip ()
  "Hue strip hit tests map vertical position to hue."
  (let* ((geometry (emacs-canvas-color-picker-test--small-geometry))
         (top (emacs-canvas-color-picker--hit-test geometry 6 1))
         (bottom (emacs-canvas-color-picker--hit-test geometry 6 4)))
    (should (eq (plist-get top :region) 'hue))
    (should (emacs-canvas-color-picker-test--close-to (plist-get top :h) 0.0))
    (should (eq (plist-get bottom :region) 'hue))
    (should (emacs-canvas-color-picker-test--close-to (plist-get bottom :h) 1.0))))

(ert-deftest emacs-canvas-color-picker-test-hit-test-outside-regions ()
  "Hit tests return nil outside the interactive palette regions."
  (let ((geometry (emacs-canvas-color-picker-test--small-geometry)))
    (should-not (emacs-canvas-color-picker--hit-test geometry 0 0))
    (should-not (emacs-canvas-color-picker--hit-test geometry 5 1))
    (should-not (emacs-canvas-color-picker--hit-test geometry 99 99))))

(ert-deftest emacs-canvas-color-picker-test-draw-palette-fills-opaque-pixels ()
  "Palette drawing fills the full data vector with opaque pixels."
  (let* ((geometry (emacs-canvas-color-picker-test--small-geometry))
         (width (emacs-canvas-color-picker--geometry-width geometry))
         (height (emacs-canvas-color-picker--geometry-height geometry))
         (data (make-vector (* width height) nil)))
    (emacs-canvas-color-picker--draw-palette data geometry 0.5 0.5 0.5)
    (should (= (length data) (* width height)))
    (dotimes (index (length data))
      (should (integerp (aref data index)))
      (should (= (logand (aref data index) #xFF000000) #xFF000000)))))

(ert-deftest emacs-canvas-color-picker-test-draw-palette-rejects-wrong-vector-size ()
  "Palette drawing rejects vectors that do not match the geometry size."
  (let ((geometry (emacs-canvas-color-picker-test--small-geometry)))
    (should-error (emacs-canvas-color-picker--draw-palette (make-vector 3 0) geometry 0 0 0))))

(ert-deftest emacs-canvas-color-picker-test-draw-palette-handles-small-geometries ()
  "Palette drawing keeps marker writes inside tiny geometries."
  (let* ((geometry (emacs-canvas-color-picker--make-geometry
                    '(:padding 0 :sv-width 1 :sv-height 1 :gap 0 :hue-width 1 :hue-height 1)))
         (data (make-vector (* (emacs-canvas-color-picker--geometry-width geometry)
                               (emacs-canvas-color-picker--geometry-height geometry))
                            nil)))
    (emacs-canvas-color-picker--draw-palette data geometry 0 0 1)
    (dotimes (index (length data))
      (should (integerp (aref data index))))))

(ert-deftest emacs-canvas-color-picker-test-refresh-markers-restores-old-marker-pixels ()
  "Marker-only refresh restores pixels from the cached base palette."
  (let* ((geometry (emacs-canvas-color-picker--make-geometry
                    '(:padding 2 :sv-width 20 :sv-height 20 :gap 2 :hue-width 3 :hue-height 20)))
         (width (emacs-canvas-color-picker--geometry-width geometry))
         (height (emacs-canvas-color-picker--geometry-height geometry))
         (base (make-vector (* width height) nil))
         (data (make-vector (* width height) nil)))
    (emacs-canvas-color-picker--draw-base-palette base geometry 0.5)
    (emacs-canvas-color-picker--refresh-markers data base geometry 0.5 0.0 1.0)
    (let ((after-first (copy-sequence data)))
      (emacs-canvas-color-picker--refresh-markers data base geometry 0.5 1.0 0.0)
      (let ((old-marker-ring-index (emacs-canvas-color-picker--pixel-index geometry 7 2)))
        (should (/= (aref after-first old-marker-ring-index) (aref base old-marker-ring-index)))
        (should (= (aref data old-marker-ring-index) (aref base old-marker-ring-index)))))))

(ert-deftest emacs-canvas-color-picker-test-native-refresh-passes-elisp-geometry ()
  "Native refresh passes Elisp geometry so hit-testing and drawing align."
  (let* ((geometry (emacs-canvas-color-picker--make-geometry))
         (data (make-vector (* (emacs-canvas-color-picker--geometry-width geometry)
                               (emacs-canvas-color-picker--geometry-height geometry))
                            0))
         (canvas (list 'image :type 'canvas :id 'test-canvas
                       :data-width (emacs-canvas-color-picker--geometry-width geometry)
                       :data-height (emacs-canvas-color-picker--geometry-height geometry)
                       :data data))
         (state (emacs-canvas-color-picker--state-create
                 :canvas canvas
                 :base-canvas canvas
                 :data data
                 :base-data data
                 :geometry geometry
                 :hue 0.5
                 :saturation 0.25
                 :value 0.75))
         (full-args nil))
    (cl-letf (((symbol-function 'emacs-canvas-color-picker--native-available-p) (lambda () t))
              ((symbol-function 'emacs-canvas-color-picker-native-render-base) (lambda (&rest _args) t))
              ((symbol-function 'emacs-canvas-color-picker-native-render-full) (lambda (&rest args) (setq full-args args) t))
              ((symbol-function 'canvas-refresh) (lambda (&rest _args) nil)))
      (emacs-canvas-color-picker--refresh state t)
      (should (equal (nthcdr 6 full-args)
                     (list (emacs-canvas-color-picker--geometry-padding geometry)
                           (emacs-canvas-color-picker--geometry-gap geometry)
                           (emacs-canvas-color-picker--geometry-hue-width geometry)
                           0.5
                           0.25
                           0.75))))))

(ert-deftest emacs-canvas-color-picker-test-native-refresh-does-not-reload-elisp-data ()
  "Native canvas writes refresh without reloading stale Elisp data."
  (let* ((geometry (emacs-canvas-color-picker-test--small-geometry))
         (data (make-vector (* (emacs-canvas-color-picker--geometry-width geometry)
                               (emacs-canvas-color-picker--geometry-height geometry))
                            0))
         (base-data (copy-sequence data))
         (canvas (list 'image :type 'canvas :id 'test-canvas
                       :data-width (emacs-canvas-color-picker--geometry-width geometry)
                       :data-height (emacs-canvas-color-picker--geometry-height geometry)
                       :data data))
         (base-canvas (copy-sequence canvas))
         (state (emacs-canvas-color-picker--state-create
                 :canvas canvas
                 :base-canvas base-canvas
                 :data data
                 :base-data base-data
                 :geometry geometry
                 :hue 0.5
                 :saturation 0.25
                 :value 0.75))
         (refresh-args nil))
    (cl-letf (((symbol-function 'emacs-canvas-color-picker--native-available-p) (lambda () t))
              ((symbol-function 'emacs-canvas-color-picker-native-render-base) (lambda (&rest _args) t))
              ((symbol-function 'emacs-canvas-color-picker-native-render-full) (lambda (&rest _args) t))
              ((symbol-function 'canvas-refresh) (lambda (&rest args) (setq refresh-args args))))
      (emacs-canvas-color-picker--refresh state t)
      (should (equal refresh-args (list canvas nil))))))

(ert-deftest emacs-canvas-color-picker-test-mouse-click-updates-without-finishing ()
  "Mouse click updates the color but does not accept it."
  (let* ((called (list nil))
         (state (emacs-canvas-color-picker--state-create
                 :hue 0.0
                 :saturation 0.0
                 :value 1.0
                 :callback (lambda (_hex) (setcar called t))
                 :done nil)))
    (cl-letf (((symbol-function 'emacs-canvas-color-picker--state-for-event) (lambda (_event) state))
              ((symbol-function 'emacs-canvas-color-picker--handle-event)
               (lambda (state _event)
                 (setf (emacs-canvas-color-picker--state-saturation state) 1.0
                       (emacs-canvas-color-picker--state-value state) 0.5))))
      (emacs-canvas-color-picker--mouse-click '(mouse-1))
      (should-not (car called))
      (should-not (emacs-canvas-color-picker--state-done state))
      (should (= (emacs-canvas-color-picker--state-saturation state) 1.0))
      (should (= (emacs-canvas-color-picker--state-value state) 0.5)))))

(ert-deftest emacs-canvas-color-picker-test-current-pointer-coordinates-account-for-status-line ()
  "Current pointer coordinates convert window pixels to canvas pixels."
  (cl-letf (((symbol-function 'window-live-p) (lambda (_window) t))
            ((symbol-function 'mouse-pixel-position) (lambda () (list 'frame 50 70)))
            ((symbol-function 'window-frame) (lambda (_window) 'frame))
            ((symbol-function 'window-inside-pixel-edges) (lambda (_window) '(10 20 200 220)))
            ((symbol-function 'emacs-canvas-color-picker--status-pixel-height) (lambda (_window) 17)))
    (should (equal (emacs-canvas-color-picker--current-pointer-coordinates 'window)
                   '(40 . 33)))))

(ert-deftest emacs-canvas-color-picker-test-current-pointer-coordinates-handle-dotted-mouse-position ()
  "Current pointer coordinates handle `(FRAME . (X . Y))` mouse positions."
  (cl-letf (((symbol-function 'window-live-p) (lambda (_window) t))
            ((symbol-function 'mouse-pixel-position) (lambda () (cons 'frame (cons 50 70))))
            ((symbol-function 'window-frame) (lambda (_window) 'frame))
            ((symbol-function 'window-inside-pixel-edges) (lambda (_window) '(10 20 200 220)))
            ((symbol-function 'emacs-canvas-color-picker--status-pixel-height) (lambda (_window) 17)))
    (should (equal (emacs-canvas-color-picker--current-pointer-coordinates 'window)
                   '(40 . 33)))))

(ert-deftest emacs-canvas-color-picker-test-track-current-pointer-updates-through-canvas-refresh ()
  "Drag timeout updates from current pointer through the canvas refresh path."
  (let ((handled nil)
        (state (emacs-canvas-color-picker--state-create :done nil)))
    (cl-letf (((symbol-function 'emacs-canvas-color-picker--current-pointer-coordinates)
               (lambda (_window) '(5 . 6)))
              ((symbol-function 'emacs-canvas-color-picker--handle-coordinates)
               (lambda (_state coordinates) (push coordinates handled))))
      (should (equal (emacs-canvas-color-picker--track-current-pointer state 'window) '(5 . 6)))
      (should (equal (emacs-canvas-color-picker--track-current-pointer state 'window '(5 . 6)) '(5 . 6)))
      (should (equal handled '((5 . 6)))))))

(ert-deftest emacs-canvas-color-picker-test-mouse-down-ignores-switch-frame-during-drag ()
  "Switch-frame events during drag do not terminate pointer polling."
  (let* ((pointer-windows nil)
         (events (list '(switch-frame) '(mouse-1)))
         (state (emacs-canvas-color-picker--state-create :done nil)))
    (cl-letf (((symbol-function 'emacs-canvas-color-picker--state-for-event) (lambda (_event) state))
              ((symbol-function 'emacs-canvas-color-picker--handle-event) (lambda (&rest _args) nil))
              ((symbol-function 'emacs-canvas-color-picker--track-current-pointer)
               (lambda (_state window &optional _last-coordinates)
                 (push window pointer-windows)
                 '(9 . 10)))
              ((symbol-function 'posn-window) (lambda (_position) 'tracking-window))
              ((symbol-function 'event-start) (lambda (_event) 'start-position))
              ((symbol-function 'track-mouse) (lambda (&rest body) (eval `(progn ,@body))))
              ((symbol-function 'read-event)
               (lambda (&rest _args)
                 (pop events))))
      (emacs-canvas-color-picker--mouse-down '(down-mouse-1))
      (should (equal pointer-windows '(tracking-window tracking-window))))))

(ert-deftest emacs-canvas-color-picker-test-mouse-release-prefers-end-coordinates ()
  "Mouse release uses the release coordinates when available."
  (cl-letf (((symbol-function 'event-start) (lambda (_event) 'start-position))
            ((symbol-function 'event-end) (lambda (_event) 'end-position))
            ((symbol-function 'posn-object-x-y)
             (lambda (position)
               (pcase position
                 ('start-position '(1 . 2))
                 ('end-position '(30 . 40))))))
    (should (equal (emacs-canvas-color-picker--event-coordinates '(mouse-1)) '(30 . 40)))))

(ert-deftest emacs-canvas-color-picker-test-mouse-down-polls-before-reading-release ()
  "Mouse-down tracking polls current pointer before reading a release event."
  (let* ((pointer-windows nil)
         (events (list '(mouse-1)))
         (state (emacs-canvas-color-picker--state-create :done nil)))
    (cl-letf (((symbol-function 'emacs-canvas-color-picker--state-for-event) (lambda (_event) state))
              ((symbol-function 'emacs-canvas-color-picker--handle-event) (lambda (&rest _args) nil))
              ((symbol-function 'emacs-canvas-color-picker--track-current-pointer)
               (lambda (_state window &optional _last-coordinates)
                 (push window pointer-windows)
                 '(9 . 10)))
              ((symbol-function 'posn-window) (lambda (_position) 'tracking-window))
              ((symbol-function 'event-start) (lambda (_event) 'start-position))
              ((symbol-function 'track-mouse) (lambda (&rest body) (eval `(progn ,@body))))
              ((symbol-function 'read-event)
               (lambda (&rest _args)
                 (pop events))))
      (emacs-canvas-color-picker--mouse-down '(down-mouse-1))
      (should (equal pointer-windows '(tracking-window))))))

(ert-deftest emacs-canvas-color-picker-test-mouse-down-drag-updates-without-finishing ()
  "Mouse drag polls the pointer while tracking and does not accept on release."
  (let* ((handled nil)
         (pointer-windows nil)
         (events (list '(mouse-movement) '(mouse-1)))
         (state (emacs-canvas-color-picker--state-create
                 :hue 0.0
                 :saturation 0.0
                 :value 1.0
                 :callback (lambda (_hex) (error "callback must not run"))
                 :done nil)))
    (cl-letf (((symbol-function 'emacs-canvas-color-picker--state-for-event) (lambda (_event) state))
              ((symbol-function 'emacs-canvas-color-picker--handle-event)
               (lambda (_state event) (push (car event) handled)))
              ((symbol-function 'emacs-canvas-color-picker--track-current-pointer)
               (lambda (_state window &optional _last-coordinates) (push window pointer-windows)))
              ((symbol-function 'posn-window) (lambda (_position) 'tracking-window))
              ((symbol-function 'event-start) (lambda (_event) 'start-position))
              ((symbol-function 'track-mouse) (lambda (&rest body) (eval `(progn ,@body))))
              ((symbol-function 'read-event)
               (lambda (&rest _args)
                 (pop events))))
      (emacs-canvas-color-picker--mouse-down '(down-mouse-1))
      (should (equal (nreverse handled) '(down-mouse-1 mouse-1)))
      (should (equal pointer-windows '(tracking-window tracking-window)))
      (should-not (emacs-canvas-color-picker--state-done state)))))

(ert-deftest emacs-canvas-color-picker-test-accept-finishes-and-calls-callback ()
  "Accepting the picker finishes and calls the callback once."
  (let* ((called (list nil))
         (state (emacs-canvas-color-picker--state-create
                 :hue 0.0
                 :saturation 1.0
                 :value 1.0
                 :callback (lambda (hex) (setcar called hex))
                 :done nil)))
    (cl-letf (((symbol-function 'emacs-canvas-color-picker--cleanup) (lambda (_state) nil)))
      (emacs-canvas-color-picker--accept state)
      (should (equal (car called) "#ff0000"))
      (should (emacs-canvas-color-picker--state-done state)))))

(ert-deftest emacs-canvas-color-picker-test-status-text-shows-current-hex ()
  "Status text displays current color and key hints."
  (let ((state (emacs-canvas-color-picker--state-create
                :hue 0.0
                :saturation 1.0
                :value 1.0)))
    (let ((status (emacs-canvas-color-picker--status-text state)))
      (should (string-match-p "#ff0000" status))
      (should (string-match-p "RET" status))
      (should (string-match-p "q" status)))))

(ert-deftest emacs-canvas-color-picker-test-update-status-replaces-existing-line ()
  "Status updates replace the existing line instead of appending text."
  (with-temp-buffer
    (let ((state (emacs-canvas-color-picker--state-create
                  :hue 0.0
                  :saturation 1.0
                  :value 1.0)))
      (insert "initial status\n")
      (setf (emacs-canvas-color-picker--state-status-marker state)
            (copy-marker (point-min) t))
      (emacs-canvas-color-picker--update-status state)
      (setf (emacs-canvas-color-picker--state-hue state) (/ 1.0 3.0))
      (emacs-canvas-color-picker--update-status state)
      (should (equal (buffer-string)
                     (concat (emacs-canvas-color-picker--status-text state) "\n"))))))

(ert-deftest emacs-canvas-color-picker-test-display-string-uses-arrow-pointer ()
  "Canvas display string uses the normal arrow pointer."
  (let ((display-string (emacs-canvas-color-picker--display-string '(image :type canvas :id test))))
    (should (eq (get-text-property 0 'pointer display-string) 'arrow))
    (should (get-text-property 0 'local-map display-string))))

(ert-deftest emacs-canvas-color-picker-test-focus-frame-selects-picker-window ()
  "Focusing the picker selects the child frame and root window."
  (let ((calls nil))
    (cl-letf (((symbol-function 'frame-live-p) (lambda (_frame) t))
              ((symbol-function 'frame-root-window) (lambda (frame) (list 'root-window frame)))
              ((symbol-function 'select-frame-set-input-focus) (lambda (frame) (push (list 'focus frame) calls)))
              ((symbol-function 'select-window) (lambda (window) (push (list 'window window) calls))))
      (emacs-canvas-color-picker--focus-frame 'picker-frame)
      (should (member '(focus picker-frame) calls))
      (should (member '(window (root-window picker-frame)) calls)))))

(ert-deftest emacs-canvas-color-picker-test-frame-size-includes-status-line ()
  "Frame size includes room for status text above the canvas."
  (let ((geometry (emacs-canvas-color-picker-test--small-geometry)))
    (cl-letf (((symbol-function 'frame-char-height) (lambda (&optional _frame) 17)))
      (let ((size (emacs-canvas-color-picker--frame-size geometry nil)))
        (should (= (car size) (emacs-canvas-color-picker--geometry-width geometry)))
        (should (= (cdr size) (+ (emacs-canvas-color-picker--geometry-height geometry) 17 1)))))))

(ert-deftest emacs-canvas-color-picker-test-setup-buffer-keeps-status-at-point ()
  "The window must not scroll past the status row to show point."
  (with-temp-buffer
    (let ((state (emacs-canvas-color-picker--state-create
                  :buffer (current-buffer)
                  :canvas '(image :type canvas :id test)
                  :hue 0.0 :saturation 1.0 :value 1.0)))
      (emacs-canvas-color-picker--setup-buffer state)
      (should (= (point) (point-min))))))

(ert-deftest emacs-canvas-color-picker-test-child-frame-shows-status-and-canvas ()
  "The child frame must display the status row and the entire canvas."
  (skip-unless (and (display-graphic-p) (image-type-available-p 'canvas)))
  (let ((state (emacs-canvas-color-picker-read-color #'ignore)))
    (unwind-protect
        (let* ((window (frame-root-window (emacs-canvas-color-picker--state-frame state)))
               (geometry (emacs-canvas-color-picker--state-geometry state)))
          (redisplay t)
          (should (= (window-start window) (with-current-buffer (window-buffer window) (point-min))))
          (should (pos-visible-in-window-p (window-start window) window))
          (should (>= (window-pixel-height window)
                      (+ (frame-char-height (window-frame window))
                         (emacs-canvas-color-picker--geometry-height geometry))))
          (let* ((position (posn-at-x-y 50 100 window t))
                 (pixel (posn-x-y position))
                 (edges (window-inside-pixel-edges window)))
            (cl-letf (((symbol-function 'mouse-pixel-position)
                       (lambda () (cons (window-frame window)
                                        (cons (+ (car pixel) (nth 0 edges))
                                              (+ (cdr pixel) (nth 1 edges)))))))
              (should (equal (emacs-canvas-color-picker--current-pointer-coordinates window)
                             (posn-object-x-y position))))))
      (emacs-canvas-color-picker--cancel state))))

(ert-deftest emacs-canvas-color-picker-test-set-window-minimal-fringes ()
  "Picker window uses minimal fringes without changing frame size."
  (let ((calls nil))
    (cl-letf (((symbol-function 'window-live-p) (lambda (_window) t))
              ((symbol-function 'window-minibuffer-p) (lambda (_window) nil))
              ((symbol-function 'window-buffer) (lambda (_window) 'picker-buffer))
              ((symbol-function 'set-window-fringes)
               (lambda (&rest args) (push args calls))))
      (emacs-canvas-color-picker--set-window-minimal-fringes 'picker-window 'picker-buffer)
      (should (equal calls '((picker-window 1 1 nil)))))))

(ert-deftest emacs-canvas-color-picker-test-geometry-includes-swatch-area ()
  "Default geometry includes swatch rectangles below the palette."
  (let ((geometry (emacs-canvas-color-picker--make-geometry)))
    (should (> (emacs-canvas-color-picker--geometry-height geometry)
               (+ (* 2 (emacs-canvas-color-picker--geometry-padding geometry))
                  (emacs-canvas-color-picker--geometry-sv-height geometry))))
    (should (numberp (emacs-canvas-color-picker--geometry-new-swatch-left geometry)))
    (should (numberp (emacs-canvas-color-picker--geometry-current-swatch-left geometry)))))

(ert-deftest emacs-canvas-color-picker-test-hex-at-point-detects-prefixed-color ()
  "Hex at point detects prefixed #RRGGBB values."
  (with-temp-buffer
    (insert "body { color: #00ff00; }")
    (goto-char (point-min))
    (search-forward "00ff")
    (let ((match (emacs-canvas-color-picker--hex-at-point-bounds)))
      (should (plist-get match :prefixed))
      (should (equal (plist-get match :text) "#00ff00")))))

(ert-deftest emacs-canvas-color-picker-test-hex-at-point-detects-bare-color ()
  "Hex at point detects bare RRGGBB values."
  (with-temp-buffer
    (insert "color 00ff00 ok")
    (goto-char (point-min))
    (search-forward "ff")
    (let ((match (emacs-canvas-color-picker--hex-at-point-bounds)))
      (should-not (plist-get match :prefixed))
      (should (equal (plist-get match :text) "00ff00")))))

(ert-deftest emacs-canvas-color-picker-test-hex-at-point-rejects-long-token ()
  "Hex at point does not match a substring inside a longer token."
  (with-temp-buffer
    (insert "abcdeff")
    (goto-char (point-min))
    (search-forward "cdef")
    (should-not (emacs-canvas-color-picker--hex-at-point-bounds))))

(ert-deftest emacs-canvas-color-picker-test-at-point-replaces-prefixed-color ()
  "At-point accept replaces a prefixed hex color and keeps #."
  (with-temp-buffer
    (insert "#00ff00")
    (goto-char 3)
    (let ((state (emacs-canvas-color-picker--make-at-point-state (current-buffer))))
      (setf (emacs-canvas-color-picker--state-hue state) 0.0
            (emacs-canvas-color-picker--state-saturation state) 1.0
            (emacs-canvas-color-picker--state-value state) 1.0)
      (funcall (emacs-canvas-color-picker--state-callback state) "#ff0000")
      (should (equal (buffer-string) "#ff0000")))))

(ert-deftest emacs-canvas-color-picker-test-at-point-replaces-bare-color ()
  "At-point accept replaces a bare hex color without adding #."
  (with-temp-buffer
    (insert "00ff00")
    (goto-char 3)
    (let ((state (emacs-canvas-color-picker--make-at-point-state (current-buffer))))
      (funcall (emacs-canvas-color-picker--state-callback state) "#ff0000")
      (should (equal (buffer-string) "ff0000")))))

(ert-deftest emacs-canvas-color-picker-test-at-point-inserts-when-no-color ()
  "At-point accept inserts #rrggbb when no color is at point."
  (with-temp-buffer
    (insert "color: ")
    (let ((state (emacs-canvas-color-picker--make-at-point-state (current-buffer))))
      (funcall (emacs-canvas-color-picker--state-callback state) "#ff0000")
      (should (equal (buffer-string) "color: #ff0000")))))

(ert-deftest emacs-canvas-color-picker-test-insert-command-does-not-replace-at-point ()
  "Insert callback inserts at point and does not replace an existing color."
  (with-temp-buffer
    (insert "#00ff00")
    (goto-char 1)
    (let ((state (emacs-canvas-color-picker--make-insert-state (current-buffer) nil)))
      (funcall (emacs-canvas-color-picker--state-callback state) "#ff0000")
      (should (equal (buffer-string) "#ff0000#00ff00")))))

(ert-deftest emacs-canvas-color-picker-test-commands-are-interactive ()
  "Public wrapper commands are interactive commands."
  (should (commandp 'emacs-canvas-color-picker-copy))
  (should (commandp 'emacs-canvas-color-picker-insert))
  (should (commandp 'emacs-canvas-color-picker-at-point)))

(defun emacs-canvas-color-picker-test--at-point (text offset expected &optional initial)
  "Accept a color at OFFSET in TEXT and compare it with EXPECTED."
  (with-temp-buffer
    (insert text)
    (goto-char (+ (point-min) offset))
    (let ((state (emacs-canvas-color-picker--make-at-point-state (current-buffer))))
      (when initial
        (let ((hsv (emacs-canvas-color-picker--hex-to-hsv initial)))
          (should (emacs-canvas-color-picker-test--close-to
                   (emacs-canvas-color-picker--state-hue state) (nth 0 hsv)))
          (should (emacs-canvas-color-picker-test--close-to
                   (emacs-canvas-color-picker--state-saturation state) (nth 1 hsv)))
          (should (emacs-canvas-color-picker-test--close-to
                   (emacs-canvas-color-picker--state-value state) (nth 2 hsv)))))
      (funcall (emacs-canvas-color-picker--state-callback state) "#aabbcc")
      (should (equal (buffer-string) expected)))))

(ert-deftest emacs-canvas-color-picker-test-at-point-css-rgba-keeps-alpha ()
  "CSS RGBA starts from RGB and preserves its trailing alpha."
  (emacs-canvas-color-picker-test--at-point
   "#11223344" 3 "#aabbcc44" "#112233"))

(ert-deftest emacs-canvas-color-picker-test-at-point-preserves-mixed-alpha-case ()
  "Keep existing alpha text while converting selected RGB to lowercase."
  (dolist (case '(("#112233aF" 8 "#aabbccaF")
                  ("#xaF112233" 3 "#xaFaabbcc")
                  ("#xfA112233" 3 "#xfAaabbcc")))
    (ert-info ((car case))
      (emacs-canvas-color-picker-test--at-point
       (nth 0 case) (nth 1 case) (nth 2 case) "#112233"))))

(ert-deftest emacs-canvas-color-picker-test-at-point-supported-prefixes ()
  "Recognize complete Emacs, C, CSS, and bare literals."
  (dolist (case '(("#x44112233" "#x44aabbcc")
                  ("#x112233" "#xaabbcc")
                  ("0x112233" "0xaabbcc")
                  ("#112233" "#aabbcc")
                  ("112233" "aabbcc")))
    (ert-info ((car case))
      (emacs-canvas-color-picker-test--at-point
       (car case) 3 (cadr case) "#112233"))))

(ert-deftest emacs-canvas-color-picker-test-at-point-uppercase-rgb ()
  "Initialize from uppercase digits and emit lowercase selected RGB."
  (dolist (case '(("#AABBCCdE" "#aabbccdE")
                  ("#xdEAABBCC" "#xdEaabbcc")
                  ("#xAABBCC" "#xaabbcc")
                  ("0xAABBCC" "0xaabbcc")
                  ("#AABBCC" "#aabbcc")
                  ("AABBCC" "aabbcc")))
    (ert-info ((car case))
      (emacs-canvas-color-picker-test--at-point
       (car case) 3 (cadr case) "#aabbcc"))))

(ert-deftest emacs-canvas-color-picker-test-at-point-any-character ()
  "Point on prefixes, RGB, and alpha identifies the full literal."
  (dolist (case '(("#11223344" "#aabbcc44")
                  ("#x44112233" "#x44aabbcc")
                  ("#x112233" "#xaabbcc")
                  ("0x112233" "0xaabbcc")
                  ("#112233" "#aabbcc")
                  ("112233" "aabbcc")))
    (dotimes (offset (length (car case)))
      (ert-info ((format "%s at %d" (car case) offset))
        (emacs-canvas-color-picker-test--at-point
         (car case) offset (cadr case) "#112233")))))

(ert-deftest emacs-canvas-color-picker-test-at-point-preserves-neighbors ()
  "Replace only the literal at point, even between other literals."
  (emacs-canvas-color-picker-test--at-point
   "L:#11223344; R:#44556677" 5 "L:#aabbcc44; R:#44556677" "#112233")
  (emacs-canvas-color-picker-test--at-point
   "(#x44112233)" 5 "(#x44aabbcc)" "#112233"))

(ert-deftest emacs-canvas-color-picker-test-at-point-rejects-partial-tokens ()
  "Insert at point instead of replacing a substring of a larger token."
  (dolist (text '("#112233445" "#x441122334" "0x1122334" "1122334"
                  "#1122334" "#x11223" "0x11223" "#11223g44"
                  "g112233" "#112233g" "112233z"))
    (ert-info (text)
      (emacs-canvas-color-picker-test--at-point
       text 3 (concat (substring text 0 3) "#aabbcc" (substring text 3))))))

(ert-deftest emacs-canvas-color-picker-test-at-point-unsupported-inserts ()
  "Insert into ordinary text or an empty buffer without replacement."
  (emacs-canvas-color-picker-test--at-point "" 0 "#aabbcc")
  (emacs-canvas-color-picker-test--at-point "word" 2 "wo#aabbccrd"))

(ert-deftest emacs-canvas-color-picker-test-copy-default-output ()
  "The default copy command writes the chosen RGB to the kill ring."
  (with-temp-buffer
    (insert "keep")
    (let ((kill-ring nil)
          (kill-ring-yank-pointer nil))
      (cl-letf (((symbol-function 'emacs-canvas-color-picker-read-color)
                 (lambda (callback &rest _args) (funcall callback "#aabbcc"))))
        (emacs-canvas-color-picker-copy)
        (should (equal (car kill-ring) "#aabbcc"))
        (should (equal (buffer-string) "keep"))))))

(ert-deftest emacs-canvas-color-picker-test-insert-default-output ()
  "The default insert command writes chosen RGB without replacement."
  (with-temp-buffer
    (insert "keep")
    (goto-char 3)
    (cl-letf (((symbol-function 'emacs-canvas-color-picker--open-state)
               (lambda (state)
                 (funcall (emacs-canvas-color-picker--state-callback state) "#aabbcc"))))
      (emacs-canvas-color-picker-insert)
      (should (equal (buffer-string) "ke#aabbccep")))))

(ert-deftest emacs-canvas-color-picker-test-copy-output-formats ()
  "Copy the chosen color in the requested format, with lowercase alpha."
  (dolist (case '((nil "#aabbcc")
                  (css-rgb "#aabbcc")
                  (css-rgba "#aabbccff")
                  (emacs-argb "#xffaabbcc")
                  (emacs-rgb "#xaabbcc")
                  (c-rgb "0xaabbcc")))
    (ert-info ((format "%s" (car case)))
      (with-temp-buffer
        (insert "keep")
        (let ((kill-ring nil)
              (kill-ring-yank-pointer nil)
              (received nil))
          (cl-letf (((symbol-function 'emacs-canvas-color-picker-read-color)
                     (lambda (callback &rest args)
                       (setq received args)
                       (funcall callback "#aabbcc"))))
            (emacs-canvas-color-picker-copy "#DDEEFF" (car case))
            (should (equal (car received) "#DDEEFF"))
            (should (equal (car kill-ring) (cadr case)))
            (should (equal (buffer-string) "keep"))))))))

(ert-deftest emacs-canvas-color-picker-test-copy-bare-initial-color ()
  "The first argument also accepts bare six-digit RGB."
  (with-temp-buffer
    (let ((kill-ring nil)
          (kill-ring-yank-pointer nil)
          (received nil))
      (cl-letf (((symbol-function 'emacs-canvas-color-picker-read-color)
                 (lambda (callback &rest args)
                   (setq received args)
                   (funcall callback "#aabbcc"))))
        (emacs-canvas-color-picker-copy "DDEEFF" 'css-rgba)
        (should (equal (car received) "DDEEFF"))
        (should (equal (car kill-ring) "#aabbccff"))))))

(ert-deftest emacs-canvas-color-picker-test-insert-output-formats ()
  "Insert formatted selected RGB without replacing an existing literal."
  (dolist (case '((nil "#aabbcc")
                  (css-rgb "#aabbcc")
                  (css-rgba "#aabbccff")
                  (emacs-argb "#xffaabbcc")
                  (emacs-rgb "#xaabbcc")
                  (c-rgb "0xaabbcc")))
    (ert-info ((format "%s" (car case)))
      (with-temp-buffer
        (insert "#112233")
        (goto-char 4)
        (let ((initial-hsv (emacs-canvas-color-picker--hex-to-hsv "#DDEEFF"))
              (opened 0))
          (cl-letf (((symbol-function 'emacs-canvas-color-picker--open-state)
                     (lambda (state)
                       (setq opened (1+ opened))
                       (should (emacs-canvas-color-picker-test--close-to
                                (emacs-canvas-color-picker--state-hue state) (nth 0 initial-hsv)))
                       (should (emacs-canvas-color-picker-test--close-to
                                (emacs-canvas-color-picker--state-saturation state) (nth 1 initial-hsv)))
                       (should (emacs-canvas-color-picker-test--close-to
                                (emacs-canvas-color-picker--state-value state) (nth 2 initial-hsv)))
                       (funcall (emacs-canvas-color-picker--state-callback state) "#aabbcc"))))
            (emacs-canvas-color-picker-insert "#DDEEFF" (car case))
            (should (= opened 1))
            (should (equal (buffer-string)
                           (concat "#11" (cadr case) "2233")))))))))

(ert-deftest emacs-canvas-color-picker-test-insert-bare-initial-color ()
  "Insert accepts bare RGB as its first argument."
  (with-temp-buffer
    (let ((initial-hsv (emacs-canvas-color-picker--hex-to-hsv "DDEEFF")))
      (cl-letf (((symbol-function 'emacs-canvas-color-picker--open-state)
                 (lambda (state)
                   (should (emacs-canvas-color-picker-test--close-to
                            (emacs-canvas-color-picker--state-hue state) (nth 0 initial-hsv)))
                   (funcall (emacs-canvas-color-picker--state-callback state) "#aabbcc"))))
        (emacs-canvas-color-picker-insert "DDEEFF" 'css-rgba)
        (should (equal (buffer-string) "#aabbccff"))))))

(ert-deftest emacs-canvas-color-picker-test-copy-invalid-format-before-open ()
  "An invalid output symbol fails without opening or changing the kill ring."
  (dolist (format '(unsupported css-rgbb))
    (with-temp-buffer
      (insert "keep")
      (let ((kill-ring '("original"))
            (kill-ring-yank-pointer nil)
            (opened 0))
        (cl-letf (((symbol-function 'emacs-canvas-color-picker-read-color)
                   (lambda (&rest _args) (setq opened (1+ opened)))))
          (let ((failure (should-error (emacs-canvas-color-picker-copy "#112233" format))))
            (should-not (eq (car failure) 'wrong-number-of-arguments)))
          (should (= opened 0))
          (should (equal kill-ring '("original")))
          (should (equal (buffer-string) "keep")))))))

(ert-deftest emacs-canvas-color-picker-test-insert-invalid-format-before-open ()
  "An invalid output symbol fails before opening or changing the buffer."
  (dolist (format '(unsupported css-rgbb))
    (with-temp-buffer
      (insert "keep")
      (let ((kill-ring '("original"))
            (kill-ring-yank-pointer nil)
            (opened 0))
        (cl-letf (((symbol-function 'emacs-canvas-color-picker--open-state)
                   (lambda (&rest _args) (setq opened (1+ opened)))))
          (let ((failure (should-error (emacs-canvas-color-picker-insert "#112233" format))))
            (should-not (eq (car failure) 'wrong-number-of-arguments)))
          (should (= opened 0))
          (should (equal kill-ring '("original")))
          (should (equal (buffer-string) "keep")))))))

(provide 'color-picker-test)

;;; color-picker-test.el ends here
