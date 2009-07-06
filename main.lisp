;;; Shell command-line interface for XCVB

#+xcvb (module (:depends-on ("static-backends" "search-path" "computations" "extract-target-properties")))

(in-package :xcvb)

(defun reset-variables ()
  ;; TODO: have some macro define notable variables
  ;; so they will be reset here.
  (setf *grains* (make-hash-table :test 'equal)
        *computations* nil
        *target-system-features* nil
        *search-path-searched-p* nil
        *lisp-setup-dependencies* +xcvb-setup-dependencies+
        *pathname-grain-cache* (make-hash-table :test 'equal))
  (initialize-search-path)
  (values))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; Make-Makefile ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defparameter +make-makefile-option-spec+
 '((("build" #\b) :type string :optional nil :documentation "specify what system to build")
   (("setup" #\s) :type string :optional t :documentation "specify a Lisp setup file")
   (("xcvb-path" #\x) :type string :optional t :documentation "override your XCVB_PATH")
   (("output-path" #\o) :type string :optional t :documentation "specify output path (default: xcvb.mk)")
   (("object-directory" #\O) :type string :optional t :documentation "specify object directory (default: obj)")
   (("lisp-implementation" #\i) :type string :optional t :documentation "specify type of Lisp implementation (default: sbcl)")
   (("lisp-binary-path" #\p) :type string :optional t :documentation "specify path of Lisp executable")
   (("verbosity" #\v) :type integer :optional t :documentation "set verbosity (default: 5)")))

(defun make-makefile (arguments &key
                                xcvb-path setup verbosity output-path
                                build lisp-implementation lisp-binary-path
                                object-directory)
  (reset-variables)
  (when arguments
    (error "Invalid arguments to make-makefile"))
  (when xcvb-path
    (set-search-path! xcvb-path))
  (when setup
    (setf *lisp-setup-dependencies*
          (append *lisp-setup-dependencies* `((:lisp ,setup)))))
  (when verbosity
    (setf *xcvb-verbosity* verbosity))
  (when output-path
    (setf *default-pathname-defaults*
          (ensure-absolute-pathname (pathname-directory-pathname output-path))))
  (when object-directory
    (setf *object-directory* ;; strip last "/"
          (but-last-char (enough-namestring (ensure-pathname-is-directory object-directory)))))
  (when lisp-implementation
    (setf *lisp-implementation-type*
          (find-symbol (string-upcase lisp-implementation) (find-package :keyword))))
  (when lisp-binary-path
    (setf *lisp-executable-pathname* lisp-binary-path))
  (extract-target-properties)
  (read-target-properties)
  (search-search-path)
  (write-makefile (canonicalize-fullname build) :output-path output-path))


(defparameter +asdf-to-xcvb-option-spec+
  '((("system" #\b) :type string :optional nil :list t :documentation "Specify a system to convert (can be repeated)")
    (("setup"  #\s) :type string :optional t :documentation "Specify the path to a Lisp setup file.")
    (("system-path" #\p) :type string :optional t :list t :documentation "Register an ASDF system path (can be repeated)")
    (("preload" #\l) :type string :optional t :list t :documentation "Specify an ASDF system to preload (can be repeated)")))

(defun asdf-to-xcvb-command (arguments &key system setup system-path preload)
  (when arguments
    (error "Invalid arguments to asdf-to-xcvb: ~S~%" arguments))
  (setf asdf:*central-registry*
        (append (mapcar #'ensure-pathname-is-directory system-path) asdf:*central-registry*))
  (when setup (load setup))
  (asdf-to-xcvb
   :systems (mapcar #'coerce-asdf-system-name system)
   :systems-to-preload (mapcar #'coerce-asdf-system-name preload)))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; Command Spec ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; Spec for XCVB command-line commands.  Each item of the list takes the form
;; (aliases function short-help long-help) where aliases is a list of strings
;; that can invoke the command, function is the function to call when the
;; command is invoked, short-help is a short help string for the user, and
;; long-help is a longer help string for the user.
(defparameter +xcvb-commands+
  '((("help" "-?" "--help" "-h") program-help ()
     "Output some help message"
     "With no additional arguments, the 'help' command provides general help on
using XCVB.  Using 'xcvb help COMMAND' where COMMAND is the name of an XCVB
command gives specific help on that command.")
    (("make-makefile" "mkmk" "mm") make-makefile +make-makefile-option-spec+
     "Create some Makefile"
     "Create Makefile rules to build a project.")
    (("asdf-to-xcvb" "a2x") asdf-to-xcvb-command +asdf-to-xcvb-option-spec+
     "Convert ASDF system to XCVB"
     "Attempt an automated conversion of an ASDF system to XCVB.
Optionally load a setup Lisp file before anything else, so the user gets
a chance to load and/or configure ASDF itself and any extension thereof.")
    (("load") load-command ()
     "Load a Lisp file"
     "Load a Lisp file in the context of XCVB itself. For XCVB developers only.")
    (("eval") eval-command ()
     "Evaluate some Lisp form"
     "Evaluate some Lisp form in the context of XCVB itself. For XCVB developers only.")
    (("repl") repl-command ()
     "Start a REPL"
     "The 'repl' command takes no additional arguments.
Using 'xcvb repl' launches a Lisp REPL.
For XCVB developers only (notably for use with SLIME).")
    (("version" "-V" "--version") show-version ()
     "Show version"
     "The 'version' command ignores all arguments, and prints out the version number
for this version of XCVB.")))


;; Lookup the command spec for the given command name, or return nil if the
;; given command name is invalid.
(defun lookup-command (command-name)
  (flet ((member-equalp (x l) (member x l :test #'equalp)))
    (assoc command-name +xcvb-commands+ :test #'member-equalp)))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; Simple Commands ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; Command to print out more detailed help.
(defun program-help (args)
  (if (null args)
      ;; If user typed "xcvb help", give general help, summarizing commands.
      (format t "~&Usage: xcvb COMMAND ARGS~%  ~
       where COMMAND is one of the following:~%~%~
       ~:{    ~1{~16A~}~*~*~A~%~}~%~
       See 'xcvb help COMMAND' for more information on a specific command.~%"
              +xcvb-commands+)
      ;; Else if user typed "xcvb help COMMAND", give specific help on that
      ;; command.
      (let* ((command (car args))
             (command-spec (lookup-command command))
             (command-options (symbol-value (third command-spec))))
        (unless (null (cdr args))
          (errexit 2 "~&Too many arguments -- try 'xcvb help'.~%"))
        (cond
          (command-spec
            (format t "~&~1{Command: ~A~%Aliases:~{ ~A~^ ~}~%~%~3*~A~}~%"
                    (cons command command-spec))
            (when command-options
              (command-line-arguments:show-option-help command-options)))
          (t
           (errexit 2 "~&Invalid XCVB command ~S -- try 'xcvb help'.~%"
                    command))))))

;; Command to print out a version string.
(defun show-version (args)
  (declare (ignore args))
  (format t "~&XCVB version ~A~%" *xcvb-version*))

;; Command to load a file.
(defun load-command (args)
  (unless (list-of-length-p 1 args)
    (error "load requires exactly 1 argument, a file to load"))
    (load (car args)))

;; Command to eval a file.
(defun eval-command (args)
  (unless (list-of-length-p 1 args)
    (error "eval requires exactly 1 argument, a form to evaluate"))
    (eval (read-from-string (car args))))

;; Command to start a REPL.
(defun repl-command (args)
  (unless (null args)
    (error "repl doesn't take any argument"))
  #-(or sbcl) (error "REPL unimplemented")
  (throw :repl nil))

(defun repl ()
  #+sbcl (progn (sb-ext:enable-debugger) (sb-impl::toplevel-repl nil))
  #-(or sbcl) (error "REPL unimplemented"))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; Main ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun main ()
  (catch :repl
    (with-exit-on-error ()
      (quit (catch :exit
              (interpret-command-line
               (command-line-arguments:get-command-line-arguments))
              0))))
    (repl))

(defun interpret-command-line (args)
  (let* ((*package* (find-package :xcvb-user))
         (command (pop args))
         (command-spec (lookup-command command))
         (fun (second command-spec))
         (option-spec-var (third command-spec)))
    (cond
      (option-spec-var
       (multiple-value-bind (options arguments)
           (process-command-line-options (symbol-value option-spec-var) args)
         (apply fun arguments options)))
      (fun
       (funcall fun args))
      ((not command)
       (errexit 2 "~&XCVB requires a command -- try 'xcvb help'.~%"))
      (t
       (errexit 2 "~&Invalid XCVB command ~S -- try 'xcvb help'.~%" command)))))

(defun exit (&optional (code 0) &rest r)
  (declare (ignore r))
  (throw :exit code))

(defun errformat (fmt &rest args)
  (apply #'format *error-output* fmt args))

(defun errexit (code fmt &rest args)
  (apply #'errformat fmt args)
  (exit code))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
