(in-package :xcvb)

;;TODO: add docstrings to those variables

;;TODO: choose -internal or -helper as your convention for all helpers/internals

;;TODO: make the name always a keyword, early

;;TODO: have an around method for fullnames and visiting stuff.

(defvar *visited-nodes*)
(defvar *build-requires-written-nodes*)
(defvar *main-files-written-nodes*)
(defvar *writing-build-requires-module* nil ;TODO: **-p
  "")
(defvar *build-requires-graph*)


(defun find-asdf-systems (dependency-graph)
  "Returns a list of the names of all the asdf-systems
that any node in the dependency-graph depends on"
  (find-asdf-systems-helper dependency-graph))


(defgeneric find-asdf-systems-helper (node)
  (:documentation "Helper generic function for find-asdf-systems.  Returns a
list of the names of all the asdf-systems that this node depends on (or any of
its dependencies depend on)"))

(defmethod find-asdf-systems-helper :around ((node dependency-graph-node))
  ;; If this node has already been looked at, don't look at it again.
  (unless (gethash (fullname node) *visited-nodes*)
    ;; Add this node to the map of nodes already visited.
    (setf (gethash (fullname node) *visited-nodes*) t)
    (call-next-method)))

(defmethod find-asdf-systems-helper ((node asdf-system-node))
  (list (strcat ":" (name node))))

(defmethod find-asdf-systems-helper ((node dependency-graph-node-with-dependencies))
  (remove-duplicates
   (mapcan (lambda (dependency-node)
             (find-asdf-systems-helper dependency-node))
           (append (compile-dependencies node) (load-dependencies node)))
   :test #'equal))

(defmethod find-asdf-systems-helper ((node image-dump-node))
  (find-asdf-systems-helper (lisp-image node)))

(defmethod find-asdf-systems-helper ((node dependency-graph-node))
  nil)


(defun write-asdf-system-header (filestream dependency-graph &optional (build-module *build-module*))
  "Writes the information from the build module to the asdf file"
  (let* ((system-name (namestring 
                       (make-pathname :name nil 
                                      :type nil 
                                      :defaults (fullname build-module)))) ;NUN
         ;;TODO: document, for it is fragile
         (system-name (subseq system-name 1 (1- (length system-name)))))
    (format filestream "~&(asdf:defsystem :~a~%" system-name))
  (if (author build-module)
    (format filestream "~2,0T:author ~s~%" (author build-module)))
  (if (maintainer build-module)
    (format filestream "~2,0T:maintainer ~s~%" (maintainer build-module)))
  (if (version build-module)
    (format filestream "~2,0T:version ~s~%" (version build-module)))
  (if (licence build-module)
    (format filestream "~2,0T:licence ~s~%" (licence build-module)))
  (if (description build-module)
    (format filestream "~2,0T:description ~s~%" (description build-module)))
  (if (long-description build-module)
    (format filestream "~2,0T:long-description ~s~%" (long-description build-module)))
  (let* ((*visited-nodes* (make-hash-table :test #'equal))
         (asdf-systems (append
                        (find-asdf-systems-helper *build-requires-graph*)
                        (find-asdf-systems dependency-graph))))
    (if asdf-systems
      (format filestream "~2,0T:depends-on~a~%" asdf-systems))))


(defgeneric write-node-to-asd-file (filestream node)
  (:documentation "Writes information about the given node and its dependencies 
to the filestream that can be put in the components section of an asd file"))


(defmethod write-node-to-asd-file (filestream (node lisp-node))
  (dolist (dep (append (compile-dependencies node) 
                       (load-dependencies node)))
    (write-node-to-asd-file filestream dep)))

(defmethod write-node-to-asd-file (filestream (node object-file-node))
  (let ((written-nodes
         (if *writing-build-requires-module*
           *build-requires-written-nodes*
           *main-files-written-nodes*)))
    (unless (or (gethash (namestring (make-pathname :type "fasl" 
                                                    :defaults (fullname node)))
                         written-nodes) ;NUN
                (gethash (namestring (make-pathname :type "cfasl" 
                                                    :defaults (fullname node)))
                         written-nodes));If this node has already been written to the makefile, don't write it again. ;NUN
      (setf (gethash (fullname node) written-nodes) t);Add this node to the map of nodes already written to the makefile
      (let ((dependencies 
             (if *writing-build-requires-module*
               (nunion (rest (compile-dependencies node)) 
                       (load-dependencies node))
               (remove-if
                (lambda (dep) 
                  (gethash (fullname dep) *build-requires-written-nodes*))
                (nunion (rest (compile-dependencies node)) 
                        (load-dependencies node))))))
        (when dependencies
          (dolist (dep dependencies)
            (write-node-to-asd-file filestream dep)))
        (format filestream "~13,0T(:file ~s~@[ :depends-on ~s~])~%"
                (namestring (make-pathname 
                             :type nil 
                             :defaults (enough-namestring (source-filepath node)
                                                          *buildpath*))) ;NUN
                (mapcar 
                 (lambda (node) (namestring (make-pathname 
                                             :type nil 
                                             :defaults (enough-namestring 
                                                        (source-filepath node) 
                                                        *buildpath*)))) ;NUN
                 (remove-if-not (lambda (dep) (typep dep 'object-file-node)) 
                                dependencies)))))))


(defmethod write-node-to-asd-file (filestream (node dependency-graph-node))
  (declare (ignore filestream node)))


(defun write-asd-file (source-path output-path)
  "Writes an asd file to output-path that can be used to compile the file at source-path with asdf"
  (with-open-file (out output-path :direction :output :if-exists :supersede)
    (let ((*build-requires-written-nodes* (make-hash-table :test #'equal))
          (*main-files-written-nodes* (make-hash-table :test #'equal))
          (dependency-graph (create-dependency-graph source-path))
          (*build-requires-graph* (create-lisp-node 
                                   (build-requires *build-module*))))
      (write-asdf-system-header out dependency-graph)
      (let ((*writing-build-requires-module* T))
        (format out 
                "~2,0T:components~%~2,0T((:module \"build-requires-files\"~%~
~12,0T:pathname #p\".\"~%~12,0T:components~%~12,0T(")
        (write-node-to-asd-file out *build-requires-graph*))
      (let ((*writing-build-requires-module* nil))
        (format out 
                "~12,0T))~%~3,0T(:module \"main-files\"~%~
~12,0T:pathname #p\".\"~%~12,0T:depends-on(\"build-requires-files\")~%~
~12,0T:components~%~12,0T(")
        (write-node-to-asd-file out dependency-graph))
      (let* ((system-name (namestring ;NUN
                           (make-pathname :name nil 
                                          :type nil 
                                          :defaults (fullname *build-module*))))
             (system-name (subseq system-name 1 (- (length system-name) 1))))
        (format out "~12,0T)))~%~%(cl:pushnew :~a *features*)" system-name)))))
