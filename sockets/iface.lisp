;; -*- Mode: Lisp; Syntax: ANSI-Common-Lisp -*-

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;   Copyright (C) 2006 by Stelian Ionescu                                 ;
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

(declaim (optimize (speed 1) (safety 2) (space 0) (debug 2)))

(in-package #:net.sockets)

(defclass interface ()
  ((name  :initarg :name
          :initform (error "The interface must have a name.")
          :reader interface-name)
   (index :initarg :index
          :initform (error "The interface must have an index.")
          :reader interface-index)))

(defmethod print-object ((iface interface) stream)
  (print-unreadable-object (iface stream :type nil :identity nil)
    (with-slots (name id) iface
      (format stream "Network Interface: ~s. Index: ~a"
              (interface-name iface) (interface-index iface)))))

(defun make-interface (name index)
  (make-instance 'interface
                 :name  name
                 :index index))

(defun get-network-interfaces ()
  (with-alien ((ifptr (* (array (struct et::if-nameindex) 0))))
    (sb-sys:with-pinned-objects (ifptr)
      (setf ifptr (et::if-nameindex))
      (unless (null-alien ifptr)
        (let ((ifarr (deref ifptr)))
          (loop
             for i from 0
             for name = (slot (deref ifarr i) 'et::name)
             for index = (slot (deref ifarr i) 'et::index)
             while (plusp index)
             collect (make-interface name index)
             finally (et::if-freenameindex ifptr)))))))

(defun get-interface-by-index (index)
  (check-type index unsigned-byte "an unsigned integer")
  (with-alien ((buff (array char #.et::ifnamesize)))
    (with-alien-saps ((buff-sap buff))
      (let ((retval
             (et::if-indextoname index buff-sap)))
        (if (null retval)
            (case (get-errno)
              (#.sb-posix:enxio
               (error 'unknown-interface
                      :code sb-posix:enxio
                      :identifier :unknown-interface
                      :index index)))
            (make-interface (copy-seq retval) index))))))

(defun get-interface-by-name (name)
  (check-type name string "a string")
  (sb-sys:with-pinned-objects (name)
    (let ((retval
           (et::if-nametoindex name)))
      (if (zerop retval)
          (error 'unknown-interface
                 :code sb-posix:enxio
                 :identifier :unknown-interface
                 :name name)
          (make-interface (copy-seq name) retval)))))

(defun lookup-interface (iface)
  (multiple-value-bind (iface-type iface-val)
      (string-or-parsed-number iface)
    (ecase iface-type
      (:number
       (get-interface-by-index iface-val))

      (:string
       (get-interface-by-name iface-val)))))