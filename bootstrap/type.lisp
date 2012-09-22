;;;; type.lisp - Type management.

(in-package "SYSTEM.INTERNALS")

(defmacro deftype (name lambda-list &body body)
  (let ((whole (gensym "WHOLE"))
	(env (gensym "ENV")))
    (multiple-value-bind (new-lambda-list env-binding)
	(fix-lambda-list-environment lambda-list)
      `(eval-when (:compile-toplevel :load-toplevel :execute)
	 (setf (get ',name 'type-expander)
	       #'(lambda (,whole ,env)
		   (declare (lambda-name (deftype ,name))
			    (ignorable ,whole ,env))
		   ,(expand-destructuring-lambda-list new-lambda-list name body
						      whole `(cdr ,whole)
						      (when env-binding
							(list `(,env-binding ,env)))
						      ''*)))
	 ',name))))

(deftype bit ()
  '(integer 0 1))

(deftype unsigned-byte (&optional s)
  (cond ((eql s '*)
	 `(integer 0))
	(t (unless (and (integerp s) (plusp s))
	     (error 'type-error :expected-type '(integer 1) :datum s))
	   `(integer 0 ,(1- (expt 2 s))))))

(deftype signed-byte (&optional s)
  (cond ((eql s '*)
	 'integer)
	(t (unless (and (integerp s) (plusp s))
	     (error 'type-error :expected-type '(integer 1) :datum s))
	   `(integer ,(- (expt 2 (1- s))) ,(1- (expt 2 (1- s)))))))

(deftype mod (n)
  (unless (and (integerp s) (plusp s))
    (error 'type-error :expected-type '(integer 1) :datum s))
  `(integer 0 (,n)))

(deftype fixnum ()
  `(integer ,most-negative-fixnum ,most-positive-fixnum))

(defun typeexpand-1 (type &optional environment)
  (let ((expander (get (if (symbolp type)
			   type
			   (first type))
		       'type-expander)))
    (cond (expander
	   (when (symbolp type)
	     (setf type (list type)))
	   (values (funcall expander type environment) t))
	  (t (values type nil)))))

(defun typeexpand (type &optional environment)
  (do ((have-expanded nil)) (nil)
    (multiple-value-bind (expansion expanded-p)
	(typeexpand-1 type environment)
      (unless expanded-p
	(return (values expansion have-expanded)))
      (setf have-expanded t
	    type expansion))))

(defun canonicalize-integer-type (type)
  (if (consp type)
      (destructuring-bind (&optional (min '*) (max '*))
	  (cdr type)
	(when (consp min)
	  (when (rest min)
	    (error "Bad INTEGER type: ~S." type))
	  (setf min (1- (first min))))
	(unless (or (eql min '*) (integerp min))
	  (error "Bad INTEGER type: ~S." type))
	(when (consp max)
	  (when (rest max)
	    (error "Bad INTEGER type: ~S." type))
	  (setf max (1- (first max))))
	(unless (or (eql max '*) (integerp max))
	  (error "Bad INTEGER type: ~S." type))
	(values min max))
      (values '* '*)))

(defun satisfies-type-p (object type)
  (destructuring-bind (function) (cdr type)
    (funcall function object)))

(setf (get 'satisfies 'compound-type) 'satisfies-type-p)

(defun compile-satisfies-type (object type)
  "Convert a type specifier with interval designators like INTEGER, REAL and RATIONAL."
  (destructuring-bind (predicate-name) (rest type)
    `(,predicate-name ,object)))

(setf (get 'satisfies 'compound-type-optimizer) 'compile-satisfies-type)

(defun integer-type-p (object type)
  (multiple-value-bind (min max)
      (canonicalize-integer-type type)
    (and (integerp object)
	 (or (eql min '*)
	     (>= object min))
	 (or (eql max '*)
	     (<= object max)))))

(setf (get 'integer 'compound-type) 'integer-type-p)

(defun real-type-p (object type)
  (destructuring-bind (&optional (min '*) (max '*))
      (cdr type)
    (and (realp object)
	 (cond ((eql '* min) t)
	       ((consp min)
		(unless (null (rest min))
		  (error "Bad REAL type ~S." type))
		(> object (first min)))
	       (t (>= object min)))
	 (cond ((eql '* max) t)
	       ((consp max)
		(unless (null (rest max))
		  (error "Bad REAL type ~S." type))
		(< object (first max)))
	       (t (<= object max))))))
(setf (get 'real 'compound-type) 'real-type-p)

(defun compile-rational-type (object type)
  "Convert a type specifier with interval designators like INTEGER, REAL and RATIONAL."
  (cond ((symbolp type)
         `(typep ,object ',type))
        (t (destructuring-bind (base &optional (min '*) (max '*))
               type
             `(and (typep ,object ',base)
                   ,(cond ((eql min '*) 't)
                          ((consp min)
                           (unless (null (rest min))
                             (error "Bad type ~S." type))
                           (when (not (typep (first min) base))
                             (error "Bad type ~S (lower-limit is not of type ~S)."
                                    type base))
                           `(> ,object ',(first min)))
                          (t (when (not (typep min base))
                               (error "Bad type ~S (lower-limit is not of type ~S)."
                                      type base))
                             `(>= ,object ',min)))
                   ,(cond ((eql max '*) 't)
                          ((consp max)
                           (unless (null (rest max))
                             (error "Bad type ~S." type))
                           (when (not (typep (first max) base))
                             (error "Bad type ~S (upper-limit is not of type ~S)."
                                    type base))
                           `(< ,object ',(first max)))
                          (t (when (not (typep max base))
                               (error "Bad type ~S (lower-limit is not of type ~S)."
                                      type base))
                             `(<= ,object ',max))))))))

(setf (get 'real 'compound-type-optimizer) 'compile-rational-type)
(setf (get 'rational 'compound-type-optimizer) 'compile-rational-type)
(setf (get 'integer 'compound-type-optimizer) 'compile-rational-type)

(defun cons-type-p (object type)
  (destructuring-bind (&optional (car-type '*) (cdr-type '*))
      (cdr type)
    (when (eql car-type '*)
      (setf car-type 't))
    (when (eql cdr-type '*)
      (setf cdr-type 't))
    (and (consp object)
	 (or (eql car-type 't)
	     (typep (car object) car-type))
	 (or (eql cdr-type 't)
	     (typep (cdr object) cdr-type)))))
(setf (get 'cons 'compound-type) 'cons-type-p)

(setf (get 'null 'type-symbol) 'null)
(setf (get 'list 'type-symbol) 'listp)
(setf (get 'cons 'type-symbol) 'consp)
(setf (get 'symbol 'type-symbol) 'symbolp)
(setf (get 'real 'type-symbol) 'realp)
(setf (get 'number 'type-symbol) 'numberp)
(setf (get 'integer 'type-symbol) 'integerp)
(setf (get 'character 'type-symbol) 'characterp)
(setf (get 'string 'type-symbol) 'stringp)
(setf (get 'function 'type-symbol) 'functionp)
(setf (get 'structure-object 'type-symbol) 'structure-object-p)
(setf (get 't 'type-symbol) #'(lambda (x) (declare (ignore x)) t))

(defun or-type (object type)
  (dolist (elt (cdr type))
    (when (typep object elt)
      (return elt))))
(setf (get 'or 'compound-type) 'or-type)

(defun compile-or-type (object type)
  `(or ,@(mapcar (lambda (x) `(typep ,object ',x)) (rest type))))
(setf (get 'or 'compound-type-optimizer) 'compile-or-type)

(defun member-type (object type)
  (dolist (o (cdr type))
    (when (eql object o)
      (return t))))
(setf (get 'member 'compound-type) 'member-type)

(defun eql-type (object type)
  (destructuring-bind (other-object) (rest type)
    (eql object other-object)))
(setf (get 'eql 'compound-type) 'eql-type)

;;; This is annoyingly incomplete and isn't particularly well integrated.
(defun subtypep (type-1 type-2 &optional environment)
  (let ((t1 (typeexpand type-1 environment))
	(t2 (typeexpand type-2 environment)))
    (cond ((equal t1 t2) (values t t))
	  ((eql t1 'nil) (values t t))
	  ((eql t2 'nil) (values nil t))
	  ((and (or (eql t2 'integer)
		    (and (consp t2)
			 (eql (car t2) 'integer)))
		(or (eql t1 'integer)
		    (and (consp t1)
			 (eql (car t1) 'integer))))
	   (multiple-value-bind (min-1 max-1)
	       (canonicalize-integer-type t1)
	     (multiple-value-bind (min-2 max-2)
		 (canonicalize-integer-type t2)
	       (values (and (or (eql min-2 '*)
				(and (not (eql min-1 '*)) (<= min-2 min-1)))
			    (or (eql max-2 '*)
				(and (not (eql max-1 '*)) (>= max-2 max-1))))
		       t))))
	  ((eql t2 'character)
	   (values (or (eql t1 'standard-char)
		       (eql t1 'base-char)
		       (eql t1 'extended-char)
		       (eql t1 'character))
		   t))
	  ((eql t2 't)
	   (values t t))
          ((and (or (and (consp t1) (eql (first t1) 'simple-array))
                    (eql t1 'simple-array))
                (or (and (consp t2) (eql (first t2) 'simple-array))
                    (eql t2 'simple-array)))
           (destructuring-bind (&optional (t1-element-type '*) (t1-dimension-spec '*))
               (if (consp t1) (rest t1) '())
             (destructuring-bind (&optional (t2-element-type '*) (t2-dimension-spec '*))
                 (if (consp t2) (rest t2) '())
               (when (integerp t1-dimension-spec)
                 (setf t1-dimension-spec (make-list t1-dimension-spec :initial-element '*)))
               (when (integerp t2-dimension-spec)
                 (setf t2-dimension-spec (make-list t2-dimension-spec :initial-element '*)))
               (values (and (cond ((eql t2-element-type '*) t)
                                  ((eql t1-element-type '*) nil)
                                  (t (equal (upgraded-array-element-type t1-element-type)
                                            (upgraded-array-element-type t2-element-type))))
                            (cond ((eql t2-dimension-spec '*) t)
                                  ((eql t1-dimension-spec '*) nil)
                                  ((not (eql (length t1-dimension-spec)
                                             (length t2-dimension-spec)))
                                   nil)
                                  (t (every 'identity
                                            (mapcar (lambda (l r)
                                                      (cond ((eql r '*) t)
                                                            ((eql l '*) nil)
                                                            (t (<= l r))))
                                                    t1-dimension-spec
                                                    t2-dimension-spec)))))
                       t))))
          ((and (consp t1) (eql (first t1) 'eql))
           (destructuring-bind (object) (rest t1)
             (values (typep object t2) t)))
	  (t (values nil t)))))

(defun typep (object type-specifier &optional environment)
  (let ((type-symbol (cond ((symbolp type-specifier)
			    type-specifier)
			   ((and (consp type-specifier)
				 (null (rest type-specifier)))
			    (first type-specifier)))))
    (when type-symbol
      (let ((test (get type-symbol 'type-symbol)))
	(when test
	  (return-from typep (funcall test object))))))
  (when (symbolp type-specifier)
    (let ((struct-type (get type-specifier 'structure-type)))
      (when struct-type
	(return-from typep (and (structure-object-p object)
				(eq (%struct-slot object 0) struct-type)))))
    (when (or (std-instance-p object)
              (funcallable-std-instance-p object))
      (let ((class (find-class type-specifier nil)))
        (when (and class (member class (clos::class-precedence-list (class-of object))))
          (return-from typep t)))))
  (let ((compound-test (get (if (symbolp type-specifier)
				type-specifier
				(first type-specifier))
			    'compound-type)))
    (when compound-test
      (return-from typep (funcall compound-test object type-specifier))))
  (multiple-value-bind (expansion expanded-p)
      (typeexpand-1 type-specifier environment)
    (when expanded-p
      (typep object expansion))))

(defun check-type-error (place value typespec string)
  (restart-case (if string
		    (error 'simple-type-error
			   :expected-type typespec
			   :datum value
			   :format-control "The value of ~S is ~S, which is not ~A."
			   :format-arguments (list place value string))
		    (error 'simple-type-error
			   :expected-type typespec
			   :datum value
			   :format-control "The value of ~S is ~S, which is not of type ~S."
			   :format-arguments (list place value typespec)))
    (store-value (v)
      :interactive (lambda ()
		     (format t "Enter a new value (evaluated): ")
		     (list (eval (read))))
      :report (lambda (s) (format s "Input a new value for ~S." place))
      v)))

(defmacro check-type (place typespec &optional string)
  (let ((value (gensym)))
    `(do ((,value ,place ,place))
	 ((typep ,value ',typespec))
       (setf ,value (check-type-error ',place ,value ',typespec ,string)))))

(defun compile-typep-expression (object type-specifier)
  (let ((type-symbol (cond ((symbolp type-specifier)
                            type-specifier)
                           ((and (consp type-specifier)
                                 (null (rest type-specifier))
                                 (symbolp (first type-specifier)))
                            (first type-specifier)))))
    (when type-symbol
      (let ((test (get type-symbol 'type-symbol)))
	(when test
	  (return-from compile-typep-expression
            `(funcall ',test ,object))))))
  (when (and (listp type-specifier)
             (symbolp (first type-specifier)))
    (let ((compiler (get (first type-specifier) 'compound-type-optimizer)))
      (when compiler
        (let* ((sym (gensym))
               (code (funcall compiler sym type-specifier)))
          (when code
            (return-from compile-typep-expression
              `(let ((,sym ,object))
                 ,code)))))))
  (multiple-value-bind (expansion expanded-p)
      (typeexpand-1 type-specifier)
    (when expanded-p
      (compile-typep-expression object expansion))))

(define-compiler-macro typep (&whole whole object type-specifier &optional environment)
  ;; Simple environments only.
  (when environment
    (return-from typep whole))
  ;; Only deal with quoted type specifiers.
  (unless (and (listp type-specifier)
               (= (list-length type-specifier) 2)
               (eql (first type-specifier) 'quote))
    (return-from typep whole))
  (setf type-specifier (second type-specifier))
  (or (compile-typep-expression object type-specifier)
      whole))
