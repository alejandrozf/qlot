(defpackage #:qlot.source.ql
  (:nicknames #:qlot/source/ql)
  (:use #:cl
        #:qlot/source)
  (:import-from #:qlot/util
                #:make-keyword
                #:starts-with
                #:split-with
                #:find-qlfile
                #:with-package-functions)
  (:import-from #:qlot/http
                #:http-get)
  (:export #:source-ql
           #:source-ql-all))
(in-package #:qlot/source/ql)


(defparameter *default-distribution*
  "http://beta.quicklisp.org/dist/quicklisp.txt")

(defparameter *quicklisp-versioned-distinfo*
  "http://beta.quicklisp.org/dist/quicklisp/{{version}}/distinfo.txt")


(defclass source-ql (source)
  ((%version :initarg :%version)
   (distribution :initarg :distribution
                 :reader source-distribution)
   (%distinfo :accessor source-distinfo)))

(defclass source-ql-all (source)
  ((%version :initarg :%version)
   (distribution :initarg :distribution
                 :reader source-distribution)
   (%distinfo :accessor source-distinfo)))


(defun set-default-distribution (instance)
  (when (not (slot-boundp instance 'distribution))
    (setf (slot-value instance 'distribution)
          *default-distribution*))

  ;; Now we may be need to update distribution's url
  ;; if it should contain a version number
  (let ((version (slot-value instance '%version)))
    (when (not (eql version
                    :latest))
      (setf (slot-value instance 'distribution)
            (get-versioned-distribution-url instance version)))))

(defmethod initialize-instance :after ((instance source-ql)
                                       &rest initargs)
  (declare (ignorable initargs))
  (set-default-distribution instance))


(defmethod initialize-instance :after ((instance source-ql-all)
                                       &rest initargs)
  (declare (ignorable initargs))
  (set-default-distribution instance)

  ;; If project name wasn't specified, we'll extract it from
  ;; distribution's metadata
  (unless (slot-boundp instance 'project-name)
    (setf (slot-value instance 'project-name)
          (retrieve-quicklisp-metadata-item instance :name))))

(defmethod defrost-source :after ((source source-ql))
  (when (slot-boundp source 'version)
    (setf (slot-value source 'distribution)
          (let ((*standard-output* (make-broadcast-stream))
                (*error-output* (make-broadcast-stream))
                (*trace-output* (make-broadcast-stream)))
            (get-versioned-distribution-url source (source-ql-version source))))
    ;; KLUDGE: Delete the wrong cached distinfo because of the above function call.
    (slot-makunbound source '%distinfo)))

(defmethod defrost-source :after ((source source-ql-all))
  (when (slot-boundp source 'version)
    (setf (slot-value source 'distribution)
          (get-versioned-distribution-url source (slot-value source 'version)))))

(defun get-distribution-url-pattern (source)
  (check-type source (or source-ql
                         source-ql-all))

  (cond ((string-equal (source-distribution source)
                       *default-distribution*)
         *quicklisp-versioned-distinfo*)
        (t
         (let ((url (retrieve-quicklisp-metadata-item source
                                                      :distinfo-template-url
                                                      *quicklisp-versioned-distinfo*)))
           (unless url
             (error "There is no \"distinfo-template-url\" in metadata at ~A"
                    (source-distribution source)))
           (values url)))))

(defun replace-version (value version)
  (check-type value string)
  (with-output-to-string (*standard-output*)
    (loop with i = 0
          for pos = (search "{{version}}" value :start2 i)
          do (princ (subseq value i pos))
          if pos
            do (princ version)
               (setf i (+ pos (length "{{version}}")))
          while pos)))

(defun get-versioned-distribution-url (source version)
  (check-type source (or source-ql
                         source-ql-all))
  (check-type version string)

  (let ((url-pattern (get-distribution-url-pattern source)))
    (replace-version url-pattern version)))


(defmethod make-source ((source (eql :ql)) &rest args
                        &key distribution
                          &allow-other-keys)
  (remf args :distribution)

  (destructuring-bind (project-name version) args
    (let ((distribution (or distribution
                            (if (eq version :latest)
                                *default-distribution*
                                (replace-version *quicklisp-versioned-distinfo* version)))))
      (if (eq project-name :all)
          (make-instance 'source-ql-all
                         :distribution distribution
                         :%version version)
          (make-instance 'source-ql
                         :project-name project-name
                         :distribution distribution
                         :%version version)))))

(defmethod print-object ((source source-ql-all) stream)
  (with-slots (project-name %version version) source
    (print-unreadable-object (source stream :type t :identity t)
      (format stream "~A ~A~:[~;~:*(~A)~]"
              (if (slot-boundp source 'project-name)
                  (if (stringp project-name)
                      project-name
                      (prin1-to-string project-name))
                  "<unknown>")
              (if (stringp %version)
                  %version
                  (prin1-to-string %version))
              (and (slot-boundp source 'version)
                   (source-version source))))))

(defmethod print-object ((source source-ql) stream)
  (with-slots (project-name %version) source
    (format stream "#<~S ~A ~A>"
            (type-of source)
            (if (stringp project-name)
                project-name
                (prin1-to-string project-name))
            (if (stringp %version)
                %version
                (prin1-to-string %version)))))

(defmethod prepare ((source source-ql-all))
  (unless (slot-boundp source 'version)
    (setf (source-version source)
          (if (eq (slot-value source '%version) :latest)
              (ql-latest-version source)
              (slot-value source '%version)))))

(defmethod prepare ((source source-ql))
  (setf (source-version source)
        (format nil "ql-~A" (source-ql-version source))))

(defmethod source-equal ((source1 source-ql-all) (source2 source-ql-all))
  (and (string= (source-project-name source1)
                (source-project-name source2))
       (string= (slot-value source1 '%version)
                (slot-value source2 '%version))))

(defmethod source-equal ((source1 source-ql) (source2 source-ql))
  (and (string= (source-project-name source1)
                (source-project-name source2))
       (string= (slot-value source1 '%version)
                (slot-value source2 '%version))))

(defun ql-latest-version (source)
  (check-type source (or source-ql source-ql-all))
  (let ((quicklisp.txt (http-get (source-distribution source))))
    (or
     (loop for line in (split-with #\Newline quicklisp.txt)
           when (starts-with "version: " line)
             do (return (subseq line 9)))
     (error "Failed to get the latest version of Quicklisp."))))


(defun retrieve-metadata (source)
  (check-type source (or source-ql
                         source-ql-all))
  (when (slot-boundp source '%distinfo)
    (return-from retrieve-metadata
      (source-distinfo source)))

  (let* ((url (source-distribution source))
         (dist-metadata (http-get url)))
    (flet ((trim (text)
             (string-trim '(#\Space #\Tab) text)))
      (setf (source-distinfo source)
            (loop for line in (split-with #\Newline dist-metadata)
                  for splitted = (split-with #\: line :limit 2)
                  for key = (make-keyword (trim (first splitted)))
                  for value = (second splitted)
                  for trimmed-value = (trim value)
                  when value
                    appending (list key trimmed-value))))))


(defun retrieve-quicklisp-metadata-item (source item-name &optional default)
  (check-type source (or source-ql
                         source-ql-all))
  (check-type item-name keyword)

  (let* ((metadata (retrieve-metadata source))
         (value (getf metadata item-name default)))
    (unless value
      (error "Failed to get a value of ~A for ~A distribution."
             item-name
             (source-distribution source)))
    value))

(defun retrieve-quicklisp-releases (source)
  (http-get (retrieve-quicklisp-metadata-item source
                                              :release-index-url)))

(defun retrieve-quicklisp-systems (source)
  (http-get (retrieve-quicklisp-metadata-item source
                                              :system-index-url)))

(defun source-ql-releases (source)
  (with-slots (project-name) source
    (let* ((version (source-ql-version source))
           (releases.txt (retrieve-quicklisp-releases source)))
      (loop with project-name/sp = (concatenate 'string project-name " ")
            for line in (split-with #\Newline releases.txt)
            when (starts-with project-name/sp line)
              do (return (split-with #\Space line))
            finally
               (error "~S doesn't exist in quicklisp ~A."
                      project-name
                      version)))))

(defun source-ql-systems (source)
  (with-slots (project-name) source
    (let ((systems.txt (retrieve-quicklisp-systems source)))
      (loop with project-name/sp = (concatenate 'string project-name " ")
            for line in (split-with #\Newline systems.txt)
            when (starts-with project-name/sp line)
              collect (split-with #\Space line)))))

(defgeneric source-ql-version (source)
  (:method ((source source-ql))
    (if (slot-boundp source 'version)
        ;; Omit 'ql-' prefix.
        (subseq (source-version source) 3)
        (with-slots (%version) source
          (if (eq %version :latest)
              (ql-latest-version source)
              %version))))
  (:method ((source source-ql-all))
    (with-slots (version) source
      (if (eq version :latest)
          (ql-latest-version source)
          version))))

(defmethod distinfo.txt ((source source-ql))
  (let* ((data (list :name                      (source-project-name source)
                     :version                   (source-version source)
                     :system-index-url          (url-for source 'systems.txt)
                     :release-index-url         (url-for source 'releases.txt)
                     :canonical-distinfo-url    (url-for source 'distinfo.txt)
                     :distinfo-subscription-url (url-for source 'project.txt)))
         (archive-url (retrieve-quicklisp-metadata-item source :archive-base-url)))
    (when archive-url
      (setf data
            (list* :archive-base-url archive-url
                   data)))

    (format nil "~{~(~A~): ~A~%~}"
            data)))

(defmethod systems.txt ((source source-ql))
  (format nil "# project system-file system-name [dependency1..dependencyN]~%~{~{~A~^ ~}~%~}"
          (source-ql-systems source)))

(defmethod releases.txt ((source source-ql))
  (format nil "# project url size file-md5 content-sha1 prefix [system-file1..system-fileN]~%~{~A~^ ~}~%"
          (source-ql-releases source)))


(defmethod url-path-for ((source source-ql-all) (for (eql 'project.txt)))
  (prepare source)
  (source-distribution source))
