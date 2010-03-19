#+xcvb (module (:depends-on ("dependencies-interpreter" "traversal")))
(in-package :xcvb)

#|
This provides a simplifying traversal that conflates all kind of dependencies
into just one kind. Used by non-enforcing backends such as the ASDF backend
and the non-enforcing Makefile backend.
|#

(defclass simplifying-traversal (xcvb-traversal)
  ())

(defmethod issue-build-command ((env simplifying-traversal) command)
  (declare (ignorable env command))
  (values))

(defmethod issue-dependency ((env simplifying-traversal) (grain fasl-grain))
  (issue-dependency env (graph-for env `(:lisp ,(second (fullname grain))))))

(define-build-command-for :lisp ((env simplifying-traversal) name)
  (build-command-for-fasl env name))

(defmethod graph-for-build-module-grain ((env simplifying-traversal) grain)
  (build-command-for* env (build-dependencies grain))
  (build-command-for* env (compile-dependencies grain))
  (build-command-for* env (cload-dependencies grain))
  (build-command-for* env (load-dependencies grain))
  nil)

(define-graph-for :fasl ((env simplifying-traversal) name)
  (check-type name string)
  (let ((grain (resolve-absolute-module-name name)))
    (check-type grain lisp-module-grain)
    (finalize-grain grain)
    (issue-dependency env grain)
    (let* ((dependencies
            (remove-duplicates
             (append (build-dependencies grain)
                     (let ((generator (grain-generator grain)))
                       (when generator (generator-dependencies generator)))
                     (compile-dependencies grain)
                     (cload-dependencies grain)
                     (load-dependencies grain))
             :test 'equal :from-end t))
           (fasl
            (make-grain 'fasl-grain :fullname `(:fasl ,name)
                        :load-dependencies ())))
      (build-command-for* env dependencies)
      (make-computation
       ()
       :outputs (list fasl)
       :inputs (traversed-dependencies env)
       :command nil)
      fasl)))

(define-graph-for :lisp ((env simplifying-traversal) name)
  (resolve-absolute-module-name name))

(defvar *asdf-system-dependencies* nil
  "A list of asdf system we depend upon")

#|(define-graph-for :asdf ((env simplifying-traversal) system-name)
  (pushnew system-name *asdf-system-dependencies* :test 'equal)
  nil)|#


(defvar *require-dependencies* nil
  "A list of require features we depend upon")

(define-build-command-for :asdf ((env simplifying-traversal) name)
  (pushnew name *asdf-system-dependencies* :test 'equal)
  (values))

#|(define-graph-for :require ((env simplifying-traversal) name)
  (pushnew name *require-dependencies* :test 'equal)
  nil)
|#

(define-build-command-for :require ((env simplifying-traversal) name)
  (pushnew name *require-dependencies* :test 'equal)
  (values))
