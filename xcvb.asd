;;; -*- mode: lisp -*-
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;                                                                  ;;;
;;; Free Software available under an MIT-style license. See LICENSE  ;;;
;;;                                                                  ;;;
;;; Copyright (c) 2008-2010 ITA Software, Inc.  All rights reserved. ;;;
;;;                                                                  ;;;
;;; Original authors: Spencer Brody, Francois-Rene Rideau            ;;;
;;;                                                                  ;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(in-package :asdf)
(load-system :asdf)
(let ((min "2.014")
      (ver (#+asdf2 asdf-version)))
  (unless (and ver (version-satisfies ver min))
    (error "XCVB requires ASDF ~D or later, you only have ~D" min ver)))

(when (plusp (length (getenv "XCVB_FARMER")))
  (pushnew :xcvb-farmer *features*))

(pushnew :xcvb-using-asdf *features*)

#+sbcl
(map () 'require
     '(;; Actually used by XCVB
       :sb-grovel :sb-posix :sb-sprof
       ;; Used by SLIME
       :sb-cltl2 :sb-introspect :sb-bsd-sockets))

(proclaim '(optimize (speed 2) (safety 3) (debug 3) (compilation-speed 0)))

(asdf:defsystem :xcvb
    :author ("Francois-Rene Rideau" "Spencer Brody" "Joyce Chen")
    :maintainer "Francois-Rene Rideau"
    :licence "MIT"
    :description "XCVB"
    :long-description "an eXtensible Component Verifier and Builder for Lisp.
XCVB provides a scalable system to build large software in Lisp, featuring
deterministic separate compilation and enforced locally-declared dependencies."
    :depends-on (:asdf
                 :xcvb-driver :xcvb-master
                 :fare-utils :command-line-arguments
                 :asdf-dependency-grovel :closer-mop
                 :fare-matcher :fare-quasiquote-readtable
                 :ironclad :binascii :babel
                 #+xcvb-farmer :quux-iolib
                 :rucksack)
    :components
    ((:file "pkgdcl")
     (:file "conditions" :depends-on ("pkgdcl"))
     (:file "specials" :depends-on ("pkgdcl"))
     (:file "macros" :depends-on ("pkgdcl"))
     (:file "profiling" :depends-on ("pkgdcl"))
     (:file "utilities" :depends-on ("macros"))
     (:file "logging" :depends-on ("specials"))
     (:file "lisp-invocation" :depends-on ("specials"))
     (:file "main" :depends-on ("specials"))
     (:file "string-escape" :depends-on ("utilities"))
     (:file "virtual-pathnames" :depends-on ("specials" "utilities"))
     (:file "grain-interface" :depends-on ("utilities" "conditions"))
     (:file "grain-sets" :depends-on ("grain-interface"))
     (:file "registry" :depends-on ("grain-interface" "specials"))
     (:file "search-path" :depends-on ("registry" "main"))
     (:file "computations" :depends-on ("grain-interface" "registry"))
     (:file "manifest" :depends-on ("macros" "virtual-pathnames"))
     (:file "extract-target-properties" :depends-on ("string-escape" "lisp-invocation"))
     (:file "grain-implementation" :depends-on ("registry" "extract-target-properties"))
     (:file "names" :depends-on ("registry" "grain-interface"))
     (:file "normalize-dependency" :depends-on ("names" "grain-interface"))
     (:file "traversal" :depends-on ("names" "computations"))
     (:file "change-detection" :depends-on ("traversal"))
     (:file "dependencies-interpreter" :depends-on ("normalize-dependency" "traversal"))
     (:file "static-traversal" :depends-on ("grain-sets" "dependencies-interpreter"))
     (:file "external-commands" :depends-on ("specials" "utilities" "grain-interface"))
     (:file "driver-commands" :depends-on ("specials" "utilities" "grain-interface" "external-commands"))
     (:file "run-program-backend" :depends-on ("profiling" "static-traversal" "driver-commands"
					       "computations" "main" "virtual-pathnames"))
     (:file "makefile-backend" :depends-on ("profiling" "static-traversal" "driver-commands"
					    "computations" "main" "virtual-pathnames"))
     (:file "simplifying-traversal" :depends-on ("traversal" "dependencies-interpreter"))
     (:file "list-files" :depends-on ("simplifying-traversal" "main"))
     (:file "asdf-backend" :depends-on ("simplifying-traversal" "logging" "main"))
     (:file "ne-makefile-backend" :depends-on ("main" "makefile-backend"
                                               "asdf-backend" "simplifying-traversal"))
     (:file "asdf-converter" :depends-on ("main" "grain-interface" "search-path"))
     (:file "slave" :depends-on ("main"))
     #+xcvb-farmer
     (:file "farmer" :depends-on ("profiling" "main" "driver-commands"
                                  "grain-interface" "dependencies-interpreter"))
     (:file "cffi-grovel-support" :depends-on
            ("makefile-backend" "static-traversal" "computations" "driver-commands"
                                "grain-implementation" "asdf-backend"))
     (:file "version" :depends-on ("specials"))))
