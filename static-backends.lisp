(in-package :xcvb)

(defparameter *nodes* (make-hash-table :test 'equal)
  "Grains in the graph, ")

(define-simple-dispatcher graph-for #'graph-for-atom)

(defun graph-for (env spec)
  ;; TODO: caching? yes, but based on full-names, not local names.
  ;; can we resolve local names early, as part of a first syntax-checking pass?
  (graph-for-dispatcher env spec))

(defun graph-for* (spec)
  (graph-for () spec))

(defun graph-for-compiled (spec)
  (graph-for () (compiled-dependency spec)))

(defun load-command-for* (spec)
  (load-command-for #'graph-for* spec))

(defun graph-for-atom (grapher atom)
  (declare (ignore grapher))
  (graph-for-atom* atom))

(defgeneric graph-for-atom* (atom))

(defmethod graph-for-atom* ((name string))
  (graph-for-lisp-module name))

(define-graph-for :build (env name)
  (declare (ignore env))
  (graph-for-build-grain (registered-grain (canonicalize-fullname name))))

(defun graph-for-build-grain (grain)
  (check-type grain build-grain)
  (handle-lisp-dependencies grain)
  (let* (;;; Build pre-image if needed
         (pre-image
          (when (build-requires grain)
            (graph-for-image-grain
             (build-pre-image-name grain)
             (build-requires grain))))
         (*lisp-image-name*
          (if pre-image
            (fullname pre-image)
            *lisp-image-name*)))
    ;;; build post-image if needed
    (let* ((post-image-name (build-image-name grain)))
      (if post-image-name
        (graph-for-image-grain
         post-image-name
         (load-dependencies grain))
        (make-phony-grain
         :name `(:build ,(fullname grain))
         :dependencies (mapcar #'graph-for*
                               (remove-duplicates
                                (append (compile-dependencies grain)
                                        (load-dependencies grain))
                                :test #'equal)))))))

(defun graph-for-image-grain (name dependencies)
  (let* ((grain
          (make-grain 'image-grain
            :fullname `(:image ,name)))
         (dependency-grains
          (mapcar #'graph-for* dependencies)))
    (make-computation 'concrete-computation
      :outputs (list grain)
      :inputs dependency-grains
      :command
      `(:lisp
        (:image ,*lisp-image-name*)
        ,@(mapcar #'load-command-for* dependencies)
        (:save-image ,name)))
    grain))


(defun graph-for-lisp-module (name)
  (resolve-module-name name *build*))

(define-graph-for :lisp (env lisp)
  "Lisp file to load without compiling it"
  (declare (ignore env))
  (check-type lisp lisp-grain)
  lisp)

(define-graph-for :asdf (env system-name)
  (declare (ignore env))
  (make-phony-grain
   :name `(:asdf ,system-name)
   :dependencies nil)) ;;TODO: make corresponding computation?

(define-graph-for :fasl (env lisp-name)
  (declare (ignore env))
  (first (graph-for-fasls lisp-name)))

(define-graph-for :cfasl (env lisp-name)
  (declare (ignore env))
  (second (graph-for-fasls lisp-name)))

(defun graph-for-fasls (fullname)
  (check-type fullname string)
  (let ((lisp (resolve-absolute-module-name fullname)))
    (check-type lisp lisp-grain)
    (handle-lisp-dependencies lisp)
    (let* ((dependencies (compile-dependencies lisp))
           (inputs (mapcar #'graph-for* dependencies))
           (outputs (fasl-grains-for-name fullname)))
      (make-computation
       'concrete-computation
       :outputs outputs
       :inputs inputs
       :command
       `(:lisp
         (:image ,*lisp-image-name*)
         ,@(mapcar #'load-command-for* dependencies)
         (:compile-lisp ,fullname)))
      outputs)))
