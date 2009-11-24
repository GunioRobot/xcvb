#+xcvb
(module
 (:depends-on
  ("macros" "specials" "static-traversal" "profiling"
   (:when (:featurep :sbcl)
     (:require :sb-grovel)
     (:require :sb-posix)))))

#|
* TODO: split and rename into active-traversal and standalone-backend

* TODO: compute world hash incrementally in an O(1) way instead of O(n)

|#

(in-package :xcvb)


(defun mkfifo (pathname mode)
  #+sbcl (sb-posix:mkfifo pathname mode)
  #+clozure (ccl::with-filename-cstrs ((p pathname))(#.(read-from-string "#_mkfifo") p mode))
  #+clisp (LINUX:mkfifo pathname mode) ;;(error "Problem with (LINUX:mkfifo ~S ~S)" pathname mode)
  #-(or sbcl clozure clisp) (error "mkfifo not implemented for your Lisp"))

(defvar *workers* (make-hash-table :test 'equal)
  "maps intentional state of the world identifiers to descriptors of worker processes
waiting at this state of the world.")

(defclass worker ()
  ())
(defgeneric worker-send (worker form)
  (:documentation "send a form to be executed on the worker"))
(defmethod worker-send (worker (x cons))
  (worker-send worker (readable-string x)))

(defclass active-world (world-grain buildable-grain)
  ((futures
    :initform nil
    :accessor world-futures
    :documentation "a list of computations in the future of this world")
   (handler
    :initform nil
    :accessor world-handler
    :documentation "a handler that will accept commands to run actions on this world")))

(defvar *root-worlds* nil "root of active worlds")

(defun make-world-summary (setup commands-r)
  ;;(cons (canonicalize-image-setup setup) commands-r)
  (make-world-name setup commands-r))
(defun world-summary (world)
  (make-world-summary (image-setup world) (build-commands-r world)))
(defun world-summary-hash (world-summary)
  (sxhash world-summary)) ; use tthsum?
(defun compute-world-hash (world)
  (world-summary-hash (world-summary world))) ; use tthsum?
(defun world-equal (w1 w2)
  (equal (world-summary w1) (world-summary w2)))
(defun intern-world-summary (setup commands-r key-thunk fun)
  (let ((fullname (make-world-name setup commands-r)))
    (call-with-grain-registration
     fullname
     (lambda ()
       (let* ((summary (make-world-summary setup commands-r))
              (hash (world-summary-hash summary)))
         #|(loop
           :for w :in (gethash hash *worlds*)
           :when (equal summary (world-summary w))
           :do (error "new world already hashed??? ~S" w))|#
         (let ((world (apply #'make-instance 'active-world
                             :fullname fullname
                             :hash hash
                             (funcall key-thunk))))
           #|(push world (gethash hash *worlds* '()))|#
           (funcall fun world)
           world))))))

(defclass farmer-traversal (static-traversal)
  ())

(defun simplified-xcvb-driver-command (computation-command)
  (cond
    ((and (list-of-length-p 2 computation-command)
          (eq :progn (first computation-command)))
     (simplified-xcvb-driver-command (second computation-command)))
    ((and (consp computation-command)
          (eq :xcvb-driver-command (first computation-command)))
     (values (second computation-command)
	     (cons :xcvb-driver-command
		   (simplify-xcvb-driver-commands (cddr computation-command)))))
    ((and (consp computation-command) (<= 2 (length computation-command) 3)
	  (eq (car computation-command) :compile-file-directly))
     (values () computation-command)) ;;; TODO: what need we do in this magic case?
    (t (error "Unrecognized computation command ~S" computation-command))))

(defun simplify-xcvb-driver-commands (commands)
  (while-collecting (c) (emit-simplified-commands #'c commands)))

(defvar *simple-xcvb-driver-commands*
  '(:load-file :require :load-asdf :register-asdf-directory :debugging))

(defun emit-simplified-commands (collector commands)
  (flet ((collect (x) (funcall collector x)))
    (dolist (c commands)
      (let ((l (length c))
            (h (first c)))
        (cond
          ((and (= 2 l) (member h *simple-xcvb-driver-commands*))
           (collect c))
          ((and (<= 2 l) (eq h :compile-lisp))
           (emit-simplified-commands collector (cddr c))
           (collect `(:compile-lisp ,(second c))))
          ((and (<= 2 l) (eq h :create-image))
           ;; TODO: distinguish the case when the target lisp is linking rather than dumping,
           ;; e.g. ECL. -- or in the future, any Lisp when linking C code.
           (emit-simplified-commands collector (cddr c))
           (collect `(:create-image ,(second c))))
          (t
           (error "Unrecognized xcvb driver command ~S" c)))))))

(defun setup-dependencies (env setup)
  (destructuring-bind (&key image load) setup
    (mapcar/
     #'graph-for env
     (append
      ;; TODO: include the lisp implementation itself, binary and image, when image is the default.
      ;; when there are no executable cores, always include the loader, too.
      (when image (list image))
      (when load load)))))

(defmethod make-computation ((env farmer-traversal)
                             &key inputs outputs command &allow-other-keys)
  (declare (ignore inputs))
  (multiple-value-bind (setup commands)
      (simplified-xcvb-driver-command command)
    (loop
      :for command = nil :then (if commands (pop commands) (return (grain-computation world)))
      :for commands-r = nil :then (cons command commands-r)
      :for grain-name = (unwrap-load-file-command command)
      :for grain = (when grain-name (registered-grain grain-name))
      :for previous = nil :then world
      :for world = (intern-world-summary
                    setup commands-r
                    (lambda ()
                      (unless previous '(:computation nil)))
                    (lambda (world)
                      (if previous
                        (push
                         (make-computation
                          ()
                          :inputs (append (list previous)
                                          (setup-dependencies env (image-setup world))
                                          (when grain (list grain)))
                          :outputs (cons world (unless commands outputs))
                          :command `(:active-command ,(fullname previous) ,command))
                         (world-futures previous))
                        (push world *root-worlds*))))
      :do (DBG :mc command commands-r grain-name grain previous world))
      ))

#|
((world
    :accessor current-world
    :documentation "world object representing the current state of the computation")))
(defmethod included-dependencies ((traversal farmer-traversal))
  (included-dependencies (current-world traversal)))
(defmethod dependency-already-included-p ((env farmer-traversal) grain)
  (or (gethash grain (included-dependencies env))
      (call-next-method)))
|#

(defmethod object-namestring ((env farmer-traversal) name &optional merge)
  ;; TODO: replace that by something that will DTRT, whatever THAT is.
  ;; probably we need to refactor or gf away the parts that currently depend on it,
  ;; notably fasl-grains-for-name's :pathname thingie.
  (let* ((pathname (portable-pathname-from-string name))
         (merged (if merge (merge-pathnames merge pathname) pathname))
         (namestring (strcat *object-directory* (portable-namestring merged))))
    (ensure-makefile-will-make-pathname env namestring)
    namestring))

(defun map-dag (dag fun)
  (NIY)
  (funcall fun dag))

(defun compute-computation-generation (dag)
  (let ((generation (make-hash-table :test 'equal)))
    (labels ((f (x)
               (or (gethash x generation)
                   (setf (gethash x generation)
                         (let ((parents (NIY 'node-parents x)))
                           (if parents
                               (1+ (loop :for p :in parents :maximize (f p)))
                               0))))))
      (NIY 'map-dag dag #'f))
    generation))

(defclass latency-parameters ()
  ((total-lisp-compile-duration
    :initform 0)
   (total-lisp-compile-size
    :initform 0)
   (total-fasl-load-duration
    :initform 0)
   (total-fasl-load-size
    :initform 0)
   (total-lisp-load-duration
    :initform 0)
   (total-lisp-load-size
    :initform 0)
   (total-fork-size
    :initform 0)
   (total-fork-duration
    :initform 0)))

(defun compute-latency-model (computations &key
                              (parameters (make-instance 'latency-parameters))
                              (current-measurements (make-hash-table))
                              (previous-parameters (make-instance 'latency-parameters))
                              (previous-measurements (make-hash-table)))
  (NIY computations parameters current-measurements previous-parameters previous-measurements)
  '(let ((latency 0))
    (NIY 'map-computations
     (lambda (c)
       (setf latency (+ (max (NIY 'latency children)))))
     computations)
    latency))

;; TODO: parameterize the farming, so that
;; 1- a first version computes the best possible latency assuming infinite cpu
;; 2- a second version computes latency assuming finite cpu (specified or detected)
;; 3- a third version actually goes on and does it, using strategy based on above estimates

(defun farm-out-world-tree ()
  ;; TODO: actually walk the world tree
  ;; 1- minimize total latency, maximize parallelism
  ;; 2- maximize ... minimize memory usage
  ;; 3- estimate cost by duration of previous successful runs (or last one)
  ;;   interpolated with known (+ K (size file)),
  ;;   using average from known files if new file, and 1 if all unknown.
  ;; 4- allow for a pure simulation, just adding up estimates.
  (let* ((computation-queue (NIY 'make-priority-queue)) ;; queue of ready computations
         (job-set (make-hash-table :test 'equal))) ;; set of pending jobs
    computation-queue
    job-set
    (NIY '(for-each-computation (computation)
         (backlink-computation-to-input-grains computation)))
    (NIY 'for-each-grain (lambda (grain)
         (when (null (grain-computation grain))
           (NIY 'compute-grain-hash)
           (NIY 'mark-grain-as-ready-in-dependencies))))
    (labels
        ((event-step ()
           (or
            (maybe-handle-finished-jobs)
            (maybe-issue-computation)
            (wait-for-event-with-timeout)))
         (maybe-handle-finished-jobs ()
           (NIY 'when-bind
                '(subprocess (NIY 'wait-for-any-terminated-subprocess :nohang t))
                (NIY 'finalize-subprocess-outputs 'subprocess)))
         (maybe-issue-computation ()
           (when (and (NIY 'some-computations-ready-p)
                      (NIY 'cpu-resources-available-p))
             (issue-one-computation)))
         (wait-for-event-with-timeout ()
           (NIY 'with-EINTR-recovery ()
                (NIY 'set-timer-to-deadline)
                (NIY 'wait-for-any-terminated-subprocess)))
         (issue-one-computation ()
           (NIY 'when-bind '(computation (NIY 'pick-one-computation-amongst-the-ready-ones))
                (NIY 'issue-computation 'computation))))
      (loop
        :until (and (NIY 'empty-p job-set) (NIY 'empty-p computation-queue))
        :do (event-step)))))


(defun standalone-build (fullname)
  #+DEBUG
  (trace graph-for build-command-for issue-dependency
         graph-for-fasls graph-for-image-grain make-computation issue-image-named
         simplified-xcvb-driver-command make-world-name
         call-with-grain-registration register-computed-grain
         )
  (multiple-value-bind (fun build) (handle-target fullname)
    (declare (ignore build))
    ;; TODO: use build for default pathname to object directory?
    (let* ((*use-master* nil)
           (*root-worlds* nil)
           (traversal (make-instance 'farmer-traversal)))
      (funcall fun traversal)
      (farm-out-world-tree))))

(defparameter +standalone-build-option-spec+
 '((("build" #\b) :type string :optional nil :documentation "specify what system to build")
   (("setup" #\s) :type string :optional t :documentation "specify a Lisp setup file")
   (("xcvb-path" #\x) :type string :optional t :documentation "override your XCVB_PATH")
   (("output-path" #\o) :type string :initial-value "xcvb.mk" :documentation "specify output path")
   (("object-directory" #\O) :type string :initial-value "obj" :documentation "specify object directory")
   (("lisp-implementation" #\i) :type string :initial-value "sbcl" :documentation "specify type of Lisp implementation")
   (("lisp-binary-path" #\p) :type string :optional t :documentation "specify path of Lisp executable")
   (("disable-cfasl" #\C) :type boolean :optional t :documentation "disable the CFASL feature")
   (("verbosity" #\v) :type integer :initial-value 5 :documentation "set verbosity")
   (("base-image" #\B) :type boolean :optional t :initial-value t :documentation "use a base image")
   (("master" #\m) :type boolean :optional t :initial-value t :documentation "enable XCVB-master")
   (("profiling" #\P) :type boolean :optional t :documentation "profiling")
   ))

(defun standalone-build-command
    (&rest keys &key
     xcvb-path setup verbosity output-path
     build lisp-implementation lisp-binary-path
     disable-cfasl master object-directory base-image profiling)
  (declare (ignore xcvb-path setup verbosity output-path
                   lisp-implementation lisp-binary-path
                   disable-cfasl master object-directory base-image))
  (with-maybe-profiling (profiling)
    (apply 'handle-global-options keys)
    (standalone-build (canonicalize-fullname build))))
