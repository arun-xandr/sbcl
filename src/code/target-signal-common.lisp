;;;; The common stuff for signals and exceptions (win32).

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS

(in-package "SB!UNIX")

;;; CMU CL comment:
;;;   Magically converted by the compiler into a break instruction.
(defun receive-pending-interrupt ()
  (receive-pending-interrupt))

(defmacro with-interrupt-bindings (&body body)
  `(let*
       ;; KLUDGE: Whatever is on the PCL stacks before the interrupt
       ;; handler runs doesn't really matter, since we're not on the
       ;; same call stack, really -- and if we don't bind these (esp.
       ;; the cache one) we can get a bogus metacircle if an interrupt
       ;; handler calls a GF that was being computed when the interrupt
       ;; hit.
       ((sb!pcl::*cache-miss-values-stack* nil)
        (sb!pcl::*dfun-miss-gfs-on-stack* nil))
     ,@body))

;;; Evaluate CLEANUP-FORMS iff PROTECTED-FORM does a non-local exit.
(defmacro nlx-protect (protected-form &rest cleanup-froms)
  (with-unique-names (completep)
    `(let ((,completep nil))
       (without-interrupts
         (unwind-protect
              (progn
                (allow-with-interrupts
                  ,protected-form)
                (setq ,completep t))
           (unless ,completep
             ,@cleanup-froms))))))

(declaim (inline %unblock-deferrable-signals %unblock-gc-signals))
(define-alien-routine ("unblock_deferrable_signals"
                       %unblock-deferrable-signals)
  void
  (where unsigned-long)
  (old unsigned-long))

(defun unblock-deferrable-signals ()
  (%unblock-deferrable-signals 0 0))

(defun with-deferrable-signals-unblocked (unblock function)
  (if (and unblock
           *unblock-deferrables-on-enabling-interrupts-p*)
      (with-alien ((old sigset-t))
        (unwind-protect
             (progn
               (alien-funcall (extern-alien "unblock_deferrable_signals"
                                            (function (values) int (* sigset-t)))
                              0 (addr old))
               (let (*unblock-deferrables-on-enabling-interrupts-p*)
                 (when (or *interrupt-pending*
                           #!+sb-thruption *thruption-pending*)
                   (receive-pending-interrupt))
                 (funcall function)))
          (alien-funcall (extern-alien "block_deferrable_signals"
                                       (function (values) (* sigset-t)))
                         (addr old))))
      (funcall function)))

(defun invoke-interruption (function)
  (without-interrupts
    ;; Reset signal mask: the C-side handler has blocked all
    ;; deferrable signals before funcalling into lisp. They are to be
    ;; unblocked the first time interrupts are enabled. With this
    ;; mechanism there are no extra frames on the stack from a
    ;; previous signal handler when the next signal is delivered
    ;; provided there is no WITH-INTERRUPTS.
    (let ((*unblock-deferrables-on-enabling-interrupts-p* t)
          (sb!debug:*stack-top-hint* (or sb!debug:*stack-top-hint* 'invoke-interruption)))
      (with-interrupt-bindings
        (sb!thread::without-thread-waiting-for (:already-without-interrupts t)
          (allow-with-interrupts
            (nlx-protect (funcall function)
                         ;; We've been running with deferrables
                         ;; blocked in Lisp called by a C signal
                         ;; handler. If we return normally the sigmask
                         ;; in the interrupted context is restored.
                         ;; However, if we do an nlx the operating
                         ;; system will not restore it for us.
                         (when *unblock-deferrables-on-enabling-interrupts-p*
                           ;; This means that storms of interrupts
                           ;; doing an nlx can still run out of stack.
                           (unblock-deferrable-signals)))))))))

(defmacro in-interruption ((&key) &body body)
  "Convenience macro on top of INVOKE-INTERRUPTION."
  `(dx-flet ((interruption () ,@body))
     (invoke-interruption #'interruption)))
