#+xcvb
(module
  (:depends-on ("makefile-backend" "asdf-backend" "simplifying-traversal" "main")))

(in-package :xcvb)

(defclass nem-traversal (asdf-traversal makefile-traversal)
  ())

(defmethod build-in-target-p ((env nem-traversal) build)
  (declare (ignorable env build))
  t)

(defmethod issue-dependency ((env nem-traversal) (grain lisp-file-grain))
  (unless (member (second (fullname grain)) '("/xcvb/driver" "/asdf/asdf" "/poiu/poiu")
                  :test 'equal)
    (call-next-method))
  (values))

(defun make-nem-stage (env asdf-name build &key previous parallel)
  (let* ((*computations* nil)
         (*asdf-system-dependencies* nil)
         (*require-dependencies* nil)
         (_g (graph-for-build-module-grain env build))
         (inputs (loop :for computation :in (reverse *computations*)
                   :for i = (first (computation-inputs computation))
                   :when (and i (not (grain-computation i)))
                   :collect i))
         (asd-vp (make-vp :obj "/" asdf-name "." "asd"))
         (_w (do-write-asd-file env :output-path (vp-namestring env asd-vp)
                                :asdf-name asdf-name))
         (image-name `(:image ,(strcat "/" asdf-name)))
         (image (make-grain 'image-grain :fullname image-name))
         (previous-spec (if previous
                            `(:image (:image ,(strcat "/" previous)))
                            (progn
                              (setf inputs
                                    (append (mapcar #'registered-grain *lisp-setup-dependencies*)
                                            inputs))
                              `(:load ,*lisp-setup-dependencies*))))
         (computation
          (make-computation ()
            :outputs (list image)
            :inputs inputs
            :command
            `(:xcvb-driver-command ,previous-spec
              (:create-image
               ,image-name
               (:register-asdf-directory ,(merge-pathnames (strcat *object-directory* "/")))
               ,@(when parallel
                       `((:register-asdf-directory
                          ,(pathname-directory-pathname
                            (grain-pathname (registered-build "/poiu" :ensure-build t))))
                         (:load-asdf :poiu)))
               (:load-asdf ,(coerce-asdf-system-name asdf-name)
                           ,@(when parallel `(:parallel t)))))))
         (*computations* (list computation)))
    (declare (ignore _w _g))
    (computations-to-Makefile env)))

(defun write-non-enforcing-makefile (build-names &key output-path asdf-name parallel)
  "Write a Makefile to output-path with information about how to compile the specified BUILD
in a fast way that doesn't enforce dependencies."
  (let* ((*print-pretty* nil); otherwise SBCL will slow us down a lot.
         (*use-cfasls* nil) ;; We use ASDF that doesn't know about them
         (builds ;; TODO: somehow use handle-target instead
          (mapcar (lambda (n) (registered-build n :ensure-build t)) build-names))
         (last-build (first (last builds)))
         (asdf-names (loop :for (build . rest) :on build-names :for i :from 1
                       :collect (if rest (format nil "~A-stage~D-~A" asdf-name i build) asdf-name)))
         (default-output-path (merge-pathnames "xcvb-ne.mk" (grain-pathname last-build)))
         (output-path (merge-pathnames output-path default-output-path))
         (makefile-path (ensure-absolute-pathname output-path))
         (makefile-dir (pathname-directory-pathname makefile-path))
         (*default-pathname-defaults* makefile-dir)
         (*makefile-target-directories* (make-hash-table :test 'equal))
         (*makefile-target-directories-to-mkdir* nil)
         (*makefile-phonies* nil)
         (smt (make-instance 'static-makefile-traversal))
         (env (make-instance 'nem-traversal))
         (static-rules
          (prog2
              (issue-image-named smt nil)
              (computations-to-Makefile smt)
            (setf *computations* nil)))
         (build-rules
          (loop
            ;; :for build-name :in build-names
            :for build :in builds
            :for previous-asdf = nil :then asdf-name
            :for asdf-name :in asdf-names
            :collect (make-nem-stage env asdf-name build
                                     :previous previous-asdf
                                     :parallel parallel))))
      (with-open-file (out makefile-path
                           :direction :output
                           :if-exists :supersede)
        (write-makefile-prelude out)
        (dolist (body (reverse (cons static-rules build-rules)))
          (princ body out))
        (write-makefile-conclusion out))))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; non-enforcing makefile ;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defparameter +non-enforcing-makefile-option-spec+
  `(,@+build-option-spec+
    ,@+setup-option-spec+
    ,@+source-registry-option-spec+
    (("name" #\n) :type string :optional t :initial-value "xcvb-tmp" :documentation "ASDF name for the target")
    ,@+setup-option-spec+
    ,@+source-registry-option-spec+
    (("output-path" #\o) :type string :initial-value "xcvb-ne.mk" :documentation "specify output path")
    ,@+object-directory-option-spec+
    ,@+lisp-implementation-option-spec+
    (("parallel" #\P) :type boolean :optional t :initial-value nil :documentation "compile in parallel with POIU")
    ,@+verbosity-option-spec+
    ;; ,@+profiling-option-spec+
    ))

(defun non-enforcing-makefile (&rest keys &key
                               build use-base-image setup source-registry name
                               output-path object-directory
                               lisp-implementation lisp-binary-path
                               define-feature undefine-feature
                               verbosity parallel debugging #|force-cfasl profiling|#)
  (declare (ignore source-registry setup verbosity
                   lisp-implementation lisp-binary-path
                   define-feature undefine-feature
                   object-directory use-base-image debugging))
  ;;(with-maybe-profiling (profiling)
  (apply 'handle-global-options
         ;;:disable-cfasl (not force-cfasl)
         keys)
  (write-non-enforcing-makefile
   (mapcar #'canonicalize-fullname build)
   :asdf-name name
   :output-path output-path
   :parallel parallel))
