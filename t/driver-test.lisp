#|
for l in ccl clisp sbcl cmucl ecl abcl xcl scl allegro # lispworks gclcvs
do cl-launch -l $l -s xcvb-driver-test -iw '(xcvb-driver-test:xcvb-driver-test)' ; done
|#
#+xcvb
(module (:description "Unit test package for XCVB-Driver"
         :build-depends-on ("/asdf" "/xcvb/driver")))

(in-package #:cl)

(defpackage #:xcvb-driver-test
  (:use :xcvb-driver :cl)
  (:export
   #:xcvb-driver-test))

(in-package #:xcvb-driver-test)

(declaim (optimize (debug 3) (safety 3)))

;;#+allegro (trace excl:run-shell-command sys:reap-os-subprocess)
;;#+lispworks (trace system:run-shell-command system:pid-exit-status)

;; Poor man's test suite, lacking stefil.
(defmacro deftest (name formals &body body)
  `(defun ,name ,formals ,@body))
(defmacro is (x)
  `(progn
     (format! *error-output* "~&Checking whether ~S~%" ',x)
     (assert ,x)))
(defmacro signals (condition sexp)
  `(progn
     (format! *error-output* "~&Checking whether ~S signals ~S~%" ',sexp ',condition)
     (handler-case
         ,sexp
       (,condition () t)
       (t (c)
         (error "Expression ~S raises signal ~S, not ~S" ',sexp c ',condition))
       (:no-error ()
         (error "Expression ~S fails to raise condition ~S" ',sexp ',condition)))))

#|
Testing run-program/process-output-stream through its derivatives:
run-program/read-output-lines
run-program/read-output-string
run-program/read-output-form
run-program/read-output-forms
run-program/echo-output
|#

;; We add a newline to the end of a string and return it.
;; We do it in this specific manner so that under unix, windows and macos,
;; format will choose the correct type of newline delimiters
(defun nl (str)
  (format nil "~A~%" str))


;; Convert the input format to a string stream, read it into a string,
;; and see if they match.
(defun slurp-stream-string/check (input-string &key (test #'string=))
  (let ((input-string (format nil input-string)))
    (with-open-stream (s (make-string-input-stream input-string))
      (is (funcall test input-string (slurp-stream-string s))))))

;; Call with a bunch of strings to call the above function upon.
(defun slurp-stream-string/checks (&rest input-string-list)
  (dolist (input-string input-string-list)
    (funcall #'slurp-stream-string/check input-string)))

;; Check to see if the input-string ins converted correctly to the
;; output-form
(defun slurp-stream-lines/check (input-string output-form &key (test #'equal))
  (let ((input-string (format nil input-string)))
    (with-open-stream (s (make-string-input-stream input-string))
      (is (funcall test output-form (slurp-stream-lines s))))))

;; Check to see if the individual input/output lists passed into this
;; function are correct.
(defun slurp-stream-lines/checks (&rest control-forms)
  (dolist (form control-forms)
    (destructuring-bind (input-string output-form) form
      (funcall #'slurp-stream-lines/check input-string output-form))))

(deftest test/slurp-stream-string ()
  ;; Check to make sure the string is exactly what it is when read
  ;; back through a stream. This is a format specifier so we can
  ;; portably test newline processing.
  (slurp-stream-string/checks
   ""
   " "
   "~%"
   "~%~%"
   "~%~%~%"
   "one~%two~%three~%~%four"
   "one two three four"
   "one two~%three four")

  ;; Check some boundary cases on the types passed.
  (signals error (slurp-stream-string nil))
  (signals error (slurp-stream-string 42))
  (signals error (slurp-stream-string "not valid"))
  t)

(deftest test/slurp-stream-lines ()
  (slurp-stream-lines/checks
   ;; input-string first, then expected output-form after its parsing
   '("" nil)
   '(" " (" "))
   '("~%" (""))
   '("~%~%" ("" ""))
   '("~%~%~%" ("" "" ""))
   '("foo" ("foo"))
   '("~%foo" ("" "foo"))
   '("~%foo~%" ("" "foo")) ; consumes last newline!
   '("one~%two~%~%three" ("one" "two" "" "three"))
   '("one~%two~%~%three~%" ("one" "two" "" "three"))
   '("one two three four" ("one two three four"))
   '("one two~%three four~%" ("one two" "three four")))

  ;; Check some boundary cases on the types passed.
  ;; NOTE: NIL is ok since it means read from stdin!
  (signals error (slurp-stream-lines 42))
  (signals error (slurp-stream-lines "not valid"))
  t)

(defun common-test/run-program/process-output-stream ()
  ;; Test that the 'echo' program can echo a single string.
  ;; Use the output-processor of slurp-stream-lines.
  (is (equal '("string")
             (run-program/read-output-lines '("echo" "string"))))

  ;; Test that the 'echo' program can echo a single string.
  ;; Use the output-processor of slurp-stream-string.
  (is (equal (nl "string")
             (run-program/read-output-string '("echo" "string"))))

  ;; Test that the 'echo' program can echo an argument with a space.
  ;; Use the output-procesor of slurp-stream-lines.
  (is (equal '("Hello World")
             (run-program/read-output-lines '("echo" "Hello World"))))

  ;; Test that the 'echo' program can echo an argument with a space.
  ;; Use the output-processor of slurp-stream-string.
  (is (equal (nl "Hello World")
             (run-program/read-output-string '("echo" "Hello World"))))

  ;; Test that the 'echo' program can echo an argument with a space.
  ;; Use the output-processor of slurp-stream-string. Also use the
  ;; command string form.
  (is (equal (nl "Hello World")
             (run-program/read-output-string "echo Hello World")))

  ;; Test that run-program/process-output-stream fails properly with an
  ;; empty program string
  #+(or clozure (and allegro os-unix) cmu (and lispworks os-unix) sbcl scl)
  (signals error (run-program/read-output-lines '("")))

  ;; An empty string itself is ok since it is passed to the shell.
  (is (equal "" (run-program/read-output-string "")))

  ;; Test that run-program/process-output-stream fails properly with a
  ;; nil program list
  #+(or clozure (and allegro os-unix) cmu sbcl scl)
  (signals error (run-program/read-output-lines nil))

  ;; Test that run-program/process-output-stream fails properly when the
  ;; executable doesn't exist.
  (signals error (run-program/read-output-lines '("does-not-exist")))
  (signals error (run-program/read-output-lines "does-not-exist"))

  (is (equal 0 (run-program/for-side-effects "echo ok")))
  (is (equal 0 (run-program/for-side-effects '("echo" "ok"))))
  t)


(defun unix-only-test/run-program/process-output-stream ()

  (is (equal 0 (run-program/for-side-effects "true")))
  (signals error (run-program/for-side-effects "false"))
  (is (equal 1 (run-program/for-side-effects "false" :ignore-error-status t)))

  (let ((tf (native-namestring (asdf:system-relative-pathname :xcvb "t/test-file"))))

    ;; a basic smoke test
    (is (equal '("Single")
               (run-program/read-output-lines
                `("/bin/grep" "Single" ,tf))))

    ;; Make sure space is handled correctly
    (is (equal '("double entry")
               (run-program/read-output-lines
                `("/bin/grep" "double entry" ,tf))))

    ;; Make sure space is handled correctly
    (is (equal '("triple word entry")
               (run-program/read-output-lines
                `("/bin/grep" "triple word entry" ,tf))))

    ;; Testing special characters
    (loop :for char :across "+-_.,%@:/\\!&*(){}"
      :for str = (string char) :do
      (is (equal (list (format nil "escape ~A" str))
                 (run-program/read-output-lines
                  `("/bin/grep" ,(format nil "[~A]" str) ,tf)))))

    ;; Test that run-program/process-output-stream signals an error
    ;; with an executable that doesn't return 0
    (signals error (run-program/read-output-lines '("/bin/false")))

    ;; Test that we can suppress the error on run-program/process-output-stream
    (is (null (run-program/read-output-lines '("/bin/false")
                                             :ignore-error-status t))))
  t)

(defun windows-only-test/run-program/process-output-stream ()

  ;; a basic smoke test
  (is (equal (run-program/read-output-lines '("cmd" "/c" "echo" "ok"))
             '(("ok"))))

  t)

(deftest test/run-program/process-output-stream ()
  #+os-unix (common-test/run-program/process-output-stream)
  #+os-unix (unix-only-test/run-program/process-output-stream)
  #+os-windows (windows-only-test/run-program/process-output-stream)
  (terpri)
  t)

(defun xcvb-driver-test ()
  (test/run-program/process-output-stream))
