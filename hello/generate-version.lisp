#+xcvb (module (:depends-on ("specials")))

(in-package :xcvb-hello)

(defparameter *version-path*
  (merge-pathnames "version.lisp" *load-truename*))
(defparameter *xcvb-version-path*
  (merge-pathnames
   (make-pathname :directory '(:relative :back) :defaults *version-path*)
   *version-path*))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package :xcvb)
    (make-package :xcvb :use '(:cl))))

(load *xcvb-version-path*)
(with-open-file (s *version-path* :direction :output
                   :if-exists :rename-and-delete :if-does-not-exist :create)
  (format s "(in-package :xcvb-hello)~%(setf *version* ~S)~%" xcvb::*xcvb-version*))
