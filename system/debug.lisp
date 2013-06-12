(in-package :sys.int)

(declaim (special *debug-io*
                  *standard-input*
                  *standard-output*))

(defparameter *debugger-depth* 0)
(defvar *debugger-condition* nil)
(defvar *current-debug-frame* nil)

(defun function-from-frame (frame)
  (memref-t (second frame) -2))

(defun read-frame-slot (frame slot)
  (memref-t (memref-unsigned-byte-64 (third frame) -1) (- (1+ slot))))

(defun show-debug-frame ()
  (format t "Frame ~D(~X): ~S~%"
          (first *current-debug-frame*)
          (second *current-debug-frame*)
          (function-from-frame *current-debug-frame*)))

(defun enter-debugger (condition)
  (let* ((*standard-input* *debug-io*)
	 (*standard-output* *debug-io*)
	 (debug-level *debugger-depth*)
	 (*debugger-depth* (1+ *debugger-depth*))
	 (restarts (compute-restarts))
	 (restart-count (length restarts))
         (*debugger-condition* condition)
         (frames nil)
         (n-frames 0)
         (*current-debug-frame*))
    (let ((prev-fp nil))
      (map-backtrace
       (lambda (i fp)
         (incf n-frames)
         (push (list (1- i) fp prev-fp) frames)
         (setf prev-fp fp))))
    (setf frames (nreverse frames))
    ;; Can't deal with the top-most frame.
    (decf n-frames)
    (pop frames)
    ;; Remove a few more frames that're done.
    (setf *current-debug-frame* (first frames))
    (fresh-line)
    (write condition :escape nil :readably nil)
    (fresh-line)
    (show-restarts restarts)
    (fresh-line)
    (backtrace 15)
    (fresh-line)
    (write-line "Enter a restart number or evaluate a form.")
    (loop
       (let ((* nil) (** nil) (*** nil)
             (/ nil) (// nil) (/// nil)
             (+ nil) (++ nil) (+++ nil)
             (- nil))
         (loop
            (with-simple-restart (abort "Return to debugger top level.")
              (fresh-line)
              (format t "~D] " debug-level)
              (let ((form (read)))
                (fresh-line)
                (typecase form
                  (integer
                   (if (and (>= form 0) (< form restart-count))
                       (invoke-restart-interactively (nth (- restart-count form 1) restarts))
                       (format t "Restart number ~D out of bounds.~%" form)))
                  (keyword
                   (case form
                     (:up
                      (if (>= (first *current-debug-frame*) n-frames)
                          (format t "At innermost frame!~%")
                          (setf *current-debug-frame* (nth (1+ (first *current-debug-frame*)) frames)))
                      (show-debug-frame))
                     (:down
                      (if (zerop (first *current-debug-frame*))
                          (format t "At outermost frame!~%")
                          (setf *current-debug-frame* (nth (1- (first *current-debug-frame*)) frames)))
                      (show-debug-frame))
                     (:current (show-debug-frame))
                     (:vars
                      (show-debug-frame)
                      (let* ((fn (function-from-frame *current-debug-frame*))
                             (info (function-pool-object fn 1)))
                        (when (and (listp info) (eql (first info) :debug-info))
                          (format t "Locals:~%")
                          (dolist (var (third info))
                            (format t "  ~S: ~S~%" (first var) (read-frame-slot *current-debug-frame* (second var))))
                          (when (fourth info)
                            (format t "Closed-over variables:~%")
                            (let ((env-object (read-frame-slot *current-debug-frame* (fourth info))))
                              (dolist (level (fifth info))
                                (do ((i 1 (1+ i))
                                     (var level (cdr var)))
                                    ((null var))
                                  (when (car var)
                                    (format t "  ~S: ~S~%" (car var) (svref env-object i))))
                                (setf env-object (svref env-object 0))))))))
                     (t (format t "Unknown command ~S~%" form))))
                  (t (let ((result (multiple-value-list (let ((- form))
                                                          (eval form)))))
                       (setf *** **
                             ** *
                             * (first result)
                             /// //
                             // /
                             / result
                             +++ ++
                             ++ +
                             + form)
                       (when result
                         (dolist (v result)
                           (fresh-line)
                           (write v)))))))))))))

(defun show-restarts (restarts)
  (let ((restart-count (length restarts)))
    (write-string "Available restarts:")(terpri)
    (do ((i 0 (1+ i))
	 (r restarts (cdr r)))
	((null r))
      (format t "~S ~S: ~A~%" (- restart-count i 1) (restart-name (car r)) (car r)))))

(defun map-backtrace (fn)
  (do ((i 0 (1+ i))
       (fp (read-frame-pointer)
           (memref-unsigned-byte-64 fp 0)))
      ((= fp 0))
    (funcall fn i fp)))

(defun backtrace (&optional limit)
  (map-backtrace
   (lambda (i fp)
     (when (and limit (> i limit))
       (return-from backtrace))
     (write-char #\Newline)
     (write-integer fp 16)
     (write-char #\Space)
     (let* ((fn (memref-t fp -2))
            (name (when (functionp fn) (function-name fn))))
       (write-integer (lisp-object-address fn) 16)
       (when name
         (write-char #\Space)
         (write name))))))

(defvar *traced-functions* '())
(defvar *trace-depth* 0)

(defmacro trace (&rest functions)
  `(%trace ,@(mapcar (lambda (f) (list 'quote f)) functions)))

(defun %trace (&rest functions)
  (dolist (fn functions)
    (when (and (not (member fn *traced-functions* :key 'car :test 'equal))
               (fboundp fn))
      (let ((name fn)
            (old-definition (fdefinition fn)))
      (push (list fn old-definition) *traced-functions*)
      (setf (fdefinition fn)
            (lambda (&rest args)
              (declare (dynamic-extent args)
                       (system:lambda-name trace-wrapper))
              (write *trace-depth* :stream *trace-output*)
              (write-string ": Enter " *trace-output*)
              (write name :stream *trace-output*)
              (write-char #\Space *trace-output*)
              (write args :stream *trace-output*)
              (terpri *trace-output*)
              (let ((result :error))
                (unwind-protect
                     (handler-bind ((error (lambda (condition) (setf result condition))))
                       (setf result (multiple-value-list (let ((*trace-depth* (1+ *trace-depth*)))
                                                           (apply old-definition args)))))
                  (write *trace-depth* :stream *trace-output*)
                  (write-string ": Leave " *trace-output*)
                  (write name :stream *trace-output*)
                  (write-char #\Space *trace-output*)
                  (write result :stream *trace-output*)
                  (terpri *trace-output*))
                (values-list result)))))))
  *traced-functions*)

(defun %untrace (&rest functions)
  (if (null functions)
      (dolist (fn *traced-functions* (setf *traced-functions* '()))
        (setf (fdefinition (first fn)) (second fn)))
      (dolist (fn functions)
        (let ((x (assoc fn *traced-functions* :test 'equal)))
          (when x
            (setf *traced-functions* (delete x *traced-functions*))
            (setf (fdefinition (first x)) (second x)))))))