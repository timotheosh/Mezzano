(in-package #:sys.int)

(defun proclaim (declaration-specifier)
  (case (first declaration-specifier)
    (special (dolist (var (rest declaration-specifier))
               (setf (system:symbol-mode var) :special)))
    (constant (dolist (var (rest declaration-specifier))
                (setf (system:symbol-mode var) :constant)))))

(defun system:symbol-mode (symbol)
  (svref #(nil :special :constant :symbol-macro)
         (ldb (byte 2 0) (%symbol-flags symbol))))

(defun (setf system:symbol-mode) (value symbol)
  (setf (ldb (byte 2 0) (%symbol-flags symbol))
        (ecase value
          ((nil) +symbol-mode-nil+)
          ((:special) +symbol-mode-special+)
          ((:constant) +symbol-mode-constant+)
          ((:symbol-macro) +symbol-mode-symbol-macro+)))
  value)

(setf (symbol-mode 'nil) :constant)

(defun variable-information (symbol)
  (symbol-mode symbol))

;;; The compiler can only handle (apply function arg-list).
(defun apply (function arg &rest more-args)
  (declare (dynamic-extent more-args))
  (cond (more-args
         ;; Convert (... (final-list ...)) to (... final-list...)
         (do* ((arg-list (cons arg more-args))
               (i arg-list (cdr i)))
              ((null (cddr i))
               (setf (cdr i) (cadr i))
               (apply function arg-list))))
        (t (apply function arg))))

;;; TODO: This requires a considerably more flexible mechanism.
;;; 12 is where the TLS slots in a stack group start.
(defparameter *next-symbol-tls-slot* 12)
(defconstant +maximum-tls-slot+ 512)
(defun %allocate-tls-slot (symbol)
  (when (>= *next-symbol-tls-slot* +maximum-tls-slot+)
    (error "Critial error! TLS slots exhausted!"))
  (let ((slot *next-symbol-tls-slot*))
    (incf *next-symbol-tls-slot*)
    (setf (ldb (byte 16 8) (%symbol-flags symbol)) slot)
    slot))

(defun %symbol-tls-slot (symbol)
  (ldb (byte 16 8) (%symbol-flags symbol)))

(defun funcall (function &rest arguments)
  (declare (dynamic-extent arguments))
  (apply function arguments))

(defun values (&rest values)
  (declare (dynamic-extent values))
  (values-list values))

(defun fboundp (name)
  (%fboundp (function-symbol name)))

(defun fmakunbound (name)
  (%fmakunbound (function-symbol name))
  name)

(defun macro-function (symbol &optional env)
  (dolist (e env
           (get symbol '%macro-function))
    (when (eql (first e) :macros)
      (let ((fn (assoc symbol (rest e))))
        (when fn (return (cdr fn)))))))

(defun (setf macro-function) (value symbol &optional env)
  (when env
    (error "TODO: (Setf Macro-function) in environment."))
  (setf (symbol-function symbol) (lambda (&rest r)
                                   (declare (ignore r))
                                   (error 'undefined-function :name symbol))
        (get symbol '%macro-function) value))

(defun symbol-macro-function (symbol)
  nil)

;;; Calls to these functions are generated by the compiler to
;;; signal errors.
(defun raise-undefined-function (invoked-through)
  (error 'undefined-function :name invoked-through))

(defun raise-unbound-error (symbol)
  (error 'unbound-variable :name symbol))

(defun raise-type-error (datum expected-type)
  (error 'type-error :datum datum :expected-type expected-type))

(defun %invalid-argument-error (&rest args)
  (error "Invalid arguments to function."))

(defun endp (list)
  (cond ((null list) t)
        ((consp list) nil)
        (t (error 'type-error
                  :datum list
                  :expected-type 'list))))

(defun list (&rest args)
  args)

(defun copy-list (list)
  (when list
    (cons (car list) (copy-list (cdr list)))))

(defun function-name (function)
  (check-type function function)
  (let* ((address (logand (lisp-object-address function) -16))
         (info (memref-unsigned-byte-64 address 0)))
    (ecase (logand info #xFF)
      (#.+function-type-function+ ;; Regular function. First entry in the constant pool.
       (memref-t address (* (logand (ash info -16) #xFFFF) 2)))
      (#.+function-type-closure+ ;; Closure.
       (function-name (memref-t address 4)))
      (#.+function-type-interpreted-function+
       ;; Interpreted function. Second entry in the constant pool.
       (memref-t address 7)))))

(defun function-lambda-expression (function)
  (check-type function function)
  (let* ((address (logand (lisp-object-address function) -16))
         (info (memref-unsigned-byte-64 address 0)))
    (ecase (logand info #xFF)
      (#.+function-type-function+ ;; Regular function. First entry in the constant pool.
       (values nil nil (* (logand (ash info -16) #xFFFF) 2)))
      (#.+function-type-closure+ ;; Closure.
       (values nil t (function-name (memref-t address 4))))
      (#.+function-type-interpreted-function+
       (values (memref-t address 5) (memref-t address 6) (memref-t address 7))))))

(defun compiled-function-p (object)
  (when (functionp object)
    (let* ((address (logand (lisp-object-address object) -16))
           (info (memref-unsigned-byte-64 address 0)))
      (not (eql (logand info #xFF) +function-type-interpreted-function+)))))

(defvar *gensym-counter* 0)
(defun gensym (&optional (thing "G"))
  (make-symbol (format nil "~A~D" thing (prog1 *gensym-counter* (incf *gensym-counter*)))))

(defun assemble-lap (code &optional name)
  (multiple-value-bind (mc constants)
      (sys.lap-x86:assemble code
        :base-address 12
        :initial-symbols (list (cons nil (lisp-object-address 'nil))
                               (cons t (lisp-object-address 't))
                               (cons 'undefined-function (lisp-object-address *undefined-function-thunk*)))
        :info (list name))
    (make-function mc constants)))

(defun compile (name &optional definition)
  (unless definition
    (setf definition (or (when (symbolp name) (macro-function name))
                         (fdefinition name))))
  (when (functionp definition)
    (multiple-value-bind (lambda-expression env)
        (function-lambda-expression definition)
      (when (null lambda-expression)
        (error "No source information available for ~S." definition))
      (when env
        (error "TODO: cannot compile functions defined outside the null lexical environment."))
      (setf definition lambda-expression)))
  (multiple-value-bind (fn warnings-p errors-p)
      (sys.c::compile-lambda definition)
    (cond (name
           (if (and (symbolp name) (macro-function name))
               (setf (macro-function name) fn)
               (setf (fdefinition name) fn))
           (values name warnings-p errors-p))
          (t (values fn warnings-p errors-p)))))

;;; TODO: Expand this so it knows about the compiler's constant folders.
(defun constantp (form &optional environment)
  (declare (ignore environment))
  (typecase form
    (symbol (eql (symbol-mode form) :constant))
    (cons (eql (first form) 'quote))
    (t t)))
