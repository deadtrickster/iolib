;; -*- Mode: Lisp; Syntax: ANSI-Common-Lisp -*-

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;   Copyright (C) 2006,2007 by Stelian Ionescu                            ;
;                                                                         ;
;   This program is free software; you can redistribute it and/or modify  ;
;   it under the terms of the GNU General Public License as published by  ;
;   the Free Software Foundation; either version 2 of the License, or     ;
;   (at your option) any later version.                                   ;
;                                                                         ;
;   This program is distributed in the hope that it will be useful,       ;
;   but WITHOUT ANY WARRANTY; without even the implied warranty of        ;
;   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the         ;
;   GNU General Public License for more details.                          ;
;                                                                         ;
;   You should have received a copy of the GNU General Public License     ;
;   along with this program; if not, write to the                         ;
;   Free Software Foundation, Inc.,                                       ;
;   51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA              ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; (declaim (optimize (speed 2) (safety 2) (space 1) (debug 2)))
(declaim (optimize (speed 0) (safety 2) (space 0) (debug 2)))

(in-package :io.multiplex)

(defconstant +epoll-priority+ 1)

(define-multiplexer epoll-multiplexer +epoll-priority+
  (multiplexer)
  ((epoll-fd :reader epoll-fd)))

(defconstant +epoll-default-size-hint+ 25)
(eval-when (:compile-toplevel :load-toplevel :execute)
  (defvar *epoll-max-events* 200))

(defmethod initialize-instance :after ((mux epoll-multiplexer)
                                       &key (size +epoll-default-size-hint+))
  (let ((epoll-fd (et:epoll-create size)))
    (setf (slot-value mux 'epoll-fd) epoll-fd)
    (finalize-object-closing-fd mux epoll-fd)))

(defun calc-epoll-flags (fd-entry)
  (logior (if (fd-entry-read-handlers fd-entry) et:epollin 0)
          (if (fd-entry-write-handlers fd-entry) et:epollout 0)
          (if (fd-entry-except-handlers fd-entry) et:epollpri 0)))

(defmethod monitor-fd ((mux epoll-multiplexer) fd-entry)
  (assert fd-entry)
  (let ((flags (calc-epoll-flags fd-entry))
        (fd (fd-entry-fd fd-entry)))
    (with-foreign-object (ev 'et:epoll-event)
      (et:memset ev 0 #.(foreign-type-size 'et:epoll-event))
      (setf (foreign-slot-value ev 'et:epoll-event 'et:events) flags)
      (setf (foreign-slot-value (foreign-slot-value ev 'et:epoll-event 'et:data)
                                'et:epoll-data 'et:fd)
            fd)
      (handler-case
          (et:epoll-ctl (epoll-fd mux) et:epoll-ctl-add fd ev)
        (et:unix-error-badf (err)
          (declare (ignore err))
          (warn "FD ~A is invalid, cannot monitor it." fd)
          (return-from monitor-fd nil))
        (et:unix-error-exist (err)
          (declare (ignore err))
          (warn "FD ~A is already monitored." fd)
          (return-from monitor-fd nil))))
    t))

(defmethod update-fd ((mux epoll-multiplexer) fd-entry)
  (assert fd-entry)
  (let ((flags (calc-epoll-flags fd-entry))
        (fd (fd-entry-fd fd-entry)))
    (with-foreign-object (ev 'et:epoll-event)
      (et:memset ev 0 #.(foreign-type-size 'et:epoll-event))
      (setf (foreign-slot-value ev 'et:epoll-event 'et:events) flags)
      (setf (foreign-slot-value (foreign-slot-value ev 'et:epoll-event 'et:data)
                                'et:epoll-data 'et:fd)
            fd)
      (handler-case
          (et:epoll-ctl (epoll-fd mux) et:epoll-ctl-mod fd ev)
        (et:unix-error-badf (err)
          (declare (ignore err))
          (warn "FD ~A is invalid, cannot update its status." fd)
          (return-from update-fd nil))
        (et:unix-error-noent (err)
          (declare (ignore err))
          (warn "FD ~A was not monitored, cannot update its status." fd)
          (return-from update-fd nil))))
    (values fd-entry)))

(defmethod unmonitor-fd ((mux epoll-multiplexer) fd &key)
  (handler-case
      (et:epoll-ctl (epoll-fd mux)
                    et:epoll-ctl-del
                    fd
                    (null-pointer))
    (et:unix-error-badf (err)
      (declare (ignore err))
      (warn "FD ~A is invalid, cannot unmonitor it." fd))
    (et:unix-error-noent (err)
      (declare (ignore err))
      (warn "FD ~A was not monitored, cannot unmonitor it." fd)))
  t)

(defun epoll-serve-single-fd (fd-entry events)
  (assert fd-entry)
  (let ((error-handlers (fd-entry-error-handlers fd-entry))
        (except-handlers (fd-entry-except-handlers fd-entry))
        (read-handlers (fd-entry-read-handlers fd-entry))
        (write-handlers (fd-entry-write-handlers fd-entry))
        (fd (fd-entry-fd fd-entry)))
    (when (and error-handlers (logtest et:epollerr events))
      (dolist (error-handler error-handlers)
        (funcall (handler-function error-handler) fd :error)))
    (when (and except-handlers (logtest et:epollpri events))
      (dolist (except-handler (fd-entry-except-handlers fd-entry))
        (funcall (handler-function except-handler) fd :except)))
    (when (and read-handlers (logtest et:epollin events))
      (dolist (read-handler (fd-entry-read-handlers fd-entry))
        (funcall (handler-function read-handler) fd :read)))
    (when (and write-handlers (logtest et:epollout events))
      (dolist (write-handler (fd-entry-write-handlers fd-entry))
        (funcall (handler-function write-handler) fd :write)))))

(defmethod serve-fd-events ((mux epoll-multiplexer)
                            &key timeout)
  (let ((milisec-timeout
         (if timeout
             (+ (* (timeout-sec timeout) 1000)
                (truncate (timeout-usec timeout) 1000))
             -1)))
    (with-foreign-object (events 'et:epoll-event #.*epoll-max-events*)
      (et:memset events 0 #.(* *epoll-max-events* (foreign-type-size 'et:epoll-event)))
      (let ((ready-fds
             (et:epoll-wait (epoll-fd mux) events
                            #.*epoll-max-events* milisec-timeout)))
        (loop
           :for i :below ready-fds
           :for fd := (foreign-slot-value (foreign-slot-value (mem-aref events 'et:epoll-event i)
                                                              'et:epoll-event 'et:data)
                                          'et:epoll-data 'et:fd)
           :for event-mask := (foreign-slot-value (mem-aref events 'et:epoll-event i)
                                                  'et:epoll-event 'et:events)
           :do (epoll-serve-single-fd (fd-entry mux fd)
                                      event-mask))
        (return-from serve-fd-events ready-fds)))))

(defmethod close-multiplexer ((mux epoll-multiplexer))
  (cancel-finalization mux)
  (et:close (epoll-fd mux)))
