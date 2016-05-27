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

Internal function types:
    jvm_hook - the type of functions given to JVM.add_<when>_hook()

Internal functions:
   jvm()  - gets the global, singleton, JVM instance, creating it if necessary
   jenv() - gets the current thread's JEnv variable, creating it as necessary
   raise_jni_err(msg, error) - takes a JNI error code and raises an exception is necessary
   jvm_create()  - creates and returns an uninitialized JVM instance
   jvm_destroy() - destroys the singleton JVM instance, shuts down the main JVM thread

FUTURE:
    hook JVM exit and abort?
"""


from libc.stdlib cimport malloc, free

########## JVM init/dealloc hooks ##########
ctypedef int (*jvm_hook)(JEnv env) except -1
cdef int __n_early_init_hooks = 0, __n_init_hooks = 0, __n_dealloc_hooks = 0
cdef jvm_hook __early_init_hooks[16]
cdef jvm_hook __init_hooks[16]
cdef jvm_hook __dealloc_hooks[16]


########## JVM Actions ##########
cdef class JVMAction(object):
    """
    An action that can be run on the main JVM thread. Default action is nothing, subclasses need to
    write their own run method which performs the desired action. This is designed to allow
    relatively easy implementation of callables and futures.
    """
    cdef object event
    cdef object exc, tb
    def __init__(self):
        import threading
        self.event = threading.Event()
    cpdef int run(self, JEnv env) except -1:
        """Called to run the action. It is given the Java environment for the current thread."""
        pass
    property completed:
        """Check if the action has completed."""
        def __get__(self): return self.event.is_set()
    cpdef bint wait(self, timeout=None):
        """
        Wait for the action to be completed, returning True. If timeout if specified, wait at most
        that many seconds (can be a floating-point number). The return value in this case it True
        only if the action has completed and False if the timeout elapsed.
        """
        return self.event.wait(timeout)
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
    cpdef int check_exception(self) except -1:
        """
        Checks the exception and if it is not `None`, raises it after clearing the exception data.
        """
        if self.exc is None: return 0
        ex = self.exc
        tb = self.tb
        self.exc = None
        self.tb = None
        raise ex, None, tb
    cpdef int clear_exception(self) except -1:
        """Clears the exception data for the action."""
        self.exc = None
        self.tb = None
        return 0


    
########## JVM Class ##########
cdef class JVM(object):
    """Class which wraps the native JavaVM pointer and contains a JEnv for each thread."""
    cdef JavaVM* jvm
    cdef object tls
    cdef object main_thread
    cdef object exc, tb
    cdef object action_queue
    def run(self, list options, object start_event):
        """
        The JVM-Main thread function. Initializes the JVM, enters an event loop, and eventually
        destroys the JVM when signalled to stop.
        """
        import threading, sys
        self.main_thread = threading.current_thread()
        
        cdef JEnv env = JEnv()
        cdef jsize nVMs
        cdef JavaVMInitArgs args
        cdef int i, retval
        cdef bint daemon
        cdef bytes name, opt
        try:
            retval = JNI_GetCreatedJavaVMs(&self.jvm, 1, &nVMs)
            raise_jni_err('Failed to find created Java VM', retval)
            if nVMs != 0:
                if len(options) != 0:
                    import warnings
                    warnings.warn('Java VM already created so specified options are ignored', RuntimeWarning)
                self.__attach(env)
            else:
                # TODO: hook exit and abort
                args.version = JNI_VERSION
                if len(options) > 0x7FFFFFFF: raise OverflowError()
                args.nOptions = <jint>(len(options)+1)
                args.options = <JavaVMOption*>malloc(sizeof(JavaVMOption)*args.nOptions)
                if args.options == NULL: raise MemoryError('Unable to allocate JavaVMInitArgs memory')
                options = [any_to_utf8j(option) for option in options]
                for i,opt in enumerate(options,1): args.options[i].optionString = opt
                with nogil:
                    args.options[0].optionString = 'vfprintf'
                    args.options[0].extraInfo    = <void*>vfprintf_hook
                    retval = JNI_CreateJavaVM(&self.jvm, <void**>&env.env, &args)
                    free(args.options)
                raise_jni_err('Failed to create Java VM', retval)
            del options
                
            # Set the environment
            self.tls = threading.local()
            self.tls.env = env
            
            # Initialize
            for i in xrange(__n_early_init_hooks):
                __early_init_hooks[i](env)
            env.check_exc() # check for any exceptions from during early initialization
            env.init()
            for i in xrange(__n_init_hooks):
                __init_hooks[i](env)
            
        except Exception as ex:
            # Failed to start, save the exception and die
            self.tls = None
            self.main_thread = None
            self.exc = ex
            self.tb = sys.exc_info()[2]
            return None
        
        # Started!
        finally: start_event.set()
        del start_event
            
        # Run the action queue (event loop)
        from Queue import Queue
        self.action_queue = Queue()
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
        for i in xrange(__n_dealloc_hooks):
            try:
                __dealloc_hooks[i](env)
            except Exception as ex:
                if self.exc is None:
                    self.exc = ex
                    self.tb = sys.exc_info()[2]
        
        # Collect garbage just in case
        from gc import collect
        collect()
        
        retval = self.jvm[0].DestroyJavaVM(self.jvm)
        if self.exc is None:
            try: raise_jni_err('Failed to destroy Java VM', retval)
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
        
    @staticmethod
    cdef void add_early_init_hook(jvm_hook hook):
        global __n_early_init_hooks
        __early_init_hooks[__n_early_init_hooks] = hook
        __n_early_init_hooks += 1

    @staticmethod
    cdef void add_init_hook(jvm_hook hook):
        global __n_init_hooks
        __init_hooks[__n_init_hooks] = hook
        __n_init_hooks += 1

    @staticmethod
    cdef void add_dealloc_hook(jvm_hook hook):
        global __n_dealloc_hooks
        __dealloc_hooks[__n_dealloc_hooks] = hook
        __n_dealloc_hooks += 1
        
    cpdef int run_action(self, JVMAction action) except -1:
        """Runs a JVM action on the main JVM thread. This function returns immediately."""
        assert self.action_queue is not None
        import threading
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
        raise_jni_err('Failed to attach thread to Java VM', retval)
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

    cdef inline is_attached(self):
        """Returns true if the current thread is currently attached to this JVM"""
        return hasattr(self.tls, 'env')
        
    cdef detach(self):
        """Detaches the current thread from the JVM"""
        assert hasattr(self.tls, 'env')
        cdef jint retval = self.jvm[0].DetachCurrentThread(self.jvm)
        raise_jni_err('Failed to detach thread', retval)
        del self.tls.env

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
    def __repr__(self): return '<Java VM instance at %s>'%str_ptr(self.jvm)

cdef inline int raise_jni_err(unicode base, int err) except -1:
    """
    Raise an exception if the given err is not JNI_OK. The base is added as part of the error
    message. Raises one of MemoryError, ValueError, or RuntimeError depending on the error code.
    """
    if err == JNI_OK: return 0
    cdef unicode msg = '%s: %d %s'%(base, err,
                        {JNI_EDETACHED:'Thread detached from the VM',
                         JNI_EVERSION: 'JNI version error',
                         JNI_ENOMEM:   'Not enough memory',
                         JNI_EEXIST:   'VM already created',
                         JNI_EINVAL:   'Invalid arguments'}.get(err,'Unknown error'))
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
            out = s
            if __vfprintf_begin_line: out = 'JVM: ' + out
            import sys
            if stream == c_stderr: sys.stderr.write(out)
            else:                  sys.stdout.write(out)
            __vfprintf_begin_line = out[-1] == '\n'
        except:
            errno = EINVAL
            return -1
    free(s)
    return retval


########## JVM Handling ##########
cdef JVM _jvm = None
def jvm_get_default_options():
    """
    Get the default options for the JVM. No longer used in modern JNI veresion so just returns an
    empty list.
    """
    cdef JavaVMInitArgs args
    args.version = JNI_VERSION
    cdef int i, retval = JNI_GetDefaultJavaVMInitArgs(&args)
    if retval != JNI_OK: raise_jni_err('Failed to get default options of the Java VM', retval)
    return [from_utf8j(args.options[i].optionString) for i in xrange(args.nOptions)]
def jvm_create():
    """
    Only to be called by jvm_start(). If the JVM is already created then an exception is raised,
    otherwise the JVM is created and it is returned. Due to the GIL, only one thread can call this
    function at once and thus no race issues.
    """
    global _jvm
    if _jvm is not None: raise RuntimeError('JVM already created')
    _jvm = JVM()
    return _jvm
def jvm_destroy():
    """Calls destroy() on the current JVM, if there is a current JVM, otherwise a no-op."""
    global _jvm
    if _jvm is not None:
        _jvm.destroy()
        _jvm = None

cdef inline JVM jvm():
    """Gets the global, singleton, JVM object or None if it isn't currently created."""
    return _jvm
cdef inline JEnv jenv():
    """Gets the JEnv object for the current thread, creating it if necessary."""
    return jvm().env()
