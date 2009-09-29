#+xcvb
(module
 (:compile-depends-on ("simplifying-traversal")
  :load-depends-on ("simplifying-traversal" "logging")))

(in-package :xcvb)

#|
The conversion to ASDF is lossy. We handle the simple base cases perfectly,
but beyond that, we currently output something that will hopefully work
well enough to load a system, but that will not encode such information as
conditional compilation, generated files, etc.

This should be good enough for deployment purposes, or as the basis on which
a hacker may manually flesh out a full-fledged ASDF system.

TODO to make it more correct:
(a) have a system "xcvb-extensions.asd" that extends ASDF to have the missing
  features provided by XCVB.
(b) push these extensions for inclusion in upstream ASDF, and/or
(c) just punt and have ASDF delegate to our in-image backend (if/when implemented)


The conversion can be tested with:
	xcvb x2a -b /xcvb -o /tmp/blah.asd
|#

(defclass asdf-traversal (simplifying-traversal)
  ())

(defvar *target-builds* (make-hashset :test 'equal)
  "A list of asdf system we supersede")

(defmethod issue-dependency ((env asdf-traversal) (grain lisp-grain))
  (let* ((build (build-grain-for grain)))
    (if (build-in-target-p build)
        (call-next-method)
        (cond
          ((supersedes-asdf build)
           (dolist (system (supersedes-asdf build))
             (pushnew system *asdf-system-dependencies* :test 'equal)))
          ((equal (fullname build) "/asdf")
           nil) ;; special case: ASDF is assumed to be there already
          (t
           (error "depending on build ~A but it has no ASDF equivalent" (fullname build))))))
  (values))

(defun build-in-target-p (build)
  (gethash (fullname build) *target-builds*))

(defmethod graph-for-build-grain ((env asdf-traversal) grain)
  (let ((asdfs (supersedes-asdf grain)))
    (cond
      ((build-in-target-p grain)
       (load-command-for* env (compile-dependencies grain))
       (load-command-for* env (load-dependencies grain)))
      (asdfs
       (dolist (system asdfs)
         (pushnew system *asdf-system-dependencies* :test 'equal)))
      (t
       (error "Targets ~S depend on ~S but it isn't in an ASDF"
              (traversed-dependencies-r env) (fullname grain))))
    nil))

(defun write-asd-prelude (s)
  (format s
   ";;; This file was automatically generated by XCVB ~A with the arguments~%~
    ;;;    ~{~A~^ ~}~%~
    ;;; It may have been specialized to the target implementation ~A~%~
    ;;; with the following features:~%~
    ;;;    ~S~%~%~
   (in-package :asdf)~%~%"
   *xcvb-version* cl-launch:*arguments* *lisp-implementation-type* *features*))

(defun write-asd-file (&key build-names output-path asdf-name)
  "Writes an asd file to OUTPUT-PATH
covering the builds specified by BUILD-NAMES.
Declare asd system as ASDF-NAME."
  (assert (consp build-names))
  (let* ((builds (mapcar #'registered-build build-names))
         (first-build (first builds))
         (asdf-name
          (coerce-asdf-system-name
           (or asdf-name
               (first (supersedes-asdf first-build))
               (pathname-name (fullname first-build)))))
         (output-path (ensure-absolute-pathname output-path))
         (output-dir (pathname-directory-pathname output-path))
         (output-path
          (merge-pathnames
           output-path
           (merge-pathnames
            (make-pathname :name asdf-name :type "asd")
            (grain-pathname first-build))))
         (*target-builds* (make-hashset :test 'equal :list (mapcar #'fullname builds)))
         (*asdf-system-dependencies* nil)
         (*require-dependencies* nil)
         (*use-cfasls* nil))
    (log-format 6 "T=~A building dependency graph~%" (get-universal-time))
    (dolist (b builds)
      (graph-for-build-grain (make-instance 'asdf-traversal) b))
    (log-format 6 "T=~A creating asd file ~A~%" (get-universal-time) output-path)
    (with-open-file (out output-path :direction :output :if-exists :supersede)
      (with-standard-io-syntax
        (let* ((form (make-asdf-form asdf-name (fullname first-build)))
               (*print-escape* nil)
               (*package* (find-package :asdf))
               (*print-case* :downcase)
               (*default-pathname-defaults* output-dir))
          (write-asd-prelude out)
          (format out "~@[~{(require ~S)~%~}~%~]" (reverse *require-dependencies*))
          (write form :stream out :pretty t :miser-width 79)
          (terpri out))))))

(defun keywordify-asdf-name (name)
  (kintern "~:@(~A~)" name))

(defun make-asdf-form (asdf-name build &aux (prefix (strcat build "/")))
  (flet ((aname (x)
           (let ((n (fullname x)))
             (if (string-prefix<= prefix n)
               (subseq n (length prefix))
               n))))
    `(asdf:defsystem ,(keywordify-asdf-name asdf-name)
       :depends-on ,(mapcar 'keywordify-asdf-name (reverse *asdf-system-dependencies*))
       :components ,(loop :for computation :in (reverse *computations*)
                      :for lisp = (first (computation-inputs computation))
                      :for deps = (rest (computation-inputs computation))
                      :for build = (and lisp (build-grain-for lisp))
                      :for includedp = (and build (build-in-target-p build))
                      :for depends-on = (loop :for dep :in deps
                                          :when (eq (type-of dep) 'lisp-grain)
                                          :collect (aname dep))
                      :for name = (and lisp (aname lisp))
                      :for pathname = (and lisp (asdf-dependency-grovel::strip.lisp
                                                 (enough-namestring (grain-pathname lisp))))
                      :when includedp :collect
                      `(:file ,name
                              ,@(unless (and (equal name pathname) (not (find #\/ name)))
                                        `(:pathname pathname))
                              ,@(when depends-on `(:depends-on ,depends-on)))))))
