;;; XCVB driver to be compiled in buildee images (largely copy-pasted from cl-launch)

#+xcvb
(module
 (:author ("Francois-Rene Rideau")
  :maintainer "Francois-Rene Rideau"
  :licence "MIT" ;; MIT-style license. See LICENSE
  :description "XCVB Driver"
  :long-description "Driver code to be loaded in all buildee images for XCVB."))

(in-package :cl)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (proclaim '(optimize (speed 2) (safety 3) (compilation-speed 0) (debug 2)
           #+sbcl (sb-ext:inhibit-warnings 3)
           #+sbcl (sb-c::merge-tail-calls 3) ;-- this plus debug 1 (or sb-c::insert-debug-catch 0 ???) should ensure all tail calls are optimized, says jsnell
	   #+cmu (ext:inhibit-warnings 3)))
  #+sbcl (proclaim '(sb-ext:muffle-conditions sb-ext:compiler-note))
  #+gcl ;;; If using GCL, do some safety checks
  (when (or #-ansi-cl t)
    (format *error-output*
     "XCVB only supports GCL in ANSI mode. Aborting.~%")
    (lisp:quit))
  #+gcl
  (when (or (< system::*gcl-major-version* 2)
            (and (= system::*gcl-major-version* 2)
                 (< system::*gcl-minor-version* 7)))
    (pushnew :gcl-pre2.7 *features*))
  (setf *print-readably* nil ; allegro 5.0 notably will bork without this
        *load-verbose* nil *compile-verbose* nil *compile-print* nil)
  #+cmu (setf ext:*gc-verbose* nil)
  #+clisp (setf custom:*source-file-types* nil custom:*compiled-file-types* nil)
  #+gcl (setf compiler::*compiler-default-type* (pathname "")
              compiler::*lsp-ext* "")
  #+ecl (require 'cmp)
  ;;;; Ensure package hygiene
  (unless (find-package :xcvb-driver)
    (if (find-package :common-lisp)
       (defpackage :xcvb-driver (:use :common-lisp))
       (make-package :xcvb-driver :use '(:lisp)))))

(in-package :xcvb-driver)

;; Variables that define the current system
(defvar *restart* nil)

(defun finish-outputs ()
  (finish-output *error-output*)
  (finish-output *standard-output*))

(defun quit (&optional (code 0) (finish-output t))
  "Quits from the Lisp world, with the given exit status if provided.
This is designed to abstract away the implementation specific quit forms."
  (when finish-output (finish-outputs))
  #+cmu (unix:unix-exit code)
  #+clisp (ext:quit code)
  #+sbcl (sb-unix:unix-exit code)
  #+clozure (ccl:quit code)
  #+gcl (lisp:quit code)
  #+allegro (excl:exit code :quiet t)
  #+ecl (si:quit code)
  #+lispworks (lispworks:quit :status code :confirm nil :return nil :ignore-errors-p t)
  #-(or cmu clisp sbcl clozure gcl allegro ecl lispworks)
  (error "xcvb driver: Quitting not implemented"))

(defun print-backtrace (out)
  nil
  #+sbcl (sb-debug:backtrace most-positive-fixnum out))

(defvar *stderr* *error-output*)

(defun bork (condition)
  (format *stderr* "~&~A~%" condition)
  (print-backtrace *stderr*)
  (format *stderr* "~&~A~%" condition)
  (quit 99))

(defun call-with-exit-on-error (thunk)
  (handler-bind ((error #'bork))
    (funcall thunk)))

(defmacro with-exit-on-error (() &body body)
  `(call-with-exit-on-error (lambda () ,@body)))

(defmacro with-controlled-compiler-conditions (() &body body)
  `(call-with-controlled-compiler-conditions (lambda () ,@body)))

(defvar *uninteresting-conditions*
  (append
   #+sbcl
   '("&OPTIONAL and &KEY found in the same lambda list: ~S"
     sb-kernel:uninteresting-redefinition
     sb-kernel:undefined-alien-style-warning
     sb-ext:implicit-generic-function-warning
     sb-kernel:lexical-environment-too-complex)
   )
  "Conditions that may be skipped. type symbols, predicates or strings")

(defvar *deferred-warnings* ()
  "Warnings the handling of which is deferred until the end of the compilation unit")

(defun uninteresting-condition-p (condition)
  ;; TODO: do something interesting, extensible and semi-portable here.
  (loop :for x :in *uninteresting-conditions* :thereis
        (etypecase x
          (symbol (typep condition x))
          (function (funcall x condition))
          (string (and (typep condition '(and simple-condition style-warning))
                       (equal (simple-condition-format-control condition) x))))))

(defun hush-undefined-warnings ()
  #+sbcl (setf sb-c::*undefined-warnings* nil)
  #+clozure (setf *compiler-warnings* nil)
  nil)

(defun call-with-controlled-compiler-conditions (thunk)
  (hush-undefined-warnings)
  (handler-bind
      (#+sbcl (sb-c::simple-compiler-note #'muffle-warning)
       #+clozure (ccl::compiler-warning #'(lambda (condition) (push condition *deferred-warnings*)))
       (style-warning
        #'(lambda (condition)
            ;; TODO: do something magic for undefined-function,
            ;; save all of aside, and reconcile in the end of the virtual compilation-unit.
            (when (uninteresting-condition-p condition)
              (muffle-warning condition)))))
    (with-compilation-unit ()
      (funcall thunk)
      #+sbcl
      (progn
        (dolist (w sb-c::*undefined-warnings*)
          (push `(:undefined
                  ,(princ-to-string (sb-c::undefined-warning-kind w))
                  ,(princ-to-string (sb-c::undefined-warning-name w)))
                *deferred-warnings*))
        (setf sb-c::*undefined-warnings* nil)))))

(defun do-resume ()
  (when *restart* (funcall *restart*))
  (quit))

(defun resume ()
  (do-resume))

#-ecl
(defun dump-image (filename &key standalone package)
  (declare (ignorable filename standalone))
  (setf *package* (find-package (or package :cl-user)))
  (defparameter *previous-features* *features*)
  #+clisp
  (apply #'ext:saveinitmem filename
   :quiet t
   :start-package *package*
   :keep-global-handlers nil
   :executable (if standalone 0 t) ;--- requires clisp 2.48 or later, still catches --clisp-x
   (when standalone
     (list
      :norc t
      :script nil
      :init-function #'resume
      )))
  #+sbcl
  (progn
    ;;(sb-pcl::precompile-random-code-segments) ;--- it is ugly slow at compile-time (!) when the initial core is a big CLOS program. If you want it, do it yourself.
   (setf sb-ext::*gc-run-time* 0)
   (apply 'sb-ext:save-lisp-and-die filename
    :executable t ;--- always include the runtime that goes with the core
    (when standalone (list :toplevel #'resume :save-runtime-options t)))) ;--- only save runtime-options for standalone executables
  #+cmu
  (progn
   (ext:gc :full t)
   (setf ext:*batch-mode* nil)
   (setf ext::*gc-run-time* 0)
   (extensions:save-lisp filename))
  #+clozure
  (ccl:save-application filename :prepend-kernel t)
  #+allegro
  (progn
   (sys:resize-areas :global-gc t :pack-heap t :sift-old-areas t :tenure t) ; :new 5000000
   (excl:dumplisp :name filename :suppress-allegro-cl-banner t))
  #+lispworks
  (if standalone
    (lispworks:deliver 'resume filename 0 :interface nil)
    (hcl:save-image filename :environment nil))
  #+gcl
  (progn
   (si::set-hole-size 500) (si::gbc nil) (si::sgc-on t)
   (si::save-system filename))
  #-(or clisp sbcl cmu clozure allegro gcl lispworks)
  (%abort 11 "XCVB-Driver doesn't supports image dumping with this Lisp implementation.~%"))

(defun do-find-symbol (name package-name)
  (let ((package (find-package (string package-name))))
    (unless package
      (error "Trying to use package ~A, but it is not loaded yet!" package-name))
    (let ((symbol (find-symbol (string name) package)))
      (unless symbol
        (error "Trying to use symbol ~A in package ~A, but it does not exist!" name package-name))
      symbol)))

(defun function-for-command (designator)
  (fdefinition (do-find-symbol designator :xcvb-driver)))

(defun run-command (command)
  (apply (function-for-command (car command))
         (cdr command)))

(defun do-run (commands)
  (with-controlled-compiler-conditions ()
    (run-commands commands)))

(defun run-commands (commands)
  (map () #'run-command commands))

(defmacro run (&rest commands)
  `(with-exit-on-error ()
    (do-run ',commands);;)
    (quit 0)))

#-ecl
(defun do-create-image (image dependencies &rest flags)
  (run-commands dependencies)
  (apply #'dump-image image flags))

#+ecl ;; wholly untested and probably buggy.
(defun do-create-image (image dependencies &key standalone)
  (let ((epilogue-code
          `(progn
            ,(if standalone '(resume) '(si::top-level)))))
    (c::builder :program (parse-namestring image)
		:lisp-files (mapcar #'second dependencies)
		:epilogue-code epilogue-code)))

(defun load-file (x)
  (load x))

(defun call (package symbol &rest args)
  (apply (do-find-symbol symbol package) args))

(defun eval-string (string)
  (eval (read-from-string string)))

(defun asdf-symbol (x)
  (do-find-symbol x :asdf))
(defun asdf-call (x &rest args)
  (apply 'call :asdf x args))

(defun load-asdf (x)
  (asdf-call :oos (asdf-symbol :load-op) x))

(defun compile-lisp (source fasl &key cfasl)
  (let ((*default-pathname-defaults* (truename *default-pathname-defaults*)))
    (multiple-value-bind (output-truename warnings-p failure-p)
        (apply #'compile-file source
               :output-file (merge-pathnames fasl)
               ;; #+(or ecl gcl) :system-p #+(or ecl gcl) t
               (when cfasl
                 `(:emit-cfasl ,cfasl)))
      (declare (ignore output-truename))
      (when (or warnings-p failure-p)
        (error "Compilation Failed for ~A" source))))
  (values))

(defun create-image (spec &rest dependencies)
  (destructuring-bind (image &key standalone package) spec
    (do-create-image image dependencies
                     :standalone standalone :package package)))

(defun asdf-system-up-to-date-p (operation-class system &rest args)
  "Takes a name of an asdf system (or the system itself) and a asdf operation
and returns a boolean indicating whether or not anything needs to be done
in order to perform the given operation on the given system.
This returns whether or not the operation has already been performed,
and none of the source files in the system have changed since then"
  (progv
      (list (asdf-symbol :*verbose-out*))
      (list (if (getf args :verbose t) *trace-output*
            (make-broadcast-stream)))
    (let* ((op (apply #'make-instance operation-class
		    :original-initargs args args))
           (system (if (typep system (asdf-symbol :component))
                       system
                       (asdf-call :find-system system)))
           (steps (asdf-call :traverse op system)))
      ;;(format T "~%that system is ~:[out-of-date~;up-to-date~]" (null steps))
      (null steps))))

(defun asdf-system-loaded-up-to-date-p (system)
  (asdf-system-up-to-date-p (asdf-symbol :load-op) system))

(defun asdf-systems-up-to-date-p (systems)
  "Takes a list of names of asdf systems, and
exits lisp with a status code indicating
whether or not all of those systems were up-to-date or not."
  (every #'asdf-system-loaded-up-to-date-p systems))

(defun shell-boolean (x)
  (quit 
   (if x 0 1)))

(defun asdf-systems-up-to-date (&rest systems)
  "Are all the loaded systems up to date?"
  (with-exit-on-error ()
    (shell-boolean (asdf-systems-up-to-date-p systems))))

(export '(finish-outputs quit resume restart run with-exit-on-error))

;;;(format t "~&XCVB driver loaded~%")
