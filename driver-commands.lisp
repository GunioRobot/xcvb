#+xcvb
(module (:depends-on ("utilities" "specials" "grain-interface" #|"external-commands"|#)))

(in-package :xcvb)

(define-simple-dispatcher text-for-xcvb-driver-command #'text-for-xcvb-driver-command-atom)

(defun text-for-xcvb-driver-command-atom (env foo)
  (declare (ignore env foo))
  (error "FOO"))

(defun text-for-xcvb-driver-command (env clause)
  (text-for-xcvb-driver-command-dispatcher env clause))

(define-text-for-xcvb-driver-command :load-file (env dep)
  (format nil "(:load-file ~S)" (effective-namestring env dep)))

(define-text-for-xcvb-driver-command :require (env name)
  (declare (ignore env))
  (format nil "(:cl-require ~(~S~))" name))

(define-text-for-xcvb-driver-command :load-asdf (env name &key parallel)
  (declare (ignore env))
  (format nil "(:load-asdf ~(~S~)~@[ :parallel t~])" name parallel))

(define-text-for-xcvb-driver-command :register-asdf-directory (env directory)
  (declare (ignore env))
  (format nil "(:register-asdf-directory ~S)" (namestring directory)))

(define-text-for-xcvb-driver-command :initialize-manifest (env manifest)
  (format nil "(:initialize-manifest ~S)"
          (pseudo-effective-namestring env manifest)))

(define-text-for-xcvb-driver-command :load-manifest (env manifest)
  (format nil "(:load-manifest ~S)"
          (pseudo-effective-namestring env manifest)))


(defun text-for-xcvb-driver-helper (env dependencies format &rest args)
  (with-output-to-string (stream)
    (format stream "(")
    (apply #'format stream format args)
    (dolist (dep dependencies)
      (write-string (text-for-xcvb-driver-command env dep) stream))
    (format stream ")")))

(define-text-for-xcvb-driver-command :compile-lisp (env name-options &rest dependencies)
  (destructuring-bind (name &key &aux (basename (second name))) name-options
    (text-for-xcvb-driver-helper
     env dependencies
     ":compile-lisp (~S ~S~@[ :cfasl ~S~]~@[ :lisp-object ~S~])"
     (effective-namestring env name)
     (tempname-target (effective-namestring env `(:fasl ,basename)))
     (when *use-cfasls*
       (tempname-target (effective-namestring env `(:cfasl ,basename))))
     (when (target-ecl-p)
       (tempname-target (effective-namestring env `(:lisp-object ,basename)))))))

(define-text-for-xcvb-driver-command :create-image (env spec &rest dependencies)
  (destructuring-bind (&key image standalone package) spec
    (text-for-xcvb-driver-helper
     env dependencies
     ":create-image (~S~@[~* :standalone t~]~@[ :package ~S~])"
     (tempname-target (effective-namestring env `(:image ,image)))
     standalone package)))

(defun lisp-invocation-for (env keys eval)
  (destructuring-bind (&key image load) keys
    (lisp-invocation-arglist
     :image-path (if image (effective-namestring env image) *lisp-image-pathname*)
     :load (mapcar/ #'effective-namestring env load)
     :eval (tweak-features-around-eval-string eval))))

(defun compile-file-directly-shell-token (env name &key cfasl lisp-object)
  (quit-form
   :code
   (format nil "(multiple-value-bind (output warningp failurep) ~
                    (let ((*default-pathname-defaults* ~
                           (truename *default-pathname-defaults*))) ~
                      (compile-file ~S :verbose nil :print nil ~
                       :output-file (merge-pathnames ~:[~S~;~:*~S~*~]) ~
                       ~@[:emit-cfasl (merge-pathnames ~S)~] ~
                       ~3:*~:[~;:system-p t) ~
                       (c::build-fasl (merge-pathnames ~S) ~
                        :lisp-files (list ~2:*(merge-pathnames ~S))~]))~
                  (if (or (not output) #-ecl warningp failurep) 1 0))"
           (effective-namestring env name)
	   (when lisp-object
	     (tempname-target (effective-namestring env `(:lisp-object ,(second name)))))
           (tempname-target (effective-namestring env `(:fasl ,(second name))))
           (when cfasl
             (tempname-target (effective-namestring env `(:cfasl ,(second name))))))))


(defgeneric grain-pathname-text (env grain))

(defmethod grain-pathname-text (env (grain file-grain))
  (grain-namestring env grain))

(defmethod grain-pathname-text (env (grain asdf-grain))
  (declare (ignorable env grain))
  nil)

(defmethod grain-pathname-text (env (grain require-grain))
  (declare (ignorable env grain))
  nil)
