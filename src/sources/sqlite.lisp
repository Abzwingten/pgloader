;;;
;;; Tools to handle the SQLite Database
;;;

(in-package :pgloader.sqlite)

;;;
;;; Integration with the pgloader Source API
;;;
(defclass copy-sqlite (copy)
  ((db :accessor db :initarg :db))
  (:documentation "pgloader SQLite Data Source"))

(defmethod initialize-instance :after ((source copy-sqlite) &key)
  "Add a default value for transforms in case it's not been provided."
  (let* ((source-db  (slot-value source 'source-db))
	 (db         (sqlite:connect (get-absolute-pathname `(:filename ,source-db))))
	 (table-name (when (slot-boundp source 'source)
		       (slot-value source 'source)))
	 (fields     (or (and (slot-boundp source 'fields)
			      (slot-value source 'fields))
			 (when table-name
			   (list-columns table-name db))))
	 (transforms (when (slot-boundp source 'transforms)
		       (slot-value source 'transforms))))

    ;; we will reuse the same SQLite database handler that we just opened
    (setf (slot-value source 'db) db)

    ;; default to using the same table-name as source and target
    (when (and table-name
	       (or (not (slot-boundp source 'target))
		   (slot-value source 'target)))
      (setf (slot-value source 'target) table-name))

    (when fields
      (unless (slot-boundp source 'fields)
	(setf (slot-value source 'fields) fields))

      (loop for field in fields
         for (column fn) = (multiple-value-bind (column fn)
                               (cast-sqlite-column-definition-to-pgsql field)
                             (list column fn))
         collect column into columns
         collect fn into fns
         finally (progn (setf (slot-value source 'columns) columns)
                        (unless transforms
                          (setf (slot-value source 'transforms) fns)))))))

;;; Map a function to each row extracted from SQLite
;;;
(defmethod map-rows ((sqlite copy-sqlite) &key process-row-fn)
  "Extract SQLite data and call PROCESS-ROW-FN function with a single
   argument (a list of column values) for each row"
  (let ((sql      (format nil "SELECT * FROM ~a" (source sqlite)))
        (blobs-p
         (coerce (mapcar #'cast-to-bytea-p (fields sqlite)) 'vector)))
    (handler-case
        (loop
           with statement = (sqlite:prepare-statement (db sqlite) sql)
           with len = (loop :for name :in (sqlite:statement-column-names statement)
                         :count name)
           while (sqlite:step-statement statement)
           for row = (let ((v (make-array len)))
                       (loop :for x :below len
                          :for raw := (sqlite:statement-column-value statement x)
                          :for val := (if (and (aref blobs-p x) (stringp raw))
                                          (base64:base64-string-to-usb8-array raw)
                                          raw)
                          :do (setf (aref v x) val))
                       v)
           counting t into rows
           do (funcall process-row-fn row)
           finally
             (sqlite:finalize-statement statement)
             (return rows))
      (condition (e)
        (progn
          (log-message :error "~a" e)
          (pgstate-incf *state* (target sqlite) :errs 1))))))


(defmethod copy-to-queue ((sqlite copy-sqlite) queue)
  "Copy data from SQLite table TABLE-NAME within connection DB into queue DATAQ"
  (let ((read (pgloader.queue:map-push-queue sqlite queue)))
    (pgstate-incf *state* (target sqlite) :read read)))

(defmethod copy-from ((sqlite copy-sqlite) &key (kernel nil k-s-p) truncate)
  "Stream the contents from a SQLite database table down to PostgreSQL."
  (let* ((summary     (null *state*))
	 (*state*     (or *state* (pgloader.utils:make-pgstate)))
	 (lp:*kernel* (or kernel (make-kernel 2)))
	 (channel     (lp:make-channel))
	 (queue       (lq:make-queue :fixed-capacity *concurrent-batches*))
	 (table-name  (target sqlite))
	 (pg-dbname   (target-db sqlite)))

    (with-stats-collection (table-name :state *state* :summary summary)
      (lp:task-handler-bind ((error #'lp:invoke-transfer-error))
        (log-message :notice "COPY ~a" table-name)
        ;; read data from SQLite
        (lp:submit-task channel #'copy-to-queue sqlite queue)

        ;; and start another task to push that data from the queue to PostgreSQL
        (lp:submit-task channel
                        #'pgloader.pgsql:copy-from-queue
                        pg-dbname table-name queue
                        :truncate truncate)

        ;; now wait until both the tasks are over
        (loop for tasks below 2 do (lp:receive-result channel)
           finally
             (log-message :info "COPY ~a done." table-name)
             (unless k-s-p (lp:end-kernel)))))))

(defmethod copy-database ((sqlite copy-sqlite)
			  &key
			    state-before
			    data-only
			    schema-only
			    (truncate        nil)
			    (create-tables   t)
			    (include-drop    t)
			    (create-indexes  t)
			    (reset-sequences t)
			    only-tables
			    including
			    excluding
                            (encoding :utf-8))
  "Stream the given SQLite database down to PostgreSQL."
  (let* ((summary       (null *state*))
	 (*state*       (or *state* (make-pgstate)))
	 (state-before  (or state-before (make-pgstate)))
	 (idx-state     (make-pgstate))
	 (seq-state     (make-pgstate))
         (cffi:*default-foreign-encoding* encoding)
         (copy-kernel   (make-kernel 2))
         (all-columns   (filter-column-list (list-all-columns (db sqlite))
					    :only-tables only-tables
					    :including including
					    :excluding excluding))
         (all-indexes   (filter-column-list (list-all-indexes (db sqlite))
					    :only-tables only-tables
					    :including including
					    :excluding excluding))
         (max-indexes   (loop for (table . indexes) in all-indexes
                           maximizing (length indexes)))
         (idx-kernel    (when (and max-indexes (< 0 max-indexes))
			  (make-kernel max-indexes)))
         (idx-channel   (when idx-kernel
			  (let ((lp:*kernel* idx-kernel))
			    (lp:make-channel))))
	 (pg-dbname     (target-db sqlite)))

    ;; if asked, first drop/create the tables on the PostgreSQL side
    (cond ((and (or create-tables schema-only) (not data-only))
           (log-message :notice "~:[~;DROP then ~]CREATE TABLES" include-drop)
           (with-stats-collection ("create, truncate"
                                   :state state-before
                                   :summary summary)
             (with-pgsql-transaction ()
               (create-tables all-columns :include-drop include-drop))))

          (truncate
           (truncate-tables *pg-dbname* (mapcar #'car all-columns))))

    (loop
       for (table-name . columns) in all-columns
       do
	 (let ((table-source
		(make-instance 'copy-sqlite
			       :db         (db sqlite)
			       :source-db  (source-db sqlite)
			       :target-db  pg-dbname
			       :source     table-name
			       :target     table-name
			       :fields     columns)))
	   ;; first COPY the data from SQLite to PostgreSQL, using copy-kernel
	   (unless schema-only
	     (copy-from table-source :kernel copy-kernel))

	   ;; Create the indexes for that table in parallel with the next
	   ;; COPY, and all at once in concurrent threads to benefit from
	   ;; PostgreSQL synchronous scan ability
	   ;;
	   ;; We just push new index build as they come along, if one
	   ;; index build requires much more time than the others our
	   ;; index build might get unsync: indexes for different tables
	   ;; will get built in parallel --- not a big problem.
	   (when (and create-indexes (not data-only))
	     (let* ((indexes
		     (cdr (assoc table-name all-indexes :test #'string=))))
	       (create-indexes-in-kernel pg-dbname indexes
					 idx-kernel idx-channel
					 :state idx-state)))))

    ;; don't forget to reset sequences, but only when we did actually import
    ;; the data.
    (when reset-sequences
      (let ((tables (or only-tables
			(mapcar #'car all-columns))))
	(log-message :notice "Reset sequences")
	(with-stats-collection ("reset sequences"
                                :use-result-as-rows t
                                :state seq-state)
	  (pgloader.pgsql:reset-all-sequences pg-dbname :tables tables))))

    ;; now end the kernels
    (let ((lp:*kernel* copy-kernel))  (lp:end-kernel))
    (let ((lp:*kernel* idx-kernel))
      ;; wait until the indexes are done being built...
      ;; don't forget accounting for that waiting time.
      (when (and create-indexes (not data-only))
	(with-stats-collection ("index build completion" :state *state*)
	 (loop for idx in all-indexes do (lp:receive-result idx-channel))))
      (lp:end-kernel))

    ;; and report the total time spent on the operation
    (report-full-summary "Total streaming time" *state*
                         :before state-before
                         :finally seq-state
                         :parallel idx-state)))

