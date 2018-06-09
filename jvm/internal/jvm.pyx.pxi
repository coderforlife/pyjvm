"""
pyjvm - Java VM access from within Python
Copyright (C) 2016 Jeffrey Bush <jeff@coderforlife.com>

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.

---------------------------------------------------------------------------------------------------

JVM Interaction code
--------------------
Code to interact with the core JVM and the overall Java system. Implements a thread where the JVM
runs that can have actions pushed to it.

Public functions:
    jvm_get_default_options() - useless

Public classes:
    JVMAction - an action that can be run on the main JVM thread

Internal classes:
    JVM - the core JVM wrapper, wraps a JavaVM*

Internal values:
    jvm - the global, singleton, JVM instance (or None if not yet created)

Internal functions:
    raise_jni_err(msg, error) - takes a JNI error code and raises an exception is necessary
    jvm_add_init_hook(hook, priority)    - adds a function to call in the initialization process
        lower priorities run earlier, negative priorities run before JEnv initialization
    jvm_add_dealloc_hook(hook, priority) - adds a function to call in the destruction process
        higher priorities run earlier, working in reverse from initialization hooks
    jvm_create()  - creates and returns an uninitialized JVM instance
    jvm_destroy() - destroys the singleton JVM instance, shuts down the main JVM thread

Internal function types:
    jvm_hook - the type of functions given to jvm_add_<when>_hook()

FUTURE:
    fix JVM exit and abort hooks to allow GIL
"""

#from __future__ import absolute_import

include "version.pxi"

DEF MAX_HOOKS=16

from libc.stdlib cimport malloc, free
from libc.string cimport memmove

from .utils cimport str_ptr
from .unicode cimport any_to_utf8j, from_utf8j

from .jni cimport JNI_GetCreatedJavaVMs, JNI_CreateJavaVM, JNI_GetDefaultJavaVMInitArgs
from .jni cimport JavaVMOption, JavaVMInitArgs, JavaVMAttachArgs
from .jni cimport JNI_OK, JNI_EDETACHED, JNI_EVERSION, JNI_ENOMEM, JNI_EEXIST, JNI_EINVAL
from .jni cimport jint, jsize


########## JVM init/dealloc hooks ##########
# Current hooks and their priorities are:
#   def         -10  (jref)
#   jclasses    -8   (jref)
#   boxes       -7   (jref)
#   importer    -1   (packages)
#   jcf          1   (jref, no dealloc)
#   objects      2
#   p2j          3   (convert)
#   synth        4
#   array        5
#   numbers     10
#   collections 11
cdef int __n_init_hooks = 0, __n_dealloc_hooks = 0
cdef jvm_hook __init_hooks[MAX_HOOKS]
cdef int __init_hooks_pris[MAX_HOOKS]
cdef jvm_hook __dealloc_hooks[MAX_HOOKS]
cdef int __dealloc_hooks_pris[MAX_HOOKS]
cdef inline void __insert_hook(jvm_hook hook, int priority, jvm_hook* hooks, int* pris, int n) nogil:
    # TODO: use binary search instead of linear search
    cdef int i
    for i in xrange(n):
        if priority < pris[i]:
            memmove(hooks+i+1, hooks+i, (n-i)*sizeof(jvm_hook))
            memmove(pris+i+1,  pris+i,  (n-i)*sizeof(int))
            hooks[i] = hook
            pris[i] = priority
            return
    hooks[n] = hook
    pris[n] = priority
cdef void jvm_add_init_hook(jvm_hook hook, int priority):
    global __n_init_hooks
    __insert_hook(hook, priority, __init_hooks, __init_hooks_pris, __n_init_hooks)
    __n_init_hooks += 1
cdef void jvm_add_dealloc_hook(jvm_hook hook, int priority):
    global __n_dealloc_hooks
    __insert_hook(hook, priority, __dealloc_hooks, __dealloc_hooks_pris, __n_dealloc_hooks)
    __n_dealloc_hooks += 1


########## JVM Actions ##########
cdef class JVMAction(object):
    """
    An action that can be run on the main JVM thread. Default action is nothing, subclasses need to
    write their own run method which performs the desired action. This is designed to allow
    relatively easy implementation of callables and futures.
    """
    def __init__(self):
        import threading
        self.event = threading.Event()
    cpdef run(self, JEnv env):
        """Called to run the action. It is given the Java environment for the current thread."""
        pass
    property completed:
        """Check if the action has completed."""
        def __get__(self): return self.event.is_set()
    cpdef wait(self, timeout=None):
        """
        Wait for the action to be completed, returning True. If timeout if specified, wait at most
        that many seconds (can be a floating-point number). The return value in this case it True
        only if the action has completed and False if the timeout elapsed.
        """
        return self.event.wait(timeout)
    cpdef execute(self):
        """Asynchronously execute this action on the JVM main thread returning immediately."""
        jvm.run_action(self)
    cpdef execute_sync(self):
        """
        Synchronously execute this action on the JVM main thread returning when complete. If the
        action raises an exception, this raises an exception as well.
        """
        jvm.run_action(self)
        self.event.wait()
        self.check_exception()
    property exception:
        """
        Get the exception raised by calling `run`, if any. Gives `None` if no exception occured or
        the action has not been run.
        """
        def __get__(self): return self.exc
    property traceback:
        """
        Get the exception traceback raised by calling `run`, if any. Gives `None` if no exception
        occured or the action has not been run.
        """
        def __get__(self): return self.tb
    cpdef check_exception(self):
        """
        Checks the exception and if it is not `None`, raises it after clearing the exception data.
        """
        if self.exc is None: return
        ex = self.exc
        tb = self.tb
        self.exc = None
        self.tb = None
        raise ex, None, tb
    cpdef clear_exception(self):
        """Clears the exception data for the action."""
        self.exc = None
        self.tb = None

########## JVM Class ##########
cdef class JVM(object):
    """Class which wraps the native JavaVM pointer and contains a JEnv for each thread."""
    def run(self, list options, object start_event):
        """
        The JVM-Main thread function. Initializes the JVM, enters an event loop, and eventually
        destroys the JVM when signalled to stop.
        """
        import threading, time, sys
        self.main_thread = threading.current_thread()

        cdef JEnv env = JEnv()
        cdef jsize nVMs
        cdef JavaVMInitArgs args
        cdef int i = 0, retval
        cdef bint daemon
        cdef bytes name, opt
        try:
            retval = JNI_GetCreatedJavaVMs(&self.jvm, 1, &nVMs)
            raise_jni_err(u'Failed to find created Java VM', retval)
            if nVMs != 0:
                if len(options) != 0:
                    import warnings
                    warnings.warn(u'Java VM already created so specified options are ignored', RuntimeWarning)
                self.__attach(env)
            else:
                args.version = JNI_VERSION
                args.ignoreUnrecognized = False
                if len(options) > 0x7FFFFFFF: raise OverflowError()
                args.nOptions = <jint>(len(options)+3)
                args.options = <JavaVMOption*>malloc(sizeof(JavaVMOption)*args.nOptions)
                if args.options == NULL: raise MemoryError(u'Unable to allocate JavaVMInitArgs memory')
                options = [any_to_utf8j(option) for option in options]
                for i,opt in enumerate(options,3): args.options[i].optionString = opt
                with nogil:
                    args.options[0].optionString = b'vfprintf'
                    args.options[0].extraInfo    = <void*>vfprintf_hook
                    args.options[1].optionString = b'exit'
                    args.options[1].extraInfo    = <void*>jvm_exit_hook
                    args.options[2].optionString = b'abort'
                    args.options[2].extraInfo    = <void*>jvm_abort_hook
                    retval = JNI_CreateJavaVM(&self.jvm, <void**>&env.env, &args)
                    free(args.options)
                raise_jni_err(u'Failed to create Java VM', retval)
            del options
            
            # Set the environment
            self.tls = threading.local()
            self.tls.env = env
            
            # Create the action queue
            IF PY_VERSION < PY_VERSION_3:
                from Queue import Queue
            ELSE:
                from queue import Queue
            self.action_queue = Queue()

            # Initialize
            while i < __n_init_hooks and __init_hooks_pris[i] < 0: __init_hooks[i](env); i += 1 # early hooks
            env.check_exc() # check for any exceptions from during early initialization
            env.init()
            while i < __n_init_hooks: __init_hooks[i](env); i += 1
        except Exception as ex:
            # Failed to start, save the exception and die
            self.tls = None
            self.main_thread = None
            self.action_queue = None
            for i in xrange(i-1, -1, -1):
                try: __dealloc_hooks[i](env)
                except Exception as ex: pass
            if self.jvm is not NULL: self.jvm[0].DestroyJavaVM(self.jvm)
            self.exc = ex
            self.tb = sys.exc_info()[2]
            return

        # Started! This will release the jvm.start() function
        finally: start_event.set()
        del start_event
        time.sleep(0)
        
        # Run the action queue (event loop)
        cdef JVMAction action
        while True:
            action = self.action_queue.get()
            if action is None: break # stopping
            try:
                action.run(env)
            except Exception as ex:
                action.exc = ex
                action.tb = sys.exc_info()[2]
            finally:
                action.event.set()
        
        # Stopping
        for i in xrange(__n_dealloc_hooks-1, -1, -1):
            try:
                __dealloc_hooks[i](env)
            except Exception as ex:
                if self.exc is None:
                    self.exc = ex
                    self.tb = sys.exc_info()[2]

        # Collect garbage just in case
        import gc
        gc.collect()

        # Destroy the JVM
        retval = self.jvm[0].DestroyJavaVM(self.jvm)
        if self.exc is None:
            try: raise_jni_err(u'Failed to destroy Java VM', retval)
            except Exception as ex:
                self.exc = ex
                self.tb = sys.exc_info()[2]

    def check_pending_exception(self):
        """
        Checks if an exception has occured on the main JVM thread. If so, raises it on this thread
        and clears the pending exception.
        """
        if self.exc is None: return
        ex = self.exc
        tb = self.tb
        self.exc = None
        self.tb = None
        raise ex, None, tb

    cpdef int run_action(self, JVMAction action) except -1:
        """Runs a JVM action on the main JVM thread. This function returns immediately."""
        assert self.action_queue is not None
        action.event.clear()
        action.exc = None
        action.tb = None
        self.action_queue.put(action)
        return 0

    cdef int __attach(self, JEnv env) except -1:
        import threading
        t = threading.current_thread()
        cdef int retval
        cdef bint daemon = t.daemon
        IF JNI_VERSION < JNI_VERSION_1_2:
            with nogil:
                retval = self.jvm[0].AttachCurrentThreadAsDaemon(self.jvm, <void**>&env.env, NULL) if daemon else \
                         self.jvm[0].AttachCurrentThread(self.jvm, <void**>&env.env, NULL)
        ELSE:
            cdef bytes name = any_to_utf8j(t.name)
            cdef JavaVMAttachArgs args
            args.name = name
            with nogil:
                args.version = JNI_VERSION
                args.group = NULL
                retval = self.jvm[0].AttachCurrentThreadAsDaemon(self.jvm, <void**>&env.env, &args) if daemon else \
                         self.jvm[0].AttachCurrentThread(self.jvm, <void**>&env.env, &args)
        raise_jni_err(u'Failed to attach thread to Java VM', retval)
        env.init() # Initialize the environment
        return 0

    cdef JEnv env(self):
        """
        Get the Java environment for the current thread. If this thread is not yet attached to the
        Java VM it is attached.
        """
        cdef JEnv env
        if not hasattr(self.tls, 'env'):
            env = JEnv()
            self.__attach(env)
            self.tls.env = env
        return self.tls.env

    cdef int detach(self) except -1:
        """Detaches the current thread from the JVM"""
        assert hasattr(self.tls, 'env')
        cdef jint retval = self.jvm[0].DetachCurrentThread(self.jvm)
        raise_jni_err(u'Failed to detach thread', retval)
        del self.tls.env
        return 0

    cdef int destroy(self) except -1:
        """
        Destroys the JVM if it is started. Terminates the JVM Main Thread and waits for it to
        finish. May raise an exception if the JVM shutdown raises an issue, however the JVM and
        thread will still be shutdown and destroyed.
        """
        if self.jvm is not NULL:
            self.exc = None
            self.detach()
            self.action_queue.put(None)
            self.main_thread.join()
            self.main_thread = None
            self.action_queue = None
            self.tls = None
            self.jvm = NULL
            self.check_pending_exception()
        return 0
    def __del__(self): self.destroy()
    def __repr__(self): return u'<Java VM instance at %s>'%str_ptr(self.jvm)

cdef inline int raise_jni_err(unicode base, int err) except -1:
    """
    Raise an exception if the given err is not JNI_OK. The base is added as part of the error
    message. Raises one of MemoryError, ValueError, or RuntimeError depending on the error code.
    """
    if err == JNI_OK: return 0
    cdef unicode msg = u'%s: %d %s'%(base, err,
                        {JNI_EDETACHED:u'Thread detached from the VM',
                         JNI_EVERSION: u'JNI version error',
                         JNI_ENOMEM:   u'Not enough memory',
                         JNI_EEXIST:   u'VM already created',
                         JNI_EINVAL:   u'Invalid arguments'}.get(err,u'Unknown error'))
    if   err == JNI_ENOMEM: raise MemoryError(msg)
    elif err == JNI_EINVAL: raise ValueError(msg)
    else: raise RuntimeError(msg)


########## vprintfv JVM hook ##########
from libc.stdio cimport FILE, stderr as c_stderr
from libc.errno cimport errno, ENOMEM, EINVAL
cdef extern from 'stdarg.h' nogil:
    cdef struct _va_list
    ctypedef _va_list *va_list
cdef extern from 'stdio.h' nogil:
    cdef int vsnprintf(char * s, size_t n, const char * format, va_list arg)
cdef bint __vfprintf_begin_line = True
cdef int vfprintf_hook(FILE *stream, const char * format, va_list arg) nogil:
    """
    The vfprintf hook for the JVM that prints the output to the Python stdout/stderr instead of
    the C stdout and stderr. Lines are prefixed with 'JVM: '
    """
    global __vfprintf_begin_line
    cdef Py_ssize_t n
    cdef int retval = 1023
    cdef char* s
    while True:
        n = retval+1
        s = <char*>malloc(n*sizeof(char))
        if s is NULL:
            errno = ENOMEM
            return -1
        retval = vsnprintf(s, n, format, arg)
        if 0 <= retval < n: break
        else:
            free(s)
            if retval < 0: return retval
    with gil:
        try:
            out = from_utf8j(s)
            if __vfprintf_begin_line: out = u'JVM: ' + out
            import sys
            if stream == c_stderr: sys.stderr.write(out)
            else:                  sys.stdout.write(out)
            __vfprintf_begin_line = out[-1] == u'\n'
        except:
            errno = EINVAL
            return -1
        finally: free(s)
    return retval


########## exit and abort JVM hooks ##########
cdef void jvm_exit_hook(jint code) nogil:
    pass
cdef void jvm_abort_hook() nogil:
    pass

        
########## JVM Handling ##########
def jvm_get_default_options():
    """
    Get the default options for the JVM. No longer used in modern JNI veresion so just returns an
    empty list.
    """
    cdef JavaVMInitArgs args
    args.version = JNI_VERSION
    cdef int i, retval = JNI_GetDefaultJavaVMInitArgs(&args)
    if retval != JNI_OK: raise_jni_err(u'Failed to get default options of the Java VM', retval)
    return [from_utf8j(args.options[i].optionString) for i in xrange(args.nOptions)]
def jvm_create():
    """
    Only to be called by jvm_start(). If the JVM is already created then an exception is raised,
    otherwise the JVM is created and it is returned. Due to the GIL, only one thread can call this
    function at once and thus no race issues.
    """
    global jvm
    if jvm is not None: raise RuntimeError(u'JVM already created')
    jvm = JVM()
    return jvm
def jvm_destroy():
    """Calls destroy() on the current JVM, if there is a current JVM, otherwise a no-op."""
    global jvm
    if jvm is not None:
        jvm.destroy()
        jvm = None
