;;; color-picker-test.el --- Tests for canvas color picker -*- lexical-binding: t; -*-
;; Copyright (c) 2026 Håkan Nilsson
;; SPDX-License-Identifier: GPL-3.0-or-later

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

(defun emacs-canvas-color-picker-test--register-native-functions ()
  "Simulate fresh function registrations by `module-load'."
  (fset 'emacs-canvas-color-picker-native-api-version (lambda () 1))
  (fset 'emacs-canvas-color-picker-native-render-full (lambda (&rest _) t)))

(defun emacs-canvas-color-picker-test--http-response (status body &optional location)
  "Return a binary HTTP response buffer with STATUS, BODY, and LOCATION."
  (let ((buffer (generate-new-buffer " *color-picker-http-test*")))
    (with-current-buffer buffer
      (set-buffer-multibyte nil)
      (insert (format "HTTP/1.1 %d Test\r\n" status))
      (when location
        (insert (format "Location: %s\r\n" location)))
      (insert "\r\n" body)
      (setq-local url-http-response-status status))
    buffer))

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

(ert-deftest emacs-canvas-color-picker-test-native-builds-missing-module ()
  "A missing module builds before loading, without displaying a picker."
  (let* ((emacs-canvas-color-picker--native-loaded nil)
         (emacs-canvas-color-picker--native-restart-required nil)
         (emacs-canvas-color-picker-native-module-file
          (make-temp-file "color-picker-test-module-" nil ".so"))
         (events nil))
    (unwind-protect
        (progn
          (delete-file emacs-canvas-color-picker-native-module-file)
          (cl-letf (((symbol-function 'emacs-canvas-color-picker-build-module)
                     (lambda ()
                       (push 'build events)
                       (with-temp-file emacs-canvas-color-picker-native-module-file)))
                    ((symbol-function 'module-load)
                     (lambda (_file)
                       (push 'load events)
                       (emacs-canvas-color-picker-test--register-native-functions)))
                    ((symbol-function 'emacs-canvas-color-picker-native-api-version)
                     (lambda () 1))
                    ((symbol-function 'emacs-canvas-color-picker-native-render-full)
                     (lambda (&rest _) t)))
            (should (emacs-canvas-color-picker-load-native))
            (should (equal (reverse events) '(build load)))))
      (when (file-exists-p emacs-canvas-color-picker-native-module-file)
        (delete-file emacs-canvas-color-picker-native-module-file)))))

(ert-deftest emacs-canvas-color-picker-test-native-choice-skip ()
  "Skipping installation closes the picker without a build or download."
  (let ((noninteractive nil)
        (system-type 'gnu/linux)
        (system-configuration "x86_64-pc-linux-gnu")
        (emacs-canvas-color-picker--native-loaded nil)
        (emacs-canvas-color-picker--native-restart-required nil)
        (emacs-canvas-color-picker--active-state nil)
        (emacs-canvas-color-picker--buffer-name " *color-picker-skip-test*")
        (emacs-canvas-color-picker-native-module-file "/no-such-color-picker-module.so")
        (chosen nil))
    (cl-letf (((symbol-function 'emacs-canvas-color-picker--ensure-canvas-available) #'ignore)
              ((symbol-function 'completing-read)
               (lambda (&rest _) (ert-fail "Used old install prompt")))
              ((symbol-function 'read-char-choice)
               (lambda (prompt choices)
                 (should (equal choices '(?d ?c ?s)))
                 (should (string-match-p "v0.2.0" prompt))
                 (setq chosen t)
                 ?s))
              ((symbol-function 'emacs-canvas-color-picker-build-module)
               (lambda () (ert-fail "Built after skip")))
              ((symbol-function 'emacs-canvas-color-picker-download-module)
               (lambda () (ert-fail "Downloaded after skip")))
              ((symbol-function 'emacs-canvas-color-picker--refresh)
               (lambda (_) (ert-fail "Rendered after skip")))
              ((symbol-function 'module-load)
               (lambda (_) (ert-fail "Loaded after skip"))))
      (should-not (emacs-canvas-color-picker-read-color #'ignore nil 'buffer))
      (should chosen)
      (should-not emacs-canvas-color-picker--active-state)
      (should-not (get-buffer emacs-canvas-color-picker--buffer-name)))))

(ert-deftest emacs-canvas-color-picker-test-native-choice-skip-child-frame ()
  "Skipping installation does not leave a new child-frame buffer behind."
  (let ((noninteractive nil)
        (system-type 'gnu/linux)
        (system-configuration "x86_64-pc-linux-gnu")
        (emacs-canvas-color-picker--native-loaded nil)
        (emacs-canvas-color-picker--native-restart-required nil)
        (emacs-canvas-color-picker--active-state nil)
        (emacs-canvas-color-picker--buffer-name " *color-picker-skip-child-test*")
        (emacs-canvas-color-picker-native-module-file "/no-such-color-picker-module.so"))
    (cl-letf (((symbol-function 'emacs-canvas-color-picker--ensure-canvas-available) #'ignore)
              ((symbol-function 'read-char-choice) (lambda (&rest _) ?s))
              ((symbol-function 'emacs-canvas-color-picker-build-module)
               (lambda () (ert-fail "Built after skip")))
              ((symbol-function 'emacs-canvas-color-picker-download-module)
               (lambda () (ert-fail "Downloaded after skip"))))
      (should-not (emacs-canvas-color-picker-read-color #'ignore nil 'child-frame))
      (should-not emacs-canvas-color-picker--active-state)
      (should-not (get-buffer emacs-canvas-color-picker--buffer-name)))))

(ert-deftest emacs-canvas-color-picker-test-native-choice-skip-keeps-existing-buffer ()
  "Skipping installation preserves an existing child-frame picker buffer."
  (let* ((emacs-canvas-color-picker--buffer-name " *color-picker-existing-skip-test*")
         (buffer (get-buffer-create emacs-canvas-color-picker--buffer-name))
         (noninteractive nil)
         (system-type 'gnu/linux)
         (system-configuration "x86_64-pc-linux-gnu")
         (emacs-canvas-color-picker--native-loaded nil)
         (emacs-canvas-color-picker--native-restart-required nil)
         (emacs-canvas-color-picker--active-state nil)
         (emacs-canvas-color-picker-native-module-file "/no-such-color-picker-module.so"))
    (unwind-protect
        (cl-letf (((symbol-function 'emacs-canvas-color-picker--ensure-canvas-available) #'ignore)
                  ((symbol-function 'read-char-choice) (lambda (&rest _) ?s)))
          (should-not (emacs-canvas-color-picker-read-color #'ignore nil 'child-frame))
          (should (eq buffer (get-buffer emacs-canvas-color-picker--buffer-name)))
          (should-not emacs-canvas-color-picker--active-state))
      (kill-buffer buffer))))

(ert-deftest emacs-canvas-color-picker-test-native-choice-download ()
  "Interactive first use offers a download without starting a build."
  (let* ((noninteractive nil)
         (system-type 'gnu/linux)
         (system-configuration "x86_64-pc-linux-gnu")
         (emacs-canvas-color-picker--native-loaded nil)
         (emacs-canvas-color-picker--native-restart-required nil)
         (emacs-canvas-color-picker-native-module-file
          (concat (make-temp-name (expand-file-name "color-picker-" temporary-file-directory)) ".so"))
         (events nil))
    (unwind-protect
        (cl-letf (((symbol-function 'read-char-choice)
                   (lambda (prompt choices)
                     (should (equal choices '(?d ?c ?s)))
                     (should (string-match-p "v0.2.0" prompt))
                     ?d))
                  ((symbol-function 'emacs-canvas-color-picker-download-module)
                   (lambda () (push 'download events)
                     (with-temp-file emacs-canvas-color-picker-native-module-file)))
                  ((symbol-function 'emacs-canvas-color-picker-build-module)
                   (lambda () (ert-fail "Built without consent")))
                  ((symbol-function 'module-load)
                   (lambda (_)
                     (push 'load events)
                     (emacs-canvas-color-picker-test--register-native-functions)))
                  ((symbol-function 'emacs-canvas-color-picker-native-api-version) (lambda () 1))
                  ((symbol-function 'emacs-canvas-color-picker-native-render-full) (lambda (&rest _) t)))
          (should (emacs-canvas-color-picker-load-native))
          (should (equal (reverse events) '(download load))))
      (when (file-exists-p emacs-canvas-color-picker-native-module-file)
        (delete-file emacs-canvas-color-picker-native-module-file)))))

(ert-deftest emacs-canvas-color-picker-test-native-choice-failure-does-not-build ()
  "A failed download never starts a source build."
  (let ((noninteractive nil)
        (system-type 'gnu/linux)
        (system-configuration "x86_64-pc-linux-gnu")
        (emacs-canvas-color-picker--native-loaded nil)
        (emacs-canvas-color-picker--native-restart-required nil)
        (emacs-canvas-color-picker-native-module-file "/no-such-color-picker-module.so"))
    (cl-letf (((symbol-function 'read-char-choice) (lambda (&rest _) ?d))
              ((symbol-function 'emacs-canvas-color-picker-download-module)
               (lambda () (error "Download failed")))
              ((symbol-function 'emacs-canvas-color-picker-build-module)
               (lambda () (ert-fail "Built after download failure")))
              ((symbol-function 'module-load) (lambda (_) (ert-fail "Loaded after download failure"))))
      (should-error (emacs-canvas-color-picker-load-native) :type 'user-error))))

(ert-deftest emacs-canvas-color-picker-test-native-batch-and-unsupported-build ()
  "Batch use and unsupported hosts build without a network request."
  (dolist (host '((t gnu/linux "x86_64-pc-linux-gnu")
                  (nil darwin "aarch64-apple-darwin")))
    (let ((noninteractive (nth 0 host))
          (system-type (nth 1 host))
          (system-configuration (nth 2 host))
          (emacs-canvas-color-picker--native-loaded nil)
         (emacs-canvas-color-picker--native-restart-required nil)
          (emacs-canvas-color-picker-native-module-file
           (concat (make-temp-name (expand-file-name "color-picker-" temporary-file-directory)) ".so")))
      (unwind-protect
          (cl-letf (((symbol-function 'read-char-choice)
                     (lambda (prompt choices)
                       (when noninteractive (ert-fail "Prompted in batch mode"))
                       (should (equal choices '(?c ?s)))
                       (should-not (string-match-p "\\[d\\]" prompt))
                       ?c))
                    ((symbol-function 'emacs-canvas-color-picker-download-module)
                     (lambda () (ert-fail "Contacted network")))
                    ((symbol-function 'emacs-canvas-color-picker-build-module)
                     (lambda () (with-temp-file emacs-canvas-color-picker-native-module-file)))
                    ((symbol-function 'module-load)
                     (lambda (_) (emacs-canvas-color-picker-test--register-native-functions)))
                    ((symbol-function 'emacs-canvas-color-picker-native-api-version) (lambda () 1))
                    ((symbol-function 'emacs-canvas-color-picker-native-render-full) (lambda (&rest _) t)))
            (should (emacs-canvas-color-picker-load-native)))
        (when (file-exists-p emacs-canvas-color-picker-native-module-file)
          (delete-file emacs-canvas-color-picker-native-module-file))))))

(ert-deftest emacs-canvas-color-picker-test-fetch-asset-binary ()
  "A successful HTTPS response writes the exact binary body."
  (let ((path (make-temp-file "picker-fetch-"))
        (body (unibyte-string 0 255 128 13 10))
        (requests nil))
    (unwind-protect
        (cl-letf (((symbol-function 'url-retrieve-synchronously)
                   (lambda (url &rest _)
                     (push url requests)
                     (emacs-canvas-color-picker-test--http-response 200 body)))
                  ((symbol-function 'call-process)
                   (lambda (&rest _) (ert-fail "Invoked external curl"))))
          (emacs-canvas-color-picker--fetch-asset
           "https://github.com/plux/emacs-canvas-color-picker/releases/download/v0.2.0/module.so"
           path)
          (should (equal (with-temp-buffer
                           (set-buffer-multibyte nil)
                           (insert-file-contents-literally path)
                           (buffer-string)) body))
          (should (= (length requests) 1)))
      (delete-file path))))

(ert-deftest emacs-canvas-color-picker-test-fetch-asset-rejects-http-errors ()
  "An unavailable or missing response never writes an asset."
  (dolist (status '(404 nil))
    (let ((path (make-temp-file "picker-fetch-")))
      (unwind-protect
          (cl-letf (((symbol-function 'url-retrieve-synchronously)
                     (lambda (&rest _)
                       (when status
                         (emacs-canvas-color-picker-test--http-response status "not found"))))
                    ((symbol-function 'call-process)
                     (lambda (&rest _) (ert-fail "Invoked external curl"))))
            (should-error
             (emacs-canvas-color-picker--fetch-asset
              "https://github.com/plux/emacs-canvas-color-picker/releases/download/v0.2.0/module.so"
              path))
            (should (= (file-attribute-size (file-attributes path)) 0)))
        (delete-file path)))))

(ert-deftest emacs-canvas-color-picker-test-fetch-asset-rejects-http-redirect ()
  "A redirect to HTTP is rejected before its destination is requested."
  (let ((path (make-temp-file "picker-fetch-"))
        (requests nil))
    (unwind-protect
        (cl-letf (((symbol-function 'url-retrieve-synchronously)
                   (lambda (url &rest _)
                     (push url requests)
                     (should (= url-max-redirections 0))
                     (emacs-canvas-color-picker-test--http-response
                      302 "" "http://example.com/module.so")))
                  ((symbol-function 'call-process)
                   (lambda (&rest _) (ert-fail "Invoked external curl"))))
          (should-error
           (emacs-canvas-color-picker--fetch-asset
            "https://github.com/plux/emacs-canvas-color-picker/releases/download/v0.2.0/module.so"
            path))
          (should (= (length requests) 1))
          (should (= (file-attribute-size (file-attributes path)) 0)))
      (delete-file path))))

(ert-deftest emacs-canvas-color-picker-test-fetch-asset-https-redirect ()
  "An HTTPS redirect can deliver the asset without losing its bytes."
  (let ((path (make-temp-file "picker-fetch-"))
        (requests nil)
        (body (unibyte-string 0 128 255)))
    (unwind-protect
        (cl-letf (((symbol-function 'url-retrieve-synchronously)
                   (lambda (url &rest _)
                     (push url requests)
                     (if (string-match-p "github.com" url)
                         (emacs-canvas-color-picker-test--http-response
                          302 "" "https://objects.example.com/module.so")
                       (emacs-canvas-color-picker-test--http-response 200 body))))
                  ((symbol-function 'call-process)
                   (lambda (&rest _) (ert-fail "Invoked external curl"))))
          (emacs-canvas-color-picker--fetch-asset
           "https://github.com/plux/emacs-canvas-color-picker/releases/download/v0.2.0/module.so"
           path)
          (should (= (length requests) 2))
          (should (equal (with-temp-buffer
                           (set-buffer-multibyte nil)
                           (insert-file-contents-literally path)
                           (buffer-string)) body)))
      (delete-file path))))

(ert-deftest emacs-canvas-color-picker-test-fetch-asset-rejects-oversize ()
  "An oversized response cannot write an asset."
  (let ((path (make-temp-file "picker-fetch-"))
        (emacs-canvas-color-picker--max-download-bytes 4))
    (unwind-protect
        (cl-letf (((symbol-function 'url-retrieve-synchronously)
                   (lambda (&rest _)
                     (emacs-canvas-color-picker-test--http-response 200 "12345")))
                  ((symbol-function 'call-process)
                   (lambda (&rest _) (ert-fail "Invoked external curl"))))
          (should-error
           (emacs-canvas-color-picker--fetch-asset
            "https://github.com/plux/emacs-canvas-color-picker/releases/download/v0.2.0/module.so"
            path))
          (should (= (file-attribute-size (file-attributes path)) 0)))
      (delete-file path))))

(ert-deftest emacs-canvas-color-picker-test-native-download-verifies-and-installs ()
  "Install only the exact release asset with a matching checksum."
  (let* ((directory (make-temp-file "picker-install-" t))
         (destination (expand-file-name "module.so" directory))
         (emacs-canvas-color-picker-native-module-file destination)
         (emacs-canvas-color-picker--native-loaded nil)
         (emacs-canvas-color-picker--native-restart-required nil)
         (asset "libcolor-picker-v0.2.0-linux-x86_64.so")
         (bytes "native binary fixture")
         (calls nil))
    (unwind-protect
        (cl-letf (((symbol-function 'emacs-canvas-color-picker--fetch-asset)
                   (lambda (url path)
                     (push url calls)
                     (should (string-prefix-p "https://github.com/plux/emacs-canvas-color-picker/releases/download/v0.2.0/" url))
                     (should-not (string-suffix-p ".api" url))
                     (with-temp-file path
                       (set-buffer-multibyte nil)
                       (insert (if (string-suffix-p ".sha256" url)
                                   (format "%s  %s\n" (secure-hash 'sha256 bytes) asset)
                                 bytes)))))
                  ((symbol-function 'module-load)
                   (lambda (path)
                     (should (file-exists-p path))
                     (should (equal (file-name-directory path)
                                    (file-name-directory destination)))
                     (emacs-canvas-color-picker-test--register-native-functions)))
                  ((symbol-function 'emacs-canvas-color-picker-native-api-version) (lambda () 1))
                  ((symbol-function 'emacs-canvas-color-picker-native-render-full) (lambda (&rest _) t)))
          (should (emacs-canvas-color-picker-download-module))
          (should (equal (with-temp-buffer (insert-file-contents-literally destination) (buffer-string)) bytes))
          (should (= (length calls) 2)))
      (when (file-exists-p destination) (delete-file destination))
      (delete-directory directory))))

(ert-deftest emacs-canvas-color-picker-test-native-download-invalid-checksum ()
  "A corrupt or unavailable release leaves no destination file."
  (dolist (response '(corrupt unavailable oversize))
    (let ((destination (concat (make-temp-name (expand-file-name "picker-install-" temporary-file-directory)) ".so"))
          (emacs-canvas-color-picker-native-module-file nil))
      (setq emacs-canvas-color-picker-native-module-file destination)
      (cl-letf (((symbol-function 'emacs-canvas-color-picker--fetch-asset)
                 (lambda (url path)
                   (when (eq response 'unavailable)
                     (error "Release unavailable"))
                   (with-temp-file path
                     (insert (if (string-suffix-p ".sha256" url)
                                 (format "%s  libcolor-picker-v0.2.0-linux-x86_64.so\n" (make-string 64 ?0))
                               "wrong content"))))))
        (should-error (emacs-canvas-color-picker-download-module) :type 'error)
        (should-not (file-exists-p destination))))))

(ert-deftest emacs-canvas-color-picker-test-native-choice-build ()
  "Interactive first use can choose an offline Zig build."
  (let ((noninteractive nil)
        (system-type 'gnu/linux)
        (system-configuration "x86_64-pc-linux-gnu")
        (emacs-canvas-color-picker--native-loaded nil)
        (emacs-canvas-color-picker--native-restart-required nil)
        (emacs-canvas-color-picker-native-module-file
         (concat (make-temp-name (expand-file-name "picker-build-" temporary-file-directory)) ".so")))
    (unwind-protect
        (cl-letf (((symbol-function 'read-char-choice) (lambda (&rest _) ?c))
                  ((symbol-function 'emacs-canvas-color-picker-download-module)
                   (lambda () (ert-fail "Downloaded instead of building")))
                  ((symbol-function 'emacs-canvas-color-picker-build-module)
                   (lambda () (with-temp-file emacs-canvas-color-picker-native-module-file)))
                  ((symbol-function 'module-load)
                   (lambda (_) (emacs-canvas-color-picker-test--register-native-functions)))
                  ((symbol-function 'emacs-canvas-color-picker-native-api-version) (lambda () 1))
                  ((symbol-function 'emacs-canvas-color-picker-native-render-full) (lambda (&rest _) t)))
          (should (emacs-canvas-color-picker-load-native)))
      (when (file-exists-p emacs-canvas-color-picker-native-module-file)
        (delete-file emacs-canvas-color-picker-native-module-file)))))

(ert-deftest emacs-canvas-color-picker-test-native-download-rejects-oversize ()
  "An oversized response never becomes the module."
  (let ((emacs-canvas-color-picker-native-module-file
         (concat (make-temp-name (expand-file-name "picker-oversize-" temporary-file-directory)) ".so"))
        (emacs-canvas-color-picker--native-loaded nil)
        (emacs-canvas-color-picker--native-restart-required nil)
        (emacs-canvas-color-picker--max-download-bytes 100))
    (cl-letf (((symbol-function 'emacs-canvas-color-picker--fetch-asset)
               (lambda (_url _path) (error "Release asset exceeds size limit")))
              ((symbol-function 'module-load) (lambda (_) (ert-fail "Loaded oversized response"))))
      (should-error (emacs-canvas-color-picker-download-module))
      (should-not (file-exists-p emacs-canvas-color-picker-native-module-file)))))

(ert-deftest emacs-canvas-color-picker-test-native-download-rejects-existing ()
  "A download does not replace an existing module."
  (let ((emacs-canvas-color-picker-native-module-file
         (make-temp-file "picker-existing-" nil ".so")))
    (unwind-protect
        (cl-letf (((symbol-function 'emacs-canvas-color-picker--fetch-asset)
                   (lambda (&rest _) (ert-fail "Contacted network"))))
          (should-error (emacs-canvas-color-picker-download-module) :type 'user-error)
          (should (file-exists-p emacs-canvas-color-picker-native-module-file)))
      (delete-file emacs-canvas-color-picker-native-module-file))))

(ert-deftest emacs-canvas-color-picker-test-native-download-rejects-incompatible-api ()
  "A valid checksum cannot install an incompatible native API."
  (let* ((destination (concat (make-temp-name (expand-file-name "picker-incompatible-" temporary-file-directory)) ".so"))
         (emacs-canvas-color-picker-native-module-file destination)
         (emacs-canvas-color-picker--native-loaded nil)
         (emacs-canvas-color-picker--native-restart-required nil)
         (asset "libcolor-picker-v0.2.0-linux-x86_64.so")
         (bytes "incompatible fixture"))
    (cl-letf (((symbol-function 'emacs-canvas-color-picker--fetch-asset)
               (lambda (url path)
                 (with-temp-file path
                   (insert (if (string-suffix-p ".sha256" url)
                               (format "%s  %s\n" (secure-hash 'sha256 bytes) asset)
                             bytes)))))
              ((symbol-function 'module-load) #'ignore)
              ((symbol-function 'emacs-canvas-color-picker-native-api-version) (lambda () 2))
              ((symbol-function 'emacs-canvas-color-picker-native-render-full) (lambda (&rest _) t)))
      (should-error (emacs-canvas-color-picker-download-module))
      (should-not (file-exists-p destination)))))

(ert-deftest emacs-canvas-color-picker-test-native-download-post-load-requires-restart ()
  "A live API mismatch prevents retry in the same Emacs session."
  (let* ((emacs-canvas-color-picker--native-loaded nil)
         (emacs-canvas-color-picker--native-restart-required nil)
         (emacs-canvas-color-picker-native-module-file
          (expand-file-name "module.so" (make-temp-file "picker-api-" t)))
         (asset "libcolor-picker-v0.2.0-linux-x86_64.so")
         (bytes "native fixture")
         (loads 0))
    (unwind-protect
        (cl-letf (((symbol-function 'emacs-canvas-color-picker--fetch-asset)
                   (lambda (url path)
                     (with-temp-file path
                       (insert (if (string-suffix-p ".sha256" url)
                                   (format "%s  %s\n" (secure-hash 'sha256 bytes) asset)
                                 bytes)))))
                  ((symbol-function 'module-load)
                   (lambda (_)
                     (cl-incf loads)
                     (fset 'emacs-canvas-color-picker-native-api-version (lambda () 2))
                     (fset 'emacs-canvas-color-picker-native-render-full (lambda (&rest _) t))))
                  ((symbol-function 'emacs-canvas-color-picker-native-api-version) (lambda () 1))
                  ((symbol-function 'emacs-canvas-color-picker-native-render-full) (lambda (&rest _) t)))
          (let ((error (should-error (emacs-canvas-color-picker-download-module))))
            (should (string-match-p "incompatible" (error-message-string error)))
            (should (string-match-p "Restart Emacs" (error-message-string error))))
          (should emacs-canvas-color-picker--native-restart-required)
          (should-error (emacs-canvas-color-picker-load-native) :type 'user-error)
          (should (= loads 1))
          (should-not (file-exists-p emacs-canvas-color-picker-native-module-file)))
      (delete-directory (file-name-directory emacs-canvas-color-picker-native-module-file)))))

(ert-deftest emacs-canvas-color-picker-test-native-build-uses-configured-header ()
  "The native build uses the selected Zig command and Emacs header directory."
  (let ((emacs-canvas-color-picker-zig-command "zig-test")
        (emacs-canvas-color-picker-emacs-include-dir "/emacs 32/include")
        (emacs-canvas-color-picker-native-module-file emacs-canvas-color-picker-test--project-dir)
        (invocation nil))
    (cl-letf (((symbol-function 'executable-find) (lambda (_command) "zig-test"))
              ((symbol-function 'call-process)
               (lambda (program _infile _destination _display &rest args)
                 (setq invocation (list program args default-directory))
                 0)))
      (should (emacs-canvas-color-picker-build-module))
      (should (equal (car invocation) "zig-test"))
      (should (equal (cadr invocation)
                     '("build" "-Doptimize=ReleaseFast"
                       "-Demacs-include-dir=/emacs 32/include")))
      (should (equal (file-truename (caddr invocation))
                     (file-truename emacs-canvas-color-picker-test--project-dir))))))

(ert-deftest emacs-canvas-color-picker-test-native-build-failure-shows-log ()
  "A failed Zig build keeps its output visible for diagnosis."
  (let ((emacs-canvas-color-picker-zig-command "zig-test")
        (emacs-canvas-color-picker-emacs-include-dir "/emacs/include")
        (shown nil))
    (cl-letf (((symbol-function 'executable-find) (lambda (_command) "zig-test"))
              ((symbol-function 'call-process)
               (lambda (_program _infile destination _display &rest _args)
                 (with-current-buffer destination
                   (insert "compiler failed"))
                 1))
              ((symbol-function 'display-buffer)
               (lambda (buffer &rest _args) (setq shown buffer))))
      (should-error (emacs-canvas-color-picker-build-module) :type 'user-error)
      (should (eq shown (get-buffer "*color-picker-build*")))
      (should (with-current-buffer shown
                (string-match-p "compiler failed" (buffer-string)))))))

(ert-deftest emacs-canvas-color-picker-test-native-existing-module-skips-build ()
  "An existing module loads without running Zig."
  (let ((emacs-canvas-color-picker--native-loaded nil)
        (emacs-canvas-color-picker--native-restart-required nil)
        (emacs-canvas-color-picker-native-module-file emacs-canvas-color-picker-test--project-dir)
        (loaded nil))
    (cl-letf (((symbol-function 'emacs-canvas-color-picker-build-module)
               (lambda () (ert-fail "Rebuilt an existing module")))
              ((symbol-function 'module-load)
               (lambda (_file)
                 (setq loaded t)
                 (emacs-canvas-color-picker-test--register-native-functions)))
              ((symbol-function 'emacs-canvas-color-picker-native-api-version)
               (lambda () 1))
              ((symbol-function 'emacs-canvas-color-picker-native-render-full)
               (lambda (&rest _) t)))
      (should (emacs-canvas-color-picker-load-native))
      (should loaded))))

(ert-deftest emacs-canvas-color-picker-test-native-rejects-stale-bindings ()
  "Do not accept global functions left by an earlier module."
  (let ((emacs-canvas-color-picker--native-loaded nil)
        (emacs-canvas-color-picker--native-restart-required nil)
        (emacs-canvas-color-picker-native-module-file emacs-canvas-color-picker-test--project-dir))
    (cl-letf (((symbol-function 'module-load) #'ignore)
              ((symbol-function 'emacs-canvas-color-picker-native-api-version) (lambda () 1))
              ((symbol-function 'emacs-canvas-color-picker-native-render-full) (lambda (&rest _) t)))
      (should-error (emacs-canvas-color-picker-load-native) :type 'user-error)
      (should-not emacs-canvas-color-picker--native-loaded)
      (should emacs-canvas-color-picker--native-restart-required))))

(ert-deftest emacs-canvas-color-picker-test-native-download-rejects-stale-renderer ()
  "Do not install a release that registers only its API function."
  (let* ((emacs-canvas-color-picker--native-loaded nil)
         (emacs-canvas-color-picker--native-restart-required nil)
         (directory (make-temp-file "picker-stale-" t))
         (emacs-canvas-color-picker-native-module-file
          (expand-file-name "module.so" directory))
         (asset "libcolor-picker-v0.2.0-linux-x86_64.so")
         (bytes "native fixture"))
    (unwind-protect
        (cl-letf (((symbol-function 'emacs-canvas-color-picker--fetch-asset)
                   (lambda (url path)
                     (with-temp-file path
                       (insert (if (string-suffix-p ".sha256" url)
                                   (format "%s  %s\n" (secure-hash 'sha256 bytes) asset)
                                 bytes)))))
                  ((symbol-function 'module-load)
                   (lambda (_)
                     (fset 'emacs-canvas-color-picker-native-api-version (lambda () 1))))
                  ((symbol-function 'emacs-canvas-color-picker-native-api-version) (lambda () 1))
                  ((symbol-function 'emacs-canvas-color-picker-native-render-full) (lambda (&rest _) t)))
          (let ((error (should-error (emacs-canvas-color-picker-download-module))))
            (should (string-match-p "Restart Emacs" (error-message-string error))))
          (should emacs-canvas-color-picker--native-restart-required)
          (should-not (file-exists-p emacs-canvas-color-picker-native-module-file)))
      (when (file-exists-p emacs-canvas-color-picker-native-module-file)
        (delete-file emacs-canvas-color-picker-native-module-file))
      (delete-directory directory))))

(ert-deftest emacs-canvas-color-picker-test-native-rejects-incompatible-api ()
  "An incompatible module cannot open the picker or render."
  (let ((emacs-canvas-color-picker--active-state nil)
        (emacs-canvas-color-picker--native-loaded nil)
        (emacs-canvas-color-picker--native-restart-required nil)
        (emacs-canvas-color-picker-native-module-file emacs-canvas-color-picker-test--project-dir))
    (cl-letf (((symbol-function 'emacs-canvas-color-picker--ensure-canvas-available) #'ignore)
              ((symbol-function 'module-load) #'ignore)
              ((symbol-function 'emacs-canvas-color-picker-native-api-version) (lambda () 2))
              ((symbol-function 'emacs-canvas-color-picker-native-render-full)
               (lambda (&rest _) (ert-fail "Rendered with incompatible module")))
              ((symbol-function 'emacs-canvas-color-picker--refresh)
               (lambda (&rest _) (ert-fail "Opened with incompatible module"))))
      (should-error (emacs-canvas-color-picker-read-color #'ignore "#ff0000" 'buffer)
                    :type 'user-error)
      (should-not emacs-canvas-color-picker--native-loaded)
      (should-not emacs-canvas-color-picker--active-state))))

(ert-deftest emacs-canvas-color-picker-test-native-checks-loaded-api ()
  "A cached module still requires a matching API version."
  (let ((emacs-canvas-color-picker--native-loaded t)
        (emacs-canvas-color-picker--native-restart-required nil))
    (cl-letf (((symbol-function 'module-load) (lambda (_) (ert-fail "Reloaded module")))
              ((symbol-function 'emacs-canvas-color-picker-native-api-version) (lambda () 2))
              ((symbol-function 'emacs-canvas-color-picker-native-render-full) (lambda (&rest _) t)))
      (should-error (emacs-canvas-color-picker-load-native) :type 'user-error)
      (should-not emacs-canvas-color-picker--native-loaded)
      (should emacs-canvas-color-picker--native-restart-required))))

(ert-deftest emacs-canvas-color-picker-test-native-required-before-render ()
  "A failed native build stops opening before rendering or displaying."
  (let ((emacs-canvas-color-picker--active-state nil)
        (emacs-canvas-color-picker--native-loaded nil)
        (emacs-canvas-color-picker--native-restart-required nil)
        (emacs-canvas-color-picker-native-module-file "/no-such-color-picker-module.so")
        (rendered nil)
        (build-attempted nil))
    (cl-letf (((symbol-function 'emacs-canvas-color-picker--ensure-canvas-available) #'ignore)
              ((symbol-function 'emacs-canvas-color-picker-build-module)
               (lambda () (setq build-attempted t) (user-error "Native build failed")))
              ((symbol-function 'emacs-canvas-color-picker--refresh)
               (lambda (&rest _) (setq rendered t)))
              ((symbol-function 'emacs-canvas-color-picker--setup-buffer)
               (lambda (&rest _) (ert-fail "Picker displayed without a module"))))
      (should-error (emacs-canvas-color-picker-read-color #'ignore "#ff0000" 'buffer)
                    :type 'user-error)
      (should build-attempted)
      (should-not rendered)
      (should-not emacs-canvas-color-picker--active-state))))

(ert-deftest emacs-canvas-color-picker-test-native-load-failure-cleans-preview ()
  "A failed module load leaves source text and window state unchanged."
  (let ((emacs-canvas-color-picker--active-state nil)
        (emacs-canvas-color-picker--native-loaded nil)
        (emacs-canvas-color-picker--native-restart-required nil)
        (emacs-canvas-color-picker-native-module-file emacs-canvas-color-picker-test--project-dir))
    (save-window-excursion
      (with-temp-buffer
        (insert "keep")
        (set-window-buffer (selected-window) (current-buffer))
        (cl-letf (((symbol-function 'emacs-canvas-color-picker--ensure-canvas-available) #'ignore)
                  ((symbol-function 'module-load) (lambda (_path) (error "module failed")))
                  ((symbol-function 'emacs-canvas-color-picker--refresh)
                   (lambda (&rest _) (ert-fail "Rendered without a module"))))
          (should-error (emacs-canvas-color-picker-insert "#ff0000") :type 'user-error)
          (should (equal (buffer-string) "keep"))
          (should-not (overlays-in (point-min) (point-max)))
          (should-not emacs-canvas-color-picker--active-state))))))

(ert-deftest emacs-canvas-color-picker-test-native-missing-entry-point ()
  "Opening fails cleanly when a loaded module has no full renderer."
  (let ((emacs-canvas-color-picker--active-state nil)
        (emacs-canvas-color-picker--native-loaded nil)
        (emacs-canvas-color-picker--native-restart-required nil)
        (emacs-canvas-color-picker-native-module-file emacs-canvas-color-picker-test--project-dir))
    (cl-letf (((symbol-function 'emacs-canvas-color-picker--ensure-canvas-available) #'ignore)
              ((symbol-function 'module-load) #'ignore)
              ((symbol-function 'emacs-canvas-color-picker-native-render-full) nil))
      (should-error (emacs-canvas-color-picker-read-color #'ignore "#ff0000" 'buffer)
                    :type 'user-error)
      (should-not emacs-canvas-color-picker--active-state))))

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
                 :geometry geometry
                 :hue 0.5
                 :saturation 0.25
                 :value 0.75))
         (full-args nil))
    (cl-letf (((symbol-function 'emacs-canvas-color-picker-native-render-full) (lambda (&rest args) (setq full-args args) t))
              ((symbol-function 'canvas-refresh) (lambda (&rest _args) nil)))
      (emacs-canvas-color-picker--refresh state)
      (should (equal (nthcdr 6 full-args)
                     (list (emacs-canvas-color-picker--geometry-padding geometry)
                           (emacs-canvas-color-picker--geometry-gap geometry)
                           (emacs-canvas-color-picker--geometry-hue-width geometry)
                           (emacs-canvas-color-picker--geometry-swatch-width geometry)
                           (emacs-canvas-color-picker--geometry-swatch-height geometry)
                           (emacs-canvas-color-picker--geometry-swatch-gap geometry)
                           (emacs-canvas-color-picker--geometry-marker-radius geometry)
                           0.5
                           0.25
                           0.75
                           0))))))

(ert-deftest emacs-canvas-color-picker-test-native-refresh-does-not-reload-elisp-data ()
  "Native canvas writes refresh without reloading stale Elisp data."
  (let* ((geometry (emacs-canvas-color-picker-test--small-geometry))
         (data (make-vector (* (emacs-canvas-color-picker--geometry-width geometry)
                               (emacs-canvas-color-picker--geometry-height geometry))
                            0))
         (canvas (list 'image :type 'canvas :id 'test-canvas
                       :data-width (emacs-canvas-color-picker--geometry-width geometry)
                       :data-height (emacs-canvas-color-picker--geometry-height geometry)
                       :data data))
         (state (emacs-canvas-color-picker--state-create
                 :canvas canvas
                 :geometry geometry
                 :hue 0.5
                 :saturation 0.25
                 :value 0.75))
         (refresh-args nil))
    (cl-letf (((symbol-function 'emacs-canvas-color-picker-native-render-full) (lambda (&rest _args) t))
              ((symbol-function 'canvas-refresh) (lambda (&rest args) (setq refresh-args args))))
      (emacs-canvas-color-picker--refresh state)
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
  "Current pointer coordinates start at the canvas's first row."
  (cl-letf (((symbol-function 'window-live-p) (lambda (_window) t))
            ((symbol-function 'mouse-pixel-position) (lambda () (list 'frame 50 70)))
            ((symbol-function 'window-frame) (lambda (_window) 'frame))
            ((symbol-function 'window-inside-pixel-edges) (lambda (_window) '(10 20 200 220))))
    (should (equal (emacs-canvas-color-picker--current-pointer-coordinates 'window)
                   '(40 . 50)))))

(ert-deftest emacs-canvas-color-picker-test-current-pointer-coordinates-exclude-fringe ()
  "Buffer-mode drags use the canvas text edge, not the fringe."
  (save-window-excursion
    (with-temp-buffer
      (set-window-buffer (selected-window) (current-buffer))
      (setq-local emacs-canvas-color-picker--state
                  (emacs-canvas-color-picker--state-create :display 'buffer))
      (cl-letf (((symbol-function 'mouse-pixel-position)
                 (lambda () (list (selected-frame) 50 70)))
                ((symbol-function 'window-inside-pixel-edges) (lambda (_window) '(10 20 200 220)))
                ((symbol-function 'window-body-pixel-edges) (lambda (_window) '(18 20 200 220))))
        (should (equal (emacs-canvas-color-picker--current-pointer-coordinates (selected-window))
                       '(32 . 50)))))))

(ert-deftest emacs-canvas-color-picker-test-current-pointer-coordinates-child-frame-inside-edge ()
  "Child-frame drags retain their original inside-edge coordinates."
  (save-window-excursion
    (with-temp-buffer
      (set-window-buffer (selected-window) (current-buffer))
      (setq-local emacs-canvas-color-picker--state
                  (emacs-canvas-color-picker--state-create :display 'child-frame))
      (cl-letf (((symbol-function 'mouse-pixel-position)
                 (lambda () (list (selected-frame) 50 70)))
                ((symbol-function 'window-inside-pixel-edges) (lambda (_window) '(10 20 200 220)))
                ((symbol-function 'window-body-pixel-edges) (lambda (_window) '(18 20 200 220))))
        (should (equal (emacs-canvas-color-picker--current-pointer-coordinates (selected-window))
                       '(40 . 50)))))))

(ert-deftest emacs-canvas-color-picker-test-current-pointer-coordinates-handle-dotted-mouse-position ()
  "Current pointer coordinates handle `(FRAME . (X . Y))` mouse positions."
  (cl-letf (((symbol-function 'window-live-p) (lambda (_window) t))
            ((symbol-function 'mouse-pixel-position) (lambda () (cons 'frame (cons 50 70))))
            ((symbol-function 'window-frame) (lambda (_window) 'frame))
            ((symbol-function 'window-inside-pixel-edges) (lambda (_window) '(10 20 200 220))))
    (should (equal (emacs-canvas-color-picker--current-pointer-coordinates 'window)
                   '(40 . 50)))))

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

(ert-deftest emacs-canvas-color-picker-test-format-preview-read-color ()
  "The read-color preview and callback use the same requested format."
  (dolist (case '((nil "#ff0000")
                  (css-rgb "#ff0000")
                  (css-rgba "#ff0000ff")
                  (emacs-argb "#xffff0000")
                  (emacs-rgb "#xff0000")
                  (c-rgb "0xff0000")))
    (ert-info ((format "format %S" (car case)))
      (let (preview received)
        (cl-letf (((symbol-function 'emacs-canvas-color-picker--open-state)
                   (lambda (state)
                     (setq preview (emacs-canvas-color-picker--status-text state))
                     (cl-letf (((symbol-function 'emacs-canvas-color-picker--cleanup) #'ignore))
                       (emacs-canvas-color-picker--accept state)))))
          (emacs-canvas-color-picker-read-color
           (lambda (value) (setq received value)) "#ff0000" nil (car case)))
        (should (equal received (cadr case)))
        (should (string-prefix-p (concat received "    RET") preview))))))

(ert-deftest emacs-canvas-color-picker-test-format-preview-read-color-existing-arguments ()
  "Existing read-color calls retain the default callback and display format."
  (let (received)
    (cl-letf (((symbol-function 'emacs-canvas-color-picker--open-state)
               (lambda (state)
                 (should (eq (emacs-canvas-color-picker--state-display state) 'buffer))
                 (should (string-prefix-p "#ff0000    RET"
                                          (emacs-canvas-color-picker--status-text state)))
                 (cl-letf (((symbol-function 'emacs-canvas-color-picker--cleanup) #'ignore))
                   (emacs-canvas-color-picker--accept state)))))
      (emacs-canvas-color-picker-read-color
       (lambda (text) (setq received text)) "#ff0000" 'buffer))
    (should (equal received "#ff0000"))))

(ert-deftest emacs-canvas-color-picker-test-format-preview-invalid-before-open ()
  "An invalid read-color output format fails before state allocation."
  (let ((allocated nil))
    (cl-letf (((symbol-function 'emacs-canvas-color-picker--make-state)
               (lambda (&rest _args) (setq allocated t))))
      (should-error (emacs-canvas-color-picker-read-color #'ignore nil nil 'bare))
      (should-not allocated))))

(ert-deftest emacs-canvas-color-picker-test-format-preview-updates-status ()
  "A changed color updates the echo message, not the canvas-only buffer."
  (with-temp-buffer
    (let ((messages nil)
          (state (emacs-canvas-color-picker--state-create
                  :buffer (current-buffer)
                  :canvas '(image :type canvas :id test)
                  :output-format 'emacs-argb
                  :hue 0.0 :saturation 1.0 :value 1.0)))
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (push (apply #'format format-string args) messages))))
        (emacs-canvas-color-picker--setup-buffer state)
        (emacs-canvas-color-picker--update-status state)
        (should (equal (car messages) "#xffff0000"))
        (setf (emacs-canvas-color-picker--state-hue state) (/ 1.0 3.0))
        (emacs-canvas-color-picker--update-status state)
        (should (equal (car messages) "#xff00ff00"))
        (should (equal (buffer-string) " "))))))

(ert-deftest emacs-canvas-color-picker-test-format-preview-copy-and-insert ()
  "Copy and insert show and emit the selected output format."
  (dolist (command '(emacs-canvas-color-picker-copy emacs-canvas-color-picker-insert))
    (dolist (case '((nil "#ff0000") (css-rgba "#ff0000ff")
                    (emacs-argb "#xffff0000") (emacs-rgb "#xff0000")
                    (c-rgb "0xff0000")))
      (ert-info ((format "%S %S" command (car case)))
        (with-temp-buffer
          (let ((kill-ring nil) (kill-ring-yank-pointer nil) (preview nil))
            (cl-letf (((symbol-function 'emacs-canvas-color-picker--open-state)
                       (lambda (state)
                         (setq preview (emacs-canvas-color-picker--status-text state))
                         (cl-letf (((symbol-function 'emacs-canvas-color-picker--cleanup) #'ignore))
                           (emacs-canvas-color-picker--accept state)))))
              (funcall command "#ff0000" (car case) 'buffer))
            (should (string-prefix-p (concat (cadr case) "    RET") preview))
            (should (equal (if (eq command 'emacs-canvas-color-picker-copy)
                               (car kill-ring)
                             (buffer-string))
                           (cadr case)))))))))

(ert-deftest emacs-canvas-color-picker-test-format-preview-at-point ()
  "At-point preview matches replacement and retains original alpha text."
  (dolist (case '(("112233" "ff0000") ("#112233" "#ff0000")
                  ("#112233aF" "#ff0000aF") ("#xAf112233" "#xAfff0000")
                  ("#x112233" "#xff0000") ("0x112233" "0xff0000")
                  ("word" "wo#ff0000rd")))
    (ert-info ((car case))
      (with-temp-buffer
        (insert (car case))
        (goto-char (+ (point-min) (if (equal (car case) "word") 2 3)))
        (let ((state (emacs-canvas-color-picker--make-at-point-state (current-buffer))))
          (setf (emacs-canvas-color-picker--state-hue state) 0.0
                (emacs-canvas-color-picker--state-saturation state) 1.0
                (emacs-canvas-color-picker--state-value state) 1.0)
          (should (string-prefix-p
                   (concat (if (equal (car case) "word") "#ff0000" (cadr case)) "    RET")
                   (emacs-canvas-color-picker--status-text state)))
          (cl-letf (((symbol-function 'emacs-canvas-color-picker--cleanup) #'ignore))
            (emacs-canvas-color-picker--accept state))
          (should (equal (buffer-string) (cadr case))))))))

(ert-deftest emacs-canvas-color-picker-test-update-status-replaces-existing-line ()
  "Repeated echo updates leave the canvas buffer unchanged."
  (with-temp-buffer
    (let ((state (emacs-canvas-color-picker--state-create
                  :buffer (current-buffer)
                  :canvas '(image :type canvas :id test)
                  :hue 0.0 :saturation 1.0 :value 1.0)))
      (cl-letf (((symbol-function 'message) (lambda (&rest _args) nil)))
        (emacs-canvas-color-picker--setup-buffer state)
        (emacs-canvas-color-picker--update-status state)
        (setf (emacs-canvas-color-picker--state-hue state) (/ 1.0 3.0))
        (emacs-canvas-color-picker--update-status state)
        (should (equal (buffer-string) " "))))))

(ert-deftest emacs-canvas-color-picker-test-echo-canvas-only-buffer ()
  "The picker buffer contains only the canvas display string."
  (with-temp-buffer
    (let ((state (emacs-canvas-color-picker--state-create
                  :buffer (current-buffer)
                  :canvas '(image :type canvas :id test)
                  :hue 0.0 :saturation 1.0 :value 1.0)))
      (emacs-canvas-color-picker--setup-buffer state)
      (should (= (buffer-size) 1))
      (should (equal (buffer-string) " "))
      (should (eq (get-text-property (point-min) 'display) (emacs-canvas-color-picker--state-canvas state))))))

(ert-deftest emacs-canvas-color-picker-test-echo-hints-only-at-startup ()
  "Opening shows the hint once; later updates show only the formatted color."
  (let ((messages nil)
        (state (emacs-canvas-color-picker--state-create
                :hue 0.0 :saturation 1.0 :value 1.0 :output-format 'emacs-rgb)))
    (cl-letf (((symbol-function 'message)
               (lambda (format-string &rest args)
                 (push (apply #'format format-string args) messages))))
      (emacs-canvas-color-picker--update-status state t)
      (setf (emacs-canvas-color-picker--state-hue state) (/ 1.0 3.0))
      (emacs-canvas-color-picker--update-status state)
      (should (equal (reverse messages)
                     '("#xff0000    RET accept, q cancel" "#x00ff00"))))))

(ert-deftest emacs-canvas-color-picker-test-echo-inline-update-does-not-repeat-hints ()
  "Inline preview updates do not replace the initial hint in the echo area."
  (let ((messages nil)
        (state (emacs-canvas-color-picker--state-create
                :hue 0.0 :saturation 1.0 :value 1.0)))
    (cl-letf (((symbol-function 'emacs-canvas-color-picker--update-preview) #'ignore)
              ((symbol-function 'message)
               (lambda (format-string &rest args)
                 (push (apply #'format format-string args) messages))))
      (emacs-canvas-color-picker--update-status state t)
      (cl-letf (((symbol-function 'overlay-buffer) (lambda (_overlay) t))
                ((symbol-function 'overlayp) (lambda (_overlay) t)))
        (setf (emacs-canvas-color-picker--state-preview-overlay state) 'preview)
        (emacs-canvas-color-picker--update-status state))
      (should (equal messages '("#ff0000    RET accept, q cancel"))))))

(ert-deftest emacs-canvas-color-picker-test-echo-updates-format-and-hints ()
  "The echo area shows formatted color without repeated hints."
  (let ((messages nil)
        (state (emacs-canvas-color-picker--state-create
                :hue 0.0 :saturation 1.0 :value 1.0 :output-format 'emacs-rgb)))
    (cl-letf (((symbol-function 'message)
               (lambda (format-string &rest args)
                 (push (apply #'format format-string args) messages))))
      (emacs-canvas-color-picker--update-status state)
      (should (equal (car messages) "#xff0000"))
      (setf (emacs-canvas-color-picker--state-hue state) (/ 1.0 3.0))
      (emacs-canvas-color-picker--update-status state)
      (should (equal (car messages) "#x00ff00")))))

(ert-deftest emacs-canvas-color-picker-test-echo-inline-preview-shows-hints ()
  "An active inline preview leaves only key hints in the echo area."
  (let ((emacs-canvas-color-picker--active-state nil)
        (messages nil))
    (save-window-excursion
      (with-temp-buffer
        (insert "source")
        (set-window-buffer (selected-window) (current-buffer))
        (cl-letf (((symbol-function 'emacs-canvas-color-picker--ensure-canvas-available) #'ignore)
                  ((symbol-function 'emacs-canvas-color-picker--refresh) #'ignore)
                  ((symbol-function 'emacs-canvas-color-picker--make-frame) #'ignore)
                  ((symbol-function 'message)
                   (lambda (format-string &rest args)
                     (push (apply #'format format-string args) messages))))
          (let ((state (emacs-canvas-color-picker-insert "#ff0000" 'emacs-rgb)))
            (unwind-protect
                (progn
                  (should (equal (car messages) "RET accept, q cancel"))
                  (should (equal (overlay-get (emacs-canvas-color-picker--state-preview-overlay state)
                                              'before-string) "#xff0000")))
              (emacs-canvas-color-picker--cancel state))))))))

(ert-deftest emacs-canvas-color-picker-test-echo-opens-in-both-modes ()
  "Opening either display mode publishes formatted hints in the echo area."
  (dolist (display '(child-frame buffer))
    (ert-info ((format "display %S" display))
      (let ((messages nil)
            (emacs-canvas-color-picker--active-state nil)
            state)
        (save-window-excursion
          (let ((caller (selected-window)))
            (cl-letf (((symbol-function 'emacs-canvas-color-picker--ensure-canvas-available) #'ignore)
                      ((symbol-function 'emacs-canvas-color-picker--refresh) #'ignore)
                      ((symbol-function 'emacs-canvas-color-picker--make-frame) #'ignore)
                      ((symbol-function 'window-body-width) (lambda (&rest _args) 400))
                      ((symbol-function 'window-body-height) (lambda (&rest _args) 500))
                      ((symbol-function 'display-buffer)
                       (lambda (buffer &rest _args)
                         (set-window-buffer caller buffer)
                         caller))
                      ((symbol-function 'message)
                       (lambda (format-string &rest args)
                         (push (apply #'format format-string args) messages))))
              (unwind-protect
                  (progn
                    (setq state (emacs-canvas-color-picker-read-color
                                 #'ignore "#ff0000" display 'emacs-rgb))
                    (should (equal (car messages) "#xff0000    RET accept, q cancel"))
                    (should (= (with-current-buffer (emacs-canvas-color-picker--state-buffer state)
                                 (buffer-size)) 1)))
                (when state (emacs-canvas-color-picker--cancel state))))))))))

(ert-deftest emacs-canvas-color-picker-test-echo-pointer-starts-at-canvas ()
  "Pointer pixels map directly to canvas pixels without a status row."
  (let ((window (selected-window)))
    (cl-letf (((symbol-function 'mouse-pixel-position)
               (lambda () (list (window-frame window) 50 70)))
              ((symbol-function 'window-inside-pixel-edges)
               (lambda (_window) '(10 20 200 220))))
      (should (equal (emacs-canvas-color-picker--current-pointer-coordinates window)
                     '(40 . 50))))))

(ert-deftest emacs-canvas-color-picker-test-canvas-keeps-keyboard-bindings ()
  "RET and q dispatch to the picker while point is on the canvas."
  (save-window-excursion
    (with-temp-buffer
      (set-window-buffer (selected-window) (current-buffer))
      (emacs-canvas-color-picker--setup-buffer
       (emacs-canvas-color-picker--state-create
        :buffer (current-buffer)
        :canvas '(image :type canvas :id test)
        :hue 0.0 :saturation 1.0 :value 1.0))
      (should (eq (key-binding (kbd "RET")) #'emacs-canvas-color-picker--accept))
      (should (eq (key-binding (kbd "q")) #'emacs-canvas-color-picker--cancel)))))

(ert-deftest emacs-canvas-color-picker-test-keyboard-navigation-square ()
  "Keyboard movement uses fixed fine and coarse HSV steps in the square."
  (with-temp-buffer
    (let ((state (emacs-canvas-color-picker--state-create
                  :buffer (current-buffer) :canvas '(image :type canvas :id test)
                  :hue 0.5 :saturation 0.5 :value 0.5)))
      (emacs-canvas-color-picker--setup-buffer state)
      (cl-letf (((symbol-function 'emacs-canvas-color-picker--refresh) #'ignore)
                ((symbol-function 'emacs-canvas-color-picker--update-status) #'ignore))
        (should (eq (emacs-canvas-color-picker--state-active-region state) 'sv))
        (call-interactively (key-binding (kbd "p")))
        (should (emacs-canvas-color-picker-test--close-to
                 (emacs-canvas-color-picker--state-value state) 0.51))
        (call-interactively (key-binding (kbd "C-f")))
        (should (emacs-canvas-color-picker-test--close-to
                 (emacs-canvas-color-picker--state-saturation state) 0.6))
        (call-interactively (key-binding (kbd "TAB")))
        (should (eq (emacs-canvas-color-picker--state-active-region state) 'hue))
        (should (emacs-canvas-color-picker-test--close-to
                 (emacs-canvas-color-picker--state-hue state) 0.5))))))

(ert-deftest emacs-canvas-color-picker-test-keyboard-hue-wrap-and-tab ()
  "Hue movement wraps, and TAB changes regions without changing HSV."
  (with-temp-buffer
    (let ((state (emacs-canvas-color-picker--state-create
                  :buffer (current-buffer) :canvas '(image :type canvas :id test)
                  :hue 0.0 :saturation 0.5 :value 0.5)))
      (emacs-canvas-color-picker--setup-buffer state)
      (cl-letf (((symbol-function 'emacs-canvas-color-picker--refresh) #'ignore)
                ((symbol-function 'emacs-canvas-color-picker--update-status) #'ignore))
        (call-interactively (key-binding (kbd "M-p")))
        (should (emacs-canvas-color-picker-test--close-to
                 (emacs-canvas-color-picker--state-hue state) (/ 359.0 360.0)))
        (call-interactively (key-binding (kbd "TAB")))
        (should (eq (emacs-canvas-color-picker--state-active-region state) 'hue))
        (call-interactively (key-binding (kbd "C-<down>")))
        (should (emacs-canvas-color-picker-test--close-to
                 (emacs-canvas-color-picker--state-hue state) (/ 14.0 360.0)))
        (should (= (emacs-canvas-color-picker--state-saturation state) 0.5))))))

(ert-deftest emacs-canvas-color-picker-test-keyboard-hue-horizontal-no-op ()
  "Horizontal keys leave hue unchanged without a message."
  (with-temp-buffer
    (let ((state (emacs-canvas-color-picker--state-create
                  :buffer (current-buffer) :canvas '(image :type canvas :id test)
                  :active-region 'hue :hue 0.3 :saturation 0.5 :value 0.5))
          (messages nil))
      (emacs-canvas-color-picker--setup-buffer state)
      (cl-letf (((symbol-function 'emacs-canvas-color-picker--refresh) #'ignore)
                ((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (push (apply #'format format-string args) messages))))
        (dolist (key '("b" "<left>" "C-f" "C-<right>"))
          (call-interactively (key-binding (kbd key)))
          (should (= (emacs-canvas-color-picker--state-hue state) 0.3))
          (should-not messages))))))

(ert-deftest emacs-canvas-color-picker-test-keyboard-sv-clamps ()
  "Value and saturation stop at their boundaries."
  (with-temp-buffer
    (let ((state (emacs-canvas-color-picker--state-create
                  :buffer (current-buffer) :canvas '(image :type canvas :id test)
                  :hue 0.5 :saturation 1.0 :value 0.0)))
      (emacs-canvas-color-picker--setup-buffer state)
      (cl-letf (((symbol-function 'emacs-canvas-color-picker--refresh) #'ignore)
                ((symbol-function 'emacs-canvas-color-picker--update-status) #'ignore))
        (call-interactively (key-binding (kbd "C-n")))
        (call-interactively (key-binding (kbd "C-f")))
        (should (= (emacs-canvas-color-picker--state-value state) 0.0))
        (should (= (emacs-canvas-color-picker--state-saturation state) 1.0))))))

(ert-deftest emacs-canvas-color-picker-test-keyboard-focus-border ()
  "TAB passes the active focus region to native rendering without changing HSV."
  (with-temp-buffer
    (let* ((geometry (emacs-canvas-color-picker-test--small-geometry))
           (canvas '(image :type canvas :id test))
           (state (emacs-canvas-color-picker--state-create
                   :buffer (current-buffer) :canvas canvas
                   :geometry geometry :hue 0.5 :saturation 0.25 :value 0.75))
           (regions nil))
      (emacs-canvas-color-picker--setup-buffer state)
      (cl-letf (((symbol-function 'emacs-canvas-color-picker-native-render-full)
                 (lambda (&rest args) (push (car (last args)) regions) t))
                ((symbol-function 'canvas-refresh) #'ignore)
                ((symbol-function 'emacs-canvas-color-picker--update-status) #'ignore))
        (emacs-canvas-color-picker--refresh state)
        (call-interactively (key-binding (kbd "TAB")))
        (should (equal regions '(1 0)))
        (should (equal (list (emacs-canvas-color-picker--state-hue state)
                             (emacs-canvas-color-picker--state-saturation state)
                             (emacs-canvas-color-picker--state-value state))
                       '(0.5 0.25 0.75)))))))

(ert-deftest emacs-canvas-color-picker-test-display-string-uses-arrow-pointer ()
  "Canvas display string uses the normal arrow pointer."
  (let ((display-string (emacs-canvas-color-picker--display-string '(image :type canvas :id test))))
    (should (eq (get-text-property 0 'pointer display-string) 'arrow))
    (should (get-text-property 0 'local-map display-string))))

(ert-deftest emacs-canvas-color-picker-test-state-remembers-caller-window ()
  "The picker uses the caller's window after it takes focus."
  (let ((emacs-canvas-color-picker-scale 1.0))
    (with-temp-buffer
      (cl-letf (((symbol-function 'selected-window) (lambda () 'caller-window))
                ((symbol-function 'frame-char-height) (lambda (&optional _frame) 32)))
        (let ((state (emacs-canvas-color-picker--make-state #'ignore nil (current-buffer))))
          (should (eq (emacs-canvas-color-picker--state-parent-window state)
                      'caller-window)))))))

(ert-deftest emacs-canvas-color-picker-test-frame-position-near-cursor ()
  "The picker opens beside point and below its row."
  (cl-letf (((symbol-function 'frame-pixel-width) (lambda (_frame) 900))
            ((symbol-function 'frame-pixel-height) (lambda (_frame) 700))
            ((symbol-function 'window-point) (lambda (_window) 12))
            ((symbol-function 'posn-at-point)
             (lambda (point window)
               (should (= point 12))
               (should (eq window 'caller-window))
               '(caller-window 12 (30 . 20) 0 nil 12 nil nil nil (15 . 18))))
            ((symbol-function 'window-inside-pixel-edges)
             (lambda (_window) '(100 60 800 650))))
    (should (equal (emacs-canvas-color-picker--frame-position
                    'parent-frame 200 160 'caller-window)
                   '(153 . 98)))))

(ert-deftest emacs-canvas-color-picker-test-frame-position-below-row ()
  "The child frame starts below the visible source row."
  (cl-letf (((symbol-function 'frame-pixel-width) (lambda (_frame) 900))
            ((symbol-function 'frame-pixel-height) (lambda (_frame) 700))
            ((symbol-function 'window-point) (lambda (_window) 12))
            ((symbol-function 'posn-at-point)
             (lambda (&rest _args)
               '(caller-window 12 (30 . 20) 0 nil 12 nil nil nil (15 . 27))))
            ((symbol-function 'window-inside-pixel-edges)
             (lambda (_window) '(100 60 800 650))))
    (should (equal (emacs-canvas-color-picker--frame-position
                    'parent-frame 200 160 'caller-window)
                   '(153 . 107)))))

(ert-deftest emacs-canvas-color-picker-test-frame-position-above-near-bottom ()
  "The child frame moves above the row instead of covering the preview."
  (cl-letf (((symbol-function 'frame-pixel-width) (lambda (_frame) 900))
            ((symbol-function 'frame-pixel-height) (lambda (_frame) 700))
            ((symbol-function 'window-point) (lambda (_window) 12))
            ((symbol-function 'posn-at-point)
             (lambda (&rest _args)
               '(caller-window 12 (30 . 600) 0 nil 12 nil nil nil (15 . 27))))
            ((symbol-function 'window-inside-pixel-edges)
             (lambda (_window) '(100 60 800 690))))
    (should (equal (emacs-canvas-color-picker--frame-position
                    'parent-frame 200 160 'caller-window)
                   '(153 . 500)))))

(ert-deftest emacs-canvas-color-picker-test-frame-position-uses-left-side ()
  "The picker moves left when the right side cannot hold it."
  (cl-letf (((symbol-function 'frame-pixel-width) (lambda (_frame) 900))
            ((symbol-function 'frame-pixel-height) (lambda (_frame) 700))
            ((symbol-function 'window-point) (lambda (_window) 12))
            ((symbol-function 'posn-at-point)
             (lambda (&rest _args)
               '(caller-window 12 (650 . 20) 0 nil 12 nil nil nil (15 . 18))))
            ((symbol-function 'window-inside-pixel-edges)
             (lambda (_window) '(100 60 800 650))))
    (should (equal (emacs-canvas-color-picker--frame-position
                    'parent-frame 200 160 'caller-window)
                   '(542 . 98)))))

(ert-deftest emacs-canvas-color-picker-test-frame-position-clamps-width ()
  "The picker stays within the parent when neither side fits."
  (cl-letf (((symbol-function 'frame-pixel-width) (lambda (_frame) 300))
            ((symbol-function 'frame-pixel-height) (lambda (_frame) 700))
            ((symbol-function 'window-point) (lambda (_window) 12))
            ((symbol-function 'posn-at-point)
             (lambda (&rest _args)
               '(caller-window 12 (145 . 20) 0 nil 12 nil nil nil (15 . 18))))
            ((symbol-function 'window-inside-pixel-edges)
             (lambda (_window) '(0 0 300 650))))
    (should (equal (emacs-canvas-color-picker--frame-position
                    'parent-frame 200 160 'caller-window)
                   '(0 . 38)))))

(ert-deftest emacs-canvas-color-picker-test-frame-position-clamps-height ()
  "The picker moves above a bottom-edge source row."
  (cl-letf (((symbol-function 'frame-pixel-width) (lambda (_frame) 900))
            ((symbol-function 'frame-pixel-height) (lambda (_frame) 700))
            ((symbol-function 'window-point) (lambda (_window) 12))
            ((symbol-function 'posn-at-point)
             (lambda (&rest _args)
               '(caller-window 12 (30 . 600) 0 nil 12 nil nil nil (15 . 18))))
            ((symbol-function 'window-inside-pixel-edges)
             (lambda (_window) '(100 60 800 650))))
    (should (equal (emacs-canvas-color-picker--frame-position
                    'parent-frame 200 160 'caller-window)
                   '(153 . 500)))))

(ert-deftest emacs-canvas-color-picker-test-frame-position-invisible-point ()
  "The old clamped position remains available when point is invisible."
  (cl-letf (((symbol-function 'frame-pixel-width) (lambda (_frame) 300))
            ((symbol-function 'frame-pixel-height) (lambda (_frame) 250))
            ((symbol-function 'window-point) (lambda (_window) 12))
            ((symbol-function 'posn-at-point) (lambda (&rest _args) nil)))
    (should (equal (emacs-canvas-color-picker--frame-position
                    'parent-frame 280 240 'caller-window)
                   '(20 . 10)))))

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

(ert-deftest emacs-canvas-color-picker-test-frame-size-omits-status-row ()
  "Child-frame height does not include a character row."
  (let ((geometry (emacs-canvas-color-picker-test--small-geometry)))
    (cl-letf (((symbol-function 'frame-char-height) (lambda (&optional _frame) 17)))
      (let ((size (emacs-canvas-color-picker--frame-size geometry nil)))
        (should (= (car size) (emacs-canvas-color-picker--geometry-width geometry)))
        (should (= (cdr size) (1+ (emacs-canvas-color-picker--geometry-height geometry))))))))

(ert-deftest emacs-canvas-color-picker-test-echo-frame-size-is-canvas-only ()
  "Child-frame height includes the canvas and its one-pixel safety margin."
  (let ((geometry (emacs-canvas-color-picker-test--small-geometry)))
    (cl-letf (((symbol-function 'frame-char-height) (lambda (&optional _frame) 17)))
      (should (equal (emacs-canvas-color-picker--frame-size geometry nil)
                     (cons (emacs-canvas-color-picker--geometry-width geometry)
                           (1+ (emacs-canvas-color-picker--geometry-height geometry))))))))

(ert-deftest emacs-canvas-color-picker-test-echo-cleanup-preserves-other-message ()
  "Picker cleanup does not erase a later message from another command."
  (let ((state (emacs-canvas-color-picker--state-create
                :hue 0.0 :saturation 1.0 :value 1.0 :done nil))
        (messages nil))
    (cl-letf (((symbol-function 'message)
               (lambda (format-string &rest args)
                 (push (apply #'format format-string args) messages))))
      (emacs-canvas-color-picker--update-status state)
      (message "%s" "other command")
      (emacs-canvas-color-picker--cancel state)
      (should (equal (car messages) "other command")))))

(ert-deftest emacs-canvas-color-picker-test-setup-buffer-keeps-canvas-at-point ()
  "Point starts on the canvas display item."
  (with-temp-buffer
    (let ((state (emacs-canvas-color-picker--state-create
                  :buffer (current-buffer)
                  :canvas '(image :type canvas :id test)
                  :hue 0.0 :saturation 1.0 :value 1.0)))
      (emacs-canvas-color-picker--setup-buffer state)
      (should (= (point) (point-min))))))

(ert-deftest emacs-canvas-color-picker-test-buffer-display-restores-reused-window ()
  "Buffer mode selects Emacs's window and restores only its picker buffer."
  (let ((emacs-canvas-color-picker-display 'buffer)
        (emacs-canvas-color-picker-scale 1.0)
        (source (generate-new-buffer " *picker source*"))
        (state nil))
    (unwind-protect
        (save-window-excursion
          (set-window-buffer (selected-window) source)
          (let ((caller (selected-window)))
            (cl-letf (((symbol-function 'emacs-canvas-color-picker--ensure-canvas-available) #'ignore)
                      ((symbol-function 'emacs-canvas-color-picker--refresh) #'ignore)
                      ((symbol-function 'window-body-width) (lambda (&rest _args) 400))
                      ((symbol-function 'window-body-height) (lambda (&rest _args) 500))
                      ((symbol-function 'display-buffer)
                       (lambda (buffer &rest _args)
                         (set-window-buffer caller buffer)
                         caller)))
              (setq state (emacs-canvas-color-picker-read-color #'ignore "#ff0000"))
              (should (eq (selected-window) caller))
              (should (eq (window-buffer caller) (emacs-canvas-color-picker--state-buffer state)))
              (should (not (eq source (emacs-canvas-color-picker--state-buffer state))))
              (emacs-canvas-color-picker--cancel state)
              (should (eq (window-buffer caller) source))
              (should-not (buffer-live-p (emacs-canvas-color-picker--state-buffer state))))))
      (when (and state (not (emacs-canvas-color-picker--state-done state)))
        (emacs-canvas-color-picker--cancel state))
      (kill-buffer source))))

(ert-deftest emacs-canvas-color-picker-test-buffer-display-leaves-changed-window ()
  "Cleanup leaves a window alone if another buffer replaced the picker."
  (let ((emacs-canvas-color-picker-display 'buffer)
        (replacement (generate-new-buffer " *picker replacement*"))
        state)
    (unwind-protect
        (save-window-excursion
          (let ((caller (selected-window)))
            (cl-letf (((symbol-function 'emacs-canvas-color-picker--ensure-canvas-available) #'ignore)
                      ((symbol-function 'emacs-canvas-color-picker--refresh) #'ignore)
                      ((symbol-function 'window-body-width) (lambda (&rest _args) 400))
                      ((symbol-function 'window-body-height) (lambda (&rest _args) 500))
                      ((symbol-function 'display-buffer)
                       (lambda (buffer &rest _args)
                         (set-window-buffer caller buffer)
                         caller)))
              (setq state (emacs-canvas-color-picker-read-color #'ignore))
              (set-window-buffer caller replacement)
              (emacs-canvas-color-picker--cancel state)
              (should (eq (window-buffer caller) replacement)))))
      (when (and state (not (emacs-canvas-color-picker--state-done state)))
        (emacs-canvas-color-picker--cancel state))
      (kill-buffer replacement))))

(ert-deftest emacs-canvas-color-picker-test-buffer-display-closes-created-window ()
  "Cleanup removes a newly created window only while it shows the picker."
  (let ((emacs-canvas-color-picker-display 'buffer)
        state)
    (unwind-protect
        (save-window-excursion
          (let ((caller (selected-window)) new-window)
            (cl-letf (((symbol-function 'emacs-canvas-color-picker--ensure-canvas-available) #'ignore)
                      ((symbol-function 'emacs-canvas-color-picker--refresh) #'ignore)
                      ((symbol-function 'window-body-width) (lambda (&rest _args) 400))
                      ((symbol-function 'window-body-height) (lambda (&rest _args) 500))
                      ((symbol-function 'display-buffer)
                       (lambda (buffer &rest _args)
                         (setq new-window (split-window caller))
                         (set-window-buffer new-window buffer)
                         new-window)))
              (setq state (emacs-canvas-color-picker-read-color #'ignore))
              (should (eq (selected-window) new-window))
              (emacs-canvas-color-picker--cancel state)
              (should-not (window-live-p new-window)))))
      (when (and state (not (emacs-canvas-color-picker--state-done state)))
        (emacs-canvas-color-picker--cancel state)))))

(ert-deftest emacs-canvas-color-picker-test-buffer-display-created-window-becomes-sole-window ()
  "Cancel leaves the remaining window usable after its sibling disappears."
  (let ((emacs-canvas-color-picker-display 'buffer)
        state)
    (unwind-protect
        (save-window-excursion
          (let ((caller (selected-window)) new-window)
            (cl-letf (((symbol-function 'emacs-canvas-color-picker--ensure-canvas-available) #'ignore)
                      ((symbol-function 'emacs-canvas-color-picker--refresh) #'ignore)
                      ((symbol-function 'window-body-width) (lambda (&rest _args) 400))
                      ((symbol-function 'window-body-height) (lambda (&rest _args) 500))
                      ((symbol-function 'display-buffer)
                       (lambda (buffer &rest _args)
                         (setq new-window (split-window caller))
                         (set-window-buffer new-window buffer)
                         new-window)))
              (setq state (emacs-canvas-color-picker-read-color #'ignore))
              (delete-window caller)
              (emacs-canvas-color-picker--cancel state)
              (should (window-live-p new-window))
              (should-not (eq (window-buffer new-window)
                              (emacs-canvas-color-picker--state-buffer state)))
              (should-not emacs-canvas-color-picker--active-state))))
      (when (and state (not (emacs-canvas-color-picker--state-done state)))
        (emacs-canvas-color-picker--cancel state)))))

(ert-deftest emacs-canvas-color-picker-test-buffer-display-missing-window ()
  "Cancel releases picker resources if its window was deleted."
  (let ((emacs-canvas-color-picker-display 'buffer)
        state)
    (unwind-protect
        (save-window-excursion
          (let ((caller (selected-window)) new-window)
            (cl-letf (((symbol-function 'emacs-canvas-color-picker--ensure-canvas-available) #'ignore)
                      ((symbol-function 'emacs-canvas-color-picker--refresh) #'ignore)
                      ((symbol-function 'window-body-width) (lambda (&rest _args) 400))
                      ((symbol-function 'window-body-height) (lambda (&rest _args) 500))
                      ((symbol-function 'display-buffer)
                       (lambda (buffer &rest _args)
                         (setq new-window (split-window caller))
                         (set-window-buffer new-window buffer)
                         new-window)))
              (setq state (emacs-canvas-color-picker-read-color #'ignore))
              (delete-window new-window)
              (emacs-canvas-color-picker--cancel state)
              (should-not emacs-canvas-color-picker--active-state)
              (should-not (buffer-live-p (emacs-canvas-color-picker--state-buffer state))))))
      (when (and state (not (emacs-canvas-color-picker--state-done state)))
        (emacs-canvas-color-picker--cancel state)))))

(ert-deftest emacs-canvas-color-picker-test-display-override-wins ()
  "The explicit backend overrides the Customize default."
  (let ((emacs-canvas-color-picker-display 'child-frame)
        state)
    (unwind-protect
        (save-window-excursion
          (let ((caller (selected-window)))
            (cl-letf (((symbol-function 'emacs-canvas-color-picker--ensure-canvas-available) #'ignore)
                      ((symbol-function 'emacs-canvas-color-picker--refresh) #'ignore)
                      ((symbol-function 'window-body-width) (lambda (&rest _args) 400))
                      ((symbol-function 'window-body-height) (lambda (&rest _args) 500))
                      ((symbol-function 'display-buffer)
                       (lambda (buffer &rest _args)
                         (set-window-buffer caller buffer)
                         caller)))
              (setq state (emacs-canvas-color-picker-read-color #'ignore nil 'buffer))
              (should (eq (emacs-canvas-color-picker--state-display state) 'buffer)))))
      (when (and state (not (emacs-canvas-color-picker--state-done state)))
        (emacs-canvas-color-picker--cancel state)))))

(ert-deftest emacs-canvas-color-picker-test-buffer-display-fits-and-refits ()
  "The canvas and hit geometry fit the window and retain the chosen color."
  (let ((emacs-canvas-color-picker-display 'buffer)
        (emacs-canvas-color-picker-scale 2.0)
        (width 210)
        (height 250)
        state)
    (unwind-protect
        (save-window-excursion
          (let ((caller (selected-window)))
            (cl-letf (((symbol-function 'emacs-canvas-color-picker--ensure-canvas-available) #'ignore)
                      ((symbol-function 'emacs-canvas-color-picker--refresh) #'ignore)
                      ((symbol-function 'frame-char-height) (lambda (&optional _frame) 32))
                      ((symbol-function 'window-body-width) (lambda (&rest _args) width))
                      ((symbol-function 'window-body-height) (lambda (&rest _args) height))
                      ((symbol-function 'display-buffer)
                       (lambda (buffer &rest _args)
                         (set-window-buffer caller buffer)
                         caller)))
              (setq state (emacs-canvas-color-picker-read-color #'ignore "#ff0000"))
              (let ((geometry (emacs-canvas-color-picker--state-geometry state)))
                (should (<= (emacs-canvas-color-picker--geometry-width geometry) width))
                (should (<= (emacs-canvas-color-picker--geometry-height geometry) height)))
              (let ((old-width (emacs-canvas-color-picker--geometry-width
                                (emacs-canvas-color-picker--state-geometry state))))
                (setq width 120 height 155)
                (run-hook-with-args 'window-size-change-functions (selected-frame))
                (should (< (emacs-canvas-color-picker--geometry-width
                            (emacs-canvas-color-picker--state-geometry state)) old-width)))
              (setq width 120 height 155)
              (run-hook-with-args 'window-size-change-functions (selected-frame))
              (let* ((geometry (emacs-canvas-color-picker--state-geometry state))
                     (left (emacs-canvas-color-picker--geometry-sv-left geometry))
                     (top (emacs-canvas-color-picker--geometry-sv-top geometry)))
                (should (<= (emacs-canvas-color-picker--geometry-width geometry) width))
                (should (<= (emacs-canvas-color-picker--geometry-height geometry) height))
                (should (= (length (plist-get (cdr (emacs-canvas-color-picker--state-canvas state)) :data))
                           (* (emacs-canvas-color-picker--geometry-width geometry)
                              (emacs-canvas-color-picker--geometry-height geometry))))
                (should (eq (plist-get (emacs-canvas-color-picker--hit-test geometry left top) :region) 'sv))
                (should (equal (emacs-canvas-color-picker--current-hex state) "#ff0000"))))))
      (when (and state (not (emacs-canvas-color-picker--state-done state)))
        (emacs-canvas-color-picker--cancel state)))))

(ert-deftest emacs-canvas-color-picker-test-buffer-display-grows-with-window ()
  "Buffer mode grows the full canvas when more window space is available."
  (let ((emacs-canvas-color-picker-display 'buffer)
        (emacs-canvas-color-picker-scale 1.0)
        (width 900)
        (height 800)
        state)
    (unwind-protect
        (save-window-excursion
          (let ((caller (selected-window)))
            (cl-letf (((symbol-function 'emacs-canvas-color-picker--ensure-canvas-available) #'ignore)
                      ((symbol-function 'emacs-canvas-color-picker--refresh) #'ignore)
                      ((symbol-function 'frame-char-height) (lambda (&optional _frame) 32))
                      ((symbol-function 'window-body-width) (lambda (&rest _args) width))
                      ((symbol-function 'window-body-height) (lambda (&rest _args) height))
                      ((symbol-function 'display-buffer)
                       (lambda (buffer &rest _args)
                         (set-window-buffer caller buffer)
                         caller)))
              (setq state (emacs-canvas-color-picker-read-color #'ignore "#ff0000"))
              (let* ((initial (emacs-canvas-color-picker--state-geometry state))
                     (initial-width (emacs-canvas-color-picker--geometry-width initial)))
                (should (> initial-width 400))
                (should (<= initial-width width))
                (should (<= (- height (emacs-canvas-color-picker--geometry-height initial)) 4))
                (setq width 1100 height 1000)
                (run-hook-with-args 'window-size-change-functions (selected-frame))
                (let* ((geometry (emacs-canvas-color-picker--state-geometry state))
                       (canvas (emacs-canvas-color-picker--state-canvas state)))
                  (should (> (emacs-canvas-color-picker--geometry-width geometry) initial-width))
                  (should (<= (emacs-canvas-color-picker--geometry-width geometry) width))
                  (should (<= (emacs-canvas-color-picker--geometry-height geometry) height))
                  (should (= (plist-get (cdr canvas) :data-width)
                             (emacs-canvas-color-picker--geometry-width geometry)))
                  (should (equal (emacs-canvas-color-picker--current-hex state) "#ff0000")))))))
      (when (and state (not (emacs-canvas-color-picker--state-done state)))
        (emacs-canvas-color-picker--cancel state)))))

(ert-deftest emacs-canvas-color-picker-test-buffer-display-fills-width ()
  "A tall window lets the buffer canvas grow close to its available width."
  (let ((emacs-canvas-color-picker-display 'buffer)
        (width 600)
        (height 1300)
        state)
    (unwind-protect
        (save-window-excursion
          (let ((caller (selected-window)))
            (cl-letf (((symbol-function 'emacs-canvas-color-picker--ensure-canvas-available) #'ignore)
                      ((symbol-function 'emacs-canvas-color-picker--refresh) #'ignore)
                      ((symbol-function 'window-body-width) (lambda (&rest _args) width))
                      ((symbol-function 'window-body-height) (lambda (&rest _args) height))
                      ((symbol-function 'display-buffer)
                       (lambda (buffer &rest _args)
                         (set-window-buffer caller buffer)
                         caller)))
              (setq state (emacs-canvas-color-picker-read-color #'ignore))
              (let ((geometry (emacs-canvas-color-picker--state-geometry state)))
                (should (<= (- width (emacs-canvas-color-picker--geometry-width geometry)) 4))
                (should (<= (emacs-canvas-color-picker--geometry-width geometry) width))
                (should (<= (emacs-canvas-color-picker--geometry-height geometry) height))))))
      (when (and state (not (emacs-canvas-color-picker--state-done state)))
        (emacs-canvas-color-picker--cancel state)))))

(ert-deftest emacs-canvas-color-picker-test-buffer-display-inserts-into-source ()
  "Accept inserts into the source after the picker replaces its window."
  (let ((emacs-canvas-color-picker-display 'buffer)
        (source (generate-new-buffer " *picker insert source*"))
        state)
    (unwind-protect
        (save-window-excursion
          (let ((caller (selected-window)))
            (set-window-buffer caller source)
            (with-current-buffer source (insert "before "))
            (cl-letf (((symbol-function 'emacs-canvas-color-picker--ensure-canvas-available) #'ignore)
                      ((symbol-function 'emacs-canvas-color-picker--refresh) #'ignore)
                      ((symbol-function 'window-body-width) (lambda (&rest _args) 400))
                      ((symbol-function 'window-body-height) (lambda (&rest _args) 500))
                      ((symbol-function 'display-buffer)
                       (lambda (buffer &rest _args)
                         (set-window-buffer caller buffer)
                         caller)))
              (with-current-buffer source
                (setq state (emacs-canvas-color-picker-insert "#ff0000" nil 'buffer)))
              (emacs-canvas-color-picker--accept state)
              (should (eq (window-buffer caller) source))
              (with-current-buffer source
                (should (equal (buffer-string) "before #ff0000"))))))
      (when (and state (not (emacs-canvas-color-picker--state-done state)))
        (emacs-canvas-color-picker--cancel state))
      (kill-buffer source))))

(ert-deftest emacs-canvas-color-picker-test-buffer-display-cancels-on-tiny-resize ()
  "An unusable resize cancels without calling the selection callback."
  (let ((emacs-canvas-color-picker-display 'buffer)
        (width 400) (height 500) (selected nil) state)
    (unwind-protect
        (save-window-excursion
          (let ((caller (selected-window))
                (source (window-buffer (selected-window))))
            (cl-letf (((symbol-function 'emacs-canvas-color-picker--ensure-canvas-available) #'ignore)
                      ((symbol-function 'emacs-canvas-color-picker--refresh) #'ignore)
                      ((symbol-function 'window-body-width) (lambda (&rest _args) width))
                      ((symbol-function 'window-body-height) (lambda (&rest _args) height))
                      ((symbol-function 'display-buffer)
                       (lambda (buffer &rest _args)
                         (set-window-buffer caller buffer)
                         caller)))
              (setq state (emacs-canvas-color-picker-read-color
                           (lambda (_hex) (setq selected t))))
              (setq width 1 height 1)
              (run-hook-with-args 'window-size-change-functions (selected-frame))
              (should (emacs-canvas-color-picker--state-done state))
              (should-not selected)
              (should (eq (window-buffer caller) source))
              (should-not (buffer-live-p (emacs-canvas-color-picker--state-buffer state))))))
      (when (and state (not (emacs-canvas-color-picker--state-done state)))
        (emacs-canvas-color-picker--cancel state)))))

(ert-deftest emacs-canvas-color-picker-test-buffer-display-rejects-tiny-window ()
  "A too-small window reports an error and restores its previous buffer."
  (let ((emacs-canvas-color-picker-display 'buffer)
        (source (generate-new-buffer " *picker tiny source*")))
    (unwind-protect
        (save-window-excursion
          (let ((caller (selected-window)))
            (set-window-buffer caller source)
            (cl-letf (((symbol-function 'emacs-canvas-color-picker--ensure-canvas-available) #'ignore)
                      ((symbol-function 'emacs-canvas-color-picker--refresh) #'ignore)
                      ((symbol-function 'window-body-width) (lambda (&rest _args) 1))
                      ((symbol-function 'window-body-height) (lambda (&rest _args) 1))
                      ((symbol-function 'display-buffer)
                       (lambda (buffer &rest _args)
                         (set-window-buffer caller buffer)
                         caller)))
              (should-error (emacs-canvas-color-picker-read-color #'ignore) :type 'user-error)
              (should (eq (window-buffer caller) source))
              (should-not emacs-canvas-color-picker--active-state))))
      (kill-buffer source))))

(ert-deftest emacs-canvas-color-picker-test-inline-buffer-resize-cleans-preview ()
  "A buffer-mode resize cancellation removes the source preview."
  (let ((emacs-canvas-color-picker-display 'buffer)
        (width 400) (height 500)
        emacs-canvas-color-picker--active-state)
    (save-window-excursion
      (with-temp-buffer
        (insert "source")
        (let* ((source (current-buffer))
               (caller (selected-window))
               (picker (split-window caller))
               state)
          (set-window-buffer caller source)
          (cl-letf (((symbol-function 'emacs-canvas-color-picker--ensure-canvas-available) #'ignore)
                    ((symbol-function 'emacs-canvas-color-picker--refresh) #'ignore)
                    ((symbol-function 'window-body-width) (lambda (&rest _args) width))
                    ((symbol-function 'window-body-height) (lambda (&rest _args) height))
                    ((symbol-function 'display-buffer)
                     (lambda (buffer &rest _args)
                       (set-window-buffer picker buffer)
                       picker)))
            (setq state (emacs-canvas-color-picker-insert "#ff0000" nil 'buffer))
            (should (overlay-buffer (emacs-canvas-color-picker--state-preview-overlay state)))
            (setq width 1 height 1)
            (run-hook-with-args 'window-size-change-functions (selected-frame))
            (should (emacs-canvas-color-picker--state-done state))
            (should-not (emacs-canvas-color-picker--state-preview-overlay state))
            (should (equal (with-current-buffer source (buffer-string)) "source"))))))))

(ert-deftest emacs-canvas-color-picker-test-buffer-display-rejects-second-open ()
  "A live picker rejects a second open, even with another display mode."
  (let ((emacs-canvas-color-picker-display 'buffer)
        state)
    (unwind-protect
        (save-window-excursion
          (let ((caller (selected-window)))
            (cl-letf (((symbol-function 'emacs-canvas-color-picker--ensure-canvas-available) #'ignore)
                      ((symbol-function 'emacs-canvas-color-picker--refresh) #'ignore)
                      ((symbol-function 'window-body-width) (lambda (&rest _args) 400))
                      ((symbol-function 'window-body-height) (lambda (&rest _args) 500))
                      ((symbol-function 'display-buffer)
                       (lambda (buffer &rest _args)
                         (set-window-buffer caller buffer)
                         caller)))
              (setq state (emacs-canvas-color-picker-read-color #'ignore))
              (should-error (emacs-canvas-color-picker-read-color #'ignore nil 'child-frame)
                            :type 'user-error))))
      (when (and state (not (emacs-canvas-color-picker--state-done state)))
        (emacs-canvas-color-picker--cancel state)))))

(ert-deftest emacs-canvas-color-picker-test-child-frame-shows-canvas ()
  "The child frame must display the entire canvas."
  (skip-unless (and (display-graphic-p) (image-type-available-p 'canvas)))
  (let ((state (emacs-canvas-color-picker-read-color #'ignore)))
    (unwind-protect
        (let* ((window (frame-root-window (emacs-canvas-color-picker--state-frame state)))
               (geometry (emacs-canvas-color-picker--state-geometry state)))
          (redisplay t)
          (should (= (window-start window) (with-current-buffer (window-buffer window) (point-min))))
          (should (pos-visible-in-window-p (window-start window) window))
          (should (>= (window-pixel-height window)
                      (emacs-canvas-color-picker--geometry-height geometry)))
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

(ert-deftest emacs-canvas-color-picker-test-scale-default-geometry ()
  "Scale 1 preserves the documented canvas and region dimensions."
  (let* ((emacs-canvas-color-picker-scale 1.0)
         (geometry (emacs-canvas-color-picker--make-geometry)))
    (should (= (emacs-canvas-color-picker--geometry-padding geometry) 12))
    (should (= (emacs-canvas-color-picker--geometry-sv-width geometry) 256))
    (should (= (emacs-canvas-color-picker--geometry-sv-height geometry) 256))
    (should (= (emacs-canvas-color-picker--geometry-gap geometry) 12))
    (should (= (emacs-canvas-color-picker--geometry-hue-width geometry) 24))
    (should (= (emacs-canvas-color-picker--geometry-hue-height geometry) 256))
    (should (= (emacs-canvas-color-picker--geometry-new-swatch-left geometry) 12))
    (should (= (emacs-canvas-color-picker--geometry-current-swatch-left geometry) 92))
    (should (= (emacs-canvas-color-picker--geometry-width geometry) 316))
    (should (= (emacs-canvas-color-picker--geometry-height geometry) 320))))

(ert-deftest emacs-canvas-color-picker-test-scale-double-and-half-geometry ()
  "Every base length contributes proportionally to the canvas."
  (dolist (case '((2.0 24 512 512 24 48 512 632 640)
                  (0.5 6 128 128 6 12 128 158 160)))
    (ert-info ((format "scale %s" (car case)))
      (let* ((emacs-canvas-color-picker-scale (car case))
             (geometry (emacs-canvas-color-picker--make-geometry)))
        (should (= (emacs-canvas-color-picker--geometry-padding geometry) (nth 1 case)))
        (should (= (emacs-canvas-color-picker--geometry-sv-width geometry) (nth 2 case)))
        (should (= (emacs-canvas-color-picker--geometry-sv-height geometry) (nth 3 case)))
        (should (= (emacs-canvas-color-picker--geometry-gap geometry) (nth 4 case)))
        (should (= (emacs-canvas-color-picker--geometry-hue-width geometry) (nth 5 case)))
        (should (= (emacs-canvas-color-picker--geometry-hue-height geometry) (nth 6 case)))
        (should (= (emacs-canvas-color-picker--geometry-width geometry) (nth 7 case)))
        (should (= (emacs-canvas-color-picker--geometry-height geometry) (nth 8 case)))))))

(ert-deftest emacs-canvas-color-picker-test-scale-fractional-rounding ()
  "Round base lengths independently, including ties to even integers."
  (let* ((emacs-canvas-color-picker-scale 0.5)
         (geometry (emacs-canvas-color-picker--make-geometry
                    '(:padding 3 :sv-width 5 :sv-height 7 :gap 1
                      :hue-width 3 :hue-height 5 :swatch-width 5
                      :swatch-height 3 :swatch-gap 3))))
    (should (= (emacs-canvas-color-picker--geometry-padding geometry) 2))
    (should (= (emacs-canvas-color-picker--geometry-sv-width geometry) 2))
    (should (= (emacs-canvas-color-picker--geometry-sv-height geometry) 4))
    (should (= (emacs-canvas-color-picker--geometry-gap geometry) 0))
    (should (= (emacs-canvas-color-picker--geometry-hue-width geometry) 2))
    (should (= (emacs-canvas-color-picker--geometry-hue-height geometry) 2))
    (should (= (emacs-canvas-color-picker--geometry-width geometry) 8))
    (should (= (emacs-canvas-color-picker--geometry-height geometry) 12))))

(ert-deftest emacs-canvas-color-picker-test-scale-custom-geometry ()
  "Custom base lengths determine both scaled bounds and swatch positions."
  (dolist (case '((1.0 1 4 4 1 2 4 3 2 1 9 9)
                  (2.0 2 8 8 2 4 8 6 4 2 18 18)))
    (ert-info ((format "scale %s" (car case)))
      (let* ((emacs-canvas-color-picker-scale (car case))
             (geometry (emacs-canvas-color-picker--make-geometry
                        '(:padding 1 :sv-width 4 :sv-height 4 :gap 1
                          :hue-width 2 :hue-height 4 :swatch-width 3
                          :swatch-height 2 :swatch-gap 1))))
        (should (= (emacs-canvas-color-picker--geometry-padding geometry) (nth 1 case)))
        (should (= (emacs-canvas-color-picker--geometry-sv-width geometry) (nth 2 case)))
        (should (= (emacs-canvas-color-picker--geometry-sv-height geometry) (nth 3 case)))
        (should (= (emacs-canvas-color-picker--geometry-gap geometry) (nth 4 case)))
        (should (= (emacs-canvas-color-picker--geometry-hue-width geometry) (nth 5 case)))
        (should (= (emacs-canvas-color-picker--geometry-hue-height geometry) (nth 6 case)))
        (should (= (emacs-canvas-color-picker--geometry-new-swatch-left geometry) (nth 1 case)))
        (should (= (emacs-canvas-color-picker--geometry-current-swatch-left geometry)
                   (+ (nth 1 case) (nth 7 case) (nth 9 case))))
        (should (= (emacs-canvas-color-picker--geometry-width geometry) (nth 10 case)))
        (should (= (emacs-canvas-color-picker--geometry-height geometry) (nth 11 case)))))))

(ert-deftest emacs-canvas-color-picker-test-scale-hit-regions ()
  "Scaled SV and hue bounds map corners without rescaling pointer pixels."
  (dolist (scale '(0.5 2.0))
    (ert-info ((format "scale %s" scale))
      (let* ((emacs-canvas-color-picker-scale scale)
             (geometry (emacs-canvas-color-picker--make-geometry))
             (left (emacs-canvas-color-picker--geometry-padding geometry))
             (top left)
             (sv-right (+ left (emacs-canvas-color-picker--geometry-sv-width geometry) -1))
             (sv-bottom (+ top (emacs-canvas-color-picker--geometry-sv-height geometry) -1))
             (hue-left (+ sv-right 1 (emacs-canvas-color-picker--geometry-gap geometry)))
             (hue-right (+ hue-left (emacs-canvas-color-picker--geometry-hue-width geometry) -1))
             (hue-bottom (+ top (emacs-canvas-color-picker--geometry-hue-height geometry) -1))
             (sv-start (emacs-canvas-color-picker--hit-test geometry left top))
             (sv-end (emacs-canvas-color-picker--hit-test geometry sv-right sv-bottom))
             (hue-start (emacs-canvas-color-picker--hit-test geometry hue-left top))
             (hue-end (emacs-canvas-color-picker--hit-test geometry hue-right hue-bottom)))
        (should (= left (if (= scale 0.5) 6 24)))
        (should (= (emacs-canvas-color-picker--geometry-sv-width geometry)
                   (if (= scale 0.5) 128 512)))
        (should (eq (plist-get sv-start :region) 'sv))
        (should (= (plist-get sv-start :s) 0))
        (should (= (plist-get sv-start :v) 1))
        (should (eq (plist-get sv-end :region) 'sv))
        (should (= (plist-get sv-end :s) 1))
        (should (= (plist-get sv-end :v) 0))
        (should (eq (plist-get hue-start :region) 'hue))
        (should (= (plist-get hue-start :h) 0))
        (should (eq (plist-get hue-end :region) 'hue))
        (should (= (plist-get hue-end :h) 1))
        (should-not (emacs-canvas-color-picker--hit-test geometry (1- left) top))
        (should-not (emacs-canvas-color-picker--hit-test geometry (1+ sv-right) top))
        (should-not (emacs-canvas-color-picker--hit-test geometry (1+ hue-right) top))
        (should-not (emacs-canvas-color-picker--hit-test geometry hue-left (1+ hue-bottom)))))))

(ert-deftest emacs-canvas-color-picker-test-scale-follows-parent-character-height ()
  "Scale one targets ten parent-frame character heights for canvas width."
  (dolist (char-height '(20 43))
    (ert-info ((format "character height %s" char-height))
      (let ((emacs-canvas-color-picker-scale 1.0))
        (with-temp-buffer
          (cl-letf (((symbol-function 'selected-frame) (lambda () 'parent-frame))
                    ((symbol-function 'frame-char-height)
                     (lambda (frame)
                       (should (eq frame 'parent-frame))
                       char-height)))
            (let* ((state (emacs-canvas-color-picker--make-state
                           #'ignore nil (current-buffer)))
                   (geometry (emacs-canvas-color-picker--state-geometry state))
                   (width (emacs-canvas-color-picker--geometry-width geometry)))
              (should (eq (emacs-canvas-color-picker--state-parent-frame state)
                          'parent-frame))
              (should (<= (abs (- width (* 10 char-height))) 2))
              (should (= (plist-get (cdr (emacs-canvas-color-picker--state-canvas state))
                                    :data-width)
                         width)))))))))

(ert-deftest emacs-canvas-color-picker-test-scale-multiplies-character-target ()
  "Scale 1.5 targets fifteen parent-frame character heights."
  (let ((emacs-canvas-color-picker-scale 1.5))
    (with-temp-buffer
      (cl-letf (((symbol-function 'selected-frame) (lambda () 'parent-frame))
                ((symbol-function 'frame-char-height) (lambda (_frame) 43)))
        (let* ((state (emacs-canvas-color-picker--make-state
                       #'ignore nil (current-buffer)))
               (geometry (emacs-canvas-color-picker--state-geometry state)))
          (should (<= (abs (- (emacs-canvas-color-picker--geometry-width geometry)
                              (* 15 43))) 2)))))))

(ert-deftest emacs-canvas-color-picker-test-scale-state-canvas-size ()
  "The native canvas and its seed vector use scaled geometry dimensions."
  (let ((emacs-canvas-color-picker-scale 0.5))
    (with-temp-buffer
      (cl-letf (((symbol-function 'frame-char-height) (lambda (&optional _frame) 32)))
        (let* ((state (emacs-canvas-color-picker--make-state #'ignore nil (current-buffer)))
               (geometry (emacs-canvas-color-picker--state-geometry state))
               (width (emacs-canvas-color-picker--geometry-width geometry))
               (height (emacs-canvas-color-picker--geometry-height geometry)))
          (should (<= (abs (- width 160)) 2))
          (let ((canvas (emacs-canvas-color-picker--state-canvas state)))
            (should (= (plist-get (cdr canvas) :data-width) width))
            (should (= (plist-get (cdr canvas) :data-height) height))
            (should (= (length (plist-get (cdr canvas) :data)) (* width height)))))))))

(ert-deftest emacs-canvas-color-picker-test-scale-native-refresh-geometry ()
  "Native full render receives scaled canvas bounds and offsets."
  (let* ((emacs-canvas-color-picker-scale 0.5)
         (geometry (emacs-canvas-color-picker--make-geometry))
         (width (emacs-canvas-color-picker--geometry-width geometry))
         (height (emacs-canvas-color-picker--geometry-height geometry))
         (data (make-vector (* width height) 0))
         (canvas (list 'image :type 'canvas :data-width width :data-height height :data data))
         (state (emacs-canvas-color-picker--state-create
                 :canvas canvas :geometry geometry :hue 0.5 :saturation 0.25 :value 0.75))
         (full-args nil)
         (refresh-args nil))
    (should (= width 158))
    (should (= height 160))
    (cl-letf (((symbol-function 'emacs-canvas-color-picker-native-render-full)
               (lambda (&rest args) (setq full-args args) t))
              ((symbol-function 'canvas-refresh)
               (lambda (&rest args) (push args refresh-args))))
      (emacs-canvas-color-picker--refresh state)
      (should (equal (nthcdr 6 full-args) '(6 6 12 32 14 8 2 0.5 0.25 0.75 0)))
      (should (equal (list (nth 1 full-args) (nth 2 full-args)) (list width height)))
      (should (equal refresh-args (list (list canvas nil)))))))

(ert-deftest emacs-canvas-color-picker-test-scale-frame-size ()
  "Frame dimensions use supplied geometry without a status row."
  (dolist (case '((0.5 158 160) (2.0 632 640)))
    (ert-info ((format "scale %s" (car case)))
      (let* ((emacs-canvas-color-picker-scale (car case))
             (geometry (emacs-canvas-color-picker--make-geometry)))
        (let ((emacs-canvas-color-picker-scale 1.0))
          (cl-letf (((symbol-function 'frame-char-height) (lambda (&optional _frame) 17)))
            (should (equal (emacs-canvas-color-picker--frame-size geometry nil)
                           (cons (nth 1 case) (1+ (nth 2 case)))))))))))

(ert-deftest emacs-canvas-color-picker-test-scale-invalid-values ()
  "Invalid scales and collapsed positive regions fail with an error."
  (dolist (scale (list 0 -1 nil "2" (read "1.0e+INF")
                       (read "0.0e+NaN") 0.001))
    (ert-info ((format "scale %S" scale))
      (let ((emacs-canvas-color-picker-scale scale))
        (should-error (emacs-canvas-color-picker--make-geometry) :type 'error)))))

(ert-deftest emacs-canvas-color-picker-test-scale-invalid-overrides ()
  "Required regions cannot be zero and override lengths remain integers."
  (let ((emacs-canvas-color-picker-scale 1.0))
    (dolist (override '((:sv-width 0) (:sv-height 0) (:hue-width 0)
                        (:hue-height 0) (:swatch-width 0) (:swatch-height 0)
                        (:padding -1) (:gap 1.5) (:swatch-gap -1)))
      (ert-info ((format "override %S" override))
        (should-error (emacs-canvas-color-picker--make-geometry override)
                      :type 'error)))))

(ert-deftest emacs-canvas-color-picker-test-scale-invalid-state-before-allocation ()
  "Invalid scale prevents state canvas allocation and frame creation."
  (let ((emacs-canvas-color-picker-scale 0))
    (with-temp-buffer
      (cl-letf (((symbol-function 'create-image)
                 (lambda (&rest _args) (ert-fail "canvas allocation attempted")))
                ((symbol-function 'make-frame)
                 (lambda (&rest _args) (ert-fail "frame creation attempted"))))
        (should-error (emacs-canvas-color-picker--make-state
                       #'ignore nil (current-buffer)) :type 'error)))))

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
      (setf (emacs-canvas-color-picker--state-hue state) 0.0
            (emacs-canvas-color-picker--state-saturation state) 1.0
            (emacs-canvas-color-picker--state-value state) 1.0)
      (funcall (emacs-canvas-color-picker--state-callback state)
               (emacs-canvas-color-picker--output-text state))
      (should (equal (buffer-string) "ff0000")))))

(ert-deftest emacs-canvas-color-picker-test-at-point-inserts-when-no-color ()
  "At-point accept inserts #rrggbb when no color is at point."
  (with-temp-buffer
    (insert "color: ")
    (let ((state (emacs-canvas-color-picker--make-at-point-state (current-buffer))))
      (funcall (emacs-canvas-color-picker--state-callback state) "#ff0000")
      (should (equal (buffer-string) "color: #ff0000")))))

(ert-deftest emacs-canvas-color-picker-test-inline-insert-preview-cancel ()
  "The default insert preview leaves buffer text intact and cancels cleanly."
  (let (emacs-canvas-color-picker--active-state)
    (save-window-excursion
    (with-temp-buffer
      (insert "before after")
      (goto-char 8)
      (let ((source (current-buffer))
            (position (point))
            (unrelated (make-overlay 1 3))
            state)
        (set-window-buffer (selected-window) source)
        (cl-letf (((symbol-function 'emacs-canvas-color-picker--ensure-canvas-available) #'ignore)
                  ((symbol-function 'emacs-canvas-color-picker--refresh) #'ignore)
                  ((symbol-function 'emacs-canvas-color-picker--make-frame) #'ignore))
          (setq state (emacs-canvas-color-picker-insert "#ff0000" 'emacs-rgb))
          (should (equal (buffer-string) "before after"))
          (should (= (point) position))
          (should (string-prefix-p "RET accept" (emacs-canvas-color-picker--status-text state)))
          (let ((overlay (emacs-canvas-color-picker--state-preview-overlay state)))
            (should (eq (overlay-buffer overlay) source))
            (should (= (overlay-start overlay) position))
            (should (equal (overlay-get overlay 'before-string) "#xff0000")))
          (setf (emacs-canvas-color-picker--state-hue state) (/ 1.0 3.0))
          (emacs-canvas-color-picker--update-status state)
          (should (equal (overlay-get (emacs-canvas-color-picker--state-preview-overlay state)
                                      'before-string)
                         "#x00ff00"))
          (should (equal (buffer-string) "before after"))
          (emacs-canvas-color-picker--cancel state)
          (should-not (emacs-canvas-color-picker--state-preview-overlay state))
          (should (eq (overlay-buffer unrelated) source))
          (should (equal (buffer-string) "before after"))))))))

(ert-deftest emacs-canvas-color-picker-test-inline-toggle ()
  "Explicit nil disables and explicit t enables preview regardless of default."
  (let (emacs-canvas-color-picker--active-state)
    (save-window-excursion
    (with-temp-buffer
      (insert "start")
      (set-window-buffer (selected-window) (current-buffer))
      (cl-letf (((symbol-function 'emacs-canvas-color-picker--ensure-canvas-available) #'ignore)
                ((symbol-function 'emacs-canvas-color-picker--refresh) #'ignore)
                ((symbol-function 'emacs-canvas-color-picker--make-frame) #'ignore))
        (let ((emacs-canvas-color-picker-inline-preview t))
          (let ((state (emacs-canvas-color-picker-insert nil nil nil nil)))
            (should (string-prefix-p "#3399cc    RET" (emacs-canvas-color-picker--status-text state)))
            (should-not (emacs-canvas-color-picker--state-preview-overlay state))
            (emacs-canvas-color-picker--cancel state)))
        (let ((emacs-canvas-color-picker-inline-preview nil))
          (let ((state (emacs-canvas-color-picker-insert nil nil nil t)))
            (should (string-prefix-p "RET accept" (emacs-canvas-color-picker--status-text state)))
            (should (overlay-buffer (emacs-canvas-color-picker--state-preview-overlay state)))
            (emacs-canvas-color-picker--cancel state))))))))

(ert-deftest emacs-canvas-color-picker-test-inline-at-point-replacement ()
  "At-point preview replaces a formatted literal without editing source text."
  (let (emacs-canvas-color-picker--active-state)
    (save-window-excursion
    (with-temp-buffer
      (insert "#xAf112233")
      (goto-char 4)
      (set-window-buffer (selected-window) (current-buffer))
      (cl-letf (((symbol-function 'emacs-canvas-color-picker--ensure-canvas-available) #'ignore)
                ((symbol-function 'emacs-canvas-color-picker--refresh) #'ignore)
                ((symbol-function 'emacs-canvas-color-picker--make-frame) #'ignore))
        (let ((state (emacs-canvas-color-picker-at-point)))
          (should (equal (buffer-string) "#xAf112233"))
          (should (cl-some (lambda (overlay)
                             (equal (overlay-get overlay 'display) "#xAf112233"))
                           (overlays-at (point))))
          (setf (emacs-canvas-color-picker--state-hue state) 0.0
                (emacs-canvas-color-picker--state-saturation state) 1.0
                (emacs-canvas-color-picker--state-value state) 1.0)
          (emacs-canvas-color-picker--update-status state)
          (should (cl-some (lambda (overlay)
                             (equal (overlay-get overlay 'display) "#xAfff0000"))
                           (overlays-at (point))))
          (emacs-canvas-color-picker--accept state)
          (should (equal (buffer-string) "#xAfff0000"))
          (should-not (overlays-at (point)))))))))

(ert-deftest emacs-canvas-color-picker-test-inline-at-point-formats ()
  "Inline preview matches each supported at-point replacement format."
  (dolist (case '(("112233" "ff0000")
                  ("#112233" "#ff0000")
                  ("#112233aF" "#ff0000aF")
                  ("#xAf112233" "#xAfff0000")
                  ("#x112233" "#xff0000")
                  ("0x112233" "0xff0000")))
    (ert-info ((car case))
      (let (emacs-canvas-color-picker--active-state)
        (save-window-excursion
          (with-temp-buffer
            (insert (car case))
            (goto-char (+ (point-min) 3))
            (set-window-buffer (selected-window) (current-buffer))
            (cl-letf (((symbol-function 'emacs-canvas-color-picker--ensure-canvas-available) #'ignore)
                      ((symbol-function 'emacs-canvas-color-picker--refresh) #'ignore)
                      ((symbol-function 'emacs-canvas-color-picker--make-frame) #'ignore))
              (let ((state (emacs-canvas-color-picker-at-point)))
                (setf (emacs-canvas-color-picker--state-hue state) 0.0
                      (emacs-canvas-color-picker--state-saturation state) 1.0
                      (emacs-canvas-color-picker--state-value state) 1.0)
                (emacs-canvas-color-picker--update-status state)
                (should (equal (overlay-get (emacs-canvas-color-picker--state-preview-overlay state)
                                            'display)
                               (cadr case)))
                (should (equal (buffer-string) (car case)))
                (emacs-canvas-color-picker--accept state)
                (should (equal (buffer-string) (cadr case)))))))))))

(ert-deftest emacs-canvas-color-picker-test-inline-at-point-disabled ()
  "Explicit nil keeps the status preview and creates no source overlay."
  (let (emacs-canvas-color-picker--active-state)
    (save-window-excursion
      (with-temp-buffer
        (insert "#x112233")
        (goto-char 4)
        (set-window-buffer (selected-window) (current-buffer))
        (cl-letf (((symbol-function 'emacs-canvas-color-picker--ensure-canvas-available) #'ignore)
                  ((symbol-function 'emacs-canvas-color-picker--refresh) #'ignore)
                  ((symbol-function 'emacs-canvas-color-picker--make-frame) #'ignore))
          (let ((state (emacs-canvas-color-picker-at-point nil nil)))
            (should (string-prefix-p "#x112233    RET" (emacs-canvas-color-picker--status-text state)))
            (should-not (overlays-at (point)))
            (emacs-canvas-color-picker--cancel state)
            (should (equal (buffer-string) "#x112233"))))))))

(ert-deftest emacs-canvas-color-picker-test-inline-at-point-no-match ()
  "At-point previews insertion when no color literal is present."
  (let (emacs-canvas-color-picker--active-state)
    (save-window-excursion
      (with-temp-buffer
        (insert "word")
        (goto-char 3)
        (set-window-buffer (selected-window) (current-buffer))
        (cl-letf (((symbol-function 'emacs-canvas-color-picker--ensure-canvas-available) #'ignore)
                  ((symbol-function 'emacs-canvas-color-picker--refresh) #'ignore)
                  ((symbol-function 'emacs-canvas-color-picker--make-frame) #'ignore))
          (let* ((state (emacs-canvas-color-picker-at-point))
                 (overlay (emacs-canvas-color-picker--state-preview-overlay state)))
            (should (equal (buffer-string) "word"))
            (should (equal (overlay-get overlay 'before-string) "#3399cc"))
            (emacs-canvas-color-picker--accept state)
            (should (equal (buffer-string) "wo#3399ccrd"))
            (should-not (emacs-canvas-color-picker--state-preview-overlay state))))))))

(ert-deftest emacs-canvas-color-picker-test-inline-at-point-tracks-source-edit ()
  "An edit before the literal keeps preview and replacement on that literal."
  (let (emacs-canvas-color-picker--active-state)
    (save-window-excursion
      (with-temp-buffer
        (insert "start #x112233 end")
        (goto-char 10)
        (set-window-buffer (selected-window) (current-buffer))
        (cl-letf (((symbol-function 'emacs-canvas-color-picker--ensure-canvas-available) #'ignore)
                  ((symbol-function 'emacs-canvas-color-picker--refresh) #'ignore)
                  ((symbol-function 'emacs-canvas-color-picker--make-frame) #'ignore))
          (let ((state (emacs-canvas-color-picker-at-point)))
            (goto-char (point-min))
            (insert "prefix ")
            (emacs-canvas-color-picker--update-status state)
            (should (equal (overlay-get (emacs-canvas-color-picker--state-preview-overlay state)
                                        'display)
                           "#x112233"))
            (emacs-canvas-color-picker--accept state)
            (should (equal (buffer-string) "prefix start #x112233 end"))))))))

(ert-deftest emacs-canvas-color-picker-test-inline-invalid-anchor-uses-status ()
  "A lost preview anchor removes the overlay and restores status text."
  (let (emacs-canvas-color-picker--active-state)
    (save-window-excursion
      (with-temp-buffer
        (insert "source")
        (set-window-buffer (selected-window) (current-buffer))
        (cl-letf (((symbol-function 'emacs-canvas-color-picker--ensure-canvas-available) #'ignore)
                  ((symbol-function 'emacs-canvas-color-picker--refresh) #'ignore)
                  ((symbol-function 'emacs-canvas-color-picker--make-frame) #'ignore))
          (let ((state (emacs-canvas-color-picker-insert "#ff0000")))
            (should (overlay-buffer (emacs-canvas-color-picker--state-preview-overlay state)))
            (set-marker (emacs-canvas-color-picker--state-preview-start state) nil)
            (emacs-canvas-color-picker--update-status state)
            (should-not (emacs-canvas-color-picker--state-preview-overlay state))
            (should (string-prefix-p "#ff0000    RET"
                                     (emacs-canvas-color-picker--status-text state)))
            (emacs-canvas-color-picker--cancel state)))))))

(ert-deftest emacs-canvas-color-picker-test-inline-insert-accept-once ()
  "Accept removes the preview and writes the chosen value once."
  (let (emacs-canvas-color-picker--active-state)
    (save-window-excursion
      (with-temp-buffer
        (insert "before after")
        (goto-char 8)
        (set-window-buffer (selected-window) (current-buffer))
        (cl-letf (((symbol-function 'emacs-canvas-color-picker--ensure-canvas-available) #'ignore)
                  ((symbol-function 'emacs-canvas-color-picker--refresh) #'ignore)
                  ((symbol-function 'emacs-canvas-color-picker--make-frame) #'ignore))
          (let ((state (emacs-canvas-color-picker-insert "#ff0000" 'emacs-rgb)))
            (should (equal (buffer-string) "before after"))
            (emacs-canvas-color-picker--accept state)
            (should (equal (buffer-string) "before #xff0000after"))
            (should-not (emacs-canvas-color-picker--state-preview-overlay state))))))))

(ert-deftest emacs-canvas-color-picker-test-inline-open-failure-cleans-overlay ()
  "A failed open removes the temporary preview and leaves source text intact."
  (let (emacs-canvas-color-picker--active-state)
    (save-window-excursion
      (with-temp-buffer
        (insert "keep")
        (set-window-buffer (selected-window) (current-buffer))
        (cl-letf (((symbol-function 'emacs-canvas-color-picker--ensure-canvas-available) #'ignore)
                  ((symbol-function 'emacs-canvas-color-picker--refresh) #'ignore)
                  ((symbol-function 'emacs-canvas-color-picker--make-frame)
                   (lambda (_state) (error "frame unavailable"))))
          (should-error (emacs-canvas-color-picker-insert))
          (should (equal (buffer-string) "keep"))
          (should-not (overlays-in (point-min) (point-max)))
          (should-not emacs-canvas-color-picker--active-state))))))

(ert-deftest emacs-canvas-color-picker-test-inline-hidden-source-uses-status ()
  "The status shows the color when the source window changes buffer."
  (let (emacs-canvas-color-picker--active-state)
    (save-window-excursion
      (with-temp-buffer
        (insert "source")
        (set-window-buffer (selected-window) (current-buffer))
        (cl-letf (((symbol-function 'emacs-canvas-color-picker--ensure-canvas-available) #'ignore)
                  ((symbol-function 'emacs-canvas-color-picker--refresh) #'ignore)
                  ((symbol-function 'emacs-canvas-color-picker--make-frame) #'ignore))
          (let ((state (emacs-canvas-color-picker-insert "#ff0000")))
            (set-window-buffer (selected-window) (get-buffer-create " *picker hidden source*"))
            (unwind-protect
                (progn
                  (emacs-canvas-color-picker--update-status state)
                  (should (string-prefix-p "#ff0000    RET"
                                           (emacs-canvas-color-picker--status-text state)))
                  (should-not (emacs-canvas-color-picker--state-preview-overlay state)))
              (emacs-canvas-color-picker--cancel state)
              (kill-buffer " *picker hidden source*"))))))))

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
      (let ((selected (emacs-canvas-color-picker--hex-to-hsv "#aabbcc")))
        (setf (emacs-canvas-color-picker--state-hue state) (nth 0 selected)
              (emacs-canvas-color-picker--state-saturation state) (nth 1 selected)
              (emacs-canvas-color-picker--state-value state) (nth 2 selected)))
      (funcall (emacs-canvas-color-picker--state-callback state)
               (emacs-canvas-color-picker--output-text state))
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
                       (funcall callback (emacs-canvas-color-picker--format-hex
                                          "#aabbcc" (nth 2 args))))))
            (emacs-canvas-color-picker-copy "#DDEEFF" (car case))
            (should (equal received (list "#DDEEFF" nil (car case))))
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
                   (funcall callback (emacs-canvas-color-picker--format-hex
                                      "#aabbcc" (nth 2 args))))))
        (emacs-canvas-color-picker-copy "DDEEFF" 'css-rgba)
        (should (equal received '("DDEEFF" nil css-rgba)))
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
                       (funcall (emacs-canvas-color-picker--state-callback state)
                                (emacs-canvas-color-picker--format-hex
                                 "#aabbcc" (emacs-canvas-color-picker--state-output-format state))))))
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
                   (funcall (emacs-canvas-color-picker--state-callback state)
                            (emacs-canvas-color-picker--format-hex
                             "#aabbcc" (emacs-canvas-color-picker--state-output-format state))))))
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
