#+xcvb
(module
 (:compile-depends-on ("simplifying-traversal")
  :load-depends-on ("simplifying-traversal" "logging")))

(in-package :xcvb)

(defclass asdf-traversal (simplifying-traversal)
  ())

(defvar *target-builds* (make-hashset :test 'equal)
  "A list of asdf system we supersede")

(defmethod issue-dependency ((env asdf-traversal) (grain lisp-module-grain))
  (let* ((build (build-module-grain-for grain)))
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

(defmethod graph-for-build-module-grain ((env asdf-traversal) grain)
  (if (build-in-target-p grain)
    (call-next-method)
    (let ((asdfs (supersedes-asdf grain)))
      (unless asdfs
        (error "Targets ~S depend on ~S but it isn't in an ASDF"
               (traversed-dependencies-r env) (fullname grain)))
      (dolist (system asdfs)
        (pushnew system *asdf-system-dependencies* :test 'equal))
      nil)))

(defun write-asd-prelude (s)
  (format s
   ";;; This file was automatically generated by XCVB ~A with the arguments~%~
    ;;;    ~{~A~^ ~}~%~
    ;;; It may have been specialized to the target implementation ~A~%~
    ;;; with the following features:~%~
    ;;;    ~(~S~)~%~%~
   (in-package :asdf)~%~%"
   *xcvb-version* *arguments* *lisp-implementation-type* *features*))

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
         (default-output-path
          (merge-pathnames
           (make-pathname :name asdf-name :type "asd")
           (grain-pathname first-build)))
         (output-path
          (if output-path
            (merge-pathnames
             (ensure-absolute-pathname output-path)
             default-output-path)
            default-output-path))
         (*target-builds* (make-hashset :test 'equal :list (mapcar #'fullname builds)))
         (*asdf-system-dependencies* nil)
         (*require-dependencies* nil)
         (*use-cfasls* nil))
    (log-format 6 "T=~A building dependency graph~%" (get-universal-time))
    (dolist (b builds)
      (graph-for-build-module-grain (make-instance 'asdf-traversal) b))
    (log-format 6 "T=~A creating asd file ~A~%" (get-universal-time) output-path)
    (do-write-asd-file
      :output-path output-path
      :asdf-name asdf-name
      :build (fullname first-build))))

(defun do-write-asd-file (&key output-path build asdf-name)
  (let* ((output-path (merge-pathnames output-path))
         (_ (ensure-directories-exist output-path))
         (*default-pathname-defaults* (pathname-directory-pathname output-path)))
    (declare (ignore _))
    (with-open-file (out output-path :direction :output :if-exists :supersede)
      (write-asd-prelude out)
      (with-safe-io-syntax (:package :asdf)
        (let* ((form (make-asdf-form asdf-name build))
               (*print-case* :downcase))
          (format out "~@[~{(require ~S)~%~}~%~]" (reverse *require-dependencies*))
          (write form :stream out :pretty t :miser-width 79)
          (terpri out))))))

(defun keywordify-asdf-name (name)
  (kintern "~:@(~A~)" name))

(defun make-asdf-form (asdf-name build)
  (let ((prefix (strcat build "/")))
    (flet ((aname (x)
             (let ((n (fullname x)))
               (if (string-prefix-p prefix n)
                 (subseq n (length prefix))
                 n))))
      `(asdf:defsystem ,(keywordify-asdf-name asdf-name)
         :depends-on ,(mapcar 'keywordify-asdf-name (reverse *asdf-system-dependencies*))
         :components ,(loop :for computation :in (reverse *computations*)
                        :for lisp = (first (computation-inputs computation))
                        :for deps = (rest (computation-inputs computation))
                        :for build = (and lisp (build-module-grain-for lisp))
                        :for includedp = (and build (build-in-target-p build))
                        :for depends-on = (loop :for dep :in deps
                                            :when (eq (type-of dep) 'lisp-module-grain)
                                            :collect (aname dep))
                        :for name = (and lisp (aname lisp))
                        :for pathname = (and lisp (asdf-dependency-grovel::strip-extension
                                                   (enough-namestring (grain-pathname lisp))
                                                   "lisp"))
                        :when includedp :collect
                        `(:file ,name
                                ,@(unless (and (equal name pathname) (not (find #\/ name)))
                                          `(:pathname ,pathname))
                                ,@(when depends-on `(:depends-on ,depends-on))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; XCVB to ASDF ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defparameter +xcvb-to-asdf-option-spec+
  '((("build" #\b) :type string :optional nil :list t :documentation "Specify a build to convert (can be repeated)")
    (("name" #\n) :type string :optional t :documentation "name of the new ASDF system")
    (("output-path" #\o) :type string :optional t :documentation "pathname for the new ASDF system")
    (("xcvb-path" #\x) :type string :optional t :documentation "override your XCVB_PATH")
    (("lisp-implementation" #\i) :type string :initial-value "sbcl" :documentation "specify type of Lisp implementation")
    (("lisp-binary-path" #\p) :type string :optional t :documentation "specify path of Lisp executable")
    (("debugging" #\Z) :type boolean :optional t :documentation "enable debugging")
    (("verbosity" #\v) :type integer :initial-value 5 :documentation "set verbosity")))

(defun xcvb-to-asdf-command (&rest keys &key
                             build name output-path verbosity xcvb-path
                             lisp-implementation lisp-binary-path debugging)
  (declare (ignore xcvb-path verbosity lisp-implementation lisp-binary-path debugging))
  (apply 'handle-global-options keys)
  (write-asd-file
   :asdf-name name
   :build-names (mapcar #'canonicalize-fullname build)
   :output-path output-path))
