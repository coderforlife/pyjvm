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

include "version.pxi"

from cpython.long    cimport PyLong_AsLongLong
from cpython.float   cimport PyFloat_AsDouble
from cpython.object  cimport PyObject_IsTrue
from cpython.unicode cimport PyUnicode_AsUTF16String

from .unicode cimport to_utf8j
from .jni cimport *
#from .jref cimport JField, JClass, jvm


########## Python to Java Primitive Conversion ##########
# Java primitives each have their own method. Additionally, since the Python wrappers for the
# boxing classes have __bool__, __int__, __long__, and __float__ as appropiate, these
# inherently support auto-unboxing.
# bool        -> boolean                  (includes anything implementing __bool__/__nonzero__)
# int/long    -> byte/char/short/int/long (includes anything implementing __int__/__long__)
# float       -> float/double             (includes anything implementing __float__)
# bytes/bytearray -> byte                 (length 1 only)
# unicode     -> char                     (length 1 only)
cdef inline jlong __p2j_long(object x, jlong mn, jlong mx) except? -1:
    cdef jlong out = PyLong_AsLongLong(x)
    if mn <= out <= mx: return out
    raise OverflowError()
cdef inline jboolean py2boolean(object x) except -1: return JNI_TRUE if PyObject_IsTrue(x) else JNI_FALSE
cdef inline jbyte  py2byte (object x) except? -1:
    if isinstance(x, bytearray):
        if len(x) == 1: return <jbyte>x[0]
        raise TypeError(u'expected single byte')
    if isinstance(x, bytes): return <jbyte>ord(x)
    return <jbyte>__p2j_long(x, JBYTE_MIN, JBYTE_MAX)
cdef inline jchar  py2char (object x) except? -1: return <jchar>(ord(x) if isinstance(x, unicode) else __p2j_long(x, 0, JCHAR_MAX))
cdef inline jshort py2short(object x) except? -1: return <jshort>__p2j_long(x, JSHORT_MIN, JSHORT_MAX)
cdef inline jint   py2int  (object x) except? -1: return <jint>__p2j_long(x, JINT_MIN, JINT_MAX)
cdef inline jlong  py2long (object x) except? -1: return <jlong>__p2j_long(x, JLONG_MIN, JLONG_MAX)
cdef inline jfloat py2float(object x) except? -1.0:
    cdef double dbl = PyFloat_AsDouble(x)
    if -JFLOAT_MAX <= dbl <= JFLOAT_MAX: return <jfloat>dbl
    raise OverflowError()
cdef inline jdouble py2double(object x) except? -1.0: return PyFloat_AsDouble(x)


cdef class JEnv(object):
    """
    Class which wraps the native JNIEnv pointer. One of these is created for each thread. This
    provides several function that are wrappers around the JNIEnv functions.
    """
    cdef JNIEnv* env
    cdef int init(self) except -1
    @staticmethod
    cdef inline JEnv wrap(JNIEnv* _env):
        cdef JEnv env = JEnv()
        env.env = _env
        return env
    
    # Basic Conversion
    cdef unicode pystr(self, jstring string, delete=*)
    cdef object __object2py(self, jobject obj)
    
    # Checking exceptions
    cdef int __raise_exception(self) except -1
    cdef inline int check_exc(self) except -1:
        """
        Checks to see if there is a Java exception pending. If there is, it is raised as a Python
        exception.
        """
        if self.env[0].ExceptionCheck(self.env) == JNI_TRUE: self.__raise_exception()
        return 0
    
    # Miscellaneous Operations
    cdef jint GetVersion(self) except -1
    # Java VM Interface - use `internal.jvm.jvm` instead
    #cdef inline JVM (*GetJavaVM)(self):
    #    cdef JavaVM *vm
    #    cdef jint result = self.env[0].GetJavaVM(self.env, &vm)
    #    if result < 0: self.check_exc()
    #    return JVM.wrap(vm)?

    # Class Operations
    cdef jobject DefineClass(self, unicode name, jobject loader, bytes buf) except NULL
    cdef inline jclass FindClass(self, unicode name) except NULL:
        cdef jclass clazz = self.env[0].FindClass(self.env, to_utf8j(name.replace(u'.', u'/')))
        if clazz is NULL: self.__raise_exception()
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

    # Module Operations
    IF JNI_VERSION >= JNI_VERSION_9:
        cdef jobject GetModule(self, jclass clazz) except NULL;

    # Exceptions - no error checking for any of these functions since they all manipulate the exception state
    cdef jint Throw(self, jthrowable obj)
    cdef jint ThrowNew(self, jclass clazz, unicode message)
    cdef jthrowable ExceptionOccurred(self)
    cdef void ExceptionDescribe(self)
    cdef void ExceptionClear(self)
    cdef void FatalError(self, unicode msg)
    cdef bint ExceptionCheck(self)

    # Global and Local References
    cdef inline jobject NewGlobalRef(self, jobject obj) except? NULL:
        cdef jobject out = self.env[0].NewGlobalRef(self.env, obj)
        if out is NULL: self.check_exc()
        return out
    cdef inline void DeleteGlobalRef(self, jobject globalRef):
        assert globalRef is not NULL
        self.env[0].DeleteGlobalRef(self.env, globalRef)
        #self.check_exc() # This is usually in the finally clause, don't check for errors
    cdef inline jobject NewLocalRef(self, jobject ref) except? NULL:
        cdef jobject out = self.env[0].NewLocalRef(self.env, ref)
        if out is NULL: self.check_exc()
        return out
    cdef inline void DeleteLocalRef(self, jobject localRef):
        assert localRef is not NULL
        self.env[0].DeleteLocalRef(self.env, localRef)
        #self.check_exc() # This is usually in the finally clause, don't check for errors
    cdef int EnsureLocalCapacity(self, jint capacity) except -1
    cdef int PushLocalFrame(self, jint capacity) except -1
    cdef jobject PopLocalFrame(self, jobject result) except? NULL

    # Weak Global References
    cdef inline jweak NewWeakGlobalRef(self, jobject obj) except? NULL:
        cdef jweak out = self.env[0].NewWeakGlobalRef(self.env, obj)
        if out is NULL: self.check_exc()
        return out
    cdef inline void DeleteWeakGlobalRef(self, jweak obj):
        assert obj is not NULL
        self.env[0].DeleteWeakGlobalRef(self.env, obj)
        #self.check_exc() # This is usually in the finally clause, don't check for errors

    # Delete<X>Ref Wrapper
    cdef inline void DeleteRef(self, jobject obj):
        """
        Deletes the reference to a Java Object regardless if it is a local, global, or weak-global reference.
        """
        if obj is NULL: return
        cdef JNIEnv* env = self.env
        IF JNI_VERSION >= JNI_VERSION_1_6:
            # We can use GetObjectRefType
            cdef jobjectRefType ref_type = env[0].GetObjectRefType(env, obj)
            if ref_type == JNIInvalidRefType:
                self.check_exc()
                raise RuntimeError(u'Attempting to delete invalid reference')
            elif ref_type == JNILocalRefType:      env[0].DeleteLocalRef(env, obj)
            elif ref_type == JNIGlobalRefType:     env[0].DeleteGlobalRef(env, obj)
            elif ref_type == JNIWeakGlobalRefType: env[0].DeleteWeakGlobalRef(env, obj)
            #self.check_exc() # This is usually in the finally clause, don't check for errors
        ELSE:
            # We cannot use GetObjectRefType
            env[0].DeleteLocalRef(env, obj)
            if env[0].ExceptionCheck(env) == JNI_TRUE:
                env[0].ExceptionClear(env)
                env[0].DeleteGlobalRef(env, obj)
                if env[0].ExceptionCheck(env) == JNI_TRUE:
                    env[0].ExceptionClear(env)
                    env[0].DeleteWeakGlobalRef(env, obj)
                    #self.check_exc() # This is usually in the finally clause, don't check for errors

    # Object Operations
    cdef jobject AllocObject(self, jclass clazz) except NULL
    cdef jobject NewObject(self, jclass clazz, jmethodID methodID, const jvalue *args, bint withgil) except NULL
    cdef inline jclass GetObjectClass(self, jobject obj) except NULL:
        assert obj is not NULL
        cdef jclass clazz = self.env[0].GetObjectClass(self.env, obj)
        if clazz is NULL: self.__raise_exception()
        return clazz
    IF JNI_VERSION >= JNI_VERSION_1_6:
        cdef jobjectRefType GetObjectRefType(self, jobject obj) except <jobjectRefType>-1
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
        assert clazz is not NULL and name is not None and sig is not None
        cdef jfieldID out = self.env[0].GetFieldID(self.env, clazz, to_utf8j(name), to_utf8j(sig))
        if out is NULL: self.__raise_exception()
        return out
    cdef inline jfieldID GetFieldID_(self, jclass clazz, unicode name, unicode sig):
        cdef jfieldID out = self.env[0].GetFieldID(self.env, clazz, to_utf8j(name), to_utf8j(sig))
        if out is NULL: self.env[0].ExceptionClear(self.env)
        return out
    cdef object GetObjectField(self, jobject obj, jfieldID fieldID)
    cdef object GetBooleanField(self, jobject obj, jfieldID fieldID)
    cdef object GetByteField(self, jobject obj, jfieldID fieldID)
    cdef object GetCharField(self, jobject obj, jfieldID fieldID)
    cdef object GetShortField(self, jobject obj, jfieldID fieldID)
    cdef object GetIntField(self, jobject obj, jfieldID fieldID)
    cdef object GetLongField(self, jobject obj, jfieldID fieldID)
    cdef object GetFloatField(self, jobject obj, jfieldID fieldID)
    cdef object GetDoubleField(self, jobject obj, jfieldID fieldID)
    cdef int SetObjectField(self, jobject obj, JField field, object value) except -1
    cdef int SetBooleanField(self, jobject obj, JField field, object value) except -1
    cdef int SetByteField(self, jobject obj, JField field, object value) except -1
    cdef int SetCharField(self, jobject obj, JField field, object value) except -1
    cdef int SetShortField(self, jobject obj, JField field, object value) except -1
    cdef int SetIntField(self, jobject obj, JField field, object value) except -1
    cdef int SetLongField(self, jobject obj, JField field, object value) except -1
    cdef int SetFloatField(self, jobject obj, JField field, object value) except -1
    cdef int SetDoubleField(self, jobject obj, JField field, object value) except -1

    # Calling Instance Methods
    cdef inline jmethodID GetMethodID(self, jclass clazz, unicode name, unicode sig) except NULL:
        assert clazz is not NULL and name is not None and sig is not None
        cdef jmethodID out = self.env[0].GetMethodID(self.env, clazz, to_utf8j(name), to_utf8j(sig))
        if out is NULL: self.__raise_exception()
        return out
    cdef object CallObjectMethod(self, jobject obj, jmethodID method, const jvalue *args, bint withgil)
    cdef object CallVoidMethod(self, jobject obj, jmethodID method, const jvalue *args, bint withgil)
    cdef object CallBooleanMethod(self, jobject obj, jmethodID method, const jvalue *args, bint withgil)
    cdef object CallByteMethod(self, jobject obj, jmethodID method, const jvalue *args, bint withgil)
    cdef object CallCharMethod(self, jobject obj, jmethodID method, const jvalue *args, bint withgil)
    cdef object CallShortMethod(self, jobject obj, jmethodID method, const jvalue *args, bint withgil)
    cdef object CallIntMethod(self, jobject obj, jmethodID method, const jvalue *args, bint withgil)
    cdef object CallLongMethod(self, jobject obj, jmethodID method, const jvalue *args, bint withgil)
    cdef object CallFloatMethod(self, jobject obj, jmethodID method, const jvalue *args, bint withgil)
    cdef object CallDoubleMethod(self, jobject obj, jmethodID method, const jvalue *args, bint withgil)
    cdef object CallNonvirtualObjectMethod(self, jobject obj, jclass clazz, jmethodID method, const jvalue *args, bint withgil)
    cdef object CallNonvirtualVoidMethod(self, jobject obj, jclass clazz, jmethodID method, const jvalue *args, bint withgil)
    cdef object CallNonvirtualBooleanMethod(self, jobject obj, jclass clazz, jmethodID method, const jvalue *args, bint withgil)
    cdef object CallNonvirtualByteMethod(self, jobject obj, jclass clazz, jmethodID method, const jvalue *args, bint withgil)
    cdef object CallNonvirtualCharMethod(self, jobject obj, jclass clazz, jmethodID method, const jvalue *args, bint withgil)
    cdef object CallNonvirtualShortMethod(self, jobject obj, jclass clazz, jmethodID method, const jvalue *args, bint withgil)
    cdef object CallNonvirtualIntMethod(self, jobject obj, jclass clazz, jmethodID method, const jvalue *args, bint withgil)
    cdef object CallNonvirtualLongMethod(self, jobject obj, jclass clazz, jmethodID method, const jvalue *args, bint withgil)
    cdef object CallNonvirtualFloatMethod(self, jobject obj, jclass clazz, jmethodID method, const jvalue *args, bint withgil)
    cdef object CallNonvirtualDoubleMethod(self, jobject obj, jclass clazz, jmethodID method, const jvalue *args, bint withgil)

    # Accessing Static Fields
    cdef inline jfieldID GetStaticFieldID(self, jclass clazz, unicode name, unicode sig) except NULL:
        assert clazz is not NULL and name is not None and sig is not None
        cdef jfieldID out = self.env[0].GetStaticFieldID(self.env, clazz, to_utf8j(name), to_utf8j(sig))
        if out is NULL: self.__raise_exception()
        return out
    cdef object GetStaticObjectField(self, jclass clazz, jfieldID fieldID)
    cdef object GetStaticBooleanField(self, jclass clazz, jfieldID fieldID)
    cdef object GetStaticByteField(self, jclass clazz, jfieldID fieldID)
    cdef object GetStaticCharField(self, jclass clazz, jfieldID fieldID)
    cdef object GetStaticShortField(self, jclass clazz, jfieldID fieldID)
    cdef object GetStaticIntField(self, jclass clazz, jfieldID fieldID)
    cdef object GetStaticLongField(self, jclass clazz, jfieldID fieldID)
    cdef object GetStaticFloatField(self, jclass clazz, jfieldID fieldID)
    cdef object GetStaticDoubleField(self, jclass clazz, jfieldID fieldID)
    cdef int SetStaticObjectField(self, jobject obj, JField field, object value) except -1
    cdef int SetStaticBooleanField(self, jclass clazz, JField field, object value) except -1
    cdef int SetStaticByteField(self, jclass clazz, JField field, object value) except -1
    cdef int SetStaticCharField(self, jclass clazz, JField field, object value) except -1
    cdef int SetStaticShortField(self, jclass clazz, JField field, object value) except -1
    cdef int SetStaticIntField(self, jclass clazz, JField field, object value) except -1
    cdef int SetStaticLongField(self, jclass clazz, JField field, object value) except -1
    cdef int SetStaticFloatField(self, jclass clazz, JField field, object value) except -1
    cdef int SetStaticDoubleField(self, jclass clazz, JField field, object value) except -1

    # Calling Static Methods
    cdef inline jmethodID GetStaticMethodID(self, jclass clazz, unicode name, unicode sig) except NULL:
        assert clazz is not NULL and name is not None and sig is not None
        cdef jmethodID out = self.env[0].GetStaticMethodID(self.env, clazz, to_utf8j(name), to_utf8j(sig))
        if out is NULL: self.__raise_exception()
        return out
    cdef object CallStaticObjectMethod(self, jclass clazz, jmethodID method, const jvalue *args, bint withgil)
    cdef object CallStaticVoidMethod(self, jclass clazz, jmethodID method, const jvalue *args, bint withgil)
    cdef object CallStaticBooleanMethod(self, jclass clazz, jmethodID method, const jvalue *args, bint withgil)
    cdef object CallStaticByteMethod(self, jclass clazz, jmethodID method, const jvalue *args, bint withgil)
    cdef object CallStaticCharMethod(self, jclass clazz, jmethodID method, const jvalue *args, bint withgil)
    cdef object CallStaticShortMethod(self, jclass clazz, jmethodID method, const jvalue *args, bint withgil)
    cdef object CallStaticIntMethod(self, jclass clazz, jmethodID method, const jvalue *args, bint withgil)
    cdef object CallStaticLongMethod(self, jclass clazz, jmethodID method, const jvalue *args, bint withgil)
    cdef object CallStaticFloatMethod(self, jclass clazz, jmethodID method, const jvalue *args, bint withgil)
    cdef object CallStaticDoubleMethod(self, jclass clazz, jmethodID method, const jvalue *args, bint withgil)

    # String Operations
    cdef inline jstring NewString(self, unicode s) except? NULL:
        if s is None: return NULL
        cdef bytes b = PyUnicode_AsUTF16String(s)
        cdef jstring string = self.env[0].NewString(self.env, (<jchar*><char*>b)+1, <jsize>(len(b)//sizeof(jchar))-1)
        if string is NULL: self.check_exc()
        return string
    cdef jsize GetStringLength(self, jstring string) except -1
    cdef const jchar *GetStringChars(self, jstring string, jboolean *isCopy=*) except NULL
    cdef void ReleaseStringChars(self, jstring string, const jchar *chars)
    cdef jstring NewStringUTF(self, unicode s) except? NULL
    cdef jsize GetStringUTFLength(self, jstring string) except -1
    cdef const char *GetStringUTFChars(self, jstring string, jboolean *isCopy=*) except NULL
    cdef void ReleaseStringUTFChars(self, jstring string, const char *utf)
    cdef int GetStringRegion(self, jstring string, jsize start, jsize len, jchar *buf) except -1
    cdef int GetStringUTFRegion(self, jstring string, jsize start, jsize len, char *buf) except -1
    cdef const jchar *GetStringCritical(self, jstring string, jboolean *isCopy=*) except NULL
    cdef void ReleaseStringCritical(self, jstring string, const jchar *carray)

    # Array Operations
    cdef inline jsize GetArrayLength(self, jarray array) except -1:
        assert array is not NULL
        cdef jsize out = self.env[0].GetArrayLength(self.env, array)
        if out < 0: self.__raise_exception()
        return out
    cdef inline jobjectArray NewObjectArray(self, jsize length, jclass elementClass, jobject initialElement) except NULL:
        assert length >= 0 and elementClass is not NULL
        cdef jobjectArray out = self.env[0].NewObjectArray(self.env, length, elementClass, initialElement)
        if out is NULL: self.__raise_exception()
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
    cdef jbooleanArray NewBooleanArray(self, jsize length) except NULL
    cdef jbyteArray NewByteArray(self, jsize length) except NULL
    cdef jcharArray NewCharArray(self, jsize length) except NULL
    cdef jshortArray NewShortArray(self, jsize length) except NULL
    cdef jintArray NewIntArray(self, jsize length) except NULL
    cdef jlongArray NewLongArray(self, jsize length) except NULL
    cdef jfloatArray NewFloatArray(self, jsize length) except NULL
    cdef jdoubleArray NewDoubleArray(self, jsize length) except NULL

    cdef jboolean *GetBooleanArrayElements(self, jbooleanArray array, jboolean *isCopy, jsize len) except NULL
    cdef jbyte *GetByteArrayElements(self, jbyteArray array, jboolean *isCopy, jsize len) except NULL
    cdef jchar *GetCharArrayElements(self, jcharArray array, jboolean *isCopy, jsize len) except NULL
    cdef jshort *GetShortArrayElements(self, jshortArray array, jboolean *isCopy, jsize len) except NULL
    cdef jint *GetIntArrayElements(self, jintArray array, jboolean *isCopy, jsize len) except NULL
    cdef jlong *GetLongArrayElements(self, jlongArray array, jboolean *isCopy, jsize len) except NULL
    cdef jfloat *GetFloatArrayElements(self, jfloatArray array, jboolean *isCopy, jsize len) except NULL
    cdef jdouble *GetDoubleArrayElements(self, jdoubleArray array, jboolean *isCopy, jsize len) except NULL

    cdef void ReleaseBooleanArrayElements(self, jbooleanArray array, jboolean *elems, jint mode)
    cdef void ReleaseByteArrayElements(self, jbyteArray array, jbyte *elems, jint mode)
    cdef void ReleaseCharArrayElements(self, jcharArray array, jchar *elems, jint mode)
    cdef void ReleaseShortArrayElements(self, jshortArray array, jshort *elems, jint mode)
    cdef void ReleaseIntArrayElements(self, jintArray array, jint *elems, jint mode)
    cdef void ReleaseLongArrayElements(self, jlongArray array, jlong *elems, jint mode)
    cdef void ReleaseFloatArrayElements(self, jfloatArray array, jfloat *elems, jint mode)
    cdef void ReleaseDoubleArrayElements(self, jdoubleArray array, jdouble *elems, jint mode)

    cdef int GetBooleanArrayRegion(self, jbooleanArray array, jsize start, jsize len, jboolean *buf) except -1
    cdef int GetByteArrayRegion(self, jbyteArray array, jsize start, jsize len, jbyte *buf) except -1
    cdef int GetCharArrayRegion(self, jcharArray array, jsize start, jsize len, jchar *buf) except -1
    cdef int GetShortArrayRegion(self, jshortArray array, jsize start, jsize len, jshort *buf) except -1
    cdef int GetIntArrayRegion(self, jintArray array, jsize start, jsize len, jint *buf) except -1
    cdef int GetLongArrayRegion(self, jlongArray array, jsize start, jsize len, jlong *buf) except -1
    cdef int GetFloatArrayRegion(self, jfloatArray array, jsize start, jsize len, jfloat *buf) except -1
    cdef int GetDoubleArrayRegion(self, jdoubleArray array, jsize start, jsize len, jdouble *buf) except -1

    cdef int SetBooleanArrayRegion(self, jbooleanArray array, jsize start, jsize len, jboolean *buf) except -1
    cdef int SetByteArrayRegion(self, jbyteArray array, jsize start, jsize len, jbyte *buf) except -1
    cdef int SetCharArrayRegion(self, jcharArray array, jsize start, jsize len, jchar *buf) except -1
    cdef int SetShortArrayRegion(self, jshortArray array, jsize start, jsize len, jshort *buf) except -1
    cdef int SetIntArrayRegion(self, jintArray array, jsize start, jsize len, jint *buf) except -1
    cdef int SetLongArrayRegion(self, jlongArray array, jsize start, jsize len, jlong *buf) except -1
    cdef int SetFloatArrayRegion(self, jfloatArray array, jsize start, jsize len, jfloat *buf) except -1
    cdef int SetDoubleArrayRegion(self, jdoubleArray array, jsize start, jsize len, jdouble *buf) except -1

    cdef inline void *GetPrimitiveArrayCritical(self, jarray array, jboolean *isCopy) except NULL:
        assert array is not NULL
        cdef void *out = self.env[0].GetPrimitiveArrayCritical(self.env, array, isCopy)
        if out is NULL: self.check_exc()
        return out
    cdef inline void ReleasePrimitiveArrayCritical(self, jarray array, void *carray, jint mode):
        assert array is not NULL and carray is not NULL
        self.env[0].ReleasePrimitiveArrayCritical(self.env, array, carray, mode)
        #self.check_exc() # This is usually in the finally clause, don't check for errors

    # Registering Native Methods
    cdef int RegisterNatives(self, jclass clazz, const JNINativeMethod *methods, jint nMethods) except -1
    cdef int UnregisterNatives(self, jclass clazz) except -1
    
    # Monitor Operations -  basically the 'synchronized' block from Java
    cdef int MonitorEnter(self, jobject obj) except -1
    cdef int MonitorExit(self, jobject obj) except -1

    # NIO Support
    IF JNI_VERSION >= JNI_VERSION_1_4:
        cdef jobject NewDirectByteBuffer(self, void* address, jlong capacity) except NULL
        cdef void* GetDirectBufferAddress(self, jobject buf) except NULL
        cdef jlong GetDirectBufferCapacity(self, jobject buf) except -1

    # Reflection Support
    cdef inline jfieldID FromReflectedField(self, jobject field) except NULL:
        assert field is not NULL
        cdef jfieldID out = self.env[0].FromReflectedField(self.env, field)
        if out is NULL: self.__raise_exception()
        return out
    cdef inline jmethodID FromReflectedMethod(self, jobject method) except NULL:
        assert method is not NULL
        cdef jmethodID out = self.env[0].FromReflectedMethod(self.env, method)
        if out is NULL: self.__raise_exception()
        return out
    cdef jobject ToReflectedMethod(self, jclass cls, jmethodID methodID, jboolean isStatic) except NULL
    cdef jobject ToReflectedField(self, jclass cls, jfieldID fieldID, jboolean isStatic) except NULL

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

cdef inline JEnv jenv():
    """Gets the JEnv object for the current thread, creating it if necessary."""
    return jvm.env()
