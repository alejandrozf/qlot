(defpackage #:qlot/local-init/setup
  (:use #:cl))
(in-package #:qlot/local-init/setup)

(defun setup-source-registry ()
  #+ros.init (setf roswell:*local-project-directories* nil)
  (let* ((source-registry (ql-setup:qmerge "source-registry.conf"))
         (local-source-registry-form
           (and (uiop:file-exists-p source-registry)
                (uiop:read-file-form source-registry)))
         (project-root
           (uiop:pathname-parent-directory-pathname ql:*quicklisp-home*)))
    (asdf:initialize-source-registry
     (if local-source-registry-form
         (append local-source-registry-form
                 `((:tree ,project-root)))
         (let* ((config-file (ql-setup:qmerge "qlot.conf"))
                (qlot-source-directory
                  (and (uiop:file-exists-p config-file)
                       (getf (uiop:read-file-form config-file) :qlot-source-directory))))
           `(:source-registry :ignore-inherited-configuration
             (:also-exclude ".qlot")
             (:also-exclude ".bundle-libs")
             (:also-exclude ".direnv")
             ,@(and qlot-source-directory
                    `((:directory ,qlot-source-directory)))
             (:tree ,project-root)))))))

(pushnew :qlot.project *features*)
(setup-source-registry)
