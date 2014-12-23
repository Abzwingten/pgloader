;;;
;;; Tools to handle the DBF file format
;;;

(in-package :pgloader.db3)

(defvar *db3-pgsql-type-mapping*
  '(("C" . "text")			; ignore field-length
    ("N" . "numeric")			; handle both integers and floats
    ("L" . "boolean")			; PostgreSQL compatible representation
    ("D" . "date")			; no TimeZone in DB3 files
    ("M" . "text")))			; not handled yet

(defstruct (db3-field
	     (:constructor make-db3-field (name type length)))
  name type length)

(defmethod format-pgsql-column ((col db3-field))
  "Return a string representing the PostgreSQL column definition."
  (let* ((column-name
	  (apply-identifier-case (db3-field-name col)))
	 (type-definition
	  (cdr (assoc (db3-field-type col)
		      *db3-pgsql-type-mapping*
		      :test #'string=))))
    (format nil "~a ~22t ~a" column-name type-definition)))

(defun list-all-columns (db3-file-name
			 &optional (table-name (pathname-name db3-file-name)))
  "Return the list of columns for the given DB3-FILE-NAME."
  (with-open-file (stream db3-file-name
			  :direction :input
                          :element-type '(unsigned-byte 8))
    (let ((db3 (make-instance 'db3:db3)))
      (db3:load-header db3 stream)
      (list
       (cons table-name
	     (loop
		for field in (db3::fields db3)
		collect (make-db3-field (db3::field-name field)
					(db3::field-type field)
					(db3::field-length field))))))))

(declaim (inline logical-to-boolean
		 db3-trim-string
		 db3-date-to-pgsql-date))

(defun logical-to-boolean (value)
  "Convert a DB3 logical value to a PostgreSQL boolean."
  (if (string= value "?") nil value))

(defun db3-trim-string (value)
  "DB3 Strings a right padded with spaces, fix that."
  (string-right-trim '(#\Space) value))

(defun db3-date-to-pgsql-date (value)
  "Convert a DB3 date to a PostgreSQL date."
  (let ((year  (subseq value 0 4))
	(month (subseq value 4 6))
	(day   (subseq value 6 8)))
    (format nil "~a-~a-~a" year month day)))

(defun list-transforms (input)
  "Return the list of transforms to apply to each row of data in order to
   convert values to PostgreSQL format"
  (with-open-file (stream input
			  :direction :input
                          :element-type '(unsigned-byte 8))
    (let ((db3 (make-instance 'db3:db3)))
      (db3:load-header db3 stream)
      (loop
	 for field in (db3::fields db3)
	 for type = (db3::field-type field)
	 collect
	   (cond ((string= type "L") #'logical-to-boolean)
		 ((string= type "C") #'db3-trim-string)
		 ((string= type "D") #'db3-date-to-pgsql-date)
		 (t                  nil))))))


;;;
;;; Integration with pgloader
;;;
(defclass copy-db3 (copy) ()
  (:documentation "pgloader DBF Data Source"))

(defmethod initialize-instance :after ((db3 copy-db3) &key)
  "Add a default value for transforms in case it's not been provided."
  (let ((transforms (when (slot-boundp db3 'transforms)
                      (slot-value db3 'transforms))))
    (unless transforms
      (setf (slot-value db3 'transforms)
            (list-transforms (source db3))))))

(defmethod map-rows ((copy-db3 copy-db3) &key process-row-fn)
  "Extract DB3 data and call PROCESS-ROW-FN function with a single
   argument (a list of column values) for each row."
  (with-open-file (stream (source copy-db3)
			  :direction :input
                          :element-type '(unsigned-byte 8))
    (let ((db3 (make-instance 'db3:db3)))
      (db3:load-header db3 stream)
      (loop
	 with count = (db3:record-count db3)
	 repeat count
	 for row-array = (db3:load-record db3 stream)
	 do (funcall process-row-fn row-array)
	 finally (return count)))))

(defmethod copy-to ((db3 copy-db3) pgsql-copy-filename)
  "Extract data from DB3 file into a PotgreSQL COPY TEXT formated file"
  (with-open-file (text-file pgsql-copy-filename
			     :direction :output
			     :if-exists :supersede
			     :external-format :utf-8)
    (let ((transforms (list-transforms (source db3))))
      (map-rows db3
		:process-row-fn
		(lambda (row)
		  (format-vector-row text-file row transforms))))))

(defmethod copy-to-queue ((db3 copy-db3) queue)
  "Copy data from DB3 file FILENAME into queue DATAQ"
  (let ((read (pgloader.queue:map-push-queue db3 queue)))
    (pgstate-incf *state* (target db3) :read read)))

(defmethod copy-from ((db3 copy-db3)
		      &key
                        table-name
                        state-before
                        (truncate     t)
                        (create-table t))
  "Open the DB3 and stream its content to a PostgreSQL database."
  (let* ((summary     (null *state*))
	 (*state*     (or *state* (make-pgstate)))
	 (dbname      (target-db db3))
	 (table-name  (or table-name
			  (target db3)
			  (pathname-name (source db3)))))

    ;; fix the table-name in the db3 object
    (setf (target db3) table-name)

    (with-stats-collection ("create, truncate" :state state-before :summary summary)
      (with-pgsql-transaction ()
	(when create-table
	  (log-message :notice "Create table \"~a\"" table-name)
	  (create-tables (list-all-columns (source db3) table-name)
			 :if-not-exists t))

	(when (and truncate (not create-table))
	  ;; we don't TRUNCATE a table we just CREATEd
	  (let ((truncate-sql  (format nil "TRUNCATE ~a;" table-name)))
	    (log-message :notice "~a" truncate-sql)
	    (pgsql-execute truncate-sql)))))

    (let* ((lp:*kernel*    (make-kernel 2))
	   (channel        (lp:make-channel))
           (queue          (lq:make-queue :fixed-capacity *concurrent-batches*)))

      (with-stats-collection (table-name :state *state* :summary summary)
        (lp:task-handler-bind ((error #'lp:invoke-transfer-error))
          (log-message :notice "COPY \"~a\" from '~a'" (target db3) (source db3))
          (lp:submit-task channel #'copy-to-queue db3 queue)

          ;; and start another task to push that data from the queue to PostgreSQL
          (lp:submit-task channel
                          #'pgloader.pgsql:copy-from-queue
                          dbname table-name queue
                          :truncate truncate)

          ;; now wait until both the tasks are over, and kill the kernel
          (loop for tasks below 2 do (lp:receive-result channel)
             finally
               (log-message :info "COPY \"~a\" done." table-name)
               (lp:end-kernel)))))))

