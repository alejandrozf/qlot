(defpackage #:qlot/util
  (:use #:cl)
  (:export #:*system-quicklisp-home*
           #:*qlfilename*
           #:with-quicklisp-home
           #:with-package-functions
           #:pathname-in-directory-p
           #:find-qlfile
           #:call-in-local-quicklisp
           #:with-local-quicklisp
           #:all-required-systems
           #:generate-random-string
           #:with-in-directory
           #:project-systems
           #:sbcl-contrib-p
           #:with-retrying
           #:make-keyword
           #:starts-with
           #:split-with
           #:extend-source-registry))
(in-package #:qlot/util)

(defvar *system-quicklisp-home*
  #+quicklisp ql:*quicklisp-home*)
(defvar *qlfilename* "qlfile")

(defmacro with-quicklisp-home (qlhome &body body)
  `(progv (list (intern #.(string :*quicklisp-home*) :ql))
       (list ,qlhome)
     ,@body))

(defmacro with-package-functions (package-designator functions &body body)
  (let ((args (gensym "ARGS")))
    `(flet (,@(loop for fn in functions
                    collect `(,fn (&rest ,args)
                                  (apply
                                   ,(if (and (listp fn) (eq (car fn) 'setf))
                                        `(eval `(function (setf ,(intern ,(string (cadr fn)) ,package-designator))))
                                        `(symbol-function (intern ,(string fn) ,package-designator)))
                                   ,args))))
       ,@body)))

(defun pathname-in-directory-p (path directory)
  (let ((directory (pathname-directory directory))
        (path (pathname-directory path)))
    (loop for dir1 = (pop directory)
          for dir2 = (pop path)
          if (null dir1)
            do (return t)
          else if (null dir2)
            do (return nil)
          else if (string/= dir1 dir2)
            do (return nil)
          finally
             (return t))))

(defun find-qlfile (directory &key (errorp t) use-lock (filename *qlfilename*))
  (check-type directory pathname)
  (unless #+clisp (ext:probe-directory directory)
          #-clisp (probe-file directory)
    (error "~S does not exist." directory))
  (let ((qlfile (merge-pathnames (format nil "~A~A" filename
                                         (if use-lock
                                             ".lock"
                                             ""))
                                 directory)))
    (unless (probe-file qlfile)
      (when errorp
        (error "'~A' is not found at '~A'." qlfile directory))
      (setf qlfile nil))

    qlfile))

(defun merge-hash-tables (from-table to-table)
  "Add all entries from FROM-TABLE to TO-TABLE, overwriting existing entries
with the same key."
  (flet ((add-to-original (value key)
           (setf (gethash value to-table) key)))
    (maphash #'add-to-original from-table)))

(defun rename-quicklisp-to-dot-qlot (&optional (pwd *default-pathname-defaults*) enable-color)
  (fresh-line *error-output*)
  (when enable-color
    (format *error-output* "~C[33m" #\Esc))
  (format *error-output*
          "Project local Quicklisp directory has changed from 'quicklisp/' to '.qlot/' since v0.9.13.
See https://github.com/fukamachi/qlot/pull/78 for the details.")
  (when enable-color
    (format *error-output* "~C[0m" #\Esc))
  (fresh-line *error-output*)
  (when (y-or-n-p "Would you like Qlot to migrate?")
    (let ((*default-pathname-defaults* pwd))
      (rename-file #P"quicklisp/" (merge-pathnames #P".qlot/"))
      (when (uiop:directory-exists-p #P".git")
        (uiop:with-output-file (out #P".gitignore" :if-exists :append :if-does-not-exist :create)
          (format out "~&.qlot/~%")))
      t)))

(defun call-in-local-quicklisp (fn qlhome &key systems (central-registry '()))
  (unless #+clisp (ext:probe-directory qlhome)
          #-clisp (probe-file qlhome)
    (error "Directory ~S does not exist." qlhome))

  (unless (probe-file (merge-pathnames #P"setup.lisp" qlhome))
    (cond
      ((or (probe-file (merge-pathnames #P".qlot/setup.lisp" qlhome))
           (and (probe-file (merge-pathnames #P"quicklisp/setup.lisp" qlhome))
                (rename-quicklisp-to-dot-qlot qlhome)))
       ;; The given `qlhome' is the project root.)
       (setf qlhome (merge-pathnames #P".qlot/" qlhome)))
      (t (error "~S is not a quicklisp directory." qlhome))))

  (let* (#+quicklisp
         (ql:*quicklisp-home* qlhome)
         #+quicklisp
         (ql:*local-project-directories* (list (merge-pathnames #P"local-projects/" qlhome)))
         (asdf:*central-registry* central-registry)
         (asdf::*source-registry* (make-hash-table :test 'equal))
         (asdf::*default-source-registries*
          '(asdf::environment-source-registry
            asdf::system-source-registry
            asdf::system-source-registry-directory))
         (original-defined-systems #+asdf3.3 asdf::*registered-systems*
                                   #-asdf3.3 asdf::*defined-systems*)
         (#+asdf3.3 asdf::*registered-systems*
          #-asdf3.3 asdf::*defined-systems* (make-hash-table :test 'equal)))

    ;; Set systems already loaded to prevent reloading the same library in the local Quicklisp.
    (maphash (lambda (name system)
               (let* ((system-object #+asdf3.3 system #-asdf3.3 (cdr system))
                      (system-path (asdf:system-source-directory system-object)))
                 (when (or (null system-path)
                           (pathname-in-directory-p system-path qlhome)
                           (typep system-object 'asdf:require-system))
                   (setf (gethash name #+asdf3.3 asdf::*registered-systems*
                                       #-asdf3.3 asdf::*defined-systems*) system))))
             original-defined-systems)

    #-quicklisp
    (load (merge-pathnames #P".qlot/setup.lisp" qlhome))
    #+quicklisp
    (push (merge-pathnames #P".qlot/" qlhome) asdf:*central-registry*)

    (asdf:initialize-source-registry)

    (dolist (system systems)
      (setf (gethash (pathname-name system) asdf::*source-registry*) system))

    (multiple-value-prog1 (funcall fn)
      ;; Make all systems that were actually loaded from the local quicklisp
      ;; visible through ASDF outside of the local environment.
      (merge-hash-tables #+asdf3.3 asdf::*registered-systems*
                         #-asdf3.3 asdf::*defined-systems* original-defined-systems))))

(defmacro with-local-quicklisp ((qlhome &key systems central-registry) &body body)
  (let ((g-qlhome (gensym "QLHOME"))
        (g-systems (gensym "SYSTEMS"))
        (g-system-file (gensym "SYSTEM-FILE")))
    `(let* ((,g-qlhome ,qlhome)
            (,g-systems ,systems)
            (,g-system-file (and (keywordp ,g-qlhome)
                                 (asdf:system-source-file ,g-qlhome))))
       (when ,g-system-file
         (push ,g-system-file ,g-systems)
         (setf ,g-qlhome
               (make-pathname :name nil
                              :type nil
                              :defaults ,g-system-file)))
       (call-in-local-quicklisp
        (lambda () ,@body)
        ,g-qlhome
        :systems ,g-systems
        :central-registry (append ,central-registry
                                  (list (asdf:system-source-directory :qlot)))))))

(defun sbcl-contrib-p (name)
  (let ((name (princ-to-string name)))
    (and (<= 3 (length name))
         (string-equal name "sb-" :end1 3))))

(defvar *already-seen* nil)

(defun all-required-systems (systems)
  (let ((systems (if (listp systems) systems (list systems)))
        (already-seen (or *already-seen* (make-hash-table :test 'equal))))
    (with-package-functions :ql (required-systems find-system)
      (labels ((main (system-name)
                 (unless (or (gethash system-name already-seen)
                             (string-equal system-name "asdf")
                             (sbcl-contrib-p system-name))
                   (setf (gethash system-name already-seen) t)
                   (let* ((system (find-system system-name))
                          (req (and system (required-systems system)))
                          (req (remove :asdf req :test #'string-equal)))
                     (if req
                         (append req (mapcan #'main req))
                         ())))))
        (delete-duplicates (mapcan #'main systems) :test #'string-equal)))))

(defun generate-random-string ()
  (let ((*random-state* (make-random-state t)))
    (format nil "~36R" (random (expt 36 #-gcl 8 #+gcl 5)))))

(defmacro with-in-directory (dir &body body)
  (let ((cwd (gensym "CWD")))
    `(let ((,cwd (uiop:getcwd)))
       (uiop:chdir ,dir)
       (unwind-protect
            (progn ,@body)
         (uiop:chdir ,cwd)))))

(defun project-systems (project-dir)
  (let ((qlhome (merge-pathnames #P".qlot/" project-dir))
        systems)
    (asdf::collect-sub*directories-asd-files
     project-dir
     :collect (lambda (asd)
                (unless (or (pathname-in-directory-p asd qlhome)
                            ;; KLUDGE: Ignore skeleton.asd of CL-Project
                            (search "skeleton" (pathname-name asd)))
                  (push asd systems)))
     :exclude (append (list "bundle-libs" "quicklisp" ".qlot")
                      asdf::*default-source-registry-exclusions*))
    systems))

(defmacro with-retrying (&body body)
  (let ((retrying (gensym))
        (e (gensym)))
    `(let ((,retrying (make-hash-table :test 'equal)))
       (asdf/session:with-asdf-session (:override t)
         (handler-bind ((asdf:missing-component
                          (lambda (,e)
                            (unless (gethash (asdf::missing-requires ,e) ,retrying)
                              (setf (gethash (asdf::missing-requires ,e) ,retrying) t)
                              (when (find :quicklisp *features*)
                                (uiop:symbol-call '#:ql-dist '#:ensure-installed
                                                  (uiop:symbol-call '#:ql-dist '#:find-system
                                                                    (asdf::missing-requires ,e)))
                                (invoke-restart (find-restart 'asdf:clear-configuration-and-retry ,e)))))))
           ,@body)))))

(defun make-keyword (text)
  "This function differ from alexandria:make-keyword
   because it upcases text before making it a keyword."
  (intern (string-upcase text) :keyword))

(defun starts-with (prefix value)
  (and (<= (length prefix) (length value))
       (string= prefix value :end2 (length prefix))))

(defun split-with (delimiter value &key limit)
  (check-type delimiter character)
  (check-type value string)
  (check-type limit (or null (integer 1)))
  (let ((results '())
        (pos 0)
        (count 0))
    (block nil
      (flet ((keep (i)
               (unless (= pos i)
                 (push (subseq value pos i) results)
                 (incf count))))
        (do ((i 0 (1+ i)))
            ((= i (length value))
             (keep i))
          (when (and limit
                     (= (1+ count) limit))
            (push (subseq value i (length value)) results)
            (return))
          (when (char= (aref value i) delimiter)
            (keep i)
            (setf pos (1+ i))))))
    (nreverse results)))

(defun extend-source-registry (current-value dir-to-add)
  "According to ASDF documentation:
   https://common-lisp.net/project/asdf/asdf/Shell_002dfriendly-syntax-for-configuration.html
   environment variable can contain a string with directories to search systems in,
   or a s-exp in DSL, describing sources of systems.

   This function modifies such string by adding `dir-to-add' in such
   way, so it will have a preference over other system sources specified
   in CL_SOURCE_REGISTRY environment variable."
  (if current-value
      (cond ((and (> (length current-value)
                     0)
                  (char= (elt current-value 0)
                         #\())
             ;; If current-value is a lisp form
             (let ((data (read-from-string current-value)))
               (unless (eql (first data)
                            :source-registry)
                 (error "Source registry definition should start with :source-registry keyword"))

               (setf data
                     (append
                      (list :source-registry
                            (list :directory (list dir-to-add)))
                      (rest data)))

               ;; Now serialize it back to a string and return as result
               (write-to-string data
                                ;; We need this flag to keep the form as a one line
                                :pretty nil)))
            ;; When current-value is a string, then just
            ;; add qlot's path to the front
            (t (format nil "~A~A~A"
                       dir-to-add
                       (if (uiop/os:os-windows-p)
                           ";"
                           ":")
                       current-value)))
      dir-to-add))
