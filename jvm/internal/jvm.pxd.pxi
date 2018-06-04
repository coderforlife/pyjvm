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
"""

#from __future__ import absolute_import

from .jni cimport JavaVM
#from .jenv cimport JEnv


########## JVM init/dealloc hooks ##########
ctypedef int (*jvm_hook)(JEnv env) except -1
cdef void jvm_add_init_hook(jvm_hook hook, int priority)
cdef void jvm_add_dealloc_hook(jvm_hook hook, int priority)


########## JVM Actions ##########
cdef class JVMAction(object):
    """
    An action that can be run on the main JVM thread. Default action is nothing, subclasses need to
    write their own run method which performs the desired action. This is designed to allow
    relatively easy implementation of callables and futures.
    """
    cdef object event
    cdef object exc, tb
    cpdef run(self, JEnv env)
    cpdef execute(self)
    cpdef execute_sync(self)
    cpdef wait(self, timeout=*)
    cpdef check_exception(self)
    cpdef clear_exception(self)


########## JVM Class ##########
cdef class JVM(object):
    """Class which wraps the native JavaVM pointer and contains a JEnv for each thread."""
    cdef JavaVM* jvm
    cdef object tls
    cdef object main_thread
    cdef object exc, tb
    cdef object action_queue
    cpdef int run_action(self, JVMAction action) except -1
    cdef int __attach(self, JEnv env) except -1
    cdef JEnv env(self)
    cdef inline is_attached(self):
        """Returns true if the current thread is currently attached to this JVM"""
        return hasattr(self.tls, 'env')
    cdef int detach(self) except -1
    cdef int destroy(self) except -1
cdef JVM jvm = None # the global, singleton, JVM object or None if it isn't currently created
#cdef int raise_jni_err(unicode base, int err) except -1
