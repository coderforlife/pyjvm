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

from __future__ import absolute_import

from .jni cimport jobject, jarray, jsize, jboolean, jint, JNI_ABORT
from .core cimport JClass, JObject, JEnv, jenv


cdef class JArray(object):
    """
    The base type for Java arrays. Contains the Java references and the length of the array, but
    doesn't do much else.
    """
    cdef readonly JObject __object__
    cdef readonly jsize length
    cdef jarray arr # a simple copy of the reference actually stored in __object__
    cdef inline object wrap(self, JEnv env, JObject obj):
        self.__object__ = obj
        self.arr = obj.obj
        self.length = env.GetArrayLength(self.arr)

cdef struct JPrimArrayDef
cdef JPrimArrayDef* get_jpad(char sig) except NULL

cdef class JPrimitiveArray(JArray):
    cdef JPrimArrayDef* p
    """The primitive array definitions for this array."""

    @staticmethod
    cdef JPrimitiveArray new_raw(JEnv env, object cls, Py_ssize_t length, JPrimArrayDef* p)

    @staticmethod
    cdef JPrimitiveArray wrap_arr(JEnv env, object cls, JObject obj, JPrimArrayDef* p)

    @staticmethod
    cdef JPrimitiveArray create(object args, object cls, JPrimArrayDef* p)

    cdef copy(self, jsize i, jsize j)

ctypedef void (*ReleasePrimArrayElements)(JEnv env, jarray array, void *elems, jint mode)

cdef class JPrimArrayPointer(object):
    cdef JPrimitiveArray arr
    cdef JEnv env
    cdef void* ptr
    cdef bint readonly
    cdef jboolean isCopy
    cdef ReleasePrimArrayElements rel
    cdef inline release(self):
        cdef JEnv env = self.env
        if self.ptr is not NULL:
            if env is None: env = jenv()
            self.rel(env, self.arr.arr, self.ptr, JNI_ABORT if self.readonly and self.isCopy else 0)
            self.ptr = NULL
            self.arr = None
            self.env = None

cdef class JObjectArray(JArray):
    @staticmethod
    cdef unicode get_objarr_classname(JClass elemClass)
    @staticmethod
    cdef JObjectArray new_raw(JEnv env, Py_ssize_t length, JClass elementClass, jobject init=*)
    @staticmethod
    cdef JObjectArray create(object args, JClass elementClass)
