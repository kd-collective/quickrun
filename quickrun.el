;;; quickrun.el --- Run commands quickly

;; Copyright (C) 2011  by Syohei YOSHIDA

;; Author: Syohei YOSHIDA <syohex@gmail.com>

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to
;; the Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Commentary:

;; This package respects `quickrun.vim' developed by thinca
;;   - https://github.com/thinca/vim-quickrun
;;
;; To use this package, add these lines to your .emacs file:
;;     (require 'quickrun)
;;

;;; Code:

(eval-when-compile
  (require 'cl))

(defvar quickrun/timeout 10
  "Timeout seconds for running too long process")

(defvar quickrun/process nil)
(make-variable-buffer-local 'quickrun/process)

(defvar quickrun/last-process-name nil)
(make-variable-buffer-local 'quickrun/last-process-name)

(defvar quickrun/temp-file nil)

(defvar quickrun/buffer-name "*quickrun*")

;;
;; Compat
;;

(unless (fboundp 'apply-partially)
  (defun apply-partially (fun &rest args)
    "Return a function that is a partial application of FUN to ARGS.
ARGS is a list of the first N arguments to pass to FUN.
The result is a new function which does the same as FUN, except that
the first N arguments are fixed at the values with which this function
was called."
    (lexical-let ((fun fun) (args1 args))
      (lambda (&rest args2) (apply fun (append args1 args2))))))

;;
;; language command parameters
;;

(defvar quickrun/language-alist
  '(("c/gcc" . ((:command . "gcc")
                (:compile . "%c %o -o %N %s")
                (:exec    . "%N %a")
                (:remove . ("%N"))))

    ("c/clang" . ((:command . "gcc")
                  (:compile . "%c %o -o %N %s")
                  (:exec    . "%N %a")
                  (:remove  . ("%N"))))

    ("c/cl" . ((:command . "cl")
               (:compile . "%c %o %s /nologo /Fo%N.obj /Fe%N.exe")
               (:exec    . "%N %a")
               (:remove  . "%N.obj %N.exe")))

    ("c++/g++" . ((:command . "g++")
                  (:compile . "%c %o -o %N %s")
                  (:exec    . "%N %a")
                  (:remove . ("%N"))))

    ("c++/clang++" . ((:command . "g++")
                      (:compile . "%c %o -o %N %s")
                      (:exec    . "%N %a")
                      (:remove  . ("%N"))))

    ("c++/cl" . ((:command . "cl")
                 (:compile . "%c %o %s /nologo /Fo%N.obj /Fe%N.exe")
                 (:exec    . "%N %a")
                 (:remove  . "%N.obj %N.exe")))

    ("java" . ((:command . "java")
               (:compile . "javac %o %s")
               (:exec    . "%c %n %a")
               (:remove  . ("%n.class"))))

    ("perl" . ((:command . "perl")))
    ("ruby" . ((:command . "ruby")))
    ("python" . ((:command . "python")))
    ("lisp" . ((:command . "clisp")))
    ("scheme/gosh" . ((:command . "gosh")))

    ("javascript/node" . ((:command . "node")))
    ("javascript/d8" . ((:command . "d8")))
    ("javascript/js" . ((:command . "js")))
    ("javascript/jrunscript" . ((:command . "jrunscript")))
    ("javascript/phantomjs" . ((:command . "phantomjs")))
    ("javascript/cscript" . ((:command . "cscript")
                             (:exec . "%c //e:jscript %o %s %a")
                             (:cmdopt . "//Nologo")))

    ("markdown/Markdown.pl" . ((:command . "Markdown.pl")))
    ("markdown/bluecloth"   . ((:command . "bluecloth")
                               (:cmdopt  . "-f")))
    ("markdown/kranmdown"   . ((:command . "kranmdown")))
    ("markdown/pandoc"      . ((:command . "pandoc")
                               (:exec . "%c --from=markdown --to=html %o %s %a")))
    ("markdown/redcarpet"   . ((:command . "redcarpet")))

    ("haskell" . ((:command . "runghc")))
    ))

;;
;; decide file type
;;
(defun* quickrun/decide-file-type (&optional (filename (buffer-file-name)))
  (if (eq major-mode 'fundamental-mode)
      (quickrun/decide-file-type-by-extension filename)
    (quickrun/decide-file-type-by-mode major-mode)))

(defun quickrun/decide-file-type-by-mode (mode)
  (case mode
    ('c-mode "c")
    ('c++-mode "c++")
    ('objc-mode "objc")
    ('perl-mode "perl") ('cperl-mode "perl")
    ('ruby-mode "ruby")
    ('python-mode "python")
    ('lisp-mode "lisp")
    ('scheme-mode "scheme")
    ('javascript-mode "javascript") ('js-mode "javascript") ('js2-mode "javascript")
    ('clojure-mode "clojure")
    ('erlang-mode "erlang")
    ('go-mode "go")
    ('haskell-mode "haskell")
    ('java-mode "java")
    ('markdown-mode "markdown")
    ('shell-script-mode "shellscript")
    (t (error (format "cannot decide file type by mode[%s]" mode)))))

(defvar quickrun/extension-alist
  '(("c"    . "c")
    ("cpp"  . "c++") ("C"  . "c++")
    ("m"    . "objc")
    ("pl"   . "perl")
    ("rb"   . "ruby")
    ("py"   . "python")
    ("lisp" . "lisp") (".lsp" . "lisp")
    ("scm"  . "scheme")
    ("js"   . "javascript")
    ("clj"  . "clojure")
    ("erl"  . "erl")
    ("go"   . "go")
    ("hs"   . "haskell")
    ("java" . "java")
    ("md"   . "markdown") (".markdown" . "markdown")
    ("sh"   . "shellscript")))

(defun quickrun/decide-file-type-by-extension (filename)
  (let* ((extension (file-name-extension filename))
         (file-type-pair (assoc extension quickrun/extension-alist)))
    (if file-type-pair
        (cdr file-type-pair)
      (error "cannot decide file type by extension"))))

(defun quickrun/extension-from-lang (lang)
  (car (rassoc lang quickrun/extension-alist)))


(defun quickrun/get-lang-info (lang)
  (let ((lang-info (assoc lang quickrun/language-alist)))
    (if (null lang-info)
        (error (format "not found [%s] language information" lang))
      lang-info)))

;;
;; Compile
;;

(defun quickrun/compile (cmd)
  (let* ((cmd-list (split-string cmd))
         (program  (car cmd-list))
         (args     (cdr cmd-list))
         (buf      (get-buffer-create quickrun/buffer-name)))
    (with-current-buffer buf
      (erase-buffer)
      (goto-char (point-min)))
    (let ((compile-func (apply-partially 'call-process program nil buf t)))
      (when (not (= (apply compile-func args) 0))
        (pop-to-buffer buf)
        (throw 'compile-error nil)))))

;;
;; Execute
;;

(defun quickrun/run (cmd)
  (let* ((buf (get-buffer-create quickrun/buffer-name))
         (process-name (format "quickrun-process-%s" (buffer-name)))
         (cmd-list (split-string cmd))
         (program (car cmd-list))
         (args (mapconcat #'identity (cdr cmd-list) " ")))
    (with-current-buffer buf
      (erase-buffer)
      (goto-char (point-min)))
    (setf quickrun/last-process-name process-name
          quickrun/process (start-process process-name buf program args))
    (run-at-time quickrun/timeout nil #'quickrun/kill-process)
    quickrun/process))

(defun quickrun/sentinel (process state)
  (let ((status (process-status process)))
    (cond
     ((eq status 'exit)
      (progn
        (funcall quickrun/epilogue)
        (pop-to-buffer (process-buffer process))))
     (t nil))))

(defun quickrun/kill-process ()
  (when (eq (process-status quickrun/process) 'run)
    (kill-process quickrun/process)
    (let ((buf (get-buffer-create quickrun/buffer-name)))
      (with-current-buffer buf
        (erase-buffer)
        (insert (message "Time out %s(over %d second)"
                         quickrun/last-process-name quickrun/timeout)))
      (pop-to-buffer buf))))

;;
;; Composing command
;;
(defvar quickrun/template-place-holders '("%c" "%o" "%s" "%a" "%n" "%N" "%e"))

(defun quickrun/executable-suffix (command)
  (if (string= command "java")
      ".class"
    (cond
     ((quickrun/windows-p) ".exe")
     (t ".out"))))

(defun* quickrun/place-holder-info (&key command
                                         command-option
                                         source
                                         argument)
  `(("%c" . ,command)
    ("%o" . ,command-option)
    ("%s" . ,source)
    ("%n" . ,(file-name-sans-extension source))
    ("%N" . ,(expand-file-name (file-name-sans-extension source)))
    ("%e" . ,(concat (file-name-sans-extension source)
                     (quickrun/executable-suffix command)))
    ("%a" . ,argument)))

(defun quickrun/get-lang-info-param (key lang-info)
  (let ((tmpl (assoc key lang-info)))
    (if tmpl
        (cdr tmpl))))

(defvar quickrun/default-exec-tmpl "%c %o %s %a")

(defun quickrun/fill-templates (lang src &optional argument)
  (let* ((lang-info (quickrun/get-lang-info lang))
         (compile-tmpl (quickrun/get-lang-info-param :compile lang-info))
         (exec-tmpl    (or (quickrun/get-lang-info-param :exec lang-info)
                           quickrun/default-exec-tmpl))
         (remove-tmpl  (quickrun/get-lang-info-param :remove  lang-info))
         (cmd          (quickrun/get-lang-info-param :command lang-info))
         (cmd-opt      (or (quickrun/get-lang-info-param :cmdopt lang-info) ""))
         (arg          (or argument
                           (quickrun/get-lang-info-param :argument lang-info)
                           ""))
         (tmpl-arg (quickrun/place-holder-info :command cmd
                                               :command-option cmd-opt
                                               :source src
                                               :argument arg))
         (info (make-hash-table)))
    (if compile-tmpl
        (puthash :compile
                 (quickrun/fill-template compile-tmpl tmpl-arg) info))
    (if exec-tmpl
        (puthash :exec
                 (quickrun/fill-template exec-tmpl tmpl-arg) info))
    (if remove-tmpl
        (let ((lst '()))
          (dolist (tmpl remove-tmpl)
            (push (quickrun/fill-template tmpl tmpl-arg) lst))
          (puthash :remove lst info)))
    info))

(defun quickrun/fill-template (tmpl info)
  (let ((place-holders quickrun/template-place-holders)
        (str tmpl))
    (dolist (holder place-holders str)
      (let ((rep (cdr (assoc holder info)))
            (case-fold-search nil))
        (setf str (replace-regexp-in-string holder rep str nil))))))

;;
;; initialize
;;
(defun quickrun/windows-p ()
  (or (string= system-type "ms-dos")
      (string= system-type "windows-nt")))

(defvar quickrun/lang-key
  (make-hash-table :test #'equal))

(defun quickrun/find-executable (lst)
  (or (find-if (lambda (cmd) (executable-find cmd)) lst) ""))

(defun quickrun/set-lang-key (lang candidates)
  (puthash lang
           (concat lang "/" (quickrun/find-executable candidates))
           quickrun/lang-key))

(defun quickrun/init-lang-key ()
  (let ((c-candidates          '("gcc" "clang"))
        (c++-candidates        '("g++" "clang++"))
        (javascript-candidates '("node" "d8" "js"
                                 "phantomjs" "jrunscript" "cscript"))
        (scheme-candidates     '("gosh" "mzscheme"))
        (markdown-candidates   '("Markdown.pl" "krandown"
                                 "bluecloth" "redcarpet" "pandoc"))
        (clojure-candidates    '("jark" "clj")))
   (progn
     (quickrun/set-lang-key "c" (if (quickrun/windows-p)
                                    (append "cl" c-candidates)
                                  c-candidates))
     (quickrun/set-lang-key "c++" (if (quickrun/windows-p)
                                      (append "cl" c++-candidates)
                                    c++-candidates))
     (quickrun/set-lang-key "javascript" javascript-candidates)
     (quickrun/set-lang-key "scheme" scheme-candidates)
     (quickrun/set-lang-key "markdown" markdown-candidates)
     (quickrun/set-lang-key "clojure" clojure-candidates))))

(quickrun/init-lang-key)

;;
;; main
;;
(defvar quickrun/remove-files nil)

(defun quickrun ()
  (interactive)
  (let* ((orig-src (file-name-nondirectory (buffer-file-name)))
         (lang (quickrun/decide-file-type))
         (lang-key (or (gethash lang quickrun/lang-key) lang))
         (extension (quickrun/extension-from-lang lang))
         (src (concat (make-temp-name "qr-") "." extension)))
    (if (string= lang "java")
        (setf src orig-src)
      (copy-file orig-src src))
    (let ((cmd-info-hash (quickrun/fill-templates lang-key src)))
      (catch 'compile-error
        (if (gethash :compile cmd-info-hash)
            (quickrun/compile (gethash :compile cmd-info-hash)))
        (let ((process (quickrun/run (gethash :exec cmd-info-hash))))
          (setf quickrun/remove-files
                (if (string= lang "java")
                    (gethash :remove cmd-info-hash)
                  (cons src (gethash :remove cmd-info-hash))))
          (set-process-sentinel quickrun/process #'quickrun/sentinel))))))

(defvar quickrun/epilogue (lambda () (message "finish")))

(defun quickrun/sentinel (process state)
  (let ((status (process-status process)))
    (cond
     ((eq status 'exit)
      (progn
        (funcall quickrun/epilogue)
        (dolist (file quickrun/remove-files)
          (if (file-exists-p file)
              (delete-file file)))
        (pop-to-buffer (process-buffer process))))
     (t nil))))

(provide 'quickrun)