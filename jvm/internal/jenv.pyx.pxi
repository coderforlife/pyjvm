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

Java Native Interface Environment Wrapper
-----------------------------------------

Wrapper for the JNI environment. Has easy to use, error-checking, possibly GIL-releasing, versions
of nearly all JNIEnv functions with some minimal type conversions. Most of the code is in inline
functions within the PXD file.

Internal classes:
    JEnv - the JNIEnv* wrapper

Internal functions:
    jenv() - gets the current thread's JEnv variable, creating it as necessary
    py2<primitive>(...) - converts a Python object to a specific Java primitive

FUTURE:
    modify traceback of exceptions to show Java information
"""

#from __future__ import absolute_import

from cpython.unicode cimport PyUnicode_DecodeUTF16

from .utils cimport PyThreadState, PyEval_SaveThread, PyEval_RestoreThread
from .utils cimport str_ptr
from .unicode cimport unichr, to_utf8j
#from .jvm cimport raise_jni_err
#from .jref cimport JClass, JObject, ThreadDef, ClassLoaderDef


cdef class JEnv(object):
    """
    Class which wraps the native JNIEnv pointer. One of these is created for each thread. This
    provides several function that are wrappers around the JNIEnv functions.
    """

    def __repr__(self): return u'<Java Environment instance at %s>'%str_ptr(self.env)

    cdef int init(self) except -1:
        """
        Initializes the environemnt for a thread. In particular this sets the thread's context
        class loader to the system class loader like Java normally does instead of the default
        bootstrap class loader used when loading from JNI.
        """
        self.EnsureLocalCapacity(256) # Make sure we can handle a large number of local references
        cdef jobject cur_thrd = self.CallStaticObject(ThreadDef.clazz, ThreadDef.currentThread)
        cdef jobject loader
        cdef jvalue val
        try:
            loader = self.CallObject(cur_thrd, ThreadDef.getContextClassLoader)
            if loader is not NULL: self.DeleteLocalRef(loader)
            else:
                val.l = self.CallStaticObject(ClassLoaderDef.clazz, ClassLoaderDef.getSystemClassLoader)
                try: self.CallVoid(cur_thrd, ThreadDef.setContextClassLoader, &val)
                finally: self.DeleteLocalRef(val.l)
        finally: self.DeleteLocalRef(cur_thrd)
        return 0

    # Basic Conversion
    cdef unicode pystr(self, jstring string, delete=True):
        """Converts a jstring to a Python unicode object. The jstring object is deleted."""
        if string is NULL: return None
        cdef JNIEnv* env = self.env
        cdef jsize length
        cdef const jchar *chars
        try:
            length = env[0].GetStringLength(env, string)
            if length < 0: self.__raise_exception(); return
            chars = env[0].GetStringCritical(env, string, NULL)
            if chars is NULL: self.__raise_exception(); return
            try: return PyUnicode_DecodeUTF16(<char*>chars, length*sizeof(jchar), NULL, NULL)
            finally: env[0].ReleaseStringCritical(env, string, chars)
        finally:
            if delete: self.DeleteRef(string)
    cdef object __object2py(self, jobject obj):
        # This is the same as convert.object2py but we can't cimport functions from that module
        # here so we reproduce it.
        if obj is NULL: return None # null -> None
        cdef JClass clazz = JClass.get(self, self.GetObjectClass(obj))
        if clazz.name == u'java.lang.String': return self.pystr(<jstring>obj)
        from .objects import create_java_object
        return create_java_object(self, JObject.create(self, obj))

    # Checking exceptions
    cdef int __raise_exception(self) except -1:
        """
        Raises the current exception from the JVM as a Python exception. Does not check if these is
        an exception to be raised, just does it.
        """
        assert self.env[0].ExceptionCheck(self.env)
        if jvm.action_queue is None: # the JVM has not yet run all of the initializers
            self.env[0].ExceptionDescribe(self.env)
            self.env[0].ExceptionClear(self.env)
            raise SystemError(u'Java exception throw during pyjvm initialization')

        # Get the Java exception
        cdef jthrowable t = self.env[0].ExceptionOccurred(self.env)
        self.env[0].ExceptionClear(self.env)

        # TODO: remove one or two frames off the bottom of the traceback and then add the Java
        # stack trace onto it, also the traceback is off when re-raise a Python exception

        # Check if the exception is actually a Python exception
        from .objects import create_java_object
        from .synth import PyException
        if self.IsAssignableFrom(self.GetObjectClass(t), (<JClass>PyException.__jclass__).clazz):
            raise create_java_object(self, JObject.create(self, t)).exc
        cdef jthrowable cause = <jthrowable>self.CallObject(t, ThrowableDef.getCause)
        if cause is not NULL and self.IsAssignableFrom(self.GetObjectClass(cause), (<JClass>PyException.__jclass__).clazz):
            raise create_java_object(self, JObject.create(self, cause)).exc

        # Just throw the Java exception
        raise create_java_object(self, JObject.create(self, t))

    # Miscellaneous Operations
    cdef jint GetVersion(self) except -1:
        cdef jint version = self.env[0].GetVersion(self.env)
        if version < 0: raise_jni_err(u'Failed to get JNI version', version)
        return version

    # Class Operations
    cdef jobject DefineClass(self, unicode name, jobject loader, bytes buf) except NULL:
        assert buf is not None
        cdef jclass clazz
        if name is None:
            clazz = self.env[0].DefineClass(self.env, NULL, loader, buf, <jsize>len(buf))
        else:
            clazz = self.env[0].DefineClass(self.env, to_utf8j(name.replace(u'.', u'/')), loader, buf, <jsize>len(buf))
        if clazz is NULL: self.__raise_exception()
        return clazz
    #cdef inline jclass FindClass(self, unicode name) except NULL:
    #cdef inline jclass GetSuperclass(self, jclass clazz) except? NULL:
    #cdef inline bint IsAssignableFrom(self, jclass clazz1, jclass clazz2) except -1:

    # Module Operations
    IF JNI_VERSION >= JNI_VERSION_9:
        cdef jobject GetModule(self, jclass clazz) except NULL:
            assert clazz is not NULL
            cdef jobject module = self.env[0].GetModule(self.env, clazz)
            if module is NULL: self.__raise_exception()
            return module

    # Exceptions - no error checking for any of these functions since they all manipulate the exception state
    #cdef inline jint Throw(self, jthrowable obj):
    cdef jint ThrowNew(self, jclass clazz, unicode message):
        assert clazz is not NULL and message is not None
        return self.env[0].ThrowNew(self.env, clazz, to_utf8j(message))
    cdef jthrowable ExceptionOccurred(self): return self.env[0].ExceptionOccurred(self.env)
    cdef void ExceptionDescribe(self): self.env[0].ExceptionDescribe(self.env)
    cdef void ExceptionClear(self): self.env[0].ExceptionClear(self.env)
    cdef void FatalError(self, unicode msg):
        assert msg is not None
        self.env[0].FatalError(self.env, to_utf8j(msg))
    cdef bint ExceptionCheck(self): return self.env[0].ExceptionCheck(self.env) == JNI_TRUE

    # Global and Local References
    #cdef inline jobject NewGlobalRef(self, jobject obj) except NULL:
    #cdef inline int DeleteGlobalRef(self, jobject globalRef) except -1:
    #cdef inline jobject NewLocalRef(self, jobject ref) except NULL:
    #cdef inline int DeleteLocalRef(self, jobject localRef) except -1:
    cdef int EnsureLocalCapacity(self, jint capacity) except -1:
        assert capacity >= 0
        cdef jint result = self.env[0].EnsureLocalCapacity(self.env, capacity)
        if result < 0: self.check_exc()
        return 0
    cdef int PushLocalFrame(self, jint capacity) except -1:
        assert capacity >= 0
        cdef jint result = self.env[0].PushLocalFrame(self.env, capacity)
        if result < 0: self.check_exc()
        return 0
    cdef jobject PopLocalFrame(self, jobject result) except? NULL:
        cdef jobject out = self.env[0].PopLocalFrame(self.env, result)
        if out is NULL: self.check_exc()
        return out

    # Weak Global References
    #cdef inline jweak NewWeakGlobalRef(self, jobject obj) except? NULL:
    #cdef inline int DeleteWeakGlobalRef(self, jweak obj) except -1:

    # Object Operations
    cdef jobject AllocObject(self, jclass clazz) except NULL:
        assert clazz is not NULL
        cdef jobject obj = self.env[0].AllocObject(self.env, clazz)
        if obj is NULL: self.__raise_exception()
        return obj
    cdef jobject NewObject(self, jclass clazz, jmethodID methodID, const jvalue *args, bint withgil) except NULL:
        assert clazz is not NULL and methodID is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jobject out = self.env[0].NewObjectA(self.env, clazz, methodID, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        if out is NULL: self.__raise_exception()
        return out
    #cdef inline jclass GetObjectClass(self, jobject obj) except NULL:
    IF JNI_VERSION >= JNI_VERSION_1_6:
        cdef jobjectRefType GetObjectRefType(self, jobject obj) except <jobjectRefType>-1:
            cdef jobjectRefType out = self.env[0].GetObjectRefType(self.env, obj)
            if out == JNIInvalidRefType: self.check_exc()
            return out
    #cdef inline bint IsInstanceOf(self, jobject obj, jclass clazz) except -1:
    #cdef inline bint IsSameObject(self, jobject ref1, jobject ref2) except -1:

    # Accessing Fields of Objects
    #cdef inline jfieldID GetFieldID(self, jclass clazz, unicode name, unicode sig) except NULL:
    cdef object GetObjectField(self, jobject obj, jfieldID fieldID):
        assert obj is not NULL and fieldID is not NULL
        cdef jobject out = self.env[0].GetObjectField(self.env, obj, fieldID)
        self.check_exc()
        return self.__object2py(out)
    cdef object GetBooleanField(self, jobject obj, jfieldID fieldID):
        assert obj is not NULL and fieldID is not NULL
        cdef jboolean out = self.env[0].GetBooleanField(self.env, obj, fieldID)
        self.check_exc()
        return out == JNI_TRUE
    cdef object GetByteField(self, jobject obj, jfieldID fieldID):
        assert obj is not NULL and fieldID is not NULL
        cdef jbyte out = self.env[0].GetByteField(self.env, obj, fieldID)
        self.check_exc()
        return out
    cdef object GetCharField(self, jobject obj, jfieldID fieldID):
        assert obj is not NULL and fieldID is not NULL
        cdef jchar out = self.env[0].GetCharField(self.env, obj, fieldID)
        self.check_exc()
        return unichr(out)
    cdef object GetShortField(self, jobject obj, jfieldID fieldID):
        assert obj is not NULL and fieldID is not NULL
        cdef jshort out = self.env[0].GetShortField(self.env, obj, fieldID)
        self.check_exc()
        return out
    cdef object GetIntField(self, jobject obj, jfieldID fieldID):
        assert obj is not NULL and fieldID is not NULL
        cdef jint out = self.env[0].GetIntField(self.env, obj, fieldID)
        self.check_exc()
        return out
    cdef object GetLongField(self, jobject obj, jfieldID fieldID):
        assert obj is not NULL and fieldID is not NULL
        cdef jlong out = self.env[0].GetLongField(self.env, obj, fieldID)
        self.check_exc()
        return out
    cdef object GetFloatField(self, jobject obj, jfieldID fieldID):
        assert obj is not NULL and fieldID is not NULL
        cdef jfloat out = self.env[0].GetFloatField(self.env, obj, fieldID)
        self.check_exc()
        return out
    cdef object GetDoubleField(self, jobject obj, jfieldID fieldID):
        assert obj is not NULL and fieldID is not NULL
        cdef jdouble out = self.env[0].GetDoubleField(self.env, obj, fieldID)
        self.check_exc()
        return out

    cdef int SetObjectField(self, jobject obj, JField field, object value) except -1:
        assert obj is not NULL and field is not None
        from .convert import py2object_py
        cdef JObject val = <JObject>py2object_py(self, value, field.type)
        self.env[0].SetObjectField(self.env, obj, field.id, val.obj)
        self.check_exc()
        return 0
    cdef int SetBooleanField(self, jobject obj, JField field, object value) except -1:
        assert obj is not NULL and field is not None and value is not None
        self.env[0].SetBooleanField(self.env, obj, field.id, py2boolean(value))
        self.check_exc()
        return 0
    cdef int SetByteField(self, jobject obj, JField field, object value) except -1:
        assert obj is not NULL and field is not None and value is not None
        self.env[0].SetByteField(self.env, obj, field.id, py2byte(value))
        self.check_exc()
        return 0
    cdef int SetCharField(self, jobject obj, JField field, object value) except -1:
        assert obj is not NULL and field is not None and value is not None
        self.env[0].SetCharField(self.env, obj, field.id, py2char(value))
        self.check_exc()
        return 0
    cdef int SetShortField(self, jobject obj, JField field, object value) except -1:
        assert obj is not NULL and field is not None and value is not None
        self.env[0].SetShortField(self.env, obj, field.id, py2short(value))
        self.check_exc()
        return 0
    cdef int SetIntField(self, jobject obj, JField field, object value) except -1:
        assert obj is not NULL and field is not None and value is not None
        self.env[0].SetIntField(self.env, obj, field.id, py2int(value))
        self.check_exc()
        return 0
    cdef int SetLongField(self, jobject obj, JField field, object value) except -1:
        assert obj is not NULL and field is not None and value is not None
        self.env[0].SetLongField(self.env, obj, field.id, py2long(value))
        self.check_exc()
        return 0
    cdef int SetFloatField(self, jobject obj, JField field, object value) except -1:
        assert obj is not NULL and field is not None and value is not None
        self.env[0].SetFloatField(self.env, obj, field.id, py2float(value))
        self.check_exc()
        return 0
    cdef int SetDoubleField(self, jobject obj, JField field, object value) except -1:
        assert obj is not NULL and field is not None and value is not None
        self.env[0].SetDoubleField(self.env, obj, field.id, py2double(value))
        self.check_exc()
        return 0

    # Calling Instance Methods
    #cdef inline jmethodID GetMethodID(self, jclass clazz, unicode name, unicode sig) except NULL:
    cdef object CallObjectMethod(self, jobject obj, jmethodID method, const jvalue *args, bint withgil):
        assert obj is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jobject out = self.env[0].CallObjectMethodA(self.env, obj, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return self.__object2py(out)
    cdef object CallVoidMethod(self, jobject obj, jmethodID method, const jvalue *args, bint withgil):
        assert obj is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        self.env[0].CallVoidMethodA(self.env, obj, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return None
    cdef object CallBooleanMethod(self, jobject obj, jmethodID method, const jvalue *args, bint withgil):
        assert obj is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jboolean out = self.env[0].CallBooleanMethodA(self.env, obj, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return out == JNI_TRUE
    cdef object CallByteMethod(self, jobject obj, jmethodID method, const jvalue *args, bint withgil):
        assert obj is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jbyte out = self.env[0].CallByteMethodA(self.env, obj, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return out
    cdef object CallCharMethod(self, jobject obj, jmethodID method, const jvalue *args, bint withgil):
        assert obj is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jchar out = self.env[0].CallCharMethodA(self.env, obj, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return unichr(out)
    cdef object CallShortMethod(self, jobject obj, jmethodID method, const jvalue *args, bint withgil):
        assert obj is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jshort out = self.env[0].CallShortMethodA(self.env, obj, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return out
    cdef object CallIntMethod(self, jobject obj, jmethodID method, const jvalue *args, bint withgil):
        assert obj is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jint out = self.env[0].CallIntMethodA(self.env, obj, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return out
    cdef object CallLongMethod(self, jobject obj, jmethodID method, const jvalue *args, bint withgil):
        assert obj is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jlong out = self.env[0].CallLongMethodA(self.env, obj, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return out
    cdef object CallFloatMethod(self, jobject obj, jmethodID method, const jvalue *args, bint withgil):
        assert obj is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jfloat out = self.env[0].CallFloatMethodA(self.env, obj, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return out
    cdef object CallDoubleMethod(self, jobject obj, jmethodID method, const jvalue *args, bint withgil):
        assert obj is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jdouble out = self.env[0].CallDoubleMethodA(self.env, obj, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return out

    cdef object CallNonvirtualObjectMethod(self, jobject obj, jclass clazz, jmethodID method, const jvalue *args, bint withgil):
        assert obj is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jobject out = self.env[0].CallNonvirtualObjectMethodA(self.env, obj, clazz, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return self.__object2py(obj)
    cdef object CallNonvirtualVoidMethod(self, jobject obj, jclass clazz, jmethodID method, const jvalue *args, bint withgil):
        assert obj is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        self.env[0].CallNonvirtualVoidMethodA(self.env, obj, clazz, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return None
    cdef object CallNonvirtualBooleanMethod(self, jobject obj, jclass clazz, jmethodID method, const jvalue *args, bint withgil):
        assert obj is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jboolean out = self.env[0].CallNonvirtualBooleanMethodA(self.env, obj, clazz, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return out == JNI_TRUE
    cdef object CallNonvirtualByteMethod(self, jobject obj, jclass clazz, jmethodID method, const jvalue *args, bint withgil):
        assert obj is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jbyte out = self.env[0].CallNonvirtualByteMethodA(self.env, obj, clazz, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return out
    cdef object CallNonvirtualCharMethod(self, jobject obj, jclass clazz, jmethodID method, const jvalue *args, bint withgil):
        assert obj is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jchar out = self.env[0].CallNonvirtualCharMethodA(self.env, obj, clazz, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return unichr(out)
    cdef object CallNonvirtualShortMethod(self, jobject obj, jclass clazz, jmethodID method, const jvalue *args, bint withgil):
        assert obj is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jshort out = self.env[0].CallNonvirtualShortMethodA(self.env, obj, clazz, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return out
    cdef object CallNonvirtualIntMethod(self, jobject obj, jclass clazz, jmethodID method, const jvalue *args, bint withgil):
        assert obj is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jint out = self.env[0].CallNonvirtualIntMethodA(self.env, obj, clazz, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return out
    cdef object CallNonvirtualLongMethod(self, jobject obj, jclass clazz, jmethodID method, const jvalue *args, bint withgil):
        assert obj is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jlong out = self.env[0].CallNonvirtualLongMethodA(self.env, obj, clazz, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return out
    cdef object CallNonvirtualFloatMethod(self, jobject obj, jclass clazz, jmethodID method, const jvalue *args, bint withgil):
        assert obj is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jfloat out = self.env[0].CallNonvirtualFloatMethodA(self.env, obj, clazz, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return out
    cdef object CallNonvirtualDoubleMethod(self, jobject obj, jclass clazz, jmethodID method, const jvalue *args, bint withgil):
        assert obj is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jdouble out = self.env[0].CallNonvirtualDoubleMethodA(self.env, obj, clazz, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return out

    # Accessing Static Fields
    #cdef inline jfieldID GetStaticFieldID(self, jclass clazz, unicode name, unicode sig) except NULL:
    cdef object GetStaticObjectField(self, jclass clazz, jfieldID fieldID):
        assert clazz is not NULL and fieldID is not NULL
        cdef jobject out = self.env[0].GetStaticObjectField(self.env, clazz, fieldID)
        self.check_exc()
        return self.__object2py(out)
    cdef object GetStaticBooleanField(self, jclass clazz, jfieldID fieldID):
        assert clazz is not NULL and fieldID is not NULL
        cdef jboolean out = self.env[0].GetStaticBooleanField(self.env, clazz, fieldID)
        self.check_exc()
        return out == JNI_TRUE
    cdef object GetStaticByteField(self, jclass clazz, jfieldID fieldID):
        assert clazz is not NULL and fieldID is not NULL
        cdef jbyte out = self.env[0].GetStaticByteField(self.env, clazz, fieldID)
        self.check_exc()
        return out
    cdef object GetStaticCharField(self, jclass clazz, jfieldID fieldID):
        assert clazz is not NULL and fieldID is not NULL
        cdef jchar out = self.env[0].GetStaticCharField(self.env, clazz, fieldID)
        self.check_exc()
        return unichr(out)
    cdef object GetStaticShortField(self, jclass clazz, jfieldID fieldID):
        assert clazz is not NULL and fieldID is not NULL
        cdef jshort out = self.env[0].GetStaticShortField(self.env, clazz, fieldID)
        self.check_exc()
        return out
    cdef object GetStaticIntField(self, jclass clazz, jfieldID fieldID):
        assert clazz is not NULL and fieldID is not NULL
        cdef jint out = self.env[0].GetStaticIntField(self.env, clazz, fieldID)
        self.check_exc()
        return out
    cdef object GetStaticLongField(self, jclass clazz, jfieldID fieldID):
        assert clazz is not NULL and fieldID is not NULL
        cdef jlong out = self.env[0].GetStaticLongField(self.env, clazz, fieldID)
        self.check_exc()
        return out
    cdef object GetStaticFloatField(self, jclass clazz, jfieldID fieldID):
        assert clazz is not NULL and fieldID is not NULL
        cdef jfloat out = self.env[0].GetStaticFloatField(self.env, clazz, fieldID)
        self.check_exc()
        return out
    cdef object GetStaticDoubleField(self, jclass clazz, jfieldID fieldID):
        assert clazz is not NULL and fieldID is not NULL
        cdef jdouble out = self.env[0].GetStaticDoubleField(self.env, clazz, fieldID)
        self.check_exc()
        return out

    cdef int SetStaticObjectField(self, jclass clazz, JField field, object value) except -1:
        assert clazz is not NULL and field is not None
        from .convert import py2object_py
        cdef JObject val = <JObject>py2object_py(self, value, field.type)
        self.env[0].SetObjectField(self.env, clazz, field.id, val.obj)
        self.check_exc()
        return 0
    cdef int SetStaticBooleanField(self, jclass clazz, JField field, object value) except -1:
        assert clazz is not NULL and field is not None and value is not None
        self.env[0].SetStaticBooleanField(self.env, clazz, field.id, py2boolean(value))
        self.check_exc()
        return 0
    cdef int SetStaticByteField(self, jclass clazz, JField field, object value) except -1:
        assert clazz is not NULL and field is not None and value is not None
        self.env[0].SetStaticByteField(self.env, clazz, field.id, py2byte(value))
        self.check_exc()
        return 0
    cdef int SetStaticCharField(self, jclass clazz, JField field, object value) except -1:
        assert clazz is not NULL and field is not None and value is not None
        self.env[0].SetStaticCharField(self.env, clazz, field.id, py2char(value))
        self.check_exc()
        return 0
    cdef int SetStaticShortField(self, jclass clazz, JField field, object value) except -1:
        assert clazz is not NULL and field is not None and value is not None
        self.env[0].SetStaticShortField(self.env, clazz, field.id, py2short(value))
        self.check_exc()
        return 0
    cdef int SetStaticIntField(self, jclass clazz, JField field, object value) except -1:
        assert clazz is not NULL and field is not None and value is not None
        self.env[0].SetStaticIntField(self.env, clazz, field.id, py2int(value))
        self.check_exc()
        return 0
    cdef int SetStaticLongField(self, jclass clazz, JField field, object value) except -1:
        assert clazz is not NULL and field is not None and value is not None
        self.env[0].SetStaticLongField(self.env, clazz, field.id, py2long(value))
        self.check_exc()
        return 0
    cdef int SetStaticFloatField(self, jclass clazz, JField field, object value) except -1:
        assert clazz is not NULL and field is not None and value is not None
        self.env[0].SetStaticFloatField(self.env, clazz, field.id, py2float(value))
        self.check_exc()
        return 0
    cdef int SetStaticDoubleField(self, jclass clazz, JField field, object value) except -1:
        assert clazz is not NULL and field is not None and value is not None
        self.env[0].SetStaticDoubleField(self.env, clazz, field.id, py2double(value))
        self.check_exc()
        return 0

    # Calling Static Methods
    #cdef inline jmethodID GetStaticMethodID(self, jclass clazz, unicode name, unicode sig) except NULL:
    cdef object CallStaticObjectMethod(self, jclass clazz, jmethodID method, const jvalue *args, bint withgil):
        assert clazz is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jobject out = self.env[0].CallStaticObjectMethodA(self.env, clazz, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return self.__object2py(out)
    cdef object CallStaticVoidMethod(self, jclass clazz, jmethodID method, const jvalue *args, bint withgil):
        assert clazz is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        self.env[0].CallStaticVoidMethodA(self.env, clazz, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return None
    cdef object CallStaticBooleanMethod(self, jclass clazz, jmethodID method, const jvalue *args, bint withgil):
        assert clazz is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jboolean out = self.env[0].CallStaticBooleanMethodA(self.env, clazz, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return out == JNI_TRUE
    cdef object CallStaticByteMethod(self, jclass clazz, jmethodID method, const jvalue *args, bint withgil):
        assert clazz is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jbyte out = self.env[0].CallStaticByteMethodA(self.env, clazz, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return out
    cdef object CallStaticCharMethod(self, jclass clazz, jmethodID method, const jvalue *args, bint withgil):
        assert clazz is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jchar out = self.env[0].CallStaticCharMethodA(self.env, clazz, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return unichr(out)
    cdef object CallStaticShortMethod(self, jclass clazz, jmethodID method, const jvalue *args, bint withgil):
        assert clazz is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jshort out = self.env[0].CallStaticShortMethodA(self.env, clazz, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return out
    cdef object CallStaticIntMethod(self, jclass clazz, jmethodID method, const jvalue *args, bint withgil):
        assert clazz is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jint out = self.env[0].CallStaticIntMethodA(self.env, clazz, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return out
    cdef object CallStaticLongMethod(self, jclass clazz, jmethodID method, const jvalue *args, bint withgil):
        assert clazz is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jlong out = self.env[0].CallStaticLongMethodA(self.env, clazz, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return out
    cdef object CallStaticFloatMethod(self, jclass clazz, jmethodID method, const jvalue *args, bint withgil):
        assert clazz is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jfloat out = self.env[0].CallStaticFloatMethodA(self.env, clazz, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return out
    cdef object CallStaticDoubleMethod(self, jclass clazz, jmethodID method, const jvalue *args, bint withgil):
        assert clazz is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jdouble out = self.env[0].CallStaticDoubleMethodA(self.env, clazz, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return out

    # String Operations
    #cdef inline jstring NewString(self, unicode s):
    cdef jsize GetStringLength(self, jstring string) except -1:
        assert string is not NULL
        cdef jsize out = self.env[0].GetStringLength(self.env, string)
        if out < 0: self.__raise_exception()
        return out
    cdef const jchar *GetStringChars(self, jstring string, jboolean *isCopy=NULL) except NULL:
        assert string is not NULL
        cdef const jchar *out = self.env[0].GetStringChars(self.env, string, isCopy)
        if out is NULL: self.__raise_exception()
        return out
    cdef void ReleaseStringChars(self, jstring string, const jchar *chars):
        assert string is not NULL and chars is not NULL
        self.env[0].ReleaseStringChars(self.env, string, chars)
        #self.check_exc() # This is usually in the finally clause, don't check for errors
    cdef jstring NewStringUTF(self, unicode s) except? NULL:
        if s is None: return NULL
        cdef jstring string = self.env[0].NewStringUTF(self.env, to_utf8j(s))
        if string is NULL: self.__raise_exception()
        return string
    cdef jsize GetStringUTFLength(self, jstring string) except -1:
        assert string is not NULL
        cdef jsize out = self.env[0].GetStringUTFLength(self.env, string)
        if out < 0: self.__raise_exception()
        return out
    cdef const char *GetStringUTFChars(self, jstring string, jboolean *isCopy=NULL) except NULL:
        assert string is not NULL
        cdef const char *out = self.env[0].GetStringUTFChars(self.env, string, isCopy)
        if out is NULL: self.__raise_exception()
        return out
    cdef void ReleaseStringUTFChars(self, jstring string, const char *utf):
        assert string is not NULL and utf is not NULL
        self.env[0].ReleaseStringUTFChars(self.env, string, utf)
        #self.check_exc() # This is usually in the finally clause, don't check for errors
    cdef int GetStringRegion(self, jstring string, jsize start, jsize len, jchar *buf) except -1:
        assert string is not NULL and start >= 0 and len >= 0 and buf is not NULL
        self.env[0].GetStringRegion(self.env, string, start, len, buf)
        self.check_exc()
        return 0
    cdef int GetStringUTFRegion(self, jstring string, jsize start, jsize len, char *buf) except -1:
        assert string is not NULL and start >= 0 and len >= 0 and buf is not NULL
        self.env[0].GetStringUTFRegion(self.env, string, start, len, buf)
        self.check_exc()
        return 0
    cdef const jchar *GetStringCritical(self, jstring string, jboolean *isCopy=NULL) except NULL:
        assert string is not NULL
        cdef const jchar *out = self.env[0].GetStringCritical(self.env, string, isCopy)
        if out is NULL: self.__raise_exception()
        return out
    cdef void ReleaseStringCritical(self, jstring string, const jchar *carray):
        assert string is not NULL and carray is not NULL
        self.env[0].ReleaseStringCritical(self.env, string, carray)
        #self.check_exc() # This is usually in the finally clause, don't check for errors

    # Array Operations
    #cdef inline jsize GetArrayLength(self, jarray array) except -1:
    #cdef inline jobjectArray NewObjectArray(self, jsize length, jclass elementClass, jobject initialElement) except NULL:
    #cdef inline jobject GetObjectArrayElement(self, jobjectArray array, jsize index) except? NULL:
    #cdef inline int SetObjectArrayElement(self, jobjectArray array, jsize index, jobject value) except -1:
    cdef jbooleanArray NewBooleanArray(self, jsize length) except NULL:
        assert length >= 0
        cdef jbooleanArray out = self.env[0].NewBooleanArray(self.env, length)
        if out is NULL: self.__raise_exception()
        return out
    cdef jbyteArray NewByteArray(self, jsize length) except NULL:
        assert length >= 0
        cdef jbyteArray out = self.env[0].NewByteArray(self.env, length)
        if out is NULL: self.__raise_exception()
        return out
    cdef jcharArray NewCharArray(self, jsize length) except NULL:
        assert length >= 0
        cdef jcharArray out = self.env[0].NewCharArray(self.env, length)
        if out is NULL: self.__raise_exception()
        return out
    cdef jshortArray NewShortArray(self, jsize length) except NULL:
        assert length >= 0
        cdef jshortArray out = self.env[0].NewShortArray(self.env, length)
        if out is NULL: self.__raise_exception()
        return out
    cdef jintArray NewIntArray(self, jsize length) except NULL:
        assert length >= 0
        cdef jintArray out = self.env[0].NewIntArray(self.env, length)
        if out is NULL: self.__raise_exception()
        return out
    cdef jlongArray NewLongArray(self, jsize length) except NULL:
        assert length >= 0
        cdef jlongArray out = self.env[0].NewLongArray(self.env, length)
        if out is NULL: self.__raise_exception()
        return out
    cdef jfloatArray NewFloatArray(self, jsize length) except NULL:
        assert length >= 0
        cdef jfloatArray out = self.env[0].NewFloatArray(self.env, length)
        if out is NULL: self.__raise_exception()
        return out
    cdef jdoubleArray NewDoubleArray(self, jsize length) except NULL:
        assert length >= 0
        cdef jdoubleArray out = self.env[0].NewDoubleArray(self.env, length)
        if out is NULL: self.__raise_exception()
        return out

    cdef jboolean *GetBooleanArrayElements(self, jbooleanArray array, jboolean *isCopy, jsize len) except NULL:
        assert array is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jboolean) else PyEval_SaveThread()
        cdef jboolean *out = self.env[0].GetBooleanArrayElements(self.env, array, isCopy)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        if out is NULL: self.__raise_exception()
        return out
    cdef jbyte *GetByteArrayElements(self, jbyteArray array, jboolean *isCopy, jsize len) except NULL:
        assert array is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jbyte) else PyEval_SaveThread()
        cdef jbyte *out = self.env[0].GetByteArrayElements(self.env, array, isCopy)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        if out is NULL: self.__raise_exception()
        return out
    cdef jchar *GetCharArrayElements(self, jcharArray array, jboolean *isCopy, jsize len) except NULL:
        assert array is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jchar) else PyEval_SaveThread()
        cdef jchar *out = self.env[0].GetCharArrayElements(self.env, array, isCopy)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        if out is NULL: self.__raise_exception()
        return out
    cdef jshort *GetShortArrayElements(self, jshortArray array, jboolean *isCopy, jsize len) except NULL:
        assert array is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jshort) else PyEval_SaveThread()
        cdef jshort *out = self.env[0].GetShortArrayElements(self.env, array, isCopy)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        if out is NULL: self.__raise_exception()
        return out
    cdef jint *GetIntArrayElements(self, jintArray array, jboolean *isCopy, jsize len) except NULL:
        assert array is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jint) else PyEval_SaveThread()
        cdef jint *out = self.env[0].GetIntArrayElements(self.env, array, isCopy)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        if out is NULL: self.__raise_exception()
        return out
    cdef jlong *GetLongArrayElements(self, jlongArray array, jboolean *isCopy, jsize len) except NULL:
        assert array is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jlong) else PyEval_SaveThread()
        cdef jlong *out = self.env[0].GetLongArrayElements(self.env, array, isCopy)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        if out is NULL: self.__raise_exception()
        return out
    cdef jfloat *GetFloatArrayElements(self, jfloatArray array, jboolean *isCopy, jsize len) except NULL:
        assert array is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jfloat) else PyEval_SaveThread()
        cdef jfloat *out = self.env[0].GetFloatArrayElements(self.env, array, isCopy)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        if out is NULL: self.__raise_exception()
        return out
    cdef jdouble *GetDoubleArrayElements(self, jdoubleArray array, jboolean *isCopy, jsize len) except NULL:
        assert array is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jdouble) else PyEval_SaveThread()
        cdef jdouble *out = self.env[0].GetDoubleArrayElements(self.env, array, isCopy)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        if out is NULL: self.__raise_exception()
        return out

    cdef void ReleaseBooleanArrayElements(self, jbooleanArray array, jboolean *elems, jint mode):
        assert array is not NULL and elems is not NULL
        cdef PyThreadState* gilstate = NULL if mode == JNI_ABORT else PyEval_SaveThread()
        self.env[0].ReleaseBooleanArrayElements(self.env, array, elems, mode)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        #self.check_exc() # This is usually in the finally clause, don't check for errors
    cdef void ReleaseByteArrayElements(self, jbyteArray array, jbyte *elems, jint mode):
        assert array is not NULL and elems is not NULL
        cdef PyThreadState* gilstate = NULL if mode == JNI_ABORT else PyEval_SaveThread()
        self.env[0].ReleaseByteArrayElements(self.env, array, elems, mode)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        #self.check_exc() # This is usually in the finally clause, don't check for errors
    cdef void ReleaseCharArrayElements(self, jcharArray array, jchar *elems, jint mode):
        assert array is not NULL and elems is not NULL
        cdef PyThreadState* gilstate = NULL if mode == JNI_ABORT else PyEval_SaveThread()
        self.env[0].ReleaseCharArrayElements(self.env, array, elems, mode)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        #self.check_exc() # This is usually in the finally clause, don't check for errors
    cdef void ReleaseShortArrayElements(self, jshortArray array, jshort *elems, jint mode):
        assert array is not NULL and elems is not NULL
        cdef PyThreadState* gilstate = NULL if mode == JNI_ABORT else PyEval_SaveThread()
        self.env[0].ReleaseShortArrayElements(self.env, array, elems, mode)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        #self.check_exc() # This is usually in the finally clause, don't check for errors
    cdef void ReleaseIntArrayElements(self, jintArray array, jint *elems, jint mode):
        assert array is not NULL and elems is not NULL
        cdef PyThreadState* gilstate = NULL if mode == JNI_ABORT else PyEval_SaveThread()
        self.env[0].ReleaseIntArrayElements(self.env, array, elems, mode)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        #self.check_exc() # This is usually in the finally clause, don't check for errors
    cdef void ReleaseLongArrayElements(self, jlongArray array, jlong *elems, jint mode):
        assert array is not NULL and elems is not NULL
        cdef PyThreadState* gilstate = NULL if mode == JNI_ABORT else PyEval_SaveThread()
        self.env[0].ReleaseLongArrayElements(self.env, array, elems, mode)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        #self.check_exc() # This is usually in the finally clause, don't check for errors
    cdef void ReleaseFloatArrayElements(self, jfloatArray array, jfloat *elems, jint mode):
        assert array is not NULL and elems is not NULL
        cdef PyThreadState* gilstate = NULL if mode == JNI_ABORT else PyEval_SaveThread()
        self.env[0].ReleaseFloatArrayElements(self.env, array, elems, mode)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        #self.check_exc() # This is usually in the finally clause, don't check for errors
    cdef void ReleaseDoubleArrayElements(self, jdoubleArray array, jdouble *elems, jint mode):
        assert array is not NULL and elems is not NULL
        cdef PyThreadState* gilstate = NULL if mode == JNI_ABORT else PyEval_SaveThread()
        self.env[0].ReleaseDoubleArrayElements(self.env, array, elems, mode)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        #self.check_exc() # This is usually in the finally clause, don't check for errors

    cdef int GetBooleanArrayRegion(self, jbooleanArray array, jsize start, jsize len, jboolean *buf) except -1:
        assert array is not NULL and start >= 0 and len >= 0 and buf is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jboolean) else PyEval_SaveThread()
        self.env[0].GetBooleanArrayRegion(self.env, array, start, len, buf)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return 0
    cdef int GetByteArrayRegion(self, jbyteArray array, jsize start, jsize len, jbyte *buf) except -1:
        assert array is not NULL and start >= 0 and len >= 0 and buf is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jbyte) else PyEval_SaveThread()
        self.env[0].GetByteArrayRegion(self.env, array, start, len, buf)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return 0
    cdef int GetCharArrayRegion(self, jcharArray array, jsize start, jsize len, jchar *buf) except -1:
        assert array is not NULL and start >= 0 and len >= 0 and buf is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jchar) else PyEval_SaveThread()
        self.env[0].GetCharArrayRegion(self.env, array, start, len, buf)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return 0
    cdef int GetShortArrayRegion(self, jshortArray array, jsize start, jsize len, jshort *buf) except -1:
        assert array is not NULL and start >= 0 and len >= 0 and buf is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jshort) else PyEval_SaveThread()
        self.env[0].GetShortArrayRegion(self.env, array, start, len, buf)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return 0
    cdef int GetIntArrayRegion(self, jintArray array, jsize start, jsize len, jint *buf) except -1:
        assert array is not NULL and start >= 0 and len >= 0 and buf is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jint) else PyEval_SaveThread()
        self.env[0].GetIntArrayRegion(self.env, array, start, len, buf)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return 0
    cdef int GetLongArrayRegion(self, jlongArray array, jsize start, jsize len, jlong *buf) except -1:
        assert array is not NULL and start >= 0 and len >= 0 and buf is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jlong) else PyEval_SaveThread()
        self.env[0].GetLongArrayRegion(self.env, array, start, len, buf)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return 0
    cdef int GetFloatArrayRegion(self, jfloatArray array, jsize start, jsize len, jfloat *buf) except -1:
        assert array is not NULL and start >= 0 and len >= 0 and buf is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jfloat) else PyEval_SaveThread()
        self.env[0].GetFloatArrayRegion(self.env, array, start, len, buf)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return 0
    cdef int GetDoubleArrayRegion(self, jdoubleArray array, jsize start, jsize len, jdouble *buf) except -1:
        assert array is not NULL and start >= 0 and len >= 0 and buf is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jdouble) else PyEval_SaveThread()
        self.env[0].GetDoubleArrayRegion(self.env, array, start, len, buf)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return 0

    cdef int SetBooleanArrayRegion(self, jbooleanArray array, jsize start, jsize len, jboolean *buf) except -1:
        assert array is not NULL and start >= 0 and len >= 0 and buf is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jboolean) else PyEval_SaveThread()
        self.env[0].SetBooleanArrayRegion(self.env, array, start, len, buf)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return 0
    cdef int SetByteArrayRegion(self, jbyteArray array, jsize start, jsize len, jbyte *buf) except -1:
        assert array is not NULL and start >= 0 and len >= 0 and buf is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jbyte) else PyEval_SaveThread()
        self.env[0].SetByteArrayRegion(self.env, array, start, len, buf)
        self.check_exc()
        return 0
    cdef int SetCharArrayRegion(self, jcharArray array, jsize start, jsize len, jchar *buf) except -1:
        assert array is not NULL and start >= 0 and len >= 0 and buf is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jchar) else PyEval_SaveThread()
        self.env[0].SetCharArrayRegion(self.env, array, start, len, buf)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return 0
    cdef int SetShortArrayRegion(self, jshortArray array, jsize start, jsize len, jshort *buf) except -1:
        assert array is not NULL and start >= 0 and len >= 0 and buf is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jshort) else PyEval_SaveThread()
        self.env[0].SetShortArrayRegion(self.env, array, start, len, buf)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return 0
    cdef int SetIntArrayRegion(self, jintArray array, jsize start, jsize len, jint *buf) except -1:
        assert array is not NULL and start >= 0 and len >= 0 and buf is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jint) else PyEval_SaveThread()
        self.env[0].SetIntArrayRegion(self.env, array, start, len, buf)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return 0
    cdef int SetLongArrayRegion(self, jlongArray array, jsize start, jsize len, jlong *buf) except -1:
        assert array is not NULL and start >= 0 and len >= 0 and buf is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jlong) else PyEval_SaveThread()
        self.env[0].SetLongArrayRegion(self.env, array, start, len, buf)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return 0
    cdef int SetFloatArrayRegion(self, jfloatArray array, jsize start, jsize len, jfloat *buf) except -1:
        assert array is not NULL and start >= 0 and len >= 0 and buf is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jfloat) else PyEval_SaveThread()
        self.env[0].SetFloatArrayRegion(self.env, array, start, len, buf)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return 0
    cdef int SetDoubleArrayRegion(self, jdoubleArray array, jsize start, jsize len, jdouble *buf) except -1:
        assert array is not NULL and start >= 0 and len >= 0 and buf is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jdouble) else PyEval_SaveThread()
        self.env[0].SetDoubleArrayRegion(self.env, array, start, len, buf)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return 0

    # Registering Native Methods
    cdef int RegisterNatives(self, jclass clazz, const JNINativeMethod *methods, jint nMethods) except -1:
        assert clazz is not NULL and methods is not NULL and nMethods > 0
        if self.env[0].RegisterNatives(self.env, clazz, methods, nMethods) < 0: self.__raise_exception()
        return 0
    cdef int UnregisterNatives(self, jclass clazz) except -1:
        assert clazz is not NULL
        if self.env[0].UnregisterNatives(self.env, clazz) < 0: self.__raise_exception()
        return 0

    # Monitor Operations -  basically the 'synchronized' block from Java
    cdef int MonitorEnter(self, jobject obj) except -1:
        if self.env[0].MonitorEnter(self.env, obj) < 0: self.__raise_exception()
        return 0
    cdef int MonitorExit(self, jobject obj) except -1:
        if self.env[0].MonitorExit(self.env, obj) < 0: self.__raise_exception()
        return 0

    # NIO Support
    IF JNI_VERSION >= JNI_VERSION_1_4:
        cdef jobject NewDirectByteBuffer(self, void* address, jlong capacity) except NULL:
            cdef jobject out = self.env[0].NewDirectByteBuffer(self.env, address, capacity)
            if out is NULL: self.__raise_exception()
            return out
        cdef void* GetDirectBufferAddress(self, jobject buf) except NULL:
            cdef void* out = self.env[0].GetDirectBufferAddress(self.env, buf)
            if out is NULL: self.__raise_exception()
            return out
        cdef jlong GetDirectBufferCapacity(self, jobject buf) except -1:
            cdef jlong out = self.env[0].GetDirectBufferCapacity(self.env, buf)
            if out < 0: self.__raise_exception()
            return out

    # Reflection Support
    #cdef inline jfieldID FromReflectedField(self, jobject field) except NULL:
    #cdef inline jmethodID FromReflectedMethod(self, jobject method) except NULL:
    cdef jobject ToReflectedMethod(self, jclass cls, jmethodID methodID, jboolean isStatic) except NULL:
        assert cls is not NULL and methodID is not NULL
        cdef jobject out = self.env[0].ToReflectedMethod(self.env, cls, methodID, isStatic)
        if out is NULL: self.__raise_exception()
        return out
    cdef jobject ToReflectedField(self, jclass cls, jfieldID fieldID, jboolean isStatic) except NULL:
        assert cls is not NULL and fieldID is not NULL
        cdef jobject out = self.env[0].ToReflectedField(self.env, cls, fieldID, isStatic)
        if out is NULL: self.__raise_exception()
        return out
