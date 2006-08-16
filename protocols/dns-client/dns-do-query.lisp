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

;; (declaim (optimize (speed 2) (safety 2) (space 1) (debug 2)))
(declaim (optimize (speed 0) (safety 2) (space 0) (debug 2)))

(in-package #:net.sockets)

(defvar *dns-nameservers* nil
  "List of the DNS nameservers to use.")
(defvar *dns-recursion-desired* t
  "Whether the \"RECURSION-DESIRED\" field should be set ot not.")
(defvar *dns-repeat* 5
  "The number of times a failed query will be retried.")
(defvar *dns-timeout* 5
  "Timeout for DNS queries in seconds.")
(defvar *dns-domain* nil
  "The current machine's domain.")
(defvar *dns-search-domain* nil
  "A domain name to be appended to the name to be searched when the latter does not contain dots.")

(defun send-query (socket-type buffer nameserver timeout)
  (let ((socket (make-socket :type socket-type
                             :ipv6 (ipv6-address-p nameserver)))
        (input-buffer (make-array +dns-datagram-size+
                                  :element-type 'octet)))
    (unwind-protect
         (progn
           (connect socket nameserver :port 53)
           (socket-send buffer socket)
           (set-socket-option socket :receive-timeout :sec timeout :usec 0)
           (socket-receive input-buffer socket))
      (socket-close socket))))

(define-constant +max-16-bits+ (1- (expt 2 16)))

(defun prepare-query (name type)
  (let* ((question (make-question name type :in))
         (query (make-query (random +max-16-bits+)
                            question *dns-recursion-desired*)))
    (write-dns-message query)))

(defun reverse-vector (vector)
  (let* ((vector-length (length vector))
         (reverse-vector
          (make-array vector-length
                      :element-type (array-element-type vector))))
    (loop
       :for target-index :below vector-length
       :for source-index := (1- vector-length) :then (1- source-index)
       :do (setf (aref reverse-vector target-index) (aref vector source-index)))
    reverse-vector))

(defun ipv4-dns-ptr-name (address)
  (declare (type (simple-array octet (4)) address))
  (concatenate 'string (vector-to-dotted (reverse-vector address))
               ".in-addr.arpa."))

(defun ipv6-vector-to-dotted (vector)
  (declare (type (simple-array ub16 (8)) vector))
  (with-standard-io-syntax
    (let ((*print-base* 16))
      (with-output-to-string (dotted-address)
        (loop
           :for index :below (length vector)
           :for element := (aref vector index)
           :do
           (when (plusp index)
             (princ #\. dotted-address))
           (princ (ldb (byte 4  0) element) dotted-address)
           (princ #\. dotted-address)
           (princ (ldb (byte 4  4) element) dotted-address)
           (princ #\. dotted-address)
           (princ (ldb (byte 4  8) element) dotted-address)
           (princ #\. dotted-address)
           (princ (ldb (byte 4 12) element) dotted-address))))))

(defun ipv6-dns-ptr-name (address)
  (declare (type (simple-array ub16 (8)) address))
  (concatenate 'string (ipv6-vector-to-dotted (reverse-vector address))
               ".ip6.arpa."))

(defun string-address->vector (address)
  (or (dotted-to-vector address :error-p nil)
      (colon-separated-to-vector address :error-p nil)))

(defun dns-ptr-name (address)
  (etypecase address
    (string
     (let ((vector (string-address->vector address)))
       (unless vector
         (error "The argument is not a valid IP address"))
       (dns-ptr-name vector)))
    ((array * (4)) (ipv4-dns-ptr-name
                    (coerce address '(simple-array octet (4)))))
    ((array * (8)) (ipv6-dns-ptr-name
                    (coerce address '(simple-array ub16 (8)))))
    (ipv4addr (ipv4-dns-ptr-name
               (name address)))
    (ipv6addr (ipv6-dns-ptr-name
               (name address)))))

(defun dns-query (name &key (type :a) (nameserver *dns-nameservers*)
                  (repeat *dns-repeat*) (timeout *dns-timeout*)
                  (decode nil) (search nil))
  (when (eq type :ptr)
    (setf name (dns-ptr-name name)))
  (let* ((query (prepare-query name type))
         (buffer (buffer-sequence query))
         (bufflen (length buffer))
         (tries-left repeat)
         in-buff bytes-received response tcp-done)

    ;; at the moment only one nameserver is used
    (when (listp nameserver)
      (setf nameserver (car nameserver)))
    (assert nameserver)

    (tagbody
     :start
       (setf tcp-done nil
             response nil)

     :do-any-query
       ;; if the query size fits into a datagram(512 bytes max) do a
       ;; UDP query, otherwise use TCP
       ;; in case of a socket error, try again
       (multiple-value-setq (in-buff bytes-received)
         (if (> bufflen +dns-datagram-size+)
             (go :do-tcp-query)
             (handler-case
                 (send-query :datagram buffer nameserver timeout)
               (socket-error (err)
                 (declare (ignore err))
                 (go :try-again-if-possible)))))
       ;; if no socket error, go parse the response
       (go :parse-response)

     :do-tcp-query
       ;; do a TCP query; in case of a socket error, try again
       (multiple-value-setq (in-buff bytes-received)
         (handler-case
             (send-query :stream buffer nameserver timeout)
           (socket-error (err)
             (declare (ignore err))
             (go :try-again-if-possible))))
       (setf tcp-done t)

     :parse-response
       ;; try to parse the response; in case of a parse error, try again
       (setf response
             (handler-case
                 (read-dns-message
                  (make-instance 'dynamic-input-buffer
                                 :sequence in-buff
                                 :size bytes-received))
               (input-buffer-error (err)
                 (declare (ignore err))
                 (go :try-again-if-possible))
               (dns-message-error (err)
                 (declare (ignore err))
                 (go :try-again-if-possible))))
       ;; if a truncated response was received by UDP, try TCP
       (when (and (not tcp-done)
                  (truncated-field response))
         (go :do-tcp-query))

     :try-again-if-possible
       (decf tries-left)
       ;; if no response received and there are tries left, try again
       (when (and (not response)
                  (plusp tries-left))
         (go :start))

     :return-response
       (when response
         (return-from dns-query response))

     :raise-error
       (error "Could not query nameserver !!"))))
