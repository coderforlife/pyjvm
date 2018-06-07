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

Cython definitions for the Java Native Interface C Header (jni.h).

Includes all type, constant, and method definitions from the manual at:
https://docs.oracle.com/javase/8/docs/technotes/guides/jni/spec/jniTOC.html
except the methods take ... or va_list arguments in JNIEnv:
    NewObject, NewObjectV,
    Call<type>Method, Call<type>MethodV
    CallNonvirtual<type>Method, CallNonvirtual<type>MethodV
    CallStatic<type>Method, CallStatic<type>MethodV
Each of them has an "A" version that takes a pointer to jvalues which should be used instead.
"""

# Added in JNI v1.2: improved FindClass, FatalError,
# EnsureLocalCapacity, PushLocalFrame, PopLocalFrame, NewLocalRef, NewWeakGlobalRef, DeleteWeakGlobalRef
# GetStringRegion, GetStringUTFRegion, GetStringCritical, ReleaseStringCritical,
# GetPrimitiveArrayCritical, ReleasePrimitiveArrayCritical,
# FromReflectedMethod, FromReflectedField, ToReflectedMethod, ToReflectedField
#
# Added in JNI v1.4: NewDirectByteBuffer, GetDirectBufferAddress, GetDirectBufferCapacity
#
# Added in JNI v1.6: GetObjectRefType
#
# Added in JNI v1.9: GetModule

cdef extern from "jni.h" nogil:
    ctypedef unsigned char jboolean
    ctypedef signed char jbyte
    ctypedef unsigned short jchar
    ctypedef signed short jshort
    ctypedef signed int jint
    ctypedef signed long jlong
    ctypedef float jfloat
    ctypedef double jdouble
    ctypedef jint jsize

    # Not technically in the header, but useful in many places
    cdef fused jprimitive:
        jboolean
        jbyte
        jchar
        jshort
        jint
        jlong
        jfloat
        jdouble

    cdef enum:
        JNI_FALSE = 0
        JNI_TRUE = 1

    cdef struct _jobject:
        pass
    ctypedef _jobject *jobject
    ctypedef jobject jclass
    ctypedef jobject jstring
    ctypedef jobject jthrowable
    ctypedef jobject jweak
    ctypedef jobject jarray
    ctypedef jobject jobjectArray
    ctypedef jobject jbooleanArray
    ctypedef jobject jbyteArray
    ctypedef jobject jcharArray
    ctypedef jobject jshortArray
    ctypedef jobject jintArray
    ctypedef jobject jlongArray
    ctypedef jobject jfloatArray
    ctypedef jobject jdoubleArray

    cdef struct _jfieldID:
        pass
    ctypedef _jfieldID *jfieldID
    cdef struct _jmethodID:
        pass
    ctypedef _jmethodID *jmethodID

    cdef union jvalue:
        jboolean z
        jbyte    b
        jchar    c
        jshort   s
        jint     i
        jlong    j
        jfloat   f
        jdouble  d
        jobject  l

    cdef enum:
        JNI_OK        =  0 # success
        JNI_ERR       = -1 # unknown error
        JNI_EDETACHED = -2 # thread detached from the VM
        JNI_EVERSION  = -3 # JNI version error
        JNI_ENOMEM    = -4 # not enough memory
        JNI_EEXIST    = -5 # VM already created
        JNI_EINVAL    = -6 # invalid arguments

    cdef enum:
        JNI_COMMIT
        JNI_ABORT

    cdef enum:
        JNI_VERSION_1_1
        JNI_VERSION_1_2
        JNI_VERSION_1_4
        JNI_VERSION_1_6
        JNI_VERSION_9

    cdef enum _jobjectType:
        JNIInvalidRefType = 0,
        JNILocalRefType = 1,
        JNIGlobalRefType = 2,
        JNIWeakGlobalRefType = 3
    ctypedef _jobjectType jobjectRefType

    cdef struct JavaVMOption:
        char *optionString  # the option as a string in the default platform encoding
        void *extraInfo
    cdef struct JavaVMInitArgs:
        jint version
        jint nOptions
        JavaVMOption *options
        jboolean ignoreUnrecognized
    cdef struct JavaVMAttachArgs:
        jint version
        char *name
        jobject group

    ctypedef struct JNINativeMethod:
        char *name
        char *signature
        void *fnPtr

    struct JavaVM_
    struct JNIInvokeInterface_
    ctypedef JNIInvokeInterface_ *JavaVM

    struct JNIEnv_
    struct JNINativeInterface_
    ctypedef JNINativeInterface_ *JNIEnv

    jint JNI_CreateJavaVM(JavaVM **p_vm, void **p_env, JavaVMInitArgs *vm_args)
    jint JNI_GetCreatedJavaVMs(JavaVM **vmBuf, jsize bufLen, jsize *nVMs)
    jint JNI_GetDefaultJavaVMInitArgs(JavaVMInitArgs *vm_args)

    struct JNIInvokeInterface_:
        jint (*GetEnv)(JavaVM *vm, void **env, jint version) nogil
        jint (*DestroyJavaVM)(JavaVM *vm) nogil
        jint (*AttachCurrentThread)(JavaVM *vm, void **p_env, JavaVMAttachArgs *thr_args) nogil
        jint (*AttachCurrentThreadAsDaemon)(JavaVM *vm, void **penv, JavaVMAttachArgs *args) nogil
        jint (*DetachCurrentThread)(JavaVM *vm) nogil

    struct JNINativeInterface_:
        # Version Information
        jint (*GetVersion)(JNIEnv *env) nogil

        # Class Operations
        jclass (*DefineClass)(JNIEnv *env, const char *name, jobject loader, const jbyte *buf, jsize bufLen) nogil
        jclass (*FindClass)(JNIEnv *env, const char *name) nogil
        jclass (*GetSuperclass)(JNIEnv *env, jclass clazz) nogil
        jboolean (*IsAssignableFrom)(JNIEnv *env, jclass clazz1, jclass clazz2) nogil

        # Module Operations
        jobject GetModule(JNIEnv *env, jclass clazz) nogil;

        # Exceptions
        jint (*Throw)(JNIEnv *env, jthrowable obj) nogil
        jint (*ThrowNew)(JNIEnv *env, jclass clazz, const char *message) nogil
        jthrowable (*ExceptionOccurred)(JNIEnv *env) nogil
        void (*ExceptionDescribe)(JNIEnv *env) nogil
        void (*ExceptionClear)(JNIEnv *env) nogil
        void (*FatalError)(JNIEnv *env, const char *msg) nogil
        jboolean (*ExceptionCheck)(JNIEnv *env) nogil

        # Global and Local References
        jobject (*NewGlobalRef)(JNIEnv *env, jobject obj) nogil
        void (*DeleteGlobalRef)(JNIEnv *env, jobject globalRef) nogil
        jobject (*NewLocalRef)(JNIEnv *env, jobject ref) nogil
        void (*DeleteLocalRef)(JNIEnv *env, jobject localRef) nogil
        jint (*EnsureLocalCapacity)(JNIEnv *env, jint capacity) nogil
        jint (*PushLocalFrame)(JNIEnv *env, jint capacity) nogil
        jobject (*PopLocalFrame)(JNIEnv *env, jobject result) nogil

        # Weak Global References
        jweak (*NewWeakGlobalRef)(JNIEnv *env, jobject obj) nogil
        void (*DeleteWeakGlobalRef)(JNIEnv *env, jweak obj) nogil

        # Object Operations
        jobject (*AllocObject)(JNIEnv *env, jclass clazz) nogil
        #jobject (*NewObject)(JNIEnv *env, jclass clazz, jmethodID methodID, ...) nogil
        jobject (*NewObjectA)(JNIEnv *env, jclass clazz, jmethodID methodID, const jvalue *args) nogil
        #jobject (*NewObjectV)(JNIEnv *env, jclass clazz, jmethodID methodID, va_list args) nogil
        jclass (*GetObjectClass)(JNIEnv *env, jobject obj) nogil
        jobjectRefType (*GetObjectRefType)(JNIEnv* env, jobject obj) nogil
        jboolean (*IsInstanceOf)(JNIEnv *env, jobject obj, jclass clazz) nogil
        jboolean (*IsSameObject)(JNIEnv *env, jobject ref1, jobject ref2) nogil

        # Accessing Fields of Objects
        jfieldID (*GetFieldID)(JNIEnv *env, jclass clazz, const char *name, const char *sig) nogil
        jobject (*GetObjectField)(JNIEnv *env, jobject obj, jfieldID fieldID) nogil
        jboolean (*GetBooleanField)(JNIEnv *env, jobject obj, jfieldID fieldID) nogil
        jbyte (*GetByteField)(JNIEnv *env, jobject obj, jfieldID fieldID) nogil
        jchar (*GetCharField)(JNIEnv *env, jobject obj, jfieldID fieldID) nogil
        jshort (*GetShortField)(JNIEnv *env, jobject obj, jfieldID fieldID) nogil
        jint (*GetIntField)(JNIEnv *env, jobject obj, jfieldID fieldID) nogil
        jlong (*GetLongField)(JNIEnv *env, jobject obj, jfieldID fieldID) nogil
        jfloat (*GetFloatField)(JNIEnv *env, jobject obj, jfieldID fieldID) nogil
        jdouble (*GetDoubleField)(JNIEnv *env, jobject obj, jfieldID fieldID) nogil
        void (*SetObjectField)(JNIEnv *env, jobject obj, jfieldID fieldID, jobject value) nogil
        void (*SetBooleanField)(JNIEnv *env, jobject obj, jfieldID fieldID, jboolean value) nogil
        void (*SetByteField)(JNIEnv *env, jobject obj, jfieldID fieldID, jbyte value) nogil
        void (*SetCharField)(JNIEnv *env, jobject obj, jfieldID fieldID, jchar value) nogil
        void (*SetShortField)(JNIEnv *env, jobject obj, jfieldID fieldID, jshort value) nogil
        void (*SetIntField)(JNIEnv *env, jobject obj, jfieldID fieldID, jint value) nogil
        void (*SetLongField)(JNIEnv *env, jobject obj, jfieldID fieldID, jlong value) nogil
        void (*SetFloatField)(JNIEnv *env, jobject obj, jfieldID fieldID, jfloat value) nogil
        void (*SetDoubleField)(JNIEnv *env, jobject obj, jfieldID fieldID, jdouble value) nogil

        # Calling Instance Methods
        jmethodID (*GetMethodID)(JNIEnv *env, jclass clazz, const char *name, const char *sig) nogil
        #NativeType (*Call<type>Method)(JNIEnv *env, jobject obj, jmethodID methodID, ...) nogil
        #NativeType (*Call<type>MethodV)(JNIEnv *env, jobject obj, jmethodID methodID, va_list args) nogil
        void (*CallVoidMethodA)(JNIEnv *env, jobject obj, jmethodID methodID, const jvalue *args) nogil
        jobject (*CallObjectMethodA)(JNIEnv *env, jobject obj, jmethodID methodID, const jvalue *args) nogil
        jboolean (*CallBooleanMethodA)(JNIEnv *env, jobject obj, jmethodID methodID, const jvalue *args) nogil
        jbyte (*CallByteMethodA)(JNIEnv *env, jobject obj, jmethodID methodID, const jvalue *args) nogil
        jchar (*CallCharMethodA)(JNIEnv *env, jobject obj, jmethodID methodID, const jvalue *args) nogil
        jshort (*CallShortMethodA)(JNIEnv *env, jobject obj, jmethodID methodID, const jvalue *args) nogil
        jint (*CallIntMethodA)(JNIEnv *env, jobject obj, jmethodID methodID, const jvalue *args) nogil
        jlong (*CallLongMethodA)(JNIEnv *env, jobject obj, jmethodID methodID, const jvalue *args) nogil
        jfloat (*CallFloatMethodA)(JNIEnv *env, jobject obj, jmethodID methodID, const jvalue *args) nogil
        jdouble (*CallDoubleMethodA)(JNIEnv *env, jobject obj, jmethodID methodID, const jvalue *args) nogil
        #NativeType (*CallNonvirtual<type>Method)(JNIEnv *env, jobject obj, jclass clazz, jmethodID methodID, ...) nogil
        #NativeType (*CallNonvirtual<type>MethodV)(JNIEnv *env, jobject obj, jclass clazz, jmethodID methodID, va_list args) nogil
        void (*CallNonvirtualVoidMethodA)(JNIEnv *env, jobject obj, jclass clazz, jmethodID methodID, const jvalue *args) nogil
        jobject (*CallNonvirtualObjectMethodA)(JNIEnv *env, jobject obj, jclass clazz, jmethodID methodID, const jvalue *args) nogil
        jboolean (*CallNonvirtualBooleanMethodA)(JNIEnv *env, jobject obj, jclass clazz, jmethodID methodID, const jvalue *args) nogil
        jbyte (*CallNonvirtualByteMethodA)(JNIEnv *env, jobject obj, jclass clazz, jmethodID methodID, const jvalue *args) nogil
        jchar (*CallNonvirtualCharMethodA)(JNIEnv *env, jobject obj, jclass clazz, jmethodID methodID, const jvalue *args) nogil
        jshort (*CallNonvirtualShortMethodA)(JNIEnv *env, jobject obj, jclass clazz, jmethodID methodID, const jvalue *args) nogil
        jint (*CallNonvirtualIntMethodA)(JNIEnv *env, jobject obj, jclass clazz, jmethodID methodID, const jvalue *args) nogil
        jlong (*CallNonvirtualLongMethodA)(JNIEnv *env, jobject obj, jclass clazz, jmethodID methodID, const jvalue *args) nogil
        jfloat (*CallNonvirtualFloatMethodA)(JNIEnv *env, jobject obj, jclass clazz, jmethodID methodID, const jvalue *args) nogil
        jdouble (*CallNonvirtualDoubleMethodA)(JNIEnv *env, jobject obj, jclass clazz, jmethodID methodID, const jvalue *args) nogil

        # Accessing Static Fields
        jfieldID (*GetStaticFieldID)(JNIEnv *env, jclass clazz, const char *name, const char *sig) nogil
        jobject (*GetStaticObjectField)(JNIEnv *env, jclass clazz, jfieldID fieldID) nogil
        jboolean (*GetStaticBooleanField)(JNIEnv *env, jclass clazz, jfieldID fieldID) nogil
        jbyte (*GetStaticByteField)(JNIEnv *env, jclass clazz, jfieldID fieldID) nogil
        jchar (*GetStaticCharField)(JNIEnv *env, jclass clazz, jfieldID fieldID) nogil
        jshort (*GetStaticShortField)(JNIEnv *env, jclass clazz, jfieldID fieldID) nogil
        jint (*GetStaticIntField)(JNIEnv *env, jclass clazz, jfieldID fieldID) nogil
        jlong (*GetStaticLongField)(JNIEnv *env, jclass clazz, jfieldID fieldID) nogil
        jfloat (*GetStaticFloatField)(JNIEnv *env, jclass clazz, jfieldID fieldID) nogil
        jdouble (*GetStaticDoubleField)(JNIEnv *env, jclass clazz, jfieldID fieldID) nogil
        void (*SetStaticObjectField)(JNIEnv *env, jclass clazz, jfieldID fieldID, jobject value) nogil
        void (*SetStaticBooleanField)(JNIEnv *env, jclass clazz, jfieldID fieldID, jboolean value) nogil
        void (*SetStaticByteField)(JNIEnv *env, jclass clazz, jfieldID fieldID, jbyte value) nogil
        void (*SetStaticCharField)(JNIEnv *env, jclass clazz, jfieldID fieldID, jchar value) nogil
        void (*SetStaticShortField)(JNIEnv *env, jclass clazz, jfieldID fieldID, jshort value) nogil
        void (*SetStaticIntField)(JNIEnv *env, jclass clazz, jfieldID fieldID, jint value) nogil
        void (*SetStaticLongField)(JNIEnv *env, jclass clazz, jfieldID fieldID, jlong value) nogil
        void (*SetStaticFloatField)(JNIEnv *env, jclass clazz, jfieldID fieldID, jfloat value) nogil
        void (*SetStaticDoubleField)(JNIEnv *env, jclass clazz, jfieldID fieldID, jdouble value) nogil

        # Calling Static Methods
        jmethodID (*GetStaticMethodID)(JNIEnv *env, jclass clazz, const char *name, const char *sig) nogil
        #NativeType (*CallStatic<type>Method)(JNIEnv *env, jclass clazz, jmethodID methodID, ...) nogil
        #NativeType (*CallStatic<type>MethodV)(JNIEnv *env, jclass clazz, jmethodID methodID, va_list args) nogil
        void (*CallStaticVoidMethodA)(JNIEnv *env, jclass clazz, jmethodID methodID, jvalue *args) nogil
        jobject (*CallStaticObjectMethodA)(JNIEnv *env, jclass clazz, jmethodID methodID, jvalue *args) nogil
        jboolean (*CallStaticBooleanMethodA)(JNIEnv *env, jclass clazz, jmethodID methodID, jvalue *args) nogil
        jbyte (*CallStaticByteMethodA)(JNIEnv *env, jclass clazz, jmethodID methodID, jvalue *args) nogil
        jchar (*CallStaticCharMethodA)(JNIEnv *env, jclass clazz, jmethodID methodID, jvalue *args) nogil
        jshort (*CallStaticShortMethodA)(JNIEnv *env, jclass clazz, jmethodID methodID, jvalue *args) nogil
        jint (*CallStaticIntMethodA)(JNIEnv *env, jclass clazz, jmethodID methodID, jvalue *args) nogil
        jlong (*CallStaticLongMethodA)(JNIEnv *env, jclass clazz, jmethodID methodID, jvalue *args) nogil
        jfloat (*CallStaticFloatMethodA)(JNIEnv *env, jclass clazz, jmethodID methodID, jvalue *args) nogil
        jdouble (*CallStaticDoubleMethodA)(JNIEnv *env, jclass clazz, jmethodID methodID, jvalue *args) nogil

        # String Operations
        jstring (*NewString)(JNIEnv *env, const jchar *unicodeChars, jsize len) nogil
        jsize (*GetStringLength)(JNIEnv *env, jstring string) nogil
        const jchar * (*GetStringChars)(JNIEnv *env, jstring string, jboolean *isCopy) nogil
        void (*ReleaseStringChars)(JNIEnv *env, jstring string, const jchar *chars) nogil
        jstring (*NewStringUTF)(JNIEnv *env, const char *bytes) nogil
        jsize (*GetStringUTFLength)(JNIEnv *env, jstring string) nogil
        const char * (*GetStringUTFChars)(JNIEnv *env, jstring string, jboolean *isCopy) nogil
        void (*ReleaseStringUTFChars)(JNIEnv *env, jstring string, const char *utf) nogil
        void (*GetStringRegion)(JNIEnv *env, jstring str, jsize start, jsize len, jchar *buf) nogil
        void (*GetStringUTFRegion)(JNIEnv *env, jstring str, jsize start, jsize len, char *buf) nogil
        const jchar * (*GetStringCritical)(JNIEnv *env, jstring string, jboolean *isCopy) nogil
        void (*ReleaseStringCritical)(JNIEnv *env, jstring string, const jchar *carray) nogil

        # Array Operations
        jsize (*GetArrayLength)(JNIEnv *env, jarray array) nogil
        jobjectArray (*NewObjectArray)(JNIEnv *env, jsize length, jclass elementClass, jobject initialElement) nogil
        jobject (*GetObjectArrayElement)(JNIEnv *env, jobjectArray array, jsize index) nogil
        void (*SetObjectArrayElement)(JNIEnv *env, jobjectArray array, jsize index, jobject value) nogil

        jbooleanArray (*NewBooleanArray)(JNIEnv *env, jsize length) nogil
        jbyteArray (*NewByteArray)(JNIEnv *env, jsize length) nogil
        jcharArray (*NewCharArray)(JNIEnv *env, jsize length) nogil
        jshortArray (*NewShortArray)(JNIEnv *env, jsize length) nogil
        jintArray (*NewIntArray)(JNIEnv *env, jsize length) nogil
        jlongArray (*NewLongArray)(JNIEnv *env, jsize length) nogil
        jfloatArray (*NewFloatArray)(JNIEnv *env, jsize length) nogil
        jdoubleArray (*NewDoubleArray)(JNIEnv *env, jsize length) nogil

        jboolean *(*GetBooleanArrayElements)(JNIEnv *env, jbooleanArray array, jboolean *isCopy) nogil
        jbyte *(*GetByteArrayElements)(JNIEnv *env, jbyteArray array, jboolean *isCopy) nogil
        jchar *(*GetCharArrayElements)(JNIEnv *env, jcharArray array, jboolean *isCopy) nogil
        jshort *(*GetShortArrayElements)(JNIEnv *env, jshortArray array, jboolean *isCopy) nogil
        jint *(*GetIntArrayElements)(JNIEnv *env, jintArray array, jboolean *isCopy) nogil
        jlong *(*GetLongArrayElements)(JNIEnv *env, jlongArray array, jboolean *isCopy) nogil
        jfloat *(*GetFloatArrayElements)(JNIEnv *env, jfloatArray array, jboolean *isCopy) nogil
        jdouble *(*GetDoubleArrayElements)(JNIEnv *env, jdoubleArray array, jboolean *isCopy) nogil

        void (*ReleaseBooleanArrayElements)(JNIEnv *env, jbooleanArray array, jboolean *elems, jint mode) nogil
        void (*ReleaseByteArrayElements)(JNIEnv *env, jbyteArray array, jbyte *elems, jint mode) nogil
        void (*ReleaseCharArrayElements)(JNIEnv *env, jcharArray array, jchar *elems, jint mode) nogil
        void (*ReleaseShortArrayElements)(JNIEnv *env, jshortArray array, jshort *elems, jint mode) nogil
        void (*ReleaseIntArrayElements)(JNIEnv *env, jintArray array, jint *elems, jint mode) nogil
        void (*ReleaseLongArrayElements)(JNIEnv *env, jlongArray array, jlong *elems, jint mode) nogil
        void (*ReleaseFloatArrayElements)(JNIEnv *env, jfloatArray array, jfloat *elems, jint mode) nogil
        void (*ReleaseDoubleArrayElements)(JNIEnv *env, jdoubleArray array, jdouble *elems, jint mode) nogil

        void (*GetBooleanArrayRegion)(JNIEnv *env, jbooleanArray array, jsize start, jsize len, jboolean *buf) nogil
        void (*GetByteArrayRegion)(JNIEnv *env, jbyteArray array, jsize start, jsize len, jbyte *buf) nogil
        void (*GetCharArrayRegion)(JNIEnv *env, jcharArray array, jsize start, jsize len, jchar *buf) nogil
        void (*GetShortArrayRegion)(JNIEnv *env, jshortArray array, jsize start, jsize len, jshort *buf) nogil
        void (*GetIntArrayRegion)(JNIEnv *env, jintArray array, jsize start, jsize len, jint *buf) nogil
        void (*GetLongArrayRegion)(JNIEnv *env, jlongArray array, jsize start, jsize len, jlong *buf) nogil
        void (*GetFloatArrayRegion)(JNIEnv *env, jfloatArray array, jsize start, jsize len, jfloat *buf) nogil
        void (*GetDoubleArrayRegion)(JNIEnv *env, jdoubleArray array, jsize start, jsize len, jdouble *buf) nogil

        void (*SetBooleanArrayRegion)(JNIEnv *env, jbooleanArray array, jsize start, jsize len, const jboolean *buf) nogil
        void (*SetByteArrayRegion)(JNIEnv *env, jbyteArray array, jsize start, jsize len, const jbyte *buf) nogil
        void (*SetCharArrayRegion)(JNIEnv *env, jcharArray array, jsize start, jsize len, const jchar *buf) nogil
        void (*SetShortArrayRegion)(JNIEnv *env, jshortArray array, jsize start, jsize len, const jshort *buf) nogil
        void (*SetIntArrayRegion)(JNIEnv *env, jintArray array, jsize start, jsize len, const jint *buf) nogil
        void (*SetLongArrayRegion)(JNIEnv *env, jlongArray array, jsize start, jsize len, const jlong *buf) nogil
        void (*SetFloatArrayRegion)(JNIEnv *env, jfloatArray array, jsize start, jsize len, const jfloat *buf) nogil
        void (*SetDoubleArrayRegion)(JNIEnv *env, jdoubleArray array, jsize start, jsize len, const jdouble *buf) nogil

        void * (*GetPrimitiveArrayCritical)(JNIEnv *env, jarray array, jboolean *isCopy) nogil
        void (*ReleasePrimitiveArrayCritical)(JNIEnv *env, jarray array, void *carray, jint mode) nogil

        # Registering Native Methods
        jint (*RegisterNatives)(JNIEnv *env, jclass clazz, const JNINativeMethod *methods, jint nMethods) nogil
        jint (*UnregisterNatives)(JNIEnv *env, jclass clazz) nogil

        # Monitor Operations
        jint (*MonitorEnter)(JNIEnv *env, jobject obj) nogil
        jint (*MonitorExit)(JNIEnv *env, jobject obj) nogil

        # NIO Support
        jobject (*NewDirectByteBuffer)(JNIEnv* env, void* address, jlong capacity) nogil
        void* (*GetDirectBufferAddress)(JNIEnv* env, jobject buf) nogil
        jlong (*GetDirectBufferCapacity)(JNIEnv* env, jobject buf) nogil

        # Reflection Support
        jfieldID (*FromReflectedField)(JNIEnv *env, jobject field) nogil
        jmethodID (*FromReflectedMethod)(JNIEnv *env, jobject method) nogil
        jobject (*ToReflectedMethod)(JNIEnv *env, jclass cls, jmethodID methodID, jboolean isStatic) nogil
        jobject (*ToReflectedField)(JNIEnv *env, jclass cls, jfieldID fieldID, jboolean isStatic) nogil

        # Java VM Interface
        jint (*GetJavaVM)(JNIEnv *env, JavaVM **vm) nogil

cdef extern from "primitive_limits.h" nogil:
    cdef enum:
        JBYTE_MIN
        JBYTE_MAX
        JSHORT_MIN
        JSHORT_MAX
        JINT_MIN
        JINT_MAX
        JLONG_MIN
        JLONG_MAX
        JCHAR_MAX
        JFLOAT_MAX
