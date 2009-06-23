#+xcvb (module (:depends-on ("names" "specials" "computations")))

(in-package :xcvb)

;;; TODO: We probably need a better interface, so that
;;; the following aspects be handled in a generic way
;;; * the fact that we don't want to load the same dependency twice
;;; * the fact that we may want to "upgrade" some cfasl's to fasl's
;;;   -- or not, because that gets tricky since we want to preserve
;;;   the order of loads, and trickier still if for whatever reason
;;;   the dependencies of the fasl are not an upgrade from the
;;;   dependencies of the cfasl
;;;   -- that condition may be tested and an error issued otherwise.
(defgeneric dependency-already-included-p (env grain))
(defgeneric issue-dependency (env grain))
(defgeneric issue-load-command (env command))
(defgeneric traversed-dependencies (env))
(defgeneric traversed-load-commands (env))
(defgeneric load-command-issued-p (env command))
(defgeneric graph-for (env spec))
(defgeneric graph-for-atom (env atom))
(defgeneric graph-for-build-grain (env grain))
(defgeneric graph-for-fasls (env fullname))

;;; Recognizer for current trivial dependency language

(defvar *asdf-systems-warned* ()
  ;; This is a bit of a kluge, but oh well.
  "the names of ASDF systems for which we have already issued a warning that
a reference to the system was superseded by a BUILD file.")


(defun lisp-grain-from (name grain)
  (let ((grain (resolve-module-name name grain)))
    (unless (lisp-grain-p grain)
      (error "Couldn't resolve ~S to a valid module from grain ~S"
             name (fullname grain)))
    grain))

(defun lisp-fullname-from (name grain)
  (fullname (lisp-grain-from name grain)))

(defun unrecognized-dependency (dep)
  (error "unrecognized dependency ~S" dep))

(defun normalize-dependency (dep grain)
  (normalize-dependency-dispatcher grain dep))

(defun normalize-dependencies (deps grain)
  (mapcar (lambda (dep) (normalize-dependency dep grain)) deps))

(define-simple-dispatcher normalize-dependency #'normalize-dependency-atom)

(defun normalize-dependency-atom (grain name)
  (let* ((g (lisp-grain-from name grain))
         (n (fullname g)))
    (if (build-grain-p g)
        `(:build ,n)
        `(:fasl ,n))))

(defun normalize-dependency-lisp* (type grain name)
  `(,type ,(lisp-fullname-from name grain)))
(define-normalize-dependency :lisp (grain name)
  (normalize-dependency-lisp* :lisp grain name))
(define-normalize-dependency :fasl (grain name)
  (normalize-dependency-lisp* :fasl grain name))
(define-normalize-dependency :cfasl (grain name)
  (normalize-dependency-lisp* :cfasl grain name))

(defun normalize-dependency-build* (type grain name)
  (let ((g (lisp-grain-from name grain)))
    (check-type g build-grain)
    `(,type ,(fullname g))))

(define-normalize-dependency :build (grain name)
  (normalize-dependency-build* :build grain name))
(define-normalize-dependency :compile-build (grain name)
  (normalize-dependency-build* :compile-build grain name))

(define-normalize-dependency :compile (grain name)
  (let ((g (lisp-grain-from name grain)))
    (check-type g lisp-grain)
    (let ((n (fullname g)))
      (if (build-grain-p g)
        `(:compile-build ,n)
        `(,(compile-time-fasl-type) ,n)))))

(define-normalize-dependency :asdf (grain name)
  (declare (ignore grain))
  (let* ((n (coerce-asdf-system-name name))
         (superseding (registered-grain `(:supersedes-asdf ,n))))
    (etypecase superseding
      (null
       `(:asdf ,n))
      (build-grain
       (let ((nn (fullname superseding)))
         (unless (member nn *asdf-systems-warned* :test 'equal)
           (push nn *asdf-systems-warned*)
           (log-format 5 "~&Declared dependency on ASDF system :~A~%     was superseded by BUILD ~S~%" n nn))
         `(:build ,nn)))
      (build-registry-conflict
       (error "Trying to use ASDF system :~A claimed by conflicting builds ~S"
              n superseding)))))

(define-normalize-dependency :source (grain name &key in)
  "File named relatively to a build"
  (let ((path (portable-pathname-from-string name)))
    (if (absolute-pathname-p path)
        (multiple-value-bind (build suffix)
            (resolve-build-relative-name name)
          (if build
              `(:source ,suffix :in ,(fullname build))
              (error "Couldn't find in a build to which ~S is relative" name)))
        (let ((build (if in
                         (registered-build in)
                         (build-grain-for grain))))
        `(:source ,name :in ,(fullname build))))))

(define-normalize-dependency :object (grain name)
  "File named relatively to the object directory"
  `(:object
    ,(portable-namestring
      (merge-pathnames
       (portable-pathname-from-string name)
       (portable-pathname-from-string (fullname grain))))))

(define-normalize-dependency :file (grain name)
  "File named relatively to the filesystem"
  `(:file ,(namestring
            (ensure-absolute-pathname
             (merge-pathnames
              name
              (pathname-directory-pathname
               (grain-pathname
                (build-grain-for grain))))))))

;;; Matcher for the normalized dependency language
(defparameter +dependency-type+
  '((:lisp . lisp-grain)
    (:fasl . fasl-grain)
    (:cfasl . cfasl-grain)
    (:asdf . asdf-grain)
    (:build . t)
    (:compiled-build . t)
    (:source . t)
    (:object . t)
    (:file . t))
  "what type for grains corresponding to a given dependency tag")

(defun deconstruct-dependency (dep k)
  (flet ((err () (error "malformed dependency ~S" dep)))
    (unless (or (and (list-of-length-p 2 dep)
		     (stringp (second dep)))
		(eq :source (car dep)))
      (err))
    (let* ((head (first dep))
           (name (second dep))
           (type (cdr (assoc head +dependency-type+))))
      (unless type
        (err))
      (funcall k head name type))))

(defmacro with-dependency ((&key head name type) expr &body body)
  (loop :for v :in (list head name type)
        :for var = (or v (gensym))
        :collect var :into vars
        :unless v :collect var :into ignored
        :finally (return
                   `(deconstruct-dependency
                     ,expr
                     (lambda ,vars
                       ,@(when ignored `((declare (ignore ,@ignored))))
                       ,@body)))))

(defun compiled-dependency (dep)
  "Go from a load-time dependency to the corresponding compile-time dependency,
in the normalized dependency mini-language"
  (with-dependency (:head h :name x) dep
    (ecase h
      (:fasl (list (compile-time-fasl-type) x))
      (:build `(:compile-build ,x))
      ((:lisp :cfasl :asdf :compile-build) dep))))

(defun compile-time-fasl-type ()
  (if *use-cfasls* :cfasl :fasl))

(defun fasl-grains-for-name (fullname load-dependencies compile-dependencies)
  (cons (make-grain 'fasl-grain
                    :fullname `(:fasl ,fullname)
                    :load-dependencies load-dependencies)
        (if *use-cfasls*
            (list (make-grain 'cfasl-grain
                              :fullname `(:cfasl ,fullname)
                              :load-dependencies compile-dependencies))
            nil)))

(defun cfasl-for-fasl (fasl-grain)
  (check-type fasl-grain fasl-grain)
  (if *use-cfasls*
    (second (computation-outputs (grain-computation fasl-grain)))
    fasl-grain))

(define-simple-dispatcher load-command-for #'load-command-for-atom)

(defun load-command-for-atom (env spec)
  (declare (ignore env))
  (error "Invalid dependency ~S" spec))

(defun load-command-for (env spec)
  (load-command-for-dispatcher env spec))

(define-load-command-for :lisp (env name)
  (simple-load-command-for
   env `(:load-file ,name) name))
(define-load-command-for :fasl (env name)
  (simple-load-command-for
   env `(:load-file (:fasl ,name)) `(:fasl ,name)))
(define-load-command-for :cfasl (env name)
  (simple-load-command-for
   env `(:load-file (:cfasl ,name)) `(:cfasl ,name)))
(define-load-command-for :asdf (env name)
  (simple-load-command-for env `(:load-asdf ,name) `(:asdf ,name)))

(define-load-command-for :source (env name &key in)
  ;; Suffices to know data file exists.  No need to issue load command.
  (call-with-dependency-grain
   env
   `(:source ,name :in ,in)
   (lambda (grain)
     (issue-dependency env grain))))

(defun call-with-dependency-grain (environment dep fun)
  (let* ((grain (graph-for environment dep)))
    (with-dependency (:type type) dep
      (unless (typep grain type)
        (error "Expected a grain of type ~S for ~S, instead got ~S"
               type dep grain))
      (funcall fun grain))))

(defun simple-load-command-for (env command fullname)
  (call-with-dependency-grain
   env fullname
   (lambda (grain)
     (unless (dependency-already-included-p env grain)
       (load-commands-for-dependencies env grain)
       (issue-dependency env grain)
       (issue-load-command env command)))))

(define-load-command-for :build (env name)
  (let ((build (registered-build name)))
    (handle-lisp-dependencies build)
    (load-commands-for-build-dependencies env build)
    (load-commands-for-dependencies env build)))

(define-load-command-for :compile-build (env name)
  (let ((build (registered-build name)))
    (handle-lisp-dependencies build)
    (load-commands-for-build-dependencies env build)
    (load-commands-for-compile-dependencies env build)))

(defun load-commands-for-dependencies (env grain)
  (dolist (dep (load-dependencies grain))
    (load-command-for env dep)))

(defun load-commands-for-compile-dependencies (env grain)
  (dolist (dep (compile-dependencies grain))
    (load-command-for env dep)))

(defun load-commands-for-build-dependencies (env grain)
  (dolist (dep (build-dependencies grain))
    (load-command-for env dep)))

#|
In more complex cases, we probably want to
(1) output to a stream of commands, while
(2) sending fullnames for grains, and getting back grains that have been
 already output to a duplicates-removed, type-checked stream of grains.
|#
