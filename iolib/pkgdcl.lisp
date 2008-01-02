;;;; -*- Mode: Lisp; Syntax: ANSI-Common-Lisp; Indent-tabs-mode: NIL -*-
;;;
;;; pkgdcl.lisp --- Package definition.
;;;
;;; Copyright (C) 2008, Stelian Ionescu  <sionescu@common-lisp.net>
;;;
;;; This code is free software; you can redistribute it and/or
;;; modify it under the terms of the version 2.1 of
;;; the GNU Lesser General Public License as published by
;;; the Free Software Foundation, as clarified by the
;;; preamble found here:
;;;     http://opensource.franz.com/preamble.html
;;;
;;; This program is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU Lesser General
;;; Public License along with this library; if not, write to the
;;; Free Software Foundation, Inc., 51 Franklin St, Fifth Floor,
;;; Boston, MA 02110-1301, USA

(in-package :common-lisp-user)

(macrolet
    ((defconduit (name &body clauses)
       (assert (= 1 (length clauses)))
       (assert (eq (caar clauses) :use))
       (flet ((get-symbols (packages)
                (loop :for sym :being :the :external-symbols :of packages
                      :collect sym :into symbols
                      :finally (return (remove-duplicates symbols :test #'eq)))))
         `(defpackage ,name
            (:use #:common-lisp ,@(cdar clauses))
            (:export ,@(get-symbols (cdar clauses)))))))

  (defconduit :iolib
    (:use :io.multiplex :io.streams :net.sockets)))