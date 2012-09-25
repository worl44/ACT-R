;;;  -*- mode: LISP; Package: CL-USER; Syntax: COMMON-LISP;  Base: 10 -*-
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Filename    : json-netstring-interface.lis                                 ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; Author      : Ryan M. Hope <rmh3093@gmail.com>
;;
;; Copyright   : (c)2012 Ryan M. Hope
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; Description : This module provides a way for any any remote environment to
;;               interface with ACT-R over a TCP connection.
;;
;;               Each TCP call is comprised of a Netstring wrapped, JSON
;;               encoded array. The array has 3 required elements:
;;                   1) The name or id of current model 
;;                   2) The method being invoked
;;                   3) An array of optional parameters for the invoked method
;;
;;               Ex: "45:"[\"model1\",\"device-move-cursor-to\",[[234,45]]]","
;;
;;               The remote environment should implement a server interface
;;               which listens for connections from ACT-R on a given port. This
;;               module implements a client which will connect to the remote
;;               environment when the device is installed.
;;
;;               All requests for information made by the model are fulfilled
;;               with data stored in the module. It is the responsibility of
;;               the remote environment server to update module when things in
;;               the environment change.
;;
;;               All actions performed by the model on the environment are sent
;;               directly to the remote server.
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; TODOs       : - Handle 'cursor-to-vis-loc' properly
;;               - Add support for 'onset' param for new-*-sound commands
;;               - Support multiple simultaneous models
;;               - Add support for PAAV module
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; Load some libraries so that this works on multiple implementations with out
;; having to write a lot of implementation specific code
;;
(eval-when (:compile-toplevel :load-toplevel)
  (asdf:load-system :usocket)
  (asdf:load-system :bordeaux-threads)
  (asdf:load-system :cl-netstrings)
  (asdf:load-system :cl-json))
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; Class for the JNI module instance
;; Holds per-model device information
(defclass jni-module ()
  ((socket :accessor socket :initform nil)
   (thread :accessor thread :initform nil)
   (ready-cond :accessor ready-cond :initform (bordeaux-threads:make-condition-variable))
   (ready-lock :accessor ready-lock :initform (bordeaux-threads:make-lock))
   (display :accessor display :initform nil)
   (cursor-loc :accessor cursor-loc :initform '(0 0))))

;; Read TCP stream from remote environment and process the commands
(defmethod read-stream ((instance jni-module))
  (handler-case
   (loop
    (let* ((s (json:decode-json-from-string
	       (netstrings:read-netstring (usocket:socket-stream (socket instance)))))
	   (model (pop s))
	   (method (pop s))
	   (params (pop s)))
      (declare (ignore model))
      (cond 
       ((string= method "ready")
	(bordeaux-threads:condition-notify (ready-cond instance)))
       ((string= method "update-display")
        (progn
          (setf (display instance)
                (pairlis (eval (read-from-string (pop params)))
                         (eval (read-from-string (pop params)))))
          (proc-display :clear (pop params))))
       ((string= method "trigger-reward")
        (trigger-reward (pop params)))
       ((string= method "set-visual-center-point")
        (set-visual-center-point (pop params) (pop params)))
       ((string= method "set-cursor-loc")
        (setf (cursor-loc instance) (pop params)))
       ((string= method "new-digit-sound")
        (new-digit-sound (pop params)))
       ((string= method "new-tone-sound")
        (new-tone-sound (pop params) (pop params)))
       ((string= method "new-word-sound")
        (new-word-sound (pop params)))
       ((string= method "new-other-sound")
        (new-other-sound (pop params) (pop params) (pop params) (pop params))))))
   (end-of-file
    ()
    (print-warning "Remote connection closed.")
    (cleanup instance))))

;; Encode method and params with JSON then send over socket as a netstring
(defmethod send-command ((instance jni-module) mid method &rest params)
  (if (socket instance)
      (let ((stream (usocket:socket-stream (socket instance))))
        (progn
          (netstrings:write-netstring (json:encode-json-to-string (vector mid method params)) stream)
          (finish-output stream)))))

(defmethod cleanup ((instance jni-module))
  (if (socket instance)
      (progn
	(usocket:socket-close (socket instance))
	(setf (socket instance) nil))))
    

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defmethod device-handle-keypress ((instance jni-module) key)
  (send-command instance (current-model) "keypress" (char-code key)))

(defmethod get-mouse-coordinates ((instance jni-module))
  (cursor-loc instance))

(defmethod cursor-to-vis-loc ((instance jni-module))
  nil)
  
(defmethod device-move-cursor-to ((instance jni-module) loc)
  (send-command instance (current-model) "mousemotion" loc))

(defmethod device-handle-click ((instance jni-module))
  (send-command instance (current-model) "mouseclick"))

(defmethod device-speak-string ((instance jni-module) msg)
  (send-command instance (current-model) "speak" msg))

(defmethod build-vis-locs-for ((instance jni-module) vis-mod)
  (declare (ignore vis-mod))
  (if (display instance)
      (mapcar 'car (display instance))))

(defmethod vis-loc-to-obj ((instance jni-module) vis-loc)
  (if (display instance)
      (cdr (assoc vis-loc (display instance)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun jni-device (host port)
  (if (current-model)
      (let ((instance (get-module jni)))
        (if (socket instance)
            instance
	  (handler-case
	   (progn
	     (setf (socket instance) (usocket:socket-connect host port :element-type '(unsigned-byte 8)))
	     (setf (thread instance) (bordeaux-threads:make-thread #'(lambda () (read-stream instance))))
	     instance)
	   (usocket:connection-refused-error
	    ()
	    (print-warning "Connection refused. Is remote environment server running?")
	    nil)
	   (usocket:timeout-error
	    ()
	    (print-warning "Timeout. Is remote environment server running?")
	    nil))))))

;; Create a new instance of the main class
(defun create-json-netstring-module (name)
  (declare (ignore name))
  (make-instance 'jni-module))

;; Signal remote environment to reset itself to a default/initial state
(defun reset-json-netstring-module (instance)
  (if (current-model)
      (progn
	(send-command instance (current-model) "reset")
	(cleanup instance))))

;; Close any open sockets
(defun delete-json-netstring-module (instance)
  (cleanup instance))

;; Signal remote environment that model is about to run
(defun run-start-json-netstring-module (instance)
  (if (current-model)
      (bordeaux-threads:with-recursive-lock-held 
       ((ready-lock instance))
       (progn
         (send-command instance (current-model) "model-run")
         (bordeaux-threads:condition-wait (ready-cond instance) (ready-lock instance))
         ))))

;; Signal remote environment that model has stopped running
(defun run-end-json-netstring-module (instance)
  (if (current-model)
      (send-command instance (current-model) "model-stop")))

;; JNI Module Definition
(define-module jni nil nil
  :version "1.0"
  :documentation "Module based manager for remote TCP environments using JSON & Netstrings"
  :creation create-json-netstring-module
  :reset reset-json-netstring-module
  :delete delete-json-netstring-module
  :run-start run-start-json-netstring-module
  :run-end run-end-json-netstring-module)