#+xcvb
(module
  (:author ("Francois-Rene Rideau" "Peter Keller")
   :maintainer "Francois-Rene Rideau"
   :depends-on ("static-traversal" "change-detection" "main" "profiling")))

(in-package :xcvb)

(defclass run-program-traversal (static-traversal timestamp-based-change-detection)
  ())

(defun simple-build (fullname &key force)
  "Run the actual build commands to produce the targets"
  (log-format 10 "Beginning simple-build with target: ~S~%" fullname)
  (multiple-value-bind (target-dependency) (handle-target fullname)
    (let* ((*print-pretty* nil); otherwise SBCL will slow us down a lot.
           (env (make-instance 'run-program-traversal)))
      (log-format 7 "object-directory: ~S" *object-directory*)
      ;; Pass 1: Traverse the graph of dependencies
      (log-format 8 "T=~A building dependency graph for target dependency: ~S"
		  (get-universal-time) target-dependency)
      (graph-for env target-dependency)
      ;; Pass 2: Execute the ordered computations contained in *computations*
      (log-format 8 "Attempting to serially execute *computations*")
      (run-computations-serially env :force force))))

(defun run-computations-serially (env &key force)
  (log-format 8 "All *computations* =~%~S" (reverse *computations*))
  (log-format 5 "Executing all computations!~%")
  (dolist (computation (reverse *computations*))
    (run-computation env computation :force force)))

(defun run-computation (env computation &key force)
  (log-format 8 "Running Computation:~%~S" computation)
  (when (and (not force) (already-computed-p env computation))
    ;; first, check the outputs are newew than the inputs, if so, bail.
    ;; same checking as with make
    (log-format 5 "No need to regenerate~{ ~A~}!~%"
                (mapcar/ #'grain-pathname-text env
                         (computation-outputs computation)))
    (return-from run-computation t))
  (let* ((outputs (computation-outputs computation))
         (output-pathnames (loop :for o :in outputs :when (file-grain-p o)
                             :collect (grain-pathname-text env o)))
         (command (computation-command computation))) ; in the xcvb command language
    ;; create the output directories
    (dolist (output-pn output-pathnames)
      (ensure-directories-exist output-pn))
    (dolist (external-command (external-commands-for-computation env command))
      (log-format
       5 "Running Computation's Shell Command:~% ~{~< \\~%   ~1,72:; ~A~>~}~%~%"
       (mapcar #'escape-token external-command))
      (run-program/echo-output external-command :prefix "command output: "))
    (mapcar/ 'update-change-information env outputs)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; Make-Makefile ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;; TODO: have only one build command. Have it multiplex the various build backends.

(defparameter +simple-build-option-spec+
  `(,@+build-option-spec+
    ,@+setup-option-spec+
    ,@+base-image-option-spec+
    ,@+source-registry-option-spec+
    ,@+object-directory-option-spec+
    ,@+lisp-implementation-option-spec+
    ,@+cfasl-option-spec+
    (("force" #\F) :type boolean :optional t :initial-value nil :documentation "force building everything")
    (("use-base-image" #\B) :type boolean :optional t :initial-value t :documentation "use a base image")
    (("master" #\m) :type boolean :optional t :initial-value t :documentation "enable XCVB-master")
    ,@+verbosity-option-spec+
    ,@+profiling-option-spec+))

(defun simple-build-command
    (&rest keys &key
     source-registry setup verbosity
     build lisp-implementation lisp-binary-path define-feature undefine-feature
     disable-cfasl master object-directory use-base-image profiling debugging
     force)
  (declare (ignore source-registry setup verbosity
                   lisp-implementation lisp-binary-path define-feature
		   undefine-feature disable-cfasl master object-directory
		   use-base-image debugging))
  (with-maybe-profiling (profiling)
    (apply 'handle-global-options keys)
    (simple-build build :force force)))
