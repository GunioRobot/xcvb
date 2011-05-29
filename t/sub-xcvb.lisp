#+xcvb (module (:depends-on ("helpers" "specials")))

(in-package #:xcvb-unit-tests)

(declaim (optimize (debug 3) (safety 3)))

(defsuite* (sub-xcvb
            :in test-xcvb
            :documentation "Test XCVB as a subprocess"))

(defun normalize-environment-var (key)
  (substitute #\_ #\- (string-upcase key)))

(defun environment-parallelize (val)
  (or val "no"))

(defun make-environment (keys)
  (loop :for xspec :in
    '(:install-bin :install-image :install-lisp :install-source :install-systems
      (:object-dir "XCVB_OBJECT_DIRECTORY") :cl-source-registry
      (:implementation-type "LISP" string-downcase)
      :path :xdg-cache-home :cl-launch-flags
      (:parallelize () environment-parallelize))
    :for spec = (alexandria:ensure-list xspec)
    :for key = (first spec)
    :for var = (or (second spec) (normalize-environment-var key))
    :for fun = (or (third spec) 'identity)
    :for val = (getf keys key)
    :when val :collect (format nil "~A=~A" var (funcall fun val))))

(defun compute-makefile-configuration-variables (&rest keys)
  (loop :with config = (apply 'extract-makefile-configuration keys)
    :for xspec :in
    '(:install-bin :install-image :install-lisp
      :install-xcvb :install-source :install-systems
      (:object-dir "XCVB_OBJECT_DIRECTORY") :cl-source-registry :implementation-type
      :cl-launch :cl-launch-flags :cl-launch-mode)
    :for spec = (alexandria:ensure-list xspec)
    :for key = (first spec)
    :for var = (or (second spec) (normalize-environment-var key))
    :for val = (association var config :test 'equal)
    :when val :do (setf (getf keys key) val))
  keys)

(defun extract-makefile-configuration (&rest keys &key xcvb-dir &allow-other-keys)
  (loop
    :for line :in (apply 'run-cmd/lines "make" "-C" xcvb-dir "show-config"
                         (make-environment keys))
    :for pos = (position #\= line)
    :for name = (subseq line 0 pos)
    :for value = (cond
                   ((null pos)
                    (format *error-output* "Ignoring line ~S~%" line)
                    nil)
                   ((= pos (1- (length line)))
                    "")
                   (t
                    (subseq line (1+ pos) nil)))
    :when value :collect (cons name value)))

(defmacro compute-xcvb-dir-variables! (keys &rest args)
  `(setf ,keys (apply 'compute-xcvb-dir-variables ,@args ,keys)))

(defmacro compute-release-dir-variables! (keys &rest args)
  `(setf ,keys (apply 'compute-release-dir-variables ,@args ,keys)))

(defmacro compute-makefile-configuration-variables! (keys)
  `(setf ,keys (apply 'compute-makefile-configuration-variables ,keys)))


(defun validate-xcvb-checkout (&key xcvb-dir &allow-other-keys)
  (is (probe-file* (in-dir xcvb-dir "xcvb.asd"))
      "Missing xcvb.asd in XCVB directory ~S" xcvb-dir)
  (is (probe-file* (in-dir xcvb-dir "driver.lisp"))
      "Missing driver.lisp in XCVB directory ~S" xcvb-dir)
  (is (probe-file* (in-dir xcvb-dir "configure.mk"))
      "Please configure your configure.mk in ~S~%~
       (and don't forget to properly setup ASDF)" xcvb-dir))

(defun validate-release-checkout (&key release-dir &allow-other-keys)
  (is (probe-file* release-dir)
      "Release directory ~S doesn't exist" release-dir)
  (is (in-dir release-dir "INSTALL")
      "Release directory ~S fails to contain INSTALL" release-dir)
  (is (in-dir release-dir "xcvb/")
      "Release directory ~S fails to contain xcvb/" release-dir)
  (validate-xcvb-dir :xcvb-dir (in-dir release-dir "xcvb/")))

(defun get-makefile-configuration (&rest keys
                                   &key xcvb-dir makefile-configuration &allow-other-keys)
  (or makefile-configuration
      (apply 'extract-makefile-configuration :xcvb-dir xcvb-dir keys)))

(defun ensure-makefile-configuration (keys)
  (if (getf keys :makefile-configuration) keys
      (list* :makefile-configuration (apply 'get-makefile-configuration keys) keys)))

(defun get-system-dependencies ()
  (loop :for dep :in +xcvb-dependencies+
    :append (destructuring-bind (build &key systems upstream repo) dep
              (declare (ignore build upstream repo))
              systems)))

(defun validate-asdf-setup-command (&key cl-launch-flags &allow-other-keys)
  (format nil "cl-launch ~A -s asdf -i ~S"
          cl-launch-flags
          (with-safe-io-syntax (:package :cl-user)
            (format nil "(cl-launch::quit (if ~S 0 1))"
                    `(loop :with cl-user::good = t
                       :for cl-user::x :in ',(get-system-dependencies)
                       :for cl-user::s = (asdf:find-system cl-user::x nil) :do
                       (cond
                         (cl-user::s (format t "Found system ~(~A~) in ~A~%" cl-user::x
                                             (asdf:system-source-directory cl-user::s)))
                         (t (setf cl-user::good nil)
                            (format t "Missing system ~(~A~)~%" cl-user::x)))
                       :finally (return cl-user::good))))))

(defun validate-asdf-setup (&rest keys)
  (run-program/echo-output (apply 'validate-asdf-setup-command keys)))

(defun lisp-long-name (impl)
  (ecase impl
    ((nil) "")
    ((:sbcl) "SBCL")
    ((:ccl) "Clozure Common Lisp")
    ((:clisp) "CLISP")))

(defun validate-xcvb-version (&key xcvb implementation-type &allow-other-keys)
  (let ((lines (run-cmd/lines xcvb 'version)))
    (is (string-prefix-p "XCVB version " (first lines)))
    (is (string-prefix-p (strcat "built on " (lisp-long-name implementation-type))
                         (second lines)))))

(defun validate-xcvb-ssr (&key xcvb xcvb-dir cl-source-registry &allow-other-keys)
  ;; preconditions: XCVB built from DIR into BUILD-DIR using ENV
  ;; postconditions: xcvb ssr working
  (let ((ssr (run-program/read-output-string
              (format nil "~S ssr --source-registry ~S"
                      xcvb (strcat xcvb-dir "//:" cl-source-registry)))))
    (is (cl-ppcre:scan "\\(:BUILD \"/xcvb\"\\) in \".*/build.xcvb\"" ssr)
        "Can't find build for xcvb")
    (is (search "(:ASDF \"xcvb\") superseded by (:BUILD \"/xcvb\")" ssr)
        "can't find superseded asdf for xcvb")
    (is (cl-ppcre:scan "CONFLICT for \"/xcvb/test/conflict/b\" between \\(\".*/examples/conflict/b2?/build.xcvb\" \".*/examples/conflict/b2?/build.xcvb\"\\)" ssr)
        "can't find conflict for /xcvb/test/conflict/b")))

(defun validate-xcvb (&rest keys &key implementation-type &allow-other-keys)
  ;; preconditions: env, xcvb built, PWD=.../xcvb/
  (apply 'validate-xcvb-version keys) ;; is the built xcvb what we think it is?
  (apply 'validate_xcvb_ssr keys) ;; can it search its search path?
  (case implementation-type
    (:sbcl (apply 'validate-a2x keys))) ; can it migrate a2x-test from xcvb?
  (apply 'validate_rmx keys) ; can it remove the xcvb annotations from a2x-test?
  (apply 'validate_x2a keys) ; can it convert hello back to asdf?
  ;; (apply 'validate-simple-build-backend) ; can it build hello with the standalone backend?
  ;; (validate-farmer-backend) ; can it build hello with the standalone backend?
  (apply 'validate-mk-backend keys) ; can it build hello with the Makefile backend?
  (case implementation-type
    ((:sbcl :ccl :clisp)
     (apply 'validate-nemk-backend keys))) ;; can it build hello with the non-enforcing Makefile backend?
  (apply 'validate-master keys)) ; does the xcvb master work?

(defun validate-hello (&key install-bin &allow-other-keys)
  (is (equal '("hello, world")
             (run-cmd/string (in-dir install-bin "hello") "-t"))
      "hello not working"))

(defun ensure-file-deleted (file)
  (ignore-errors (delete-file file)))

(defun validate-hello-build (build-target &rest keys
                             &key install-bin install-image xcvb-dir environment
                             &allow-other-keys)
  (ensure-directories-exist install-bin)
  (ensure-directories-exist install-image)
  (flet ((clean ()
           (ensure-file-deleted (in-dir xcvb-dir "examples/hello/setup.lisp"))
           (ensure-file-deleted (in-dir install-bin "hello"))))
    (clean)
    (apply 'run-make (in-dir xcvb-dir "examples/hello/") build-target environment)
    (apply 'validate-hello keys)
    (clean)))

(defun validate-mk-backend (&rest keys)
  (apply 'validate-hello-build "hello" keys))

(defun validate-nemk-backend (&rest keys &key parallelize implementation-type &allow-other-keys)
  (apply 'validate-hello-build "hello-using-nemk"
         :parallelize (and parallelize (not (eq implementation-type :clisp)))
         keys))

(defun validate-x2a (&rest keys)
  (apply 'validate-hello-build "hello-using-asdf" keys))

(defun validate-rmx (&rest keys &key xcvb build-dir xcvb-dir cl-source-registry &allow-other-keys)
  (ensure-directories-exist (in-dir build-dir "a2x_rmx/"))
  (rsync "-a" (in-dir xcvb-dir "test/a2x/") (in-dir build-dir "a2x_rmx/"))
  (let ((cl-source-registry (format nil "~A/a2x_rmx//:~A" build-dir cl-source-registry)))
    (apply 'validate-xcvb-ssr :source-registry cl-source-registry keys)
    (run-cmd xcvb 'rmx :build "/xcvb/test/a2x"
             :verbosity 9 :source-registry cl-source-registry)
    (is (not (probe-file* (in-dir build-dir "a2x_rmx/build.xcvb")))
        "xcvb rmx failed to remove build.xcvb")
    (dolist (l (is (directory (merge-pathnames* #p"a2x_rmx/*.lisp" build-dir))))
      (is (not (module-form-p (read-module-declaration l)))
          "xcvb rmx failed to delete module form from ~A" l))))

(defun validate-a2x (&key xcvb build-dir xcvb-dir &allow-other-keys)
  (ensure-directories-exist (in-dir build-dir "a2x_a2x/"))
  (rsync "-a" (in-dir xcvb-dir "test/a2x/") (in-dir build-dir "a2x_a2x/"))
  (run-cmd xcvb 'a2x :system "a2x-test" :name "/xcvb/test/a2x")
  (is (probe-file* (in-dir build-dir "a2x_a2x/build.xcvb"))
      "xcvb a2x failed to create build.xcvb")
  (dolist (l (is (directory (merge-pathnames* #p"a2x_a2x/*.lisp" build-dir))))
    (is (module-form-p (read-module-declaration l))
        "xcvb a2x failed to create module form for ~A" l)))

(defun validate-master (&key xcvb build-dir object-dir cl-source-registry implementation-type
                        &allow-other-keys)
  (let* ((driver
          (is (first
               (run-cmd/lines
                xcvb 'find-module :name "xcvb/driver" :short))))
         (out
          (run-program/read-output-string
           (xcvb::lisp-invocation-arglist
            :implementation-type implementation-type :lisp-path nil :load driver
            :eval (format nil "'(#.(xcvb-driver:bnl \"xcvb/hello\" ~
                     :output-path ~S :object-directory ~S :source-registry ~S :verbosity 9) ~
                     #.(let ((*print-base* 30)) (xcvb-hello::hello :name 716822547 :traditional t)))"
                          build-dir object-dir cl-source-registry)))))
    (is (search "hello, tester" out)
        "Failed to use hello through the XCVB master")))

(defun validate-slave (&key xcvb build-dir object-dir implementation-type &allow-other-keys)
  (let ((out
         (run-cmd/string
          xcvb 'slave-builder :build "/xcvb/hello"
          :lisp-implementation (string-downcase implementation-type)
          :object-directory object-dir :output-path build-dir)))
    (is (search "Your desires are my orders" out)
        "Failed to drive a slave ~(~A~) to build hello" implementation-type)))

(defun do-xxx-build (target &rest keys &key xcvb-dir &allow-other-keys)
  (apply 'run-make xcvb-dir target (make-environment keys)))

(defun do-asdf-build (&rest keys)
  (apply 'do-xxx-build "xcvb-using-asdf" keys))

(defun do-self-mk-build (&rest keys)
  (apply 'do-xxx-build "xcvb-using-asdf" keys))

(defun do-self-nemk-build (&rest keys)
  (apply 'do-xxx-build "xcvb-using-nemk" keys))

(defun do-bootstrapped-build (&rest keys)
  (apply 'do-xxx-build "xcvb-using-xcvb" keys))

(defun validate-xxx-build (fun &rest keys)
  (apply fun keys)
  (apply 'validate-xcvb keys))

(defun validate-asdf-build (&rest keys)
  (apply 'validate-xxx-build 'do-asdf-build keys))

(defun validate-mk-build (&rest keys)
  (apply 'validate-xxx-build 'do-self-mk-build keys))

(defun validate-nemk-build (&rest keys)
  (apply 'validate-xxx-build 'do-self-nemk-build keys))

(defun validate-bootstrapped-build (&rest keys)
  (apply 'validate-xxx-build 'do-bootstrapped-build keys))

(defun do-release-build (&rest keys &key release-dir build-dir &allow-other-keys)
  (rm-rfv (in-dir build-dir "obj/"))
  (apply 'run-make release-dir "install" (make-environment keys)))

(defun ensure-build-directories (&key object-dir install-bin install-image
                                 &allow-other-keys)
  (map () 'ensure-directories-exist
       (list object-dir install-bin install-image)))

(defun call-with-xcvb-build-dir (thunk &rest keys)
  (apply 'ensure-build-directories keys)
  (apply thunk keys)
  (apply 'clean-xcvb-dir keys))

(defun validate-current-xcvb (&rest keys)
  (asdf:find-system :xcvb)
  (compute-xcvb-dir-variables! keys :xcvb-dir (asdf:system-source-directory :xcvb))
  (apply 'validate-xcvb-dir keys)
  (apply 'clean-xcvb-dir keys)
  (call-with-xcvb-build-dir 'validate_xcvb keys))

(defun validate-xcvb-dir (&rest keys)
  (compute-xcvb-dir-variables! keys)
  (apply 'validate-xcvb-checkout keys)
  (apply 'clean-xcvb-dir keys)
  (call-with-xcvb-build-dir
   (lambda (&rest keys)
     (apply 'call-with-xcvb-build-dir 'validate_asdf_xcvb keys)
     (apply 'call-with-xcvb-build-dir 'validate_mk_xcvb keys)
     (apply 'call-with-xcvb-build-dir 'validate_nemk_xcvb keys))
   keys))

(defun validate-xcvb-dir-all-lisps (&rest keys)
  (compute-xcvb-dir-variables! keys)
  (dolist (implementation-type +xcvb-lisps+)
    (apply 'validate-xcvb-dir :implementation-type implementation-type keys)))

(defun clean-release-dir (&key xcvb-dir release-dir &allow-other-keys)
  (run-make xcvb-dir "clean")
  (rm-rfv (in-dir release-dir "build/")))

(defun call-with-release-build-dir (thunk &rest keys)
  (compute-release-dir-variables! keys)
  (apply 'clean-release-dir keys)
  (apply 'ensure-build-directories keys)
  (apply thunk keys)
  (apply 'clean-release-dir keys))

(defun validate-release-dir (&rest keys)
  (compute-release-dir-variables! keys)
  (apply 'validate-release-checkout keys)
  (call-with-release-build-dir 'validate-bootstrapped-xcvb keys)
  (call-with-release-build-dir 'validate-asdf-xcvb keys)
  (call-with-release-build-dir 'validate-mk-xcvb keys)
  (call-with-release-build-dir 'validate-nemk-xcvb keys))

(defun validate-release-dir-all-lisps (&rest keys)
  (compute-xcvb-dir-variables! keys)
  (dolist (implementation-type +xcvb-lisps+)
    (apply 'validate-release-dir :implementation-type implementation-type keys)))

(defmacro letk1 (keys var val &body body)
  `(let ((,var ,val))
     (setf (getf ,keys ,(conc-keyword var)) ,var)
     ,@body))
(defmacro letk* (keys bindings &body body)
  (if bindings
      `(letk1 ,keys ,@(first bindings) (letk* keys ,(rest bindings) ,@body))
      `(progn ,@body)))

(defun finalize-variables (&rest keys &key
                           implementation-type object-dir build-dir
                           install-bin install-lisp install-image install-source install-systems
                           cl-source-registry
                           (parallelize () parallelizep)
                           &allow-other-keys)
  (letk* keys
      ((implementation-type (or implementation-type *lisp-implementation-type*))
       (build-dir (pathname build-dir))
       (object-dir (or object-dir (in-dir build-dir "obj/")))
       (install-bin (or install-bin (in-dir build-dir "bin/")))
       (install-lisp (or install-lisp (in-dir build-dir "common-lisp/")))
       (install-image (or install-image (in-dir build-dir "images/")))
       (install-source (or install-source (in-dir build-dir "source/")))
       (install-systems (or install-systems (in-dir build-dir "systems/")))
       (parallelize (if parallelizep parallelize
                        (let ((ncpus (parse-integer
                                      (run-program/read-output-string
                                       "cat /proc/cpuinfo|grep '^processor' | wc -l")
                                      :junk-allowed t)))
                          (format nil "-l~A" (1+ ncpus)))))
       (path (format nil "~A:~@[~A~]" install-bin (getenv "PATH")))
       (cl-launch-flags (format nil "--lisp ~(~A~) --source-registry ~S"
                                implementation-type cl-source-registry))
       (asdf-output-translations (format nil "/:~A/cache/" build-dir)))
    keys))

(defun compute-release-dir-variables (&rest keys &key release-dir &allow-other-keys)
  (letk* keys
      ((release-dir (pathname release-dir))
       (xcvb-dir (in-dir release-dir "xcvb/"))
       (build-dir (in-dir release-dir "build/"))
       (cl-source-registry
        (format nil "~A//:~A//:~A/dependencies//"
                build-dir xcvb-dir release-dir)))
    (apply 'finalize-variables keys)))

(defun compute-xcvb-dir-variables (&rest keys &key xcvb-dir &allow-other-keys)
  (letk* keys
      ((build-dir (in-dir xcvb-dir "build/"))
       (cl-source-registry
        (format nil "~A//:~A//:~@[~A~]"
                build-dir xcvb-dir (getenv "CL_SOURCE_REGISTRY"))))
    (apply 'finalize-variables keys)))
