;;; nim-mode.el --- A major mode for the Nim programming language
;;
;; Filename: nim-mode.el
;; Description: A major mode for the Nim programming language
;; Author: Simon Hafner
;; Maintainer: Simon Hafner <hafnersimon@gmail.com>
;; Version: 0.2.0
;; Keywords: nim languages
;; Compatibility: GNU Emacs 24
;; Package-Requires: ((emacs "24") (epc "0.1.1"))
;;
;; Taken over from James H. Fisher <jameshfisher@gmail.com>
;;
;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program; see the file COPYING.  If not, write to
;; the Free Software Foundation, Inc., 51 Franklin Street, Fifth
;; Floor, Boston, MA 02110-1301, USA.
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;; Commentary:
;;
;; Large parts of this code is shamelessly stolen from python.el and
;; adapted to Nim
;;
;; Todo:
;;
;; -- Make things non-case-sensitive and ignore underscores
;; -- Identifier following "proc" gets font-lock-function-name-face
;; -- Treat parameter lists separately
;; -- Treat pragmas inside "{." and ".}" separately
;; -- Make double-# comments get font-lock-doc-face
;; -- Highlight tabs as syntax error
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;; Code:

(eval-when-compile
  (require 'cl))

(require 'nim-vars)
(require 'nim-syntax)
(require 'nim-util)
(require 'nim-helper)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                                Helpers                                     ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun nim-glue-strings (glue strings)
  "Concatenate some GLUE and a list of STRINGS."
  (mapconcat 'identity strings glue))

(defun nim-regexp-choice (strings)
  "Construct a regexp multiple-choice from a list of STRINGS."
  (concat "\\(" (nim-glue-strings "\\|" strings) "\\)"))

(put 'nim-mode 'font-lock-defaults '(nim-font-lock-keywords nil t))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                               Indentation                                  ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;; Indentation

(defvar nim-indent-current-level 0
  "Current indentation level `nim-indent-line-function' is using.")

(defvar nim-indent-levels '(0)
  "Levels of indentation available for `nim-indent-line-function'.")

(defvar nim-indent-dedenters
  (nim-rx symbol-start
             (or "else" "elif" "of" "finally" "except")
             symbol-end
             (* (not (in "\n")))
             ":" (* space) (or "#" eol))
  "Regular expression matching the end of line after which should be dedented.
If the end of a line matches this regular expression, the line
will be dedented relative to the previous block.")

(defcustom nim-indent-trigger-commands
  '(indent-for-tab-command yas-expand yas/expand)
  "Commands that might trigger a `nim-indent-line' call."
  :type '(repeat symbol)
  :group 'nim)

(defun nim-indent-context ()
  "Get information on indentation context.
Context information is returned with a cons with the form:
    \(STATUS . START)

Where status can be any of the following symbols:
 * inside-paren: If point in between (), {} or [].  START is the
   position of the opening parenthesis.
 * inside-string: If point is inside a string.  START is the
   beginning of the string.
 * after-beginning-of-block: Point is after beginning of
   block.  START is the beginning position of line that starts the
   new block.
 * after-operator: Previous line ends in an operator or current
   line starts with an operator.  START is the position of the
   operator.
 * after-line: Point is after normal line.  START is the beginning
   of the line.
 * no-indent: Point is at beginning of buffer or other special
   case.  START is the position of point."
  (save-restriction
    (widen)
    ;; restrict to the enclosing parentheses, if any
    (let* ((within-paren (nim-util-narrow-to-paren))
           (ppss (save-excursion (beginning-of-line) (syntax-ppss)))
           (start))
      (cons
       (cond
        ;; Beginning of buffer
        ((= (line-beginning-position) (point-min))
         (setq start (point))
         (if within-paren 'inside-paren 'no-indent))
        ;; Inside string
        ((setq start (nim-syntax-context 'string ppss))
         'inside-string)
        ;; After beginning of block
        ((setq start (save-excursion
                       (when (progn
                               (back-to-indentation)
                               (nim-util-forward-comment -1)
                               (or (save-excursion
                                     (back-to-indentation)
                                     (looking-at (nim-rx decl-block)))
                                   (memq (char-before) '(?: ?=))
                                   (looking-back nim-indent-indenters nil)))
                         (cond
                          ((= (char-before) ?:)
                           (nim-util-backward-stmt)
                           (point))
                          ((= (char-before) ?=)
                           (nim-util-backward-stmt)
                           (and (looking-at (nim-rx defun))
                                (point)))
                          ;; a single block statement on a line like type, var, const, ...
                          (t
                           (back-to-indentation)
                           (point))))))
         'after-beginning-of-block)
        ;; Current line begins with operator
        ((setq start (save-excursion
                       (progn
                         (back-to-indentation)
                         (and (looking-at (nim-rx operator))
                              (match-beginning 0)))))
         'after-operator)
        ;; After operator on previous line
        ((setq start (save-excursion
                       (progn
                         (back-to-indentation)
                         (nim-util-forward-comment -1)
                         (and (looking-back (nim-rx operator)
                                            (line-beginning-position))
                              (match-beginning 0)))))
         'after-operator)
        ;; After normal line
        ((setq start (save-excursion
                       (back-to-indentation)
                       (point)))
         (if (and within-paren
                  (save-excursion
                    (skip-chars-backward "\s\n")
                    (bobp)))
             'inside-paren
           'after-line))
        ;; Do not indent
        (t 'no-indent))
       start))))

(defun nim-indent-calculate-indentation ()
  "Calculate correct indentation offset for the current line."
  (let* ((indentation-context (nim-indent-context))
         (context-status (car indentation-context))
         (context-start (cdr indentation-context)))
    (save-restriction
      (widen)
      ;; restrict to enclosing parentheses, if any
      (nim-util-narrow-to-paren)
      (save-excursion
        (cl-case context-status
          ('no-indent 0)
          ;; When point is after beginning of block just add one level
          ;; of indentation relative to the context-start
          ('after-beginning-of-block
           (goto-char context-start)
           (+ (nim-util-real-current-column) nim-indent-offset))
          ;; When after a simple line just use previous line
          ;; indentation, in the case current line starts with a
          ;; `nim-indent-dedenters' de-indent one level.
          ('after-line
           (-
            (save-excursion
              (goto-char context-start)
              (forward-line -1)
              (end-of-line)
              (nim-nav-beginning-of-statement)
              (nim-util-real-current-indentation))
            (if (progn
                  (back-to-indentation)
                  (looking-at nim-indent-dedenters))
                nim-indent-offset
              0)))
          ;; When inside of a string, do nothing. just use the current
          ;; indentation.  XXX: perhaps it would be a good idea to
          ;; invoke standard text indentation here
          ('inside-string
           (goto-char context-start)
           (nim-util-real-current-indentation))
          ;; When point is after an operator line, there are several cases
          ('after-operator
           (save-excursion
             (nim-nav-beginning-of-statement)
             (cond
              ;; current line is a continuation of a block statement
              ((looking-at (nim-rx block-start (* space)))
               (goto-char (match-end 0))
               (nim-util-real-current-column))
              ;; current line is a continuation of an assignment
              ;; operator. Find an assignment operator that is not
              ;; contained in a string/comment/paren and is not
              ;; followed by whitespace only
              ((save-excursion
                 (and (re-search-forward (nim-rx not-simple-operator
                                                    assignment-operator
                                                    not-simple-operator)
                                         nil
                                         t)
                      (not (nim-syntax-context-type))
                      (progn
                        (backward-char)
                        (not (looking-at (rx (* space) (or "#" eol)))))))
               (goto-char (match-end 0))
               (skip-syntax-forward "\s")
               (nim-util-real-current-column))
              ;; current line is a continuation of some other operator, just indent
              (t
               (back-to-indentation)
               (+ (nim-util-real-current-column) nim-indent-offset)))))
          ;; When inside a paren there's a need to handle nesting
          ;; correctly
          ('inside-paren
           (cond
            ;; If current line closes the outermost open paren use the
            ;; current indentation of the context-start line.
            ((save-excursion
               (skip-syntax-forward "\s" (line-end-position))
               (when (and (looking-at (nim-rx (in ")]}")))
                          (progn
                            (forward-char 1)
                            (not (nim-syntax-context 'paren))))
                 (goto-char context-start)
                 (nim-util-real-current-indentation))))
            ;; If open paren is contained on a line by itself add another
            ;; indentation level, else look for the first word after the
            ;; opening paren and use it's column position as indentation
            ;; level.
            ((let* ((content-starts-in-newline)
                    (indent
                     (save-excursion
                       (if (setq content-starts-in-newline
                                 (progn
                                   (goto-char context-start)
                                   (forward-char)
                                   (save-restriction
                                     (narrow-to-region
                                      (line-beginning-position)
                                      (line-end-position))
                                     (nim-util-forward-comment))
                                   (looking-at "$")))
                           (+ (nim-util-real-current-indentation) nim-indent-offset)
                         (nim-util-real-current-column)))))
               ;; Adjustments
               (cond
                ;; If current line closes a nested open paren de-indent one
                ;; level.
                ((progn
                   (back-to-indentation)
                   (looking-at (nim-rx ")]}")))
                 (- indent nim-indent-offset))
                ;; If the line of the opening paren that wraps the current
                ;; line starts a block add another level of indentation to
                ;; follow new pep8 recommendation. See: http://ur1.ca/5rojx
                ((save-excursion
                   (when (and content-starts-in-newline
                              (progn
                                (goto-char context-start)
                                (back-to-indentation)
                                (looking-at (nim-rx block-start))))
                     (+ indent nim-indent-offset))))
                (t indent)))))))))))

(defun nim-indent-calculate-levels ()
  "Calculate `nim-indent-levels' and reset `nim-indent-current-level'."
  (let* ((indentation (nim-indent-calculate-indentation))
         (remainder (% indentation nim-indent-offset))
         (steps (/ (- indentation remainder) nim-indent-offset)))
    (setq nim-indent-levels (list 0))
    (dotimes (step steps)
      (push (* nim-indent-offset (1+ step)) nim-indent-levels))
    (when (not (eq 0 remainder))
      (push (+ (* nim-indent-offset steps) remainder) nim-indent-levels))
    (setq nim-indent-levels (nreverse nim-indent-levels))
    (setq nim-indent-current-level (1- (length nim-indent-levels)))))

(defun nim-indent-toggle-levels ()
  "Toggle `nim-indent-current-level' over `nim-indent-levels'."
  (setq nim-indent-current-level (1- nim-indent-current-level))
  (when (< nim-indent-current-level 0)
    (setq nim-indent-current-level (1- (length nim-indent-levels)))))

(defun nim-indent-line (&optional force-toggle)
  "Internal implementation of `nim-indent-line-function'.
Uses the offset calculated in
`nim-indent-calculate-indentation' and available levels
indicated by the variable `nim-indent-levels' to set the
current indentation.

When the variable `last-command' is equal to one of the symbols
inside `nim-indent-trigger-commands' or FORCE-TOGGLE is
non-nil it cycles levels indicated in the variable
`nim-indent-levels' by setting the current level in the
variable `nim-indent-current-level'.

When the variable `last-command' is not equal to one of the
symbols inside `nim-indent-trigger-commands' and FORCE-TOGGLE
is nil it calculates possible indentation levels and saves it in
the variable `nim-indent-levels'.  Afterwards it sets the
variable `nim-indent-current-level' correctly so offset is
equal to (`nth' `nim-indent-current-level'
`nim-indent-levels')"
  (or
   (and (or (and (memq this-command nim-indent-trigger-commands)
                 (eq last-command this-command))
            force-toggle)
        (not (equal nim-indent-levels '(0)))
        (or (nim-indent-toggle-levels) t))
   (nim-indent-calculate-levels))
  (let* ((starting-pos (point-marker))
         (indent-ending-position
          (+ (line-beginning-position) (current-indentation)))
         (follow-indentation-p
          (or (bolp)
              (and (<= (line-beginning-position) starting-pos)
                   (>= indent-ending-position starting-pos))))
         (next-indent (nth nim-indent-current-level nim-indent-levels)))
    (unless (= next-indent (current-indentation))
      (beginning-of-line)
      (delete-horizontal-space)
      (indent-to next-indent)
      (goto-char starting-pos))
    (and follow-indentation-p (back-to-indentation)))
  ;(nim-info-closing-block-message)
  )

(defun nim-indent-line-function ()
  "`indent-line-function' for Nim mode.
See `nim-indent-line' for details."
  (nim-indent-line))

(defun nim-indent-dedent-line ()
  "De-indent current line."
  (interactive "*")
  (when (and (not (nim-syntax-comment-or-string-p))
             (<= (point-marker) (save-excursion
                                  (back-to-indentation)
                                  (point-marker)))
             (> (current-column) 0))
    (nim-indent-line t)
    t))

(defun nim-indent-dedent-line-backspace (arg)
  "De-indent current line.
Argument ARG is passed to `backward-delete-char-untabify' when
point is  not in between the indentation."
  (interactive "*p")
  (when (not (nim-indent-dedent-line))
    (backward-delete-char-untabify arg)))
(put 'nim-indent-dedent-line-backspace 'delete-selection 'supersede)

(defun nim-indent-region (start end)
  "Indent a nim region automagically.

Called from a program, START and END specify the region to indent."
  (let ((deactivate-mark nil))
    (save-excursion
      (goto-char end)
      (setq end (point-marker))
      (goto-char start)
      (or (bolp) (forward-line 1))
      (while (< (point) end)
        (or (and (bolp) (eolp))
            (let (word)
              (forward-line -1)
              (back-to-indentation)
              (setq word (current-word))
              (forward-line 1)
              (when (and word
                         ;; Don't mess with strings, unless it's the
                         ;; enclosing set of quotes.
                         (or (not (nim-syntax-context 'string))
                             (eq
                              (syntax-after
                               (+ (1- (point))
                                  (current-indentation)
                                  (nim-syntax-count-quotes (char-after) (point))))
                              (string-to-syntax "|"))))
                (beginning-of-line)
                (delete-horizontal-space)
                (indent-to (nim-indent-calculate-indentation)))))
        (forward-line 1))
      (move-marker end nil))))

(defun nim-indent-shift-left (start end &optional count)
  "Shift lines contained in region START END by COUNT columns to the left.
COUNT defaults to `nim-indent-offset'.  If region isn't
active, the current line is shifted.  The shifted region includes
the lines in which START and END lie.  An error is signaled if
any lines in the region are indented less than COUNT columns."
  (interactive
   (if mark-active
       (list (region-beginning) (region-end) current-prefix-arg)
     (list (line-beginning-position) (line-end-position) current-prefix-arg)))
  (if count
      (setq count (prefix-numeric-value count))
    (setq count nim-indent-offset))
  (when (> count 0)
    (let ((deactivate-mark nil))
      (save-excursion
        (goto-char start)
        (while (< (point) end)
          (if (and (< (current-indentation) count)
                   (not (looking-at "[ \t]*$")))
              (error "Can't shift all lines enough"))
          (forward-line))
        (indent-rigidly start end (- count))))))

(add-to-list 'debug-ignored-errors "^Can't shift all lines enough")

(defun nim-indent-shift-right (start end &optional count)
  "Shift lines contained in region START END by COUNT columns to the left.
COUNT defaults to `nim-indent-offset'.  If region isn't
active, the current line is shifted.  The shifted region includes
the lines in which START and END lie."
  (interactive
   (if mark-active
       (list (region-beginning) (region-end) current-prefix-arg)
     (list (line-beginning-position) (line-end-position) current-prefix-arg)))
  (let ((deactivate-mark nil))
    (if count
        (setq count (prefix-numeric-value count))
      (setq count nim-indent-offset))
    (indent-rigidly start end count)))

(defun nim-indent-electric-colon (arg)
  "Insert a colon and maybe de-indent the current line.
With numeric ARG, just insert that many colons.  With
\\[universal-argument], just insert a single colon."
  (interactive "*P")
  (self-insert-command (if (not (integerp arg)) 1 arg))
  (when (and (not arg)
             (eolp)
             (not (equal ?: (char-after (- (point-marker) 2))))
             (not (nim-syntax-comment-or-string-p)))
    (let ((indentation (current-indentation))
          (calculated-indentation (nim-indent-calculate-indentation)))
      ;(nim-info-closing-block-message)
      (when (> indentation calculated-indentation)
        (save-excursion
          (indent-line-to calculated-indentation)
          ;; (when (not (nim-info-closing-block-message))
          ;;   (indent-line-to indentation)))))))
          )))))
(put 'nim-indent-electric-colon 'delete-selection t)

(defun nim-indent-post-self-insert-function ()
  "Adjust closing paren line indentation after a char is added.
This function is intended to be added to the
`post-self-insert-hook.'  If a line renders a paren alone, after
adding a char before it, the line will be re-indented
automatically if needed."
  (when (and (eq (char-before) last-command-event)
             (not (bolp))
             (memq (char-after) '(?\) ?\] ?\})))
    (save-excursion
      (goto-char (line-beginning-position))
      ;; If after going to the beginning of line the point
      ;; is still inside a paren it's ok to do the trick
      (when (nim-syntax-context 'paren)
        (let ((indentation (nim-indent-calculate-indentation)))
          (when (< (current-indentation) indentation)
            (indent-line-to indentation)))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                             Wrap it all up ...                             ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;###autoload
(define-derived-mode nim-mode prog-mode "Nim"
  "A major mode for the Nim programming language."
  :group 'nim

  (setq font-lock-defaults '(nim-font-lock-keywords nil t))

  ;; ;; Comment
  ;; (set (make-local-variable 'comment-start) "# ")
  ;; (set (make-local-variable 'comment-start-skip) "#+\\s-*")
  ;; modify the keymap
  (set (make-local-variable 'indent-line-function) 'nim-indent-line-function)
  (set (make-local-variable 'indent-region-function) #'nim-indent-region)
  (setq indent-tabs-mode nil) ;; Always indent with SPACES!
  )

(defcustom nim-compiled-buffer-name "*nim-js*"
  "The name of the scratch buffer used to compile Javascript from Nim."
  :type 'string
  :group 'nim)

(defcustom nim-command "nim"
  "Path to the nim executable.
You don't need to set this if the nim executable is inside your PATH."
  :type 'string
  :group 'nim)

(defcustom nim-args-compile '()
  "The arguments to pass to `nim-command' to compile a file."
  :type '(repeat string)
  :group 'nim)

(defcustom nim-project-root-regex "\\(\.git\\|\.nim\.cfg\\|\.nimble\\)$"
  "Regex to find project root directory."
  :type 'string
  :group 'nim)

(defun nim-get-project-root ()
  "Return project directory."
  (file-name-directory
   (nim-find-file-in-hierarchy (file-name-directory (buffer-file-name)) nim-project-root-regex)))

(defun nim-compile-file-to-js (&optional callback)
  "Save current file and compiles it.
Use the project directory, so it will work best with external
libraries where `nim-compile-region-to-js' does not.  Return the
filename of the compiled file.  The CALLBACK is executed on
success with the filename of the compiled file."
  (interactive)
  (save-buffer)
  (let ((default-directory (or (nim-get-project-root) default-directory)))
    (lexical-let ((callback callback))
      (nim-compile (list "js" (buffer-file-name))
                      (lambda () (when callback
                              (funcall callback (concat default-directory
                                                        "nimcache/"
                                                        (file-name-sans-extension (file-name-nondirectory (buffer-file-name)))
                                                        ".js"))))))))

(defun nim-compile-region-to-js (start end)
  "Compile the current region to javascript.
The result is written into the buffer
`nim-compiled-buffer-name'."
  (interactive "r")

  (lexical-let ((buffer (get-buffer-create nim-compiled-buffer-name))
                (tmpdir (file-name-as-directory (make-temp-file "nim-compile" t))))
    (let ((default-directory tmpdir))
      (write-region start end "tmp.nim" nil 'foo)
      (with-current-buffer buffer
        (erase-buffer)
        (let ((default-directory tmpdir))
          (nim-compile '("js" "tmp.nim")
                       (lambda () (with-current-buffer buffer
                               (insert-file-contents
                                (concat tmpdir (file-name-as-directory "nimcache") "tmp.js"))
                               (display-buffer buffer)))))))))

(defun nim-compile (args &optional on-success)
  "Invoke the compiler and call ON-SUCCESS in case of successful compilation."
  (lexical-let ((on-success (or on-success (lambda () (message "Compilation successful.")))))
    (if (bufferp "*nim-compile*")
        (with-current-buffer "*nim-compile*"
          (erase-buffer)))
    ))

(defun nim-doc-buffer (element)
  "Displays documentation buffer with ELEMENT contents."
  (let ((buf (get-buffer-create "*nim-doc*")))
    (with-current-buffer buf
      (view-mode -1)
      (erase-buffer)
      (insert (get-text-property 0 :nim-doc element))
      (goto-char (point-min))
      (view-mode 1)
      buf)))

;;; Completion

(defcustom nim-nimsuggest-path nil "Path to the nimsuggest binary."
  :type 'string
  :group 'nim)

(require 'epc)

;;; If you change the order here, make sure to change it over in
;;; nimsuggest.nim too.
(defconst nim-epc-order '(:section :symkind :qualifiedPath :filePath :forth :line :column :doc))

(cl-defstruct nim-epc section symkind qualifiedPath filePath forth line column doc)
(defun nim-parse-epc (list)
  ;; (message "%S" list)
  (cl-mapcar (lambda (sublist) (apply #'make-nim-epc
                               (cl-mapcan #'list nim-epc-order sublist)))
          list))

(defvar nim-epc-processes-alist nil)

(defun nim-find-or-create-epc ()
  "Get the epc responsible for the current buffer."
  (let ((main-file (or (nim-find-project-main-file)
                           (buffer-file-name))))
    (or (let ((epc-process (cdr (assoc main-file nim-epc-processes-alist))))
          (if (eq 'run (epc:manager-status-server-process epc-process))
              epc-process
            (progn (setq nim-epc-processes-alist (assq-delete-all main-file nim-epc-processes-alist))
                   nil)))
        (let ((epc-process (epc:start-epc nim-nimsuggest-path (list "--epc" main-file))))
          (push (cons main-file epc-process) nim-epc-processes-alist)
          epc-process))))

(defun nim-call-epc (method callback)
  "Call the nimsuggest process on point.

Call the nimsuggest process responsible for the current buffer.
All commands work with the current cursor position.  METHOD can be
one of:

sug: suggest a symbol
con: suggest, but called at fun(_ <-
def: where the is defined
use: where the symbol is used

The callback is called with a list of nim-epc structs."
  (lexical-let ((tempfile (nim-save-buffer-temporarly))
                (cb callback))
    (deferred:$
      (epc:call-deferred
       (nim-find-or-create-epc)
       method
       (list (buffer-file-name)
             (line-number-at-pos)
             (current-column)
             tempfile))
      (deferred:nextc it
        (lambda (x) (funcall cb (nim-parse-epc x))))
      (deferred:watch it (lambda (x) (delete-directory (file-name-directory tempfile) t))))))

(defun nim-save-buffer-temporarly ()
  "Save the current buffer and return the location, so we
can pass it to epc."
  (let* ((dirname (make-temp-file "nim-dirty" t))
         (filename (expand-file-name (file-name-nondirectory (buffer-file-name))
                                     (file-name-as-directory dirname))))
    (save-restriction
      (widen)
      (write-region (point-min) (point-max) filename nil 1))
    filename))

(defun nim-find-file-in-hierarchy (current-dir pattern)
  "Search for a file matching PATTERN upwards through the directory
hierarchy, starting from CURRENT-DIR"
  (catch 'found
    (locate-dominating-file
     current-dir
     (lambda (dir)
       (let ((file (first (directory-files dir t pattern nil))))
         (when file (throw 'found file)))))))

(defun nim-find-project-main-file ()
  "Get the main file for the project."
  (let ((main-file (nim-find-file-in-hierarchy
                (file-name-directory (buffer-file-name))
                ".*\.nim\.cfg")))
    (when main-file (file-name-base main-file))))

(defun nim-goto-sym ()
  "Go to the definition of the symbol currently under the cursor."
  (interactive)
  (nim-call-epc 'def
                (lambda (defs)
                  (let ((def (first defs)))
                    (when (not def) (error "Symbol not found"))
                    (find-file (nim-epc-filePath def))
                    (goto-char (point-min))
                    (forward-line (1- (nim-epc-line def)))))))

;; compilation error
(eval-after-load 'compile
  '(progn
     (with-no-warnings
       (add-to-list 'compilation-error-regexp-alist 'nim)
       (add-to-list 'compilation-error-regexp-alist-alist
                    '(nim "^\\s-*\\(.*\\)(\\([0-9]+\\),\\s-*\\([0-9]+\\))\\s-+\\(?:Error\\|\\(Hint\\)\\):" 1 2 3 (4))))))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.nim\\'" . nim-mode))

(provide 'nim-mode)

;;; nim-mode.el ends here
