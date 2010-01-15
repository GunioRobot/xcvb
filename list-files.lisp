#+xcvb (module (:depends-on ("dependencies-interpreter")))

(in-package :xcvb)

;;; LIST-FILES
(defparameter *files-list* ())
(defparameter *files-table* (make-hash-table :test 'equal))

(defclass file-listing-traversal (simplifying-traversal)
  ())

(defmethod graph-for :around ((env file-listing-traversal) spec)
  (multiple-value-bind (v foundp) (gethash spec *files-table*)
    (if foundp
        v
        (progn
          (setf (gethash spec *files-table*) nil)
          (let ((v (call-next-method)))
            (setf (gethash spec *files-table*) v)
            (pushnew v *files-list*)
            v)))))

(defun list-files (spec)
  (let ((env (make-instance 'file-listing-traversal))
        (*files-list* ())
        (*files-table* (make-hash-table :test 'equal)))
    (build-command-for env spec)
    (reverse *files-list*)))

;;; TODO: some magic to break circularities that are due to flattening conditionals.
(define-build-command-for :when ((env file-listing-traversal) expression &rest dependencies)
  (build-command-for* env dependencies))
(define-build-command-for :cond ((env file-listing-traversal) &rest cond-expressions)
  (dolist (cond-expression cond-expressions)
    (build-command-for* env (cdr cond-expression))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; Remove XCVB ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defparameter +remove-xcvb-option-spec+
  '((("build" #\b) :type string :optional nil
     :documentation "Specify XCVB build to remove modules from")
    (("xcvb-path" #\x) :type string :optional t
     :documentation "override your XCVB_PATH")
    (("debugging" #\Z) :type boolean :optional t :documentation "enable debugging")
    (("verbosity" #\v) :type integer :optional t :initial-value 5 :documentation "set verbosity (default: 5)")))

(defun remove-xcvb-command (&rest keys &key xcvb-path verbosity build debugging)
  (declare (ignore xcvb-path verbosity debugging))
  (apply 'handle-global-options keys)
  (remove-xcvb-from-build build))

;; Using the build.xcvb as a starting point, finds files and
;; strips XCVB modules from them.
(defun remove-xcvb-from-build (fullname)
  (multiple-value-bind (target-dependency build) (handle-target fullname)
    (log-format 7 "Removing XCVB from build ~A~%" build)
    (dolist (grain (list-files target-dependency))
      (log-format 7 "Inspecting grain ~A~%" grain)
      (when (typep grain 'lisp-grain)
        (log-format 8 "This grain is in build ~A~%" (build-grain-for grain))
        (log-format 9 "EQ: ~A EQUAL NAMES: ~A~%"
                    ;; for some reason, the builds are different objects(!). HOW???
                    (eq build (build-grain-for grain))
                    (equal (fullname build) (fullname (build-grain-for grain))))
        (when (equal (fullname build) (fullname (build-grain-for grain)))
          (log-format 8 "This is the correct build~%")
          (log-format 5 "Removing module declaration from ~A~%" (grain-pathname grain))
          (remove-module-from-file (grain-pathname grain)))))
    (log-format 5 "Deleting build file for ~A~%" (grain-pathname build))
    (delete-file (grain-pathname build))))
