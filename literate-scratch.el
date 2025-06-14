;;; literate-scratch.el --- Lisp Interaction w/ text paragraphs  -*- lexical-binding: t -*-

;; Copyright (C) 2023-2025  Free Software Foundation, Inc.

;; Author: Sean Whitton <spwhitton@spwhitton.name>
;; Maintainer: Sean Whitton <spwhitton@spwhitton.name>
;; Package-Requires: ((emacs "29.1"))
;; Version: 2.2
;; URL: https://git.spwhitton.name/dotfiles/tree/.emacs.d/site-lisp/literate-scratch.el
;; Keywords: lisp text

;; This file is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this file.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Variant Lisp Interaction mode for easier interleaving of paragraphs of
;; plain text with Lisp code.  This means you can have
;;
;;     ;; This buffer is for text that is not saved ...
;;     ;; To create a file, visit it with C-x C-f and ...
;;
;;     (here is some Lisp)
;;
;;     Here is a plain text paragraph )( including some unmatched parentheses.
;;     Uh oh!  Paredit won't like that.
;;
;;     (here is some more Lisp)
;;
;; but (e.g.) Paredit won't complain about the unmatched parentheses.
;; Indeed, the whole plain text paragraph is font-locked as a comment.
;;
;; If you use Paredit but want to be able to use *scratch* for both Lisp
;; interaction and blocks of plain text, then this mode is for you.
;; Also compatible with the `orgalist-mode' and `orgtbl-mode' minor modes.
;;
;; To enable this mode after installing this file, simply customise
;; `initial-major-mode' to `literate-scratch-mode'.

;;; News:

;; Ver 2.2 2025/04/25 Sean Whitton
;;     Bug fix: prevent \\`M-j' and \\`M-q' copying the first characters of
;;     block comment lines to the beginnings of newly added lines.
;;     Bug fix: prevent `comment-indent' indenting block comment lines as
;;     though they were Lisp comments beginning with single semicolons.
;;     Make \\`TAB' indent block comment lines, copying the preceding block
;;     comment line's indentation downwards.
;; Ver 2.1 2025/04/19 Sean Whitton
;;     Bug fix: before adding whitespace syntax to the newline character
;;     following a block comment line, check we're not on the last line of a
;;     buffer with no final newline character.
;; Ver 2.0 2025/04/18 Sean Whitton
;;     Rewrite core algorithm to use comment starters not comment fences,
;;     and therefore no `syntax-propertize-extend-region-functions' entry.
;;     Thanks to Stefan Monnier for comments which prompted this.
;;     Newly recognise `\\=`(' as starting paragraphs of Lisp.
;; Ver 1.0 2024/06/21 Sean Whitton
;;     Initial release.
;;     Thanks to Philip Kaludercic for review.

;;; Code:

(defun literate-scratch--propertize (start end)
  (goto-char start)
  (unless (bolp)
    ;; Skip this line if START is already later than where we'd put the text
    ;; property (i.e., make a modification).  Else just ensure BOL.
    (back-to-indentation)
    (forward-line (if (>= (point) start) 0 1)))
  (while (and (not (eobp)) (>= end (point)))
    ;; Here we do want to treat `]' the same as `)'.
    (skip-syntax-forward "-)")
    (unless (looking-at paragraph-separate)
      (back-to-indentation)
      (let ((1st (point)))
	;; 1ST's line ...
	(if (eq (pos-bol) (point-min))
	    ;; ... is the first line of the buffer.
	    (literate-scratch--put-comment-start 1st)
	  (save-excursion
	    (forward-line -1)
	    (cond ((not (looking-at paragraph-separate))
		   ;; ... is within a paragraph.
		   ;; Then make 1ST's line a block comment line if and only
		   ;; if the line preceding it is a block comment line too.
		   (back-to-indentation)
		   (when (literate-scratch--comment-start-p (point))
		     (literate-scratch--put-comment-start 1st t)))
		  ((eq (pos-bol 2) 1st)
		   ;; ... starts a paragraph and is unindented.
		   (literate-scratch--put-comment-start 1st))
		  ((zerop (car (syntax-ppss 1st)))
		   ;; ... starts a paragraph and is indented, but could not
		   ;; be a code paragraph within a multi-paragraph defun.
		   (literate-scratch--put-comment-start 1st)
		   (syntax-ppss-flush-cache 1st)))))))
    (forward-line 1))
  ;; Now also call the usual `syntax-propertize-function' for this mode.
  (elisp-mode-syntax-propertize start end))

(defun literate-scratch--indent-line ()
  "`indent-line-function' for `literate-scratch-mode'.
If within a block comment, copy previous line's indentation,
unless at start of paragraph.
Otherwise defer to `lisp-indent-line'."
  ;; `lisp-indent-line' has hardcoded behaviour to call `comment-indent' for
  ;; lines starting with a single comment character, which includes the ones
  ;; we've marked.  This is fine for the first lines of block comments;
  ;; `comment-search-forward' identifies the line as a comment line and so our
  ;; `comment-indent-function' is used properly even in the absence of this
  ;; custom `indent-line-function'.  But since the fix for Emacs bug#78003,
  ;; `comment-indent' will identify subsequent block comment lines as part of
  ;; multiline constructs, and defer back to the mode to indent them.
  ;; We require a custom `indent-line-function' to break the infinite loop.
  (if (literate-scratch--comment-line-p)
      (indent-line-to (save-excursion
			(literate-scratch--calc-comment-indent)))
    (lisp-indent-line)))

(defun literate-scratch--comment-indent ()
  "`comment-indent-function' for `literate-scratch-mode'.
If within a block comment, copy previous line's indentation,
unless at start of paragraph.
Otherwise defer to `lisp-comment-indent'."
  (if (literate-scratch--comment-line-p)
      (literate-scratch--calc-comment-indent)
    (lisp-comment-indent)))

(defun literate-scratch--calc-comment-indent ()
  (let ((indent (current-indentation)))
    (if (or (eq (line-number-at-pos) 1)
	    (progn (forward-line -1)
		   (looking-at paragraph-separate)))
	indent
      (current-indentation))))

(defun literate-scratch--fill-paragraph (&optional justify)
  "`fill-paragraph-function' for `literate-scratch-mode'.
If within a block comment, perform a text paragraph fill.
Otherwise defer to `lisp-fill-paragraph'."
  (if (literate-scratch--comment-line-p)
      ;; Just fill as a text paragraph.
      ;; M-q is usually bound to `prog-fill-reindent-defun', which calls
      ;; `fill-paragraph', which calls us, and then if we simply return nil
      ;; the paragraph will be filled as text.
      ;; However, Paredit has its own binding for M-q.
      ;; Calling `fill-paragraph' like this, instead of just returning nil,
      ;; covers both `prog-fill-reindent-defun' and `paredit-reindent-defun'.
      (let (fill-paragraph-function)
	(fill-paragraph justify))
    (lisp-fill-paragraph justify)))

(defun literate-scratch--comment-break (&optional soft)
  "`comment-line-break-function' for `literate-scratch-mode'.
If within a block comment, perform a simple newline-and-indent.
Otherwise defer to `comment-indent-new-line'."
  (if (literate-scratch--comment-line-p)
      (let ((indent (current-indentation)))
	;; Insert the newline and clear horizontal space in the same manner as
	;; `default-indent-new-line' and `comment-indent-new-line', which see.
	(if soft (insert-and-inherit ?\n) (newline 1))
	(save-excursion (forward-char -1) (delete-horizontal-space))
	(delete-horizontal-space)
	;; Indent to the same level as the previous line.
	(indent-to indent))
    (comment-indent-new-line soft)))

(defun literate-scratch--put-comment-start (pos &optional force)
  "Mark POS's line as a block comment line depending on the char(s) at POS.
If FORCE is non-nil, instead unconditionally mark POS's line as a block
comment line.  Moves point to POS if it is not already there."
  (goto-char pos)
  ;; We consider only non-self-evaluating forms to compose Lisp paragraphs.
  ;; It might be useful to be able to prepare forms starting with `\\='(' or
  ;; `[' in *scratch* with the benefit of Paredit, and then kill them and yank
  ;; into other buffers.  On the other hand, you might want to start plain
  ;; text paragraphs with those strings.
  ;;
  ;; Treat a backtick on its own as Lisp so that when an immediate following
  ;; open parenthesis is typed, Paredit inserts a closing parenthesis too.
  (when (or force (not (looking-at "`$\\|`?(\\|;")))
    (put-text-property pos (1+ pos) 'syntax-table
		       (eval-when-compile (string-to-syntax "<")))
    ;; Mark the newline as not a comment ender, as it usually is for Elisp.
    ;; Then only the second newline of the two newlines at the end of a text
    ;; paragraph is a comment ender.  This means that when point is between
    ;; the two newlines, i.e. at the beginning of an empty line right after
    ;; the text paragraph, `paredit-in-comment-p' still returns t, and so
    ;; \\`(' and \\`[' insert only single characters.
    (let ((eol (pos-eol)))
     (unless (eq eol (point-max))
       (put-text-property eol (1+ eol) 'syntax-table
			  (eval-when-compile (string-to-syntax "-")))))))

(defun literate-scratch--comment-start-p (pos)
  (equal (get-text-property pos 'syntax-table)
	 (eval-when-compile (string-to-syntax "<"))))

(defun literate-scratch--comment-line-p ()
  (save-excursion
    (back-to-indentation)
    (literate-scratch--comment-start-p (point))))

;;;###autoload
(define-derived-mode literate-scratch-mode lisp-interaction-mode
  "Lisp Interaction"
  "Variant `lisp-interaction-mode' designed for the *scratch* buffer.
Paragraphs that don't start with `(', `\\=`(' or `;' become block comments.
This makes it easier to interleave paragraphs of plain text with Lisp.

You can enable this mode by customising the variable `initial-major-mode'
to `literate-scratch-mode'."
  (setq-local syntax-propertize-function  #'literate-scratch--propertize
	      indent-line-function        #'literate-scratch--indent-line
	      comment-indent-function     #'literate-scratch--comment-indent
	      fill-paragraph-function     #'literate-scratch--fill-paragraph
	      comment-line-break-function #'literate-scratch--comment-break))

(provide 'literate-scratch)

;;; literate-scratch.el ends here
