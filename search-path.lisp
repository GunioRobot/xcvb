;;; Handle the Search Path for XCVB modules.
#+xcvb (module (:depends-on ("registry" "specials" "portablish-pathnames")))
(in-package :xcvb)

(defvar *search-path-searched-p* nil
  "Did we search the search path?")

(defun default-search-path ()
  (list
   *default-pathname-defaults*
   (subpathname (user-homedir-pathname) ".local/share/common-lisp/source/")
   *xcvb-lisp-directory*
   #p"/usr/local/share/common-lisp/source/"
   #p"/usr/share/common-lisp/source/"))

(defun verify-path-element (element)
  (let* ((absolute-path (ensure-absolute-pathname (ensure-pathname-is-directory element))))
    (cond
      ((ignore-errors (truename absolute-path))
       absolute-path)
      (t
       (format *error-output* "~&Discarding invalid path element ~S~%"
               (namestring element))
       nil))))

(defun expand-search-path-string (string &optional (previous-path *search-path*))
  (cond
    ((or (null string) (equal string ""))
     previous-path)
    ((stringp string)
     (loop
	 :with path = ()
	 :with start = 0
	 :with end = (length string)
	 :for i = (or (position #\: string :start start) end) :do
	 (let ((s (subseq string start i)))
	   (cond
	     ((equal "" s) ; empty element
	      nil)
	     ((equal "!" s) ; previous path
	      (setf path (append (reverse previous-path) path)))
	     (t
	      (push s path))))
	 (setf start (1+ i))
	 (when (>= start end) (return (nreverse path)))))))

(defun set-search-path! (string)
  (setf *search-path* (expand-search-path-string string)))

(defun initialize-search-path ()
  (setf *search-path-searched-p* nil)
  (setf *search-path* (default-search-path))
  (set-search-path! (cl-launch:getenv "XCVB_PATH")))

(defun finalize-search-path ()
  (setf *search-path*
	(loop :for elt :in *search-path*
	      :for v = (verify-path-element elt)
	      :when v :collect v)))

(defun pathname-newest-version-p (x)
  (or
   (member (pathname-version x) '(nil :newest :unspecific))
   (and (integerp (pathname-version x))
        (equal (truename x) (truename (make-pathname :version :newest :defaults x))))))

(defun pathname-is-build.xcvb-p (x)
  (and (equal (pathname-name x) "build")
       (equal (pathname-type x) "xcvb")
       #+genera (pathname-newest-version-p x)))

(defvar *archive-directory-names* '("_darcs" ".svn")
  "names of archive directories inside which we should not look for BUILD files")

(defun in-archive-directory-p (x)
  (loop :for d :in (pathname-directory x)
        :thereis (member d *archive-directory-names* :test #'equal)))

(defvar +all-builds-path+
  (make-pathname :directory '(:relative :wild-inferiors)
                 :name "build"
                 :type "xcvb"
                 :version :newest))

(defun underscore-for-non-alphanum-chars (x)
  (map 'base-string
       (lambda (c) (if (or (char<= #\a c #\z) (char<= #\A c #\Z) (char<= #\0 c #\9)) c #\_))
       x))

(defun find-build-files-under (root)
  ;;; This is what we want, but too slow with SBCL.
  ;; It took 5.8 seconds on my machine, whereas what's below takes .56 seconds
  ;; I haven't timed it with other implementations -- they might or might not need the same hack.
  ;; TODO: profile it and fix SBCL.
  #-sbcl
  (directory (merge-pathnames +all-builds-path+ root)
                    #+sbcl #+sbcl :resolve-symlinks nil)
  #+sbcl
  (run-program/read-output-lines
   "find" "-H" (escape-shell-token (namestring root)) "-type" "f" "-name" "build.xcvb"))

(defun map-build-files-under (root fn)
  "Call FN for all BUILD files under ROOT"
  (let* ((builds (find-build-files-under root))
         (builds (remove-if #'in-archive-directory-p builds))
         #+(or) ;; uncomment it for depth first traversal
         (builds (sort builds #'<
                       :key #'(lambda (p) (length (pathname-directory p))))))
    (map () fn builds)))

(defun search-search-path ()
  (setf *search-path-searched-p* t)
  (finalize-search-path)
  (dolist (root *search-path*)
    (map-build-files-under root #'(lambda (x) (register-build-file x root)))
    (register-build-nicknames-under root)))

(defun ensure-search-path-searched ()
  (unless *search-path-searched-p*
    (search-search-path)))

(defun show-search-path ()
  "Show registered builds"
  (format t "~&Registered search paths:~{~% ~S~}~%" *search-path*)
  (format t "~%Builds found in the search paths:~%")
  (flet ((entry-string (x)
           (destructuring-bind (fullname . entry) x
             (etypecase entry
               (build-grain
                (if (and (list-of-length-p 2 fullname) (eq (first fullname) :supersedes-asdf))
                    (format nil " (:ASDF ~S) superseded by (:BUILD ~S)~%"
                            (second fullname) (fullname entry))
                    (format nil " (:BUILD ~S) in ~S~%" fullname (grain-pathname entry))))
               (build-registry-conflict
                (format nil " CONFLICT for ~S between ~S~%" fullname (brc-pathnames entry)))))))
    (map () #'princ (sort (mapcar #'entry-string (hash-table->alist *grains*)) #'string<))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; Show Search Path ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defparameter +show-search-path-option-spec+
  '((("xcvb-path" #\x) :type string :optional t :documentation "override your XCVB_PATH")))

(defun show-search-path-command (arguments &key xcvb-path)
  (when arguments
    (error "Invalid arguments to show-search-path: ~S~%" arguments))
  (reset-variables)
  (when xcvb-path
    (set-search-path! xcvb-path))
  (search-search-path)
  (show-search-path))
