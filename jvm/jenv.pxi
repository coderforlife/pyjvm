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
of nearly all JNIEnv functions.

Internal classes:
    JEnv - the JNIEnv* wrapper

Internal function types:
    obj2py - the type of functions given to JEnv.objs2list or JEnv.CallObjects
"""

from cpython.ref cimport Py_INCREF
from cpython.list cimport PyList_New, PyList_SET_ITEM
from cpython.unicode cimport PyUnicode_DecodeUTF16, PyUnicode_AsUTF16String

ctypedef object (*obj2py)(JEnv, jobject)

cdef class JEnv(object):
    """
    Class which wraps the native JNIEnv pointer. One of these is created for each thread. This
    provides several function that are wrappers around the JNIEnv functions.
    """

    cdef JNIEnv* env
    def __repr__(self): return '<Java Environment instance at %s>'%str_ptr(self.env)

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
                self.CallVoidMethod(cur_thrd, ThreadDef.setContextClassLoader, &val, True)
                self.DeleteLocalRef(val.l)
                self.check_exc()
        finally: self.DeleteLocalRef(cur_thrd)
        return 0
    
    cdef inline int check_exc(self) except -1:
        """
        Checks to see if there is a Java exception pending. If there is, it is raised as a Python
        exception.
        """
        cdef jthrowable t
        if self.ExceptionCheck():
            t = self.ExceptionOccurred()
            #self.ExceptionDescribe()
            self.ExceptionClear()
            raise create_java_object(t)
        return 0

    ########## JNIEnv Wrappers with error checking ##########
    # Also, some methods support some very minimal conversion and the NewObject. Some methods are
    # GIL-aware as well:
    #    Call<xxx>Method    argument withgil controls GIL being released around the Java call
    #    NewObject          as above, default value for withgil is True
    #    Get/Set<Type>ArrayRegion    automatically release GIL for arrays >8192 bytes in length
    #    Get<Type>ArrayElements      like above, requires an extra parameter 'len' to be efficient
    #    Release<Type>ArrayElements  only if mode is not JNI_ABORT
    # Get/ReleasePrimitiveArrayCritical does not release the GIL since the hope is that it simply
    # pins the array.

    # Version Information
    cdef inline jint GetVersion(self) except -1:
        cdef jint version = self.env[0].GetVersion(self.env)
        if version < 0: raise_jni_err('Failed to get JNI version', version)
        return version

    # Class Operations
    cdef inline jobject DefineClass(self, unicode name, jobject loader, bytes buf):
        assert name is not None and loader is not NULL and buf is not None
        cdef bytes bn = to_utf8j(name.replace('.', '/'))
        cdef jclass clazz = self.env[0].DefineClass(self.env, bn, loader, buf, <jsize>len(buf))
        if clazz is NULL: self.check_exc()
        return clazz
    cdef inline jclass FindClass(self, unicode name) except NULL:
        cdef jclass clazz = self.env[0].FindClass(self.env, to_utf8j(name.replace('.', '/')))
        if clazz is NULL: self.check_exc()
        return clazz
    cdef inline jclass GetSuperclass(self, jclass clazz) except? NULL:
        assert clazz is not NULL
        cdef jclass superclazz = self.env[0].GetSuperclass(self.env, clazz)
        if superclazz is NULL: self.check_exc()
        return superclazz
    cdef inline bint IsAssignableFrom(self, jclass clazz1, jclass clazz2) except -1:
        assert clazz1 is not NULL and clazz2 is not NULL
        cdef bint out = self.env[0].IsAssignableFrom(self.env, clazz1, clazz2)
        self.check_exc()
        return out

    # Exceptions - no error checking for any of these functions since they all manipulate the exception state
    cdef inline jint Throw(self, jthrowable obj):
        assert obj is not NULL
        return self.env[0].Throw(self.env, obj)
    cdef inline jint ThrowNew(self, jclass clazz, unicode message):
        assert clazz is not NULL and message is not None
        return self.env[0].ThrowNew(self.env, clazz, to_utf8j(message))
    cdef inline jthrowable ExceptionOccurred(self): return self.env[0].ExceptionOccurred(self.env)
    cdef inline void ExceptionDescribe(self): self.env[0].ExceptionDescribe(self.env)
    cdef inline void ExceptionClear(self): self.env[0].ExceptionClear(self.env)
    cdef inline void FatalError(self, unicode msg):
        assert msg is not None
        self.env[0].FatalError(self.env, to_utf8j(msg))
    cdef inline bint ExceptionCheck(self): return self.env[0].ExceptionCheck(self.env) == JNI_TRUE

    # Global and Local References
    cdef inline jobject NewGlobalRef(self, jobject obj) except NULL:
        assert obj != NULL
        cdef jobject out = self.env[0].NewGlobalRef(self.env, obj)
        if out is NULL: self.check_exc()
        return out
    cdef inline int DeleteGlobalRef(self, jobject globalRef) except -1:
        assert globalRef is not NULL
        self.env[0].DeleteGlobalRef(self.env, globalRef)
        self.check_exc()
    cdef inline jobject NewLocalRef(self, jobject ref) except NULL:
        assert ref is not NULL
        cdef jobject out = self.env[0].NewLocalRef(self.env, ref)
        if out is NULL: self.check_exc()
        return out
    cdef inline int DeleteLocalRef(self, jobject localRef) except -1:
        assert localRef is not NULL
        self.env[0].DeleteLocalRef(self.env, localRef)
        self.check_exc()
    cdef inline int EnsureLocalCapacity(self, jint capacity) except -1:
        assert capacity >= 0
        cdef jint result = self.env[0].EnsureLocalCapacity(self.env, capacity)
        if result < 0: self.check_exc()
        return 0
    cdef inline int PushLocalFrame(self, jint capacity) except -1:
        assert capacity >= 0
        cdef jint result = self.env[0].PushLocalFrame(self.env, capacity)
        if result < 0: self.check_exc()
        return 0
    cdef inline jobject PopLocalFrame(self, jobject result) except? NULL:
        cdef jobject out = self.env[0].PopLocalFrame(self.env, result)
        if out is NULL: self.check_exc()
        return out

    # Weak Global References
    cdef inline jweak NewWeakGlobalRef(self, jobject obj) except? NULL:
        cdef jweak out = self.env[0].NewWeakGlobalRef(self.env, obj)
        if out is NULL: self.check_exc()
        return out
    cdef inline int DeleteWeakGlobalRef(self, jweak obj) except -1:
        self.env[0].DeleteWeakGlobalRef(self.env, obj)
        self.check_exc()
        return 0

    # Object Operations
    cdef inline jobject AllocObject(self, jclass clazz):
        assert clazz is not NULL
        cdef jobject obj = self.env[0].AllocObject(self.env, clazz)
        if obj is NULL: self.check_exc()
        return obj
    cdef inline jobject NewObject(self, jclass clazz, jmethodID methodID, const jvalue *args=NULL, bint withgil=True) except NULL:
        assert clazz is not NULL and methodID is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jobject out = self.env[0].NewObjectA(self.env, clazz, methodID, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        if out is NULL: self.check_exc()
        return out
    cdef inline jclass GetObjectClass(self, jobject obj) except NULL:
        assert obj is not NULL
        cdef jclass clazz = self.env[0].GetObjectClass(self.env, obj)
        if clazz is NULL: self.check_exc()
        return clazz
    IF JNI_VERSION >= JNI_VERSION_1_6:
        cdef inline jobjectRefType GetObjectRefType(self, jobject obj) except <jobjectRefType>-1:
            cdef jobjectRefType out = self.env[0].GetObjectRefType(self.env, obj)
            if out == JNIInvalidRefType: self.check_exc()
            return out
    cdef inline bint IsInstanceOf(self, jobject obj, jclass clazz) except -1:
        assert clazz is not NULL
        cdef bint out = self.env[0].IsInstanceOf(self.env, obj, clazz)
        self.check_exc()
        return out
    cdef inline bint IsSameObject(self, jobject ref1, jobject ref2) except -1:
        cdef bint out = self.env[0].IsSameObject(self.env, ref1, ref2)
        self.check_exc()
        return out

    # Accessing Fields of Objects
    cdef inline jfieldID GetFieldID(self, jclass clazz, unicode name, unicode sig) except NULL:
        assert clazz is not NULL
        cdef jfieldID out = self.env[0].GetFieldID(self.env, clazz, to_utf8j(name), to_utf8j(sig))
        if out is NULL: self.check_exc()
        return out

    cdef inline object GetObjectField(self, jobject obj, jfieldID fieldID):
        assert obj is not NULL and fieldID is not NULL
        cdef jobject out = self.env[0].GetObjectField(self.env, obj, fieldID)
        self.check_exc()
        return object2py(out)
    cdef inline object GetBooleanField(self, jobject obj, jfieldID fieldID):
        assert obj is not NULL and fieldID is not NULL
        cdef jboolean out = self.env[0].GetBooleanField(self.env, obj, fieldID)
        self.check_exc()
        return out == JNI_TRUE
    cdef inline object GetByteField(self, jobject obj, jfieldID fieldID):
        assert obj is not NULL and fieldID is not NULL
        cdef jbyte out = self.env[0].GetByteField(self.env, obj, fieldID)
        self.check_exc()
        return out
    cdef inline object GetCharField(self, jobject obj, jfieldID fieldID):
        assert obj is not NULL and fieldID is not NULL
        cdef jchar out = self.env[0].GetCharField(self.env, obj, fieldID)
        self.check_exc()
        return unichr(out)
    cdef inline object GetShortField(self, jobject obj, jfieldID fieldID):
        assert obj is not NULL and fieldID is not NULL
        cdef jshort out = self.env[0].GetShortField(self.env, obj, fieldID)
        self.check_exc()
        return out
    cdef inline object GetIntField(self, jobject obj, jfieldID fieldID):
        assert obj is not NULL and fieldID is not NULL
        cdef jint out = self.env[0].GetIntField(self.env, obj, fieldID)
        self.check_exc()
        return out
    cdef inline object GetLongField(self, jobject obj, jfieldID fieldID):
        assert obj is not NULL and fieldID is not NULL
        cdef jlong out = self.env[0].GetLongField(self.env, obj, fieldID)
        self.check_exc()
        return out
    cdef inline object GetFloatField(self, jobject obj, jfieldID fieldID):
        assert obj is not NULL and fieldID is not NULL
        cdef jfloat out = self.env[0].GetFloatField(self.env, obj, fieldID)
        self.check_exc()
        return out
    cdef inline object GetDoubleField(self, jobject obj, jfieldID fieldID):
        assert obj is not NULL and fieldID is not NULL
        cdef jdouble out = self.env[0].GetDoubleField(self.env, obj, fieldID)
        self.check_exc()
        return out

    cdef inline int SetObjectField(self, jobject obj, JField field, object value) except -1:
        assert obj is not NULL and field is not None
        cdef jobject val = py2object(self, value, field.type)
        try:
            self.env[0].SetObjectField(self.env, obj, field.id, val)
            self.check_exc()
        finally:
            self.DeleteLocalRef(val)
        return 0
    cdef inline int SetBooleanField(self, jobject obj, JField field, object value) except -1:
        assert obj is not NULL and field is not None and value is not None
        self.env[0].SetBooleanField(self.env, obj, field.id, py2boolean(value))
        self.check_exc()
        return 0
    cdef inline int SetByteField(self, jobject obj, JField field, object value) except -1:
        assert obj is not NULL and field is not None and value is not None
        self.env[0].SetByteField(self.env, obj, field.id, py2byte(value))
        self.check_exc()
        return 0
    cdef inline int SetCharField(self, jobject obj, JField field, object value) except -1:
        assert obj is not NULL and field is not None and value is not None
        self.env[0].SetCharField(self.env, obj, field.id, py2char(value))
        self.check_exc()
        return 0
    cdef inline int SetShortField(self, jobject obj, JField field, object value) except -1:
        assert obj is not NULL and field is not None and value is not None
        self.env[0].SetShortField(self.env, obj, field.id, py2short(value))
        self.check_exc()
        return 0
    cdef inline int SetIntField(self, jobject obj, JField field, object value) except -1:
        assert obj is not NULL and field is not None and value is not None
        self.env[0].SetIntField(self.env, obj, field.id, py2int(value))
        self.check_exc()
        return 0
    cdef inline int SetLongField(self, jobject obj, JField field, object value) except -1:
        assert obj is not NULL and field is not None and value is not None
        self.env[0].SetLongField(self.env, obj, field.id, py2long(value))
        self.check_exc()
        return 0
    cdef inline int SetFloatField(self, jobject obj, JField field, object value) except -1:
        assert obj is not NULL and field is not None and value is not None
        self.env[0].SetFloatField(self.env, obj, field.id, py2float(value))
        self.check_exc()
        return 0
    cdef inline int SetDoubleField(self, jobject obj, JField field, object value) except -1:
        assert obj is not NULL and field is not None and value is not None
        self.env[0].SetDoubleField(self.env, obj, field.id, py2double(value))
        self.check_exc()
        return 0

    # Calling Instance Methods
    cdef inline jmethodID GetMethodID(self, jclass clazz, unicode name, unicode sig) except NULL:
        assert clazz is not NULL
        cdef jmethodID out = self.env[0].GetMethodID(self.env, clazz, to_utf8j(name), to_utf8j(sig))
        if out is NULL: self.check_exc()
        return out

    cdef inline object CallObjectMethod(self, jobject obj, jmethodID method, const jvalue *args, bint withgil):
        assert obj is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jobject out = self.env[0].CallObjectMethodA(self.env, obj, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return object2py(out)
    cdef inline object CallVoidMethod(self, jobject obj, jmethodID method, const jvalue *args, bint withgil):
        assert obj is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        self.env[0].CallVoidMethodA(self.env, obj, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return None
    cdef inline object CallBooleanMethod(self, jobject obj, jmethodID method, const jvalue *args, bint withgil):
        assert obj is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jboolean out = self.env[0].CallBooleanMethodA(self.env, obj, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return out == JNI_TRUE
    cdef inline object CallByteMethod(self, jobject obj, jmethodID method, const jvalue *args, bint withgil):
        assert obj is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jbyte out = self.env[0].CallByteMethodA(self.env, obj, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return out
    cdef inline object CallCharMethod(self, jobject obj, jmethodID method, const jvalue *args, bint withgil):
        assert obj is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jchar out = self.env[0].CallCharMethodA(self.env, obj, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return unichr(out)
    cdef inline object CallShortMethod(self, jobject obj, jmethodID method, const jvalue *args, bint withgil):
        assert obj is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jshort out = self.env[0].CallShortMethodA(self.env, obj, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return out
    cdef inline object CallIntMethod(self, jobject obj, jmethodID method, const jvalue *args, bint withgil):
        assert obj is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jint out = self.env[0].CallIntMethodA(self.env, obj, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return out
    cdef inline object CallLongMethod(self, jobject obj, jmethodID method, const jvalue *args, bint withgil):
        assert obj is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jlong out = self.env[0].CallLongMethodA(self.env, obj, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return out
    cdef inline object CallFloatMethod(self, jobject obj, jmethodID method, const jvalue *args, bint withgil):
        assert obj is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jfloat out = self.env[0].CallFloatMethodA(self.env, obj, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return out
    cdef inline object CallDoubleMethod(self, jobject obj, jmethodID method, const jvalue *args, bint withgil):
        assert obj is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jdouble out = self.env[0].CallDoubleMethodA(self.env, obj, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return out

    cdef inline object CallNonvirtualObjectMethod(self, jobject obj, jclass clazz, jmethodID method, const jvalue *args, bint withgil):
        assert obj is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jobject out = self.env[0].CallNonvirtualObjectMethodA(self.env, obj, clazz, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return object2py(out)
    cdef inline object CallNonvirtualVoidMethod(self, jobject obj, jclass clazz, jmethodID method, const jvalue *args, bint withgil):
        assert obj is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        self.env[0].CallNonvirtualVoidMethodA(self.env, obj, clazz, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return None
    cdef inline object CallNonvirtualBooleanMethod(self, jobject obj, jclass clazz, jmethodID method, const jvalue *args, bint withgil):
        assert obj is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jboolean out = self.env[0].CallNonvirtualBooleanMethodA(self.env, obj, clazz, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return out == JNI_TRUE
    cdef inline object CallNonvirtualByteMethod(self, jobject obj, jclass clazz, jmethodID method, const jvalue *args, bint withgil):
        assert obj is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jbyte out = self.env[0].CallNonvirtualByteMethodA(self.env, obj, clazz, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return out
    cdef inline object CallNonvirtualCharMethod(self, jobject obj, jclass clazz, jmethodID method, const jvalue *args, bint withgil):
        assert obj is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jchar out = self.env[0].CallNonvirtualCharMethodA(self.env, obj, clazz, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return unichr(out)
    cdef inline object CallNonvirtualShortMethod(self, jobject obj, jclass clazz, jmethodID method, const jvalue *args, bint withgil):
        assert obj is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jshort out = self.env[0].CallNonvirtualShortMethodA(self.env, obj, clazz, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return out
    cdef inline object CallNonvirtualIntMethod(self, jobject obj, jclass clazz, jmethodID method, const jvalue *args, bint withgil):
        assert obj is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jint out = self.env[0].CallNonvirtualIntMethodA(self.env, obj, clazz, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return out
    cdef inline object CallNonvirtualLongMethod(self, jobject obj, jclass clazz, jmethodID method, const jvalue *args, bint withgil):
        assert obj is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jlong out = self.env[0].CallNonvirtualLongMethodA(self.env, obj, clazz, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return out
    cdef inline object CallNonvirtualFloatMethod(self, jobject obj, jclass clazz, jmethodID method, const jvalue *args, bint withgil):
        assert obj is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jfloat out = self.env[0].CallNonvirtualFloatMethodA(self.env, obj, clazz, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return out
    cdef inline object CallNonvirtualDoubleMethod(self, jobject obj, jclass clazz, jmethodID method, const jvalue *args, bint withgil):
        assert obj is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jdouble out = self.env[0].CallNonvirtualDoubleMethodA(self.env, obj, clazz, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return out

    # Accessing Static Fields
    cdef inline jfieldID GetStaticFieldID(self, jclass clazz, unicode name, unicode sig) except NULL:
        assert clazz is not NULL
        cdef jfieldID out = self.env[0].GetStaticFieldID(self.env, clazz, to_utf8j(name), to_utf8j(sig))
        if out is NULL: self.check_exc()
        return out

    cdef inline object GetStaticObjectField(self, jclass clazz, jfieldID fieldID):
        assert clazz is not NULL and fieldID is not NULL
        cdef jobject out = self.env[0].GetStaticObjectField(self.env, clazz, fieldID)
        self.check_exc()
        return object2py(out)
    cdef inline object GetStaticBooleanField(self, jclass clazz, jfieldID fieldID):
        assert clazz is not NULL and fieldID is not NULL
        cdef jboolean out = self.env[0].GetStaticBooleanField(self.env, clazz, fieldID)
        self.check_exc()
        return out == JNI_TRUE
    cdef inline object GetStaticByteField(self, jclass clazz, jfieldID fieldID):
        assert clazz is not NULL and fieldID is not NULL
        cdef jbyte out = self.env[0].GetStaticByteField(self.env, clazz, fieldID)
        self.check_exc()
        return out
    cdef inline object GetStaticCharField(self, jclass clazz, jfieldID fieldID):
        assert clazz is not NULL and fieldID is not NULL
        cdef jchar out = self.env[0].GetStaticCharField(self.env, clazz, fieldID)
        self.check_exc()
        return unichr(out)
    cdef inline object GetStaticShortField(self, jclass clazz, jfieldID fieldID):
        assert clazz is not NULL and fieldID is not NULL
        cdef jshort out = self.env[0].GetStaticShortField(self.env, clazz, fieldID)
        self.check_exc()
        return out
    cdef inline object GetStaticIntField(self, jclass clazz, jfieldID fieldID):
        assert clazz is not NULL and fieldID is not NULL
        cdef jint out = self.env[0].GetStaticIntField(self.env, clazz, fieldID)
        self.check_exc()
        return out
    cdef inline object GetStaticLongField(self, jclass clazz, jfieldID fieldID):
        assert clazz is not NULL and fieldID is not NULL
        cdef jlong out = self.env[0].GetStaticLongField(self.env, clazz, fieldID)
        self.check_exc()
        return out
    cdef inline object GetStaticFloatField(self, jclass clazz, jfieldID fieldID):
        assert clazz is not NULL and fieldID is not NULL
        cdef jfloat out = self.env[0].GetStaticFloatField(self.env, clazz, fieldID)
        self.check_exc()
        return out
    cdef inline object GetStaticDoubleField(self, jclass clazz, jfieldID fieldID):
        assert clazz is not NULL and fieldID is not NULL
        cdef jdouble out = self.env[0].GetStaticDoubleField(self.env, clazz, fieldID)
        self.check_exc()
        return out

    cdef inline int SetStaticObjectField(self, jclass clazz, JField field, object value) except -1:
        assert clazz is not NULL and field is not None
        cdef jobject val = py2object(self, value, field.type)
        try:
            self.env[0].SetStaticObjectField(self.env, clazz, field.id, val)
            self.check_exc()
        finally:
            self.DeleteLocalRef(val)
        return 0
    cdef inline int SetStaticBooleanField(self, jclass clazz, JField field, object value) except -1:
        assert clazz is not NULL and field is not None and value is not None
        self.env[0].SetStaticBooleanField(self.env, clazz, field.id, py2boolean(value))
        self.check_exc()
        return 0
    cdef inline int SetStaticByteField(self, jclass clazz, JField field, object value) except -1:
        assert clazz is not NULL and field is not None and value is not None
        self.env[0].SetStaticByteField(self.env, clazz, field.id, py2byte(value))
        self.check_exc()
        return 0
    cdef inline int SetStaticCharField(self, jclass clazz, JField field, object value) except -1:
        assert clazz is not NULL and field is not None and value is not None
        self.env[0].SetStaticCharField(self.env, clazz, field.id, py2char(value))
        self.check_exc()
        return 0
    cdef inline int SetStaticShortField(self, jclass clazz, JField field, object value) except -1:
        assert clazz is not NULL and field is not None and value is not None
        self.env[0].SetStaticShortField(self.env, clazz, field.id, py2short(value))
        self.check_exc()
        return 0
    cdef inline int SetStaticIntField(self, jclass clazz, JField field, object value) except -1:
        assert clazz is not NULL and field is not None and value is not None
        self.env[0].SetStaticIntField(self.env, clazz, field.id, py2int(value))
        self.check_exc()
        return 0
    cdef inline int SetStaticLongField(self, jclass clazz, JField field, object value) except -1:
        assert clazz is not NULL and field is not None and value is not None
        self.env[0].SetStaticLongField(self.env, clazz, field.id, py2long(value))
        self.check_exc()
        return 0
    cdef inline int SetStaticFloatField(self, jclass clazz, JField field, object value) except -1:
        assert clazz is not NULL and field is not None and value is not None
        self.env[0].SetStaticFloatField(self.env, clazz, field.id, py2float(value))
        self.check_exc()
        return 0
    cdef inline int SetStaticDoubleField(self, jclass clazz, JField field, object value) except -1:
        assert clazz is not NULL and field is not None and value is not None
        self.env[0].SetStaticDoubleField(self.env, clazz, field.id, py2double(value))
        self.check_exc()
        return 0

    # Calling Static Methods
    cdef inline jmethodID GetStaticMethodID(self, jclass clazz, unicode name, unicode sig) except NULL:
        assert clazz is not NULL
        cdef jmethodID out = self.env[0].GetStaticMethodID(self.env, clazz, to_utf8j(name), to_utf8j(sig))
        if out is NULL: self.check_exc()
        return out
    cdef inline object CallStaticObjectMethod(self, jclass clazz, jmethodID method, const jvalue *args, bint withgil):
        assert clazz is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jobject out = self.env[0].CallStaticObjectMethodA(self.env, clazz, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return object2py(out)
    cdef inline object CallStaticVoidMethod(self, jclass clazz, jmethodID method, const jvalue *args, bint withgil):
        assert clazz is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        self.env[0].CallStaticVoidMethodA(self.env, clazz, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return None
    cdef inline object CallStaticBooleanMethod(self, jclass clazz, jmethodID method, const jvalue *args, bint withgil):
        assert clazz is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jboolean out = self.env[0].CallStaticBooleanMethodA(self.env, clazz, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return out == JNI_TRUE
    cdef inline object CallStaticByteMethod(self, jclass clazz, jmethodID method, const jvalue *args, bint withgil):
        assert clazz is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jbyte out = self.env[0].CallStaticByteMethodA(self.env, clazz, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return out
    cdef inline object CallStaticCharMethod(self, jclass clazz, jmethodID method, const jvalue *args, bint withgil):
        assert clazz is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jchar out = self.env[0].CallStaticCharMethodA(self.env, clazz, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return unichr(out)
    cdef inline object CallStaticShortMethod(self, jclass clazz, jmethodID method, const jvalue *args, bint withgil):
        assert clazz is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jshort out = self.env[0].CallStaticShortMethodA(self.env, clazz, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return out
    cdef inline object CallStaticIntMethod(self, jclass clazz, jmethodID method, const jvalue *args, bint withgil):
        assert clazz is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jint out = self.env[0].CallStaticIntMethodA(self.env, clazz, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return out
    cdef inline object CallStaticLongMethod(self, jclass clazz, jmethodID method, const jvalue *args, bint withgil):
        assert clazz is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jlong out = self.env[0].CallStaticLongMethodA(self.env, clazz, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return out
    cdef inline object CallStaticFloatMethod(self, jclass clazz, jmethodID method, const jvalue *args, bint withgil):
        assert clazz is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jfloat out = self.env[0].CallStaticFloatMethodA(self.env, clazz, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return out
    cdef inline object CallStaticDoubleMethod(self, jclass clazz, jmethodID method, const jvalue *args, bint withgil):
        assert clazz is not NULL and method is not NULL
        cdef PyThreadState* gilstate = NULL if withgil else PyEval_SaveThread()
        cdef jdouble out = self.env[0].CallStaticDoubleMethodA(self.env, clazz, method, args)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return out

    # String Operations
    cdef inline jstring NewString(self, unicode s):
        if s is None: return NULL
        cdef bytes b = PyUnicode_AsUTF16String(s)
        cdef jstring string = self.env[0].NewString(self.env, (<jchar*><char*>b)+1, <jsize>(len(b)//sizeof(jchar))-1)
        if string is NULL: self.check_exc()
        return string
    cdef inline jsize GetStringLength(self, jstring string) except -1:
        assert string is not NULL
        cdef jsize out = self.env[0].GetStringLength(self.env, string)
        if out < 0: self.check_exc()
        return out
    cdef inline const jchar *GetStringChars(self, jstring string, jboolean *isCopy=NULL) except NULL:
        assert string is not NULL
        cdef const jchar *out = self.env[0].GetStringChars(self.env, string, isCopy)
        if out is NULL: self.check_exc()
        return out
    cdef inline int ReleaseStringChars(self, jstring string, const jchar *chars) except -1:
        assert string is not NULL and chars is not NULL
        self.env[0].ReleaseStringChars(self.env, string, chars)
        self.check_exc()
        return 0
    cdef inline jstring NewStringUTF(self, unicode s) except NULL:
        if s is None: return NULL
        cdef jstring string = self.env[0].NewStringUTF(self.env, to_utf8j(s))
        if string is NULL: self.check_exc()
        return string
    cdef inline jsize GetStringUTFLength(self, jstring string) except -1:
        assert string is not NULL
        cdef jsize out = self.env[0].GetStringUTFLength(self.env, string)
        if out < 0: self.check_exc()
        return out
    cdef inline const char *GetStringUTFChars(self, jstring string, jboolean *isCopy=NULL) except NULL:
        assert string is not NULL
        cdef const char *out = self.env[0].GetStringUTFChars(self.env, string, isCopy)
        if out is NULL: self.check_exc()
        return out
    cdef inline int ReleaseStringUTFChars(self, jstring string, const char *utf) except -1:
        assert string is not NULL and utf is not NULL
        self.env[0].ReleaseStringUTFChars(self.env, string, utf)
        self.check_exc()
        return 0
    cdef inline int GetStringRegion(self, jstring string, jsize start, jsize len, jchar *buf) except -1:
        assert string is not NULL and start >= 0 and len >= 0 and buf is not NULL
        self.env[0].GetStringRegion(self.env, string, start, len, buf)
        self.check_exc()
        return 0
    cdef inline int GetStringUTFRegion(self, jstring string, jsize start, jsize len, char *buf) except -1:
        assert string is not NULL and start >= 0 and len >= 0 and buf is not NULL
        self.env[0].GetStringUTFRegion(self.env, string, start, len, buf)
        self.check_exc()
        return 0
    cdef inline const jchar *GetStringCritical(self, jstring string, jboolean *isCopy=NULL) except NULL:
        assert string is not NULL
        cdef const jchar *out = self.env[0].GetStringCritical(self.env, string, isCopy)
        if out is NULL: self.check_exc()
        return out
    cdef inline int ReleaseStringCritical(self, jstring string, const jchar *carray) except -1:
        assert string is not NULL and carray is not NULL
        self.env[0].ReleaseStringCritical(self.env, string, carray)
        self.check_exc()
        return 0

    # Array Operations
    cdef inline jsize GetArrayLength(self, jarray array) except -1:
        assert array is not NULL
        cdef jsize out = self.env[0].GetArrayLength(self.env, array)
        if out < 0: self.check_exc()
        return out
    cdef jobjectArray NewObjectArray(self, jsize length, jclass elementClass, jobject initialElement) except NULL:
        assert length >= 0 and elementClass is not NULL
        cdef jobjectArray out = self.env[0].NewObjectArray(self.env, length, elementClass, initialElement)
        if out is NULL: self.check_exc()
        return out
    cdef inline jobject GetObjectArrayElement(self, jobjectArray array, jsize index) except? NULL:
        assert array is not NULL
        cdef jobject out = self.env[0].GetObjectArrayElement(self.env, array, index)
        self.check_exc()
        return out
    cdef inline int SetObjectArrayElement(self, jobjectArray array, jsize index, jobject value) except -1:
        assert array is not NULL
        self.env[0].SetObjectArrayElement(self.env, array, index, value)
        self.check_exc()
        return 0

    cdef inline jbooleanArray NewBooleanArray(self, jsize length) except NULL:
        assert length >= 0
        cdef jbooleanArray out = self.env[0].NewBooleanArray(self.env, length)
        if out is NULL: self.check_exc()
        return out
    cdef inline jbyteArray NewByteArray(self, jsize length) except NULL:
        assert length >= 0
        cdef jbyteArray out = self.env[0].NewByteArray(self.env, length)
        if out is NULL: self.check_exc()
        return out
    cdef inline jcharArray NewCharArray(self, jsize length) except NULL:
        assert length >= 0
        cdef jcharArray out = self.env[0].NewCharArray(self.env, length)
        if out is NULL: self.check_exc()
        return out
    cdef inline jshortArray NewShortArray(self, jsize length) except NULL:
        assert length >= 0
        cdef jshortArray out = self.env[0].NewShortArray(self.env, length)
        if out is NULL: self.check_exc()
        return out
    cdef inline jintArray NewIntArray(self, jsize length) except NULL:
        assert length >= 0
        cdef jintArray out = self.env[0].NewIntArray(self.env, length)
        if out is NULL: self.check_exc()
        return out
    cdef inline jlongArray NewLongArray(self, jsize length) except NULL:
        assert length >= 0
        cdef jlongArray out = self.env[0].NewLongArray(self.env, length)
        if out is NULL: self.check_exc()
        return out
    cdef inline jfloatArray NewFloatArray(self, jsize length) except NULL:
        assert length >= 0
        cdef jfloatArray out = self.env[0].NewFloatArray(self.env, length)
        if out is NULL: self.check_exc()
        return out
    cdef inline jdoubleArray NewDoubleArray(self, jsize length) except NULL:
        assert length >= 0
        cdef jdoubleArray out = self.env[0].NewDoubleArray(self.env, length)
        if out is NULL: self.check_exc()
        return out

    cdef inline jboolean *GetBooleanArrayElements(self, jbooleanArray array, jboolean *isCopy, jsize len) except NULL:
        assert array is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jboolean) else PyEval_SaveThread()
        cdef jboolean *out = self.env[0].GetBooleanArrayElements(self.env, array, isCopy)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        if out is NULL: self.check_exc()
        return out
    cdef inline jbyte *GetByteArrayElements(self, jbyteArray array, jboolean *isCopy, jsize len) except NULL:
        assert array is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jbyte) else PyEval_SaveThread()
        cdef jbyte *out = self.env[0].GetByteArrayElements(self.env, array, isCopy)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        if out is NULL: self.check_exc()
        return out
    cdef inline jchar *GetCharArrayElements(self, jcharArray array, jboolean *isCopy, jsize len) except NULL:
        assert array is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jchar) else PyEval_SaveThread()
        cdef jchar *out = self.env[0].GetCharArrayElements(self.env, array, isCopy)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        if out is NULL: self.check_exc()
        return out
    cdef inline jshort *GetShortArrayElements(self, jshortArray array, jboolean *isCopy, jsize len) except NULL:
        assert array is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jshort) else PyEval_SaveThread()
        cdef jshort *out = self.env[0].GetShortArrayElements(self.env, array, isCopy)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        if out is NULL: self.check_exc()
        return out
    cdef inline jint *GetIntArrayElements(self, jintArray array, jboolean *isCopy, jsize len) except NULL:
        assert array is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jint) else PyEval_SaveThread()
        cdef jint *out = self.env[0].GetIntArrayElements(self.env, array, isCopy)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        if out is NULL: self.check_exc()
        return out
    cdef inline jlong *GetLongArrayElements(self, jlongArray array, jboolean *isCopy, jsize len) except NULL:
        assert array is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jlong) else PyEval_SaveThread()
        cdef jlong *out = self.env[0].GetLongArrayElements(self.env, array, isCopy)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        if out is NULL: self.check_exc()
        return out
    cdef inline jfloat *GetFloatArrayElements(self, jfloatArray array, jboolean *isCopy, jsize len) except NULL:
        assert array is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jfloat) else PyEval_SaveThread()
        cdef jfloat *out = self.env[0].GetFloatArrayElements(self.env, array, isCopy)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        if out is NULL: self.check_exc()
        return out
    cdef inline jdouble *GetDoubleArrayElements(self, jdoubleArray array, jboolean *isCopy, jsize len) except NULL:
        assert array is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jdouble) else PyEval_SaveThread()
        cdef jdouble *out = self.env[0].GetDoubleArrayElements(self.env, array, isCopy)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        if out is NULL: self.check_exc()
        return out

    cdef inline int ReleaseBooleanArrayElements(self, jbooleanArray array, jboolean *elems, jint mode) except -1:
        assert array is not NULL and elems is not NULL
        cdef PyThreadState* gilstate = NULL if mode == JNI_ABORT else PyEval_SaveThread()
        self.env[0].ReleaseBooleanArrayElements(self.env, array, elems, mode)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return 0
    cdef inline int ReleaseByteArrayElements(self, jbyteArray array, jbyte *elems, jint mode) except -1:
        assert array is not NULL and elems is not NULL
        cdef PyThreadState* gilstate = NULL if mode == JNI_ABORT else PyEval_SaveThread()
        self.env[0].ReleaseByteArrayElements(self.env, array, elems, mode)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return 0
    cdef inline int ReleaseCharArrayElements(self, jcharArray array, jchar *elems, jint mode) except -1:
        assert array is not NULL and elems is not NULL
        cdef PyThreadState* gilstate = NULL if mode == JNI_ABORT else PyEval_SaveThread()
        self.env[0].ReleaseCharArrayElements(self.env, array, elems, mode)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return 0
    cdef inline int ReleaseShortArrayElements(self, jshortArray array, jshort *elems, jint mode) except -1:
        assert array is not NULL and elems is not NULL
        cdef PyThreadState* gilstate = NULL if mode == JNI_ABORT else PyEval_SaveThread()
        self.env[0].ReleaseShortArrayElements(self.env, array, elems, mode)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return 0
    cdef inline int ReleaseIntArrayElements(self, jintArray array, jint *elems, jint mode) except -1:
        assert array is not NULL and elems is not NULL
        cdef PyThreadState* gilstate = NULL if mode == JNI_ABORT else PyEval_SaveThread()
        self.env[0].ReleaseIntArrayElements(self.env, array, elems, mode)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return 0
    cdef inline int ReleaseLongArrayElements(self, jlongArray array, jlong *elems, jint mode) except -1:
        assert array is not NULL and elems is not NULL
        cdef PyThreadState* gilstate = NULL if mode == JNI_ABORT else PyEval_SaveThread()
        self.env[0].ReleaseLongArrayElements(self.env, array, elems, mode)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return 0
    cdef inline int ReleaseFloatArrayElements(self, jfloatArray array, jfloat *elems, jint mode) except -1:
        assert array is not NULL and elems is not NULL
        cdef PyThreadState* gilstate = NULL if mode == JNI_ABORT else PyEval_SaveThread()
        self.env[0].ReleaseFloatArrayElements(self.env, array, elems, mode)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return 0
    cdef inline int ReleaseDoubleArrayElements(self, jdoubleArray array, jdouble *elems, jint mode) except -1:
        assert array is not NULL and elems is not NULL
        cdef PyThreadState* gilstate = NULL if mode == JNI_ABORT else PyEval_SaveThread()
        self.env[0].ReleaseDoubleArrayElements(self.env, array, elems, mode)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return 0

    cdef inline int GetBooleanArrayRegion(self, jbooleanArray array, jsize start, jsize len, jboolean *buf) except -1:
        assert array is not NULL and start >= 0 and len >= 0 and buf is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jboolean) else PyEval_SaveThread()
        self.env[0].GetBooleanArrayRegion(self.env, array, start, len, buf)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return 0
    cdef inline int GetByteArrayRegion(self, jbyteArray array, jsize start, jsize len, jbyte *buf) except -1:
        assert array is not NULL and start >= 0 and len >= 0 and buf is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jbyte) else PyEval_SaveThread()
        self.env[0].GetByteArrayRegion(self.env, array, start, len, buf)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return 0
    cdef inline int GetCharArrayRegion(self, jcharArray array, jsize start, jsize len, jchar *buf) except -1:
        assert array is not NULL and start >= 0 and len >= 0 and buf is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jchar) else PyEval_SaveThread()
        self.env[0].GetCharArrayRegion(self.env, array, start, len, buf)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return 0
    cdef inline int GetShortArrayRegion(self, jshortArray array, jsize start, jsize len, jshort *buf) except -1:
        assert array is not NULL and start >= 0 and len >= 0 and buf is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jshort) else PyEval_SaveThread()
        self.env[0].GetShortArrayRegion(self.env, array, start, len, buf)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return 0
    cdef inline int GetIntArrayRegion(self, jintArray array, jsize start, jsize len, jint *buf) except -1:
        assert array is not NULL and start >= 0 and len >= 0 and buf is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jint) else PyEval_SaveThread()
        self.env[0].GetIntArrayRegion(self.env, array, start, len, buf)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return 0
    cdef inline int GetLongArrayRegion(self, jlongArray array, jsize start, jsize len, jlong *buf) except -1:
        assert array is not NULL and start >= 0 and len >= 0 and buf is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jlong) else PyEval_SaveThread()
        self.env[0].GetLongArrayRegion(self.env, array, start, len, buf)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return 0
    cdef inline int GetFloatArrayRegion(self, jfloatArray array, jsize start, jsize len, jfloat *buf) except -1:
        assert array is not NULL and start >= 0 and len >= 0 and buf is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jfloat) else PyEval_SaveThread()
        self.env[0].GetFloatArrayRegion(self.env, array, start, len, buf)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return 0
    cdef inline int GetDoubleArrayRegion(self, jdoubleArray array, jsize start, jsize len, jdouble *buf) except -1:
        assert array is not NULL and start >= 0 and len >= 0 and buf is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jdouble) else PyEval_SaveThread()
        self.env[0].GetDoubleArrayRegion(self.env, array, start, len, buf)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return 0

    cdef inline int SetBooleanArrayRegion(self, jbooleanArray array, jsize start, jsize len, jboolean *buf) except -1:
        assert array is not NULL and start >= 0 and len >= 0 and buf is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jboolean) else PyEval_SaveThread()
        self.env[0].SetBooleanArrayRegion(self.env, array, start, len, buf)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return 0
    cdef inline int SetByteArrayRegion(self, jbyteArray array, jsize start, jsize len, jbyte *buf) except -1:
        assert array is not NULL and start >= 0 and len >= 0 and buf is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jbyte) else PyEval_SaveThread()
        self.env[0].SetByteArrayRegion(self.env, array, start, len, buf)
        self.check_exc()
        return 0
    cdef inline int SetCharArrayRegion(self, jcharArray array, jsize start, jsize len, jchar *buf) except -1:
        assert array is not NULL and start >= 0 and len >= 0 and buf is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jchar) else PyEval_SaveThread()
        self.env[0].SetCharArrayRegion(self.env, array, start, len, buf)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return 0
    cdef inline int SetShortArrayRegion(self, jshortArray array, jsize start, jsize len, jshort *buf) except -1:
        assert array is not NULL and start >= 0 and len >= 0 and buf is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jshort) else PyEval_SaveThread()
        self.env[0].SetShortArrayRegion(self.env, array, start, len, buf)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return 0
    cdef inline int SetIntArrayRegion(self, jintArray array, jsize start, jsize len, jint *buf) except -1:
        assert array is not NULL and start >= 0 and len >= 0 and buf is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jint) else PyEval_SaveThread()
        self.env[0].SetIntArrayRegion(self.env, array, start, len, buf)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return 0
    cdef inline int SetLongArrayRegion(self, jlongArray array, jsize start, jsize len, jlong *buf) except -1:
        assert array is not NULL and start >= 0 and len >= 0 and buf is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jlong) else PyEval_SaveThread()
        self.env[0].SetLongArrayRegion(self.env, array, start, len, buf)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return 0
    cdef inline int SetFloatArrayRegion(self, jfloatArray array, jsize start, jsize len, jfloat *buf) except -1:
        assert array is not NULL and start >= 0 and len >= 0 and buf is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jfloat) else PyEval_SaveThread()
        self.env[0].SetFloatArrayRegion(self.env, array, start, len, buf)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return 0
    cdef inline int SetDoubleArrayRegion(self, jdoubleArray array, jsize start, jsize len, jdouble *buf) except -1:
        assert array is not NULL and start >= 0 and len >= 0 and buf is not NULL
        cdef PyThreadState* gilstate = NULL if len < 8192//sizeof(jdouble) else PyEval_SaveThread()
        self.env[0].SetDoubleArrayRegion(self.env, array, start, len, buf)
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        self.check_exc()
        return 0

    cdef inline void *GetPrimitiveArrayCritical(self, jarray array, jboolean *isCopy) except NULL:
        assert array is not NULL
        cdef void *out = self.env[0].GetPrimitiveArrayCritical(self.env, array, isCopy)
        if out is NULL: self.check_exc()
        return out
    cdef inline int ReleasePrimitiveArrayCritical(self, jarray array, void *carray, jint mode) except -1:
        assert array is not NULL and carray is not NULL
        self.env[0].ReleasePrimitiveArrayCritical(self.env, array, carray, mode)
        self.check_exc()
        return 0

    # Registering Native Methods
    cdef inline int RegisterNatives(self, jclass clazz, const JNINativeMethod *methods, jint nMethods) except -1:
        assert clazz is not NULL and methods is not NULL and nMethods > 0
        cdef jint result = self.env[0].RegisterNatives(self.env, clazz, methods, nMethods)
        if result < 0: self.check_exc()
        return 0
    cdef inline int UnregisterNatives(self, jclass clazz) except -1:
        assert clazz is not NULL
        cdef jint result = self.env[0].UnregisterNatives(self.env, clazz)
        if result < 0: self.check_exc()
        return 0
    
    # Monitor Operations -  basically the 'synchronized' block from Java
    cdef inline int MonitorEnter(self, jobject obj) except -1:
        cdef jint result = self.env[0].MonitorEnter(self.env, obj)
        if result < 0: self.check_exc()
        return 0
    cdef inline int MonitorExit(self, jobject obj) except -1:
        cdef jint result = self.env[0].MonitorExit(self.env, obj)
        if result < 0: self.check_exc()
        return 0

    # NIO Support
    IF JNI_VERSION >= JNI_VERSION_1_4:
        cdef inline jobject NewDirectByteBuffer(self, void* address, jlong capacity):
            cdef jobject out = self.env[0].NewDirectByteBuffer(self.env, address, capacity)
            if out is NULL: self.check_exc()
            return out
        cdef inline void* GetDirectBufferAddress(self, jobject buf) except NULL:
            cdef void* out = self.env[0].GetDirectBufferAddress(self.env, buf)
            if out is NULL: self.check_exc()
            return out
        cdef inline jlong GetDirectBufferCapacity(self, jobject buf) except -1:
            cdef jlong out = self.env[0].GetDirectBufferCapacity(self.env, buf)
            if out < 0: self.check_exc()
            return out

    # Reflection Support
    cdef inline jfieldID FromReflectedField(self, jobject field) except NULL:
        assert field is not NULL
        cdef jfieldID out = self.env[0].FromReflectedField(self.env, field)
        if out is NULL: self.check_exc()
        return out
    cdef inline jmethodID FromReflectedMethod(self, jobject method) except NULL:
        assert method is not NULL
        cdef jmethodID out = self.env[0].FromReflectedMethod(self.env, method)
        if out is NULL: self.check_exc()
        return out
    cdef inline jobject ToReflectedMethod(self, jclass cls, jmethodID methodID, jboolean isStatic) except NULL:
        assert cls is not NULL and methodID is not NULL
        cdef jobject out = self.env[0].ToReflectedMethod(self.env, cls, methodID, isStatic)
        if out is NULL: self.check_exc()
        return out
    cdef inline jobject ToReflectedField(self, jclass cls, jfieldID fieldID, jboolean isStatic) except NULL:
        assert cls is not NULL and fieldID is not NULL
        cdef jobject out = self.env[0].ToReflectedField(self.env, cls, fieldID, isStatic)
        if out is NULL: self.check_exc()
        return out

    # Java VM Interface - use the jvm() global function instead
    #cdef int (*GetJavaVM)(self, JavaVM **vm) except -1:
    #    cdef jint result = self.env[0].GetJavaVM(self.env, vm)
    #    if result < 0: self.check_exc()
    #    return 0


    ########## Basic Conversion ##########
    cdef unicode pystr(self, jstring string, delete=True):
        """Converts a jstring to a Python unicode object. The jstring object is deleted."""
        if string is NULL: return None
        cdef JNIEnv* env = self.env
        cdef jsize length
        cdef const jchar *chars
        try:
            length = self.GetStringLength(string)
            chars = self.GetStringCritical(string)
            try:
                return PyUnicode_DecodeUTF16(<char*>chars, length*sizeof(jchar), NULL, NULL)
            finally: self.ReleaseStringCritical(string, chars)
        finally:
            if delete: self.DeleteRef(string)

    cdef list objs2list(self, jobjectArray arr, obj2py conv):
        """
        Converts a jobjectArray to a Python list. Each object in the array is given to the provided
        function. If arr is NULL, returns None. The array is deleted and the `conv` function should
        delete the object references it is given as well.
        """
        if arr is NULL: return None
        cdef jsize i, length = self.GetArrayLength(arr)
        cdef list lst = PyList_New(length)
        cdef jobject o
        for i in xrange(length):
            pyobj = conv(self, self.GetObjectArrayElement(arr, i))
            Py_INCREF(pyobj)
            PyList_SET_ITEM(lst, i, pyobj)
        self.DeleteRef(arr)
        return lst


    ########## Delete<X>Ref Wrapper ##########
    cdef inline int DeleteRef(self, jobject obj) except -1:
        """
        Deletes the reference to a Java Object regardless if it is a local, global, or weak-global reference.
        """
        if obj is NULL: return 0
        IF JNI_VERSION >= JNI_VERSION_1_6:
            # We can use GetObjectRefType
            cdef jobjectRefType ref_type = self.GetObjectRefType(obj)
            if   ref_type == JNIInvalidRefType:    raise RuntimeError('Attempting to delete invalid reference')
            elif ref_type == JNILocalRefType:      self.DeleteLocalRef(obj)
            elif ref_type == JNIGlobalRefType:     self.DeleteGlobalRef(obj)
            elif ref_type == JNIWeakGlobalRefType: self.DeleteWeakGlobalRef(obj)
        ELSE:
            # We cannot use GetObjectRefType
            self.env[0].DeleteLocalRef(self.env, obj)
            if self.env[0].ExceptionCheck(self.env) == JNI_TRUE:
                self.env[0].ExceptionClear(self.env)
                self.env[0].DeleteGlobalRef(self.env, obj)
                if self.env[0].ExceptionCheck(self.env) == JNI_TRUE:
                    self.env[0].ExceptionClear(self.env)
                    self.DeleteWeakGlobalRef(obj)


    ########## Call<type>Method Wrappers with some conversion ##########
    # These are designed for reading the reflection data. They do not release the GIL and only
    # perform very basic conversions.
    cdef inline bint CallBoolean(self, jobject obj, jmethodID method, jvalue* args = NULL) except -1:
        assert obj is not NULL and method is not NULL
        cdef jboolean out = self.env[0].CallBooleanMethodA(self.env, obj, method, args)
        self.check_exc()
        return out == JNI_TRUE
    cdef inline jint CallInt(self, jobject obj, jmethodID method, jvalue* args = NULL) except? -1:
        assert obj is not NULL and method is not NULL
        cdef jint out = self.env[0].CallIntMethodA(self.env, obj, method, args)
        self.check_exc()
        return out
    cdef inline jobject CallObject(self, jobject obj, jmethodID method, jvalue* args = NULL) except? NULL:
        assert obj is not NULL and method is not NULL
        cdef jobject out = self.env[0].CallObjectMethodA(self.env, obj, method, args)
        self.check_exc()
        return out
    cdef inline unicode CallString(self, jobject obj, jmethodID method, jvalue* args = NULL):
        return self.pystr(<jstring>self.CallObject(obj, method, args))
    cdef inline JClass CallClass(self, jobject obj, jmethodID method, jvalue* args = NULL):
        return JClass.get(self, <jclass>self.CallObject(obj, method, args))
    cdef inline list CallObjects(self, jobject obj, jmethodID method, obj2py conv, jvalue* args = NULL):
        return self.objs2list(<jobjectArray>self.CallObject(obj, method, args), conv)
    cdef inline list CallClasses(self, jobject obj, jmethodID method, jvalue* args = NULL):
        return self.objs2list(<jobjectArray>self.CallObject(obj, method, args), <obj2py>JClass.get)
    cdef inline jint CallStaticInt(self, jclass clazz, jmethodID method, jvalue* args = NULL) except? -1:
        assert clazz is not NULL and method is not NULL
        cdef jint out = self.env[0].CallStaticIntMethodA(self.env, clazz, method, args)
        self.check_exc()
        return out
    cdef inline jobject CallStaticObject(self, jclass clazz, jmethodID method, jvalue* args = NULL) except? NULL:
        assert clazz is not NULL and method is not NULL
        cdef jobject out = self.env[0].CallStaticObjectMethodA(self.env, clazz, method, args)
        self.check_exc()
        return out
