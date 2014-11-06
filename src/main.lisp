(in-package #:pgloader)

(defun log-threshold (min-message &key quiet verbose debug)
  "Return the internal value to use given the script parameters."
  (cond ((and debug verbose) :data)
        (debug   :debug)
	(verbose :info)
	(quiet   :warning)
	(t       (or (find-symbol (string-upcase min-message) "KEYWORD")
		     :notice))))

(defparameter *opt-spec*
  `((("help" #\h) :type boolean :documentation "Show usage and exit.")

    (("version" #\V) :type boolean
     :documentation "Displays pgloader version and exit.")

    (("quiet"   #\q) :type boolean :documentation "Be quiet")
    (("verbose" #\v) :type boolean :documentation "Be verbose")
    (("debug"   #\d) :type boolean :documentation "Display debug level information.")

    ("client-min-messages" :type string :initial-value "warning"
			   :documentation "Filter logs seen at the console")

    ("log-min-messages" :type string :initial-value "notice"
			:documentation "Filter logs seen in the logfile")

    (("summary" #\S) :type string :documentation "Filename where to copy the summary")

    (("root-dir" #\D) :type string :initial-value ,*root-dir*
                      :documentation "Output root directory.")

    (("upgrade-config" #\U) :type boolean
     :documentation "Output the command(s) corresponding to .conf file for v2.x")

    (("list-encodings" #\E) :type boolean
     :documentation "List pgloader known encodings and exit.")

    (("logfile" #\L) :type string
     :documentation "Filename where to send the logs.")

    (("load-lisp-file" #\l) :type string :list t :optional t
     :documentation "Read user code from files")

    ("self-upgrade" :type string :optional t
     :documentation "Path to pgloader newer sources")))

(defun print-backtrace (condition debug stream)
  "Depending on DEBUG, print out the full backtrace or just a shorter
   message on STREAM for given CONDITION."
  (if debug
      (trivial-backtrace:print-backtrace condition :output stream :verbose t)
      (trivial-backtrace:print-condition condition stream)))

(defun mkdir-or-die (path debug &optional (stream *standard-output*))
  "Create a directory at given PATH and exit with an error message when
   that's not possible."
  (handler-case
      (let ((dir (uiop:ensure-directory-pathname path)))
        (when debug
          (format stream "mkdir -p ~s~%" dir))
        (uiop:parse-unix-namestring (ensure-directories-exist dir)))
    (condition (e)
      ;; any error here is a panic
      (if debug
	  (print-backtrace e debug stream)
	  (format stream "PANIC: ~a.~%" e))
      (uiop:quit))))

(defun log-file-name (logfile)
  " If the logfile has not been given by the user, default to using
    pgloader.log within *root-dir*."
  (cond ((null logfile)
	 (make-pathname :defaults *root-dir*
			:name "pgloader"
			:type "log"))

	((fad:pathname-relative-p logfile)
	 (merge-pathnames logfile *root-dir*))

	(t
	 logfile)))

(defun usage (argv &key quit)
  "Show usage then QUIT if asked to."
  (format t "~a [ option ... ] command-file ..." (first argv))
  (command-line-arguments:show-option-help *opt-spec*)
  (when quit (uiop:quit)))

(defvar *self-upgraded-already* nil
  "Keep track if we did reload our own source code already.")

(defun self-upgrade (namestring)
  "Load pgloader sources at PATH-TO-PGLOADER-SOURCES."
  (let ((pgloader-pathname (uiop:directory-exists-p
                            (uiop:parse-unix-namestring namestring))))
    (unless pgloader-pathname
      (format t "No such directory: ~s~%" namestring)
      (uiop:quit))

    ;; now the real thing
    (handler-case
        (handler-bind ((condition #'muffle-warning))
          (let ((asdf:*central-registry* (list* pgloader-pathname
                                                asdf:*central-registry*)))
            (format t "Self-upgrading from sources at ~s~%"
                    (uiop:native-namestring pgloader-pathname))
            (with-output-to-string (*standard-output*)
              (asdf:operate 'asdf:load-op :pgloader :verbose nil))))
      (condition (c)
        (format t "Fatal: ~a~%" c)))))

(defun parse-summary-filename (summary debug)
  "Return the pathname where to write the summary output."
  (when summary
    (let* ((summary-pathname (uiop:parse-unix-namestring summary))
           (summary-pathname (if (uiop:absolute-pathname-p summary-pathname)
                                 summary-pathname
                                 (uiop:merge-pathnames* summary-pathname *root-dir*)))
           (summary-dir      (directory-namestring summary-pathname)))
      (mkdir-or-die summary-dir debug)
      summary-pathname)))

(defvar *--load-list-file-extension-whitelist* '("lisp" "lsp" "cl" "asd")
  "White list of file extensions allowed with the --load option.")

(defun load-extra-transformation-functions (filename)
  "Load an extra filename to tweak pgloader's behavior."
  (let ((pathname (uiop:parse-native-namestring filename)))
    (unless (member (pathname-type pathname)
                    *--load-list-file-extension-whitelist*
                    :test #'string=)
      (error "Unknown lisp file extension: ~s" (pathname-type pathname)))

    (load (compile-file pathname :verbose nil :print nil))))

(defun main (argv)
  "Entry point when building an executable image with buildapp"
  (let ((args (rest argv)))
    (multiple-value-bind (options arguments)
	(handler-case
            (command-line-arguments:process-command-line-options *opt-spec* args)
          (condition (e)
            ;; print out the usage, whatever happens here
            (declare (ignore e))
            (usage argv :quit t)))

      (destructuring-bind (&key help version quiet verbose debug logfile
				list-encodings upgrade-config
                                ((:load-lisp-file load))
				client-min-messages log-min-messages summary
				root-dir self-upgrade)
	  options

        ;; First thing: Self Upgrade?
        (when self-upgrade
          (unless *self-upgraded-already*
            (self-upgrade self-upgrade)
            (let ((*self-upgraded-already* t))
              (main argv))))

        ;; parse the log thresholds
        (setf *log-min-messages*
              (log-threshold log-min-messages
                             :quiet quiet :verbose verbose :debug debug)

              *client-min-messages*
              (log-threshold client-min-messages
                             :quiet quiet :verbose verbose :debug debug)

              verbose (member *client-min-messages* '(:info :debug :data))
              debug   (member *client-min-messages* '(:debug :data))
              quiet   (and (not verbose) (not debug)))

	;; First care about the root directory where pgloader is supposed to
	;; output its data logs and reject files
        (let ((root-dir-truename (or (probe-file root-dir)
                                     (mkdir-or-die root-dir debug))))
          (setf *root-dir* (uiop:ensure-directory-pathname root-dir-truename)))

	;; Set parameters that come from the environement
	(init-params-from-environment)

	;; Then process options
	(when debug
	  #+sbcl
          (format t "sb-impl::*default-external-format* ~s~%"
		  sb-impl::*default-external-format*)
	  (format t "tmpdir: ~s~%" *default-tmpdir*))

	(when version
	  (format t "pgloader version ~s~%" *version-string*)
          (format t "compiled with ~a ~a~%"
                  (lisp-implementation-type)
                  (lisp-implementation-version)))

	(when help
          (usage argv))

	(when (or help version) (uiop:quit))

	(when list-encodings
	  (show-encodings)
	  (uiop:quit))

	(when upgrade-config
	  (loop for filename in arguments
	     do
               (handler-case
                   (with-monitor ()
                     (pgloader.ini:convert-ini-into-commands filename))
                 (condition (c)
                   (when debug (invoke-debugger c))
                   (uiop:quit 1)))
	       (format t "~%~%"))
	  (uiop:quit))

	(when load
          (loop for filename in load do
               (handler-case
                   (load-extra-transformation-functions filename)
                 (condition (e)
                   (format *standard-output*
                           "Failed to load lisp source file ~s~%"
                           filename)
                   (format *standard-output* "~a~%" e)
                   (uiop:quit 3)))))

	;; Now process the arguments
	(when arguments
	  ;; Start the logs system
	  (let ((*log-filename* (log-file-name logfile)))

            (with-monitor ()
              ;; tell the user where to look for interesting things
              (log-message :log "Main logs in '~a'" (probe-file *log-filename*))
              (log-message :log "Data errors in '~a'~%" *root-dir*)

              ;; process the files
              (loop for filename in arguments
                 do
                 ;; The handler-case is to catch unhandled exceptions at the
                 ;; top level and continue with the next file in the list.
                 ;;
                 ;; The handler-bind is to be able to offer a meaningful
                 ;; backtrace to the user in case of unexpected conditions
                 ;; being signaled.
                   (handler-case
                       (handler-bind
                           ((condition
                             #'(lambda (condition)
                                 (log-message :fatal "We have a situation here.")
                                 (print-backtrace condition debug *standard-output*))))
                         (let ((truename (probe-file filename))
                               (summary-pathname
                                (parse-summary-filename summary debug)))
                           (if truename
                               (run-commands truename
                                             :summary summary-pathname
                                             :start-logger nil)
                               (log-message :error "Can not find file: ~s" filename)))
                         (format t "~&"))

                     (condition (c)
                       (when debug (invoke-debugger c))
                       (uiop:quit 1)))))))

	(uiop:quit)))))
