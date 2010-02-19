;;; Handle the Search Path for XCVB modules.
#+xcvb (module (:depends-on ("macros" "specials" "registry")))
(in-package :xcvb)


;;; The Source Registry itself.
;;; We directly use the code from ASDF, therefore ensuring 100% compatibility.

(defparameter *source-registry* ()
  "Either NIL (for uninitialized), or a list of one element,
said element itself being a list of directory pathnames where to look for build.xcvb files")

(defun default-source-registry ()
  `(:source-registry
    (:tree ,*default-pathname-defaults*)
    (:tree ,(subpathname (user-homedir-pathname) ".local/share/common-lisp/source/"))
    (:directory ,*xcvb-lisp-directory*)
    (:tree #p"/usr/local/share/common-lisp/source/")
    (:tree #p"/usr/share/common-lisp/source/")
    :inherit-configuration))

(defun register-source-directory (directory &key exclude recurse collect)
  (funcall collect (list directory :recurse recurse :exclude exclude)))

(defun compute-source-registry (&optional parameter)
  (while-collecting (collect)
    (inherit-source-registry
     (append
      (list parameter)
      *default-source-registries*
      '(default-source-registry))
     :register
     (lambda (directory &key recurse exclude)
       (register-source-directory
        directory
        :recurse recurse :exclude exclude :collect #'collect)))))

(defun initialize-source-registry (&optional parameter)
  (let ((source-registry (compute-source-registry parameter)))
    (setf *source-registry* (list source-registry))
    *source-registry*))

(defun ensure-source-registry ()
  (unless *source-registry*
    (error "You should have already initialized the source registry by now!")))


;;; Now for actually searching the source registry!

(defparameter *source-registry-searched-p* nil
  "Has the source registry been searched yet?")

(defun verify-path-element (element)
  (let* ((absolute-path (ensure-absolute-pathname element)))
    (cond
      ((ignore-errors (truename absolute-path))
       absolute-path)
      (t
       (format *error-output* "~&Discarding invalid path element ~S~%"
               element)
       nil))))

(defun finalize-source-registry ()
  (setf *source-registry*
        (list
         (loop :for (path . flags) :in (car *source-registry*)
           :for v = (verify-path-element path)
           :when v :collect (cons v flags)))))

(defvar +all-builds-path+
  (make-pathname :directory '(:relative :wild-inferiors)
                 :name "build"
                 :type "xcvb"
                 :version :newest))

(defun pathname-newest-version-p (x)
  (or
   (member (pathname-version x) '(nil :newest :unspecific))
   (and (integerp (pathname-version x))
        (equal (truename x) (truename (make-pathname :version :newest :defaults x))))))

(defun pathname-is-build.xcvb-p (x)
  (and (equal (pathname-name x) "build")
       (equal (pathname-type x) "xcvb")
       #+genera (pathname-newest-version-p x)))


(defun find-build-files-under (root)
  (destructuring-bind (pathname &key recurse exclude) root
    (if (not recurse)
        (let ((path (probe-file (merge-pathnames "build.xcvb" pathname))))
          (when path (list path)))
        ;; This is what we want, but too slow with SBCL.
        ;; It took 5.8 seconds on my machine, whereas what's below takes .56 seconds
        ;; I haven't timed it with other implementations
        ;; -- they might or might not need the same hack.
        ;; TODO: profile it and fix SBCL.
        #-sbcl
        (loop
          :for file :in (ignore-errors
                          (directory (merge-pathnames +all-builds-path+ pathname)
                                     #+sbcl #+sbcl :resolve-symlinks nil
                                     #+clisp #+clisp :circle t))
          :unless (loop :for x :in exclude
                    :thereis (find x (pathname-directory file) :test #'equal))
          :collect file)
        #+sbcl
        (run-program/read-output-lines
         `("find" "-H" ,(escape-shell-token (namestring pathname))
               "(" "(" ,@(loop :for x :in exclude :append `("-name" ,x)) ")" "-prune"
               "-o" "-name" "build.xcvb" ")" "-type" "f" "-print")))))

(defun map-build-files-under (root fn)
  "Call FN for all BUILD files under ROOT"
  (let* ((builds (find-build-files-under root))
         #+(or) ;; uncomment it for depth first traversal
         (builds (sort builds #'<
                       :key #'(lambda (p) (length (pathname-directory p))))))
    (map () fn builds)))

(defun search-source-registry ()
  (finalize-source-registry)
  (loop :for root :in (remove-duplicates (car *source-registry*) :test 'equal) :do
    (map-build-files-under root #'(lambda (x) (register-build-file x root)))
    (register-build-nicknames-under root)))

(defun ensure-source-registry-searched ()
  (unless *source-registry-searched-p*
    (search-source-registry)))

;;;; Registering a build

(defparameter *builds*
  (make-hash-table :test 'equal)
  "A registry of known builds, indexed by canonical name.
Initially populated with all build.xcvb files from the search path.")

(defun supersedes-asdf-name (x)
  `(:supersedes-asdf ,(coerce-asdf-system-name x)))

(defun registered-build (name &key ensure-build)
  (let ((build (gethash name *builds*)))
    (when ensure-build
      (unless (build-grain-p build)
        (error "Could not find a build with requested fullname ~A. Try xcvb show-source-registry"
               name)))
    build))

(defun (setf registered-build) (build name &key ensure-build)
  (when ensure-build
    (unless (build-grain-p build)
      (error "Cannot register build ~S to non-build grain ~S" name build)))
  (setf (gethash name *builds*) build))

(defun register-build-file (build root)
  "Registers build file build.xcvb (given as pathname)
as having found under root path ROOT (another pathname),
for each of its registered names."
  ;;(format *error-output* "~&Found build file ~S in ~S~%" build root)
  (let* ((build-grain (make-grain-from-file build :build-p t))
         (fullname (when build-grain (fullname build-grain))))
    (when (and fullname (not (slot-boundp build-grain 'root)))
      (setf (bre-root build-grain) root)
      (register-build-named fullname build-grain root)))
  (values))

(defun register-build-nicknames-under (root)
  (dolist (b (remove-duplicates
              (loop :for b :being :the :hash-values :of *builds*
                :when (and (build-grain-p b) (equal (bre-root b) root)) :collect b)))
    (dolist (name (append (mapcar #'canonicalize-fullname (nicknames b))
                          (mapcar #'supersedes-asdf-name (supersedes-asdf b))))
      (register-build-named name b root))))

(defun merge-build (previous-build new-build name root)
  ;; Detect ambiguities.
  ;; If the name has already been registered, then
  ;; * if the previous entry is from a previous root, it has precedence
  ;; * else if the previous entry is from same root and is in an ancestor directory,
  ;;   it has precedence
  ;; * otherwise, it's a conflict, and the name shall be marked as conflicted and
  ;;   an error be printed if/when it is used.
  ;; Note: to do that in a more functional way, have some mechanism
  ;; that applies a modify-function to a gethash value, allowing (values NIL NIL) to specify remhash.
  (check-type previous-build (or null build-registry-conflict build-grain))
  (cond
    ((null previous-build)
     ;; we're the first entry with that name. Bingo!
     new-build)
    ((equal (bre-root previous-build) root)
     ;; There was a previous entry in same root:
     ;; there's an ambiguity, so that's a conflict!
     (make-instance 'build-registry-conflict
                    :fullname name
                    :pathnames (cons (grain-pathname new-build) (brc-pathnames previous-build))
                    :root root))
    (t
     ;; There was a previous entry in a previous root,
     ;; the previous entry takes precedence -- do nothing.
     previous-build)))

(defun register-build-named (name build-grain root)
  "Register under NAME pathname BUILD found in user-specified ROOT."
  (funcallf (registered-build name) #'merge-build build-grain name root))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; Show Search Path ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun show-source-registry ()
  "Show registered builds"
  (format t "~&Registered search paths:~{~% ~S~}~%" (car *source-registry*))
  (format t "~%Builds found in the search paths:~%")
  (flet ((entry-string (x)
           (destructuring-bind (fullname . entry) x
             (etypecase entry
               (build-grain
                (if (and (list-of-length-p 2 fullname) (eq (first fullname) :supersedes-asdf))
                    (format nil " (:ASDF ~S) superseded by (:BUILD ~S)~%"
                            (second fullname) (fullname entry))
                    (format nil " (:BUILD ~S) in ~S~%"
                            fullname (namestring (grain-pathname entry)))))
               (build-registry-conflict
                (format nil " CONFLICT for ~S between ~S~%"
                        fullname (mapcar 'namestring (brc-pathnames entry))))))))
    (map () #'princ (sort (mapcar #'entry-string (hash-table->alist *builds*)) #'string<))))

(defparameter +show-source-registry-option-spec+
  '((("xcvb-path" #\x) :type string :optional t :documentation "override your XCVB_PATH")))

(defun show-source-registry-command (&key xcvb-path)
  (handle-global-options :xcvb-path xcvb-path)
  (show-source-registry))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; Find Module ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun find-module (&key xcvb-path name short)
  "find modules of given full name"
  (handle-global-options :xcvb-path xcvb-path)
  (let ((all-good t))
    (dolist (fullname name)
      (let ((grain (resolve-absolute-module-name fullname)))
        (cond
          (grain
           (if short
             (format t "~A~%" (namestring (grain-pathname grain)))
             (format t "Found ~S at ~S~%" (fullname grain) (namestring (grain-pathname grain)))))
          (t
           (format *error-output* "Could not find ~S. Check your paths with xcvb ssp.~%" fullname)
           (setf all-good nil)))))
    (exit (if all-good 0 1))))

(defparameter +find-module-option-spec+
  (append
   '((("name" #\n) :type string :optional nil :list t :documentation "name to search for")
     (("short" #\s) :type boolean :optional t :documentation "short output"))
   +show-source-registry-option-spec+))
