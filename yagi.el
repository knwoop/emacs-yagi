;;; yagi.el --- AI assistant using yagi CLI -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Kenta Takahashi

;; Author: Kenta Takahashi <knwoop@gmail.com>
;; URL: https://github.com/knwoop/emacs-yagi
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: convenience tools ai

;; This file is not part of GNU Emacs.

;; Permission is hereby granted, free of charge, to any person obtaining a copy
;; of this software and associated documentation files (the "Software"), to deal
;; in the Software without restriction, including without limitation the rights
;; to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
;; copies of the Software, and to permit persons to whom the Software is
;; furnished to do so, subject to the following conditions:

;; The above copyright notice and this permission notice shall be included in
;; all copies or substantial portions of the Software.

;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
;; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
;; SOFTWARE.

;;; Commentary:

;; Emacs package for AI assistance using yagi (https://github.com/mattn/yagi).
;; Provides interactive commands for chatting with AI, explaining code,
;; refactoring, adding comments, and fixing bugs.
;;
;; Usage:
;;   (require 'yagi)
;;   (yagi-mode 1)
;;
;; Or with use-package:
;;   (use-package yagi
;;     :config
;;     (yagi-mode 1))

;;; Code:

(require 'json)

;;; Customization

(defgroup yagi nil
  "AI assistant using yagi CLI."
  :group 'tools
  :prefix "yagi-")

(defcustom yagi-executable "yagi"
  "Path to the yagi executable."
  :type 'string
  :group 'yagi)

(defcustom yagi-model (or (getenv "YAGI_MODEL") "openai")
  "Model provider to use with yagi."
  :type 'string
  :group 'yagi)

(defcustom yagi-show-prompt t
  "Whether to show the prompt in the response buffer."
  :type 'boolean
  :group 'yagi)

(defcustom yagi-stream t
  "Whether to use streaming mode for responses.
When non-nil, responses are displayed incrementally as tokens arrive."
  :type 'boolean
  :group 'yagi)

(defcustom yagi-response-buffer-name "*yagi-response*"
  "Name of the buffer used to display yagi responses."
  :type 'string
  :group 'yagi)

(defcustom yagi-api-key-env-vars
  '("OPENAI_API_KEY" "ANTHROPIC_API_KEY" "GEMINI_API_KEY"
    "DEEPSEEK_API_KEY" "GROQ_API_KEY" "XAI_API_KEY"
    "MISTRAL_API_KEY" "PERPLEXITY_API_KEY" "CEREBRAS_API_KEY"
    "COHERE_API_KEY" "OPENROUTER_API_KEY" "SAMBANOVA_API_KEY"
    "GLM_API_KEY" "YAGI_MODEL")
  "Environment variable names to pass through to the yagi process."
  :type '(repeat string)
  :group 'yagi)

;;; Internal variables

(defvar yagi--process nil
  "The current yagi subprocess.")

(defvar yagi--pending-code nil
  "Pending code string from refactor for applying to buffer.")

(defvar yagi--source-buffer nil
  "The buffer that initiated the yagi request.")

(defvar yagi--source-region nil
  "Cons cell (BEG-MARKER . END-MARKER) of the region in the source buffer.
Uses markers to track position even when the buffer is edited.")

;;; Utilities

(defun yagi--mode-to-language ()
  "Return the programming language name for the current major mode."
  (let ((mode-name (symbol-name major-mode)))
    (cond
     ((string-match "\\`\\(.*\\)-ts-mode\\'" mode-name)
      (match-string 1 mode-name))
     ((string-match "\\`\\(.*\\)-mode\\'" mode-name)
      (match-string 1 mode-name))
     (t mode-name))))

(defun yagi--extract-code-from-response (content)
  "Extract code from markdown code blocks in CONTENT.
Returns the extracted code as a string.  If no code blocks are found,
returns the original content with leading/trailing whitespace removed."
  (let ((lines (split-string content "\n"))
        (code-lines '())
        (in-code-block nil)
        (has-code-block nil))
    (dolist (line lines)
      (if (string-match-p "^```" line)
          (progn
            (setq has-code-block t)
            (setq in-code-block (not in-code-block)))
        (when in-code-block
          (push line code-lines))))
    (if (and has-code-block code-lines)
        (string-join (nreverse code-lines) "\n")
      (string-trim content))))

;;; Response buffer

(defvar yagi-response-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "a") #'yagi-apply)
    map)
  "Keymap for `yagi-response-mode'.")

(define-derived-mode yagi-response-mode special-mode "Yagi-Response"
  "Major mode for displaying yagi AI responses."
  (setq buffer-read-only t)
  (when (fboundp 'markdown-view-mode)
    (markdown-view-mode)))

(defun yagi--show-in-buffer (content)
  "Display CONTENT in the yagi response buffer."
  (let ((buf (get-buffer-create yagi-response-buffer-name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert content)
        (goto-char (point-min)))
      (unless (derived-mode-p 'yagi-response-mode)
        (yagi-response-mode)))
    (display-buffer buf '(display-buffer-in-side-window
                          . ((side . right)
                             (window-width . 0.4))))))

(defun yagi--prepare-response-buffer ()
  "Prepare the response buffer for streaming output.
Clears the buffer and ensures it is visible."
  (let ((buf (get-buffer-create yagi-response-buffer-name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer))
      (unless (derived-mode-p 'yagi-response-mode)
        (yagi-response-mode)))
    (display-buffer buf '(display-buffer-in-side-window
                          . ((side . right)
                             (window-width . 0.4))))))

(defun yagi--append-to-response-buffer (text)
  "Append TEXT incrementally to the yagi response buffer."
  (let ((buf (get-buffer-create yagi-response-buffer-name)))
    (unless (get-buffer-window buf)
      (display-buffer buf '(display-buffer-in-side-window
                            . ((side . right)
                               (window-width . 0.4)))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert text)))))

;;; Process management

(defun yagi--build-process-environment ()
  "Build process environment with API keys."
  (let ((env (copy-sequence process-environment)))
    (dolist (key yagi-api-key-env-vars)
      (let ((val (getenv key)))
        (when val
          (push (format "%s=%s" key val) env))))
    env))

(defun yagi--send-request (messages callback)
  "Send MESSAGES to yagi and call CALLBACK with the result.
MESSAGES is a list of message alists with `role' and `content' keys.
CALLBACK receives a plist with either :content or :error key.
Per-request state is stored on the process object via `process-put',
so concurrent requests do not interfere with each other."
  (if (not (executable-find yagi-executable))
      (funcall callback (list :error (format "yagi executable not found: %s" yagi-executable)))
    (when (and yagi--process (process-live-p yagi--process))
      (delete-process yagi--process))
    (let* ((request (json-encode `((messages . ,(vconcat messages))
                                   (stream . ,(if yagi-stream t :json-false)))))
           (process-environment (yagi--build-process-environment))
           (stderr-pipe (make-pipe-process
                         :name "yagi-stderr"
                         :noquery t
                         :sentinel #'ignore))
           (proc (make-process
                  :name "yagi"
                  :command (list yagi-executable "-stdio" "-model" yagi-model)
                  :connection-type 'pipe
                  :noquery t
                  :filter #'yagi--process-filter
                  :sentinel #'yagi--process-sentinel
                  :stderr stderr-pipe)))
      (process-put proc 'yagi-response "")
      (process-put proc 'yagi-error "")
      (process-put proc 'yagi-pending-output "")
      (process-put proc 'yagi-callback callback)
      (process-put proc 'yagi-stream yagi-stream)
      (process-put proc 'yagi-stderr-process stderr-pipe)
      (set-process-filter stderr-pipe
                          (lambda (_stderr-proc output)
                            (process-put proc 'yagi-error
                                         (concat (process-get proc 'yagi-error)
                                                 output))))
      (when yagi-stream
        (yagi--prepare-response-buffer))
      (setq yagi--process proc)
      (process-send-string proc (concat request "\n"))
      (process-send-eof proc)
      (message "Yagi: Thinking..."))))

(defun yagi--process-filter (process output)
  "Process filter for yagi PROCESS OUTPUT.
Buffers incomplete lines and accumulates state on the PROCESS object."
  (let* ((pending (concat (or (process-get process 'yagi-pending-output) "") output))
         (lines (split-string pending "\n")))
    ;; Last element may be an incomplete line; keep it for next call
    (process-put process 'yagi-pending-output (car (last lines)))
    (dolist (line (butlast lines))
      (when (not (string-match-p "^\\s-*$" line))
        (condition-case err
            (let ((response (json-read-from-string line)))
              (let-alist response
                (cond
                 (.error
                  (process-put process 'yagi-error
                               (concat (process-get process 'yagi-error) .error)))
                 (.content
                  (process-put process 'yagi-response
                               (concat (process-get process 'yagi-response) .content))
                  (when (process-get process 'yagi-stream)
                    (yagi--append-to-response-buffer .content)))
                 (.done nil))))
          (error
           (message "Yagi: Failed to parse response: %s" (error-message-string err))))))))

(defun yagi--process-sentinel (process event)
  "Process sentinel for yagi PROCESS EVENT.
Cleans up stderr pipe, flushes remaining output, and invokes the callback."
  (when (string-match-p "\\(?:finished\\|exited\\)" event)
    ;; Clean up stderr pipe
    (when-let ((stderr (process-get process 'yagi-stderr-process)))
      (when (process-live-p stderr)
        (delete-process stderr)))
    ;; Flush any remaining buffered output
    (let ((pending (or (process-get process 'yagi-pending-output) "")))
      (when (not (string-match-p "^\\s-*$" pending))
        (condition-case nil
            (let ((response (json-read-from-string pending)))
              (let-alist response
                (cond
                 (.error
                  (process-put process 'yagi-error
                               (concat (process-get process 'yagi-error) .error)))
                 (.content
                  (process-put process 'yagi-response
                               (concat (process-get process 'yagi-response) .content))))))
          (error nil))))
    (let ((callback (process-get process 'yagi-callback))
          (response (or (process-get process 'yagi-response) ""))
          (err (or (process-get process 'yagi-error) ""))
          (streamed (process-get process 'yagi-stream)))
      (cond
       ((not (string-empty-p err))
        (when callback
          (funcall callback (list :error err))))
       ((string-match-p "finished" event)
        (when callback
          (funcall callback (list :content response :stream streamed))))
       (t
        (when callback
          (let ((msg (format "yagi process %s" (string-trim event))))
            (unless (string-empty-p err)
              (setq msg (concat msg ": " err)))
            (funcall callback (list :error msg)))))))))

;;; Response handlers

(defun yagi--handle-response (result)
  "Generic response handler.  Display RESULT content in response buffer.
When RESULT contains :stream t, content was already displayed incrementally
by the process filter, so skip the buffer rewrite."
  (let ((err (plist-get result :error))
        (content (plist-get result :content))
        (streamed (plist-get result :stream)))
    (cond
     (err (message "Yagi error: %s" err))
     (streamed (message "Yagi: Done."))
     (content (yagi--show-in-buffer content)))))

(defun yagi--handle-refactor-response (source-buffer source-region result)
  "Handle refactor RESULT.
SOURCE-BUFFER and SOURCE-REGION are saved for potential apply."
  (let ((err (plist-get result :error))
        (content (plist-get result :content)))
    (cond
     (err (message "Yagi error: %s" err))
     (content
      (let ((code (yagi--extract-code-from-response content)))
        (setq yagi--pending-code code
              yagi--source-buffer source-buffer
              yagi--source-region source-region)
        (yagi--show-in-buffer
         (concat "# Refactored Code\n\n"
                 "```\n" code "\n```\n\n"
                 "Press `a` to apply changes, `q` to dismiss.")))))))

(defun yagi--handle-fix-response (source-buffer source-region result)
  "Handle fix RESULT.  Prompt to apply changes.
SOURCE-BUFFER and SOURCE-REGION identify the code to replace."
  (let ((err (plist-get result :error))
        (content (plist-get result :content)))
    (cond
     (err (message "Yagi error: %s" err))
     (content
      (let ((code (yagi--extract-code-from-response content)))
        (if (y-or-n-p (format "Yagi: Apply fixed code?\n%s"
                              (truncate-string-to-width code 200)))
            (with-current-buffer source-buffer
              (let ((beg (car source-region))
                    (end (cdr source-region)))
                (goto-char beg)
                (delete-region beg end)
                (insert code))
              (message "Yagi: Code fixed!"))
          (yagi--show-in-buffer content)))))))

;;; Interactive commands

;;;###autoload
(defun yagi-chat (prompt beg end)
  "Chat with AI.
PROMPT is the user's question.  If region is active, use selected
code between BEG and END as context."
  (interactive
   (list (read-string "Yagi> ")
         (if (use-region-p) (region-beginning))
         (if (use-region-p) (region-end))))
  (when (string-empty-p prompt)
    (user-error "Empty prompt"))
  (let* ((selection (when (and beg end)
                      (buffer-substring-no-properties beg end)))
         (lang (yagi--mode-to-language))
         (filename (or (file-name-nondirectory (or buffer-file-name "")) ""))
         (user-content
          (if selection
              (concat "File: " filename
                      (unless (string-empty-p lang) (concat " (" lang ")"))
                      "\n\n```" lang "\n" selection "\n```\n\n" prompt)
            prompt))
         (messages (vector `((role . "user") (content . ,user-content)))))
    (yagi--send-request messages #'yagi--handle-response)))

;;;###autoload
(defun yagi-prompt (prompt)
  "Ask yagi a question without code context.
PROMPT is the question to ask."
  (interactive (list (read-string "Yagi> ")))
  (when (string-empty-p prompt)
    (user-error "Empty prompt"))
  (let ((messages (vector `((role . "user") (content . ,prompt)))))
    (yagi--send-request messages #'yagi--handle-response)))

;;;###autoload
(defun yagi-explain (beg end)
  "Explain the selected code between BEG and END."
  (interactive "r")
  (let* ((selection (buffer-substring-no-properties beg end))
         (lang (yagi--mode-to-language))
         (filename (or (file-name-nondirectory (or buffer-file-name "")) ""))
         (prompt (concat "Explain the following code.\n\n"
                         "File: " filename "\n"
                         (unless (string-empty-p lang)
                           (concat "Language: " lang "\n"))
                         "\n```" lang "\n" selection "\n```"))
         (messages (vector `((role . "user") (content . ,prompt)))))
    (yagi--send-request messages #'yagi--handle-response)))

;;;###autoload
(defun yagi-refactor (beg end)
  "Refactor the selected code between BEG and END."
  (interactive "r")
  (let* ((selection (buffer-substring-no-properties beg end))
         (lang (yagi--mode-to-language))
         (filename (or (file-name-nondirectory (or buffer-file-name "")) ""))
         (full-content (buffer-substring-no-properties (point-min) (point-max)))
         (line1 (line-number-at-pos beg))
         (line2 (line-number-at-pos end))
         (source-buf (current-buffer))
         (source-reg (cons (copy-marker beg) (copy-marker end)))
         (prompt (concat "Refactor and improve the following code.\n\n"
                         "File: " filename "\n"
                         (unless (string-empty-p lang)
                           (concat "Language: " lang "\n"))
                         "Selected lines: " (number-to-string line1) "-" (number-to-string line2) "\n\n"
                         "Full file for context:\n```" lang "\n" full-content "\n```\n\n"
                         "Selected code to refactor:\n```" lang "\n" selection "\n```\n\n"
                         "Return ONLY the refactored code for the selected portion, without markdown formatting or explanations."))
         (messages (vector `((role . "user") (content . ,prompt)))))
    (yagi--send-request messages
                        (lambda (result)
                          (yagi--handle-refactor-response source-buf source-reg result)))))

;;;###autoload
(defun yagi-comment (beg end)
  "Add comments to the selected code between BEG and END."
  (interactive "r")
  (let* ((selection (buffer-substring-no-properties beg end))
         (lang (yagi--mode-to-language))
         (filename (or (file-name-nondirectory (or buffer-file-name "")) ""))
         (prompt (concat "Add helpful comments to the following code.\n\n"
                         "File: " filename "\n"
                         (unless (string-empty-p lang)
                           (concat "Language: " lang "\n"))
                         "\n```" lang "\n" selection "\n```\n\n"
                         "Return the code with comments added. Use appropriate comment syntax for " lang "."))
         (messages (vector `((role . "user") (content . ,prompt)))))
    (yagi--send-request messages #'yagi--handle-response)))

;;;###autoload
(defun yagi-fix (beg end)
  "Fix bugs in the selected code between BEG and END."
  (interactive "r")
  (let* ((selection (buffer-substring-no-properties beg end))
         (lang (yagi--mode-to-language))
         (filename (or (file-name-nondirectory (or buffer-file-name "")) ""))
         (full-content (buffer-substring-no-properties (point-min) (point-max)))
         (line1 (line-number-at-pos beg))
         (line2 (line-number-at-pos end))
         (source-buf (current-buffer))
         (source-reg (cons (copy-marker beg) (copy-marker end)))
         (prompt (concat "Fix bugs or issues in the following code.\n\n"
                         "File: " filename "\n"
                         (unless (string-empty-p lang)
                           (concat "Language: " lang "\n"))
                         "Selected lines: " (number-to-string line1) "-" (number-to-string line2) "\n\n"
                         "Full file for context:\n```" lang "\n" full-content "\n```\n\n"
                         "Selected code to fix:\n```" lang "\n" selection "\n```\n\n"
                         "Return ONLY the fixed code for the selected portion, without markdown formatting or explanations."))
         (messages (vector `((role . "user") (content . ,prompt)))))
    (yagi--send-request messages
                        (lambda (result)
                          (yagi--handle-fix-response source-buf source-reg result)))))

;;;###autoload
(defun yagi-apply ()
  "Apply pending refactored code to the source buffer."
  (interactive)
  (unless yagi--pending-code
    (user-error "No pending code to apply"))
  (unless (buffer-live-p yagi--source-buffer)
    (user-error "Source buffer no longer exists"))
  (when (y-or-n-p "Apply refactored code?")
    (with-current-buffer yagi--source-buffer
      (let ((beg (car yagi--source-region))
            (end (cdr yagi--source-region)))
        (goto-char beg)
        (delete-region beg end)
        (insert yagi--pending-code)))
    (when yagi--source-region
      (set-marker (car yagi--source-region) nil)
      (set-marker (cdr yagi--source-region) nil))
    (setq yagi--pending-code nil
          yagi--source-buffer nil
          yagi--source-region nil)
    (message "Yagi: Code applied!")))

;;; Keymap and minor mode

(defvar yagi-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "c") #'yagi-chat)
    (define-key map (kbd "p") #'yagi-prompt)
    (define-key map (kbd "e") #'yagi-explain)
    (define-key map (kbd "r") #'yagi-refactor)
    (define-key map (kbd "m") #'yagi-comment)
    (define-key map (kbd "f") #'yagi-fix)
    map)
  "Keymap for yagi commands, used under the prefix key.")

;;;###autoload
(define-minor-mode yagi-mode
  "Minor mode for yagi AI assistant keybindings.

\\{yagi-mode-map}"
  :lighter " Yagi"
  :keymap (let ((map (make-sparse-keymap)))
            (define-key map (kbd "C-c Y") yagi-command-map)
            map)
  :global t)

(provide 'yagi)
;;; yagi.el ends here
