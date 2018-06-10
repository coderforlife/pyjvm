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

Java Reflection and Wrappers
----------------------------

This includes some basic JNIEnv wrappers with no error checking or conversion, basic Java classes
and methods (mainly for reflection) for use in the internals of pyjvm, and basic Python wrappers
for the core Java reflected types.

Internal enums:
    Modifiers - possible modifiers for Java classes, constructors, methods, and fields

Internal classes:
    JClass  - wrapper around a jclass / java.lang.Class
    JMethod - wrapper around a jmethodID / java.lang.reflect.Method / java.lang.reflect.Constructor
    JField  - wrapper around a jfieldID / java.lang.reflect.Field
    JObject - wrapper around a jobject / java.lang.Object
    DeleteGlobalRefAction   - JVMAction to perform DeleteGlobalRef
    UnregisterNativesAction - JVMAction to perform UnregisterNatives
    RunnableAction          - JVMAction to execute a Runnable
    GCAction                - JVMAction to perform garbage collection in Java and Python

Internal values:
    ObjectDef      - common jmethodIDs needed from java.lang.Object
    SystemDef      - common jmethodIDs needed from java.lang.System
    ClassLoaderDef - common jmethodIDs needed from java.lang.ClassLoader
    URLClassLoaderDef - common jmethodIDs needed from java.net.URLClassLoader
    FileDef        - common jmethodIDs needed from java.io.File
    URIDef         - common jmethodIDs needed from java.net.URI
    PackageDef     - common jmethodIDs needed from java.lang.Package
    ClassDef       - common jmethodIDs needed from java.lang.Class
    FieldDef       - common jmethodIDs needed from java.lang.reflect.Field
    MethodDef      - common jmethodIDs needed from java.lang.reflect.Method
    ConstructorDef - common jmethodIDs needed from java.lang.reflect.Constructor
    RunnableDef    - common jmethodIDs needed from java.lang.Runnable
    ThreadDef      - common jmethodIDs needed from java.lang.Thread
    ThrowableDef   - common jmethodIDs needed from java.lang.Throwable

Internal functions:
    class_exists       - check if a Java class exists with a given name
    box_<primitive>    - box a primitive value, one function for each primitive type
    protection_prefix  - get the Python prefix (e.g. '__') for an access modifier
    delete_global_ref  - eithers calls DeleteGlobalRef now or as an action on the JVM thread
    unregister_natives - eithers calls UnregisterNatives now or as an action on the JVM thread

TODO:
    should all JObjects be dealloced when JVM deallocs?

FUTURE:
    handle generics and annotations
"""

#from __future__ import absolute_import

from cpython.ref cimport Py_INCREF
from cpython.list cimport PyList_New, PyList_SET_ITEM

from .utils cimport VALUES
from .jni cimport JNIEnv, jclass, jobject, jmethodID, jfieldID, jvalue, jsize
#from .jvm cimport jvm_add_init_hook, jvm_add_dealloc_hook, JVMAction
#from .jenv cimport JEnv, jenv, obj2py


########## Simple JNIEnv Wrappers ##########
# These are used before the environment is fully ready to get the reflection classes and methods.
# They take modified UTF-8 string instead of unicode, which means bytes objects if they have ascii
# only characters. They must also already have / instead of . for class names.
cdef inline jclass FindClass(JNIEnv* env, const char* name) nogil: return env[0].FindClass(env, name)
cdef inline jmethodID GetMethodID(JNIEnv* env, jclass clazz, const char* name, const char* sig) nogil:
    return env[0].GetMethodID(env, clazz, name, sig)
cdef inline jmethodID GetStaticMethodID(JNIEnv* env, jclass clazz, const char* name, const char* sig) nogil:
    return env[0].GetStaticMethodID(env, clazz, name, sig)
cdef inline jfieldID GetStaticFieldID(JNIEnv *env, jclass clazz, const char* name, const char* sig) nogil:
    return env[0].GetStaticFieldID(env, clazz, name, sig)
cdef inline jobject GetStaticObjectField(JNIEnv *env, jclass clazz, jfieldID fieldID) nogil:
    return env[0].GetStaticObjectField(env, clazz, fieldID)
cdef inline jobject NewGlobalRef(JNIEnv *env, jobject obj) nogil: return env[0].NewGlobalRef(env, obj)
cdef inline void DeleteGlobalRef(JNIEnv *env, jobject globalRef) nogil: env[0].DeleteGlobalRef(env, globalRef)
cdef inline jobject NewLocalRef(JNIEnv *env, jobject obj) nogil: return env[0].NewLocalRef(env, obj)
cdef inline void DeleteLocalRef(JNIEnv *env, jobject localRef) nogil: env[0].DeleteLocalRef(env, localRef)


########## Call Java functions that return Object arrays ##########
ctypedef object (*obj2py)(JEnv, jobject)
cdef inline list objs2list(JEnv env, jobjectArray arr, obj2py conv):
    """
    Converts a jobjectArray to a Python list. Each object in the array is given to the provided
    function. If arr is NULL, returns None. The array is deleted and the `conv` function should
    delete the object references it is given as well.
    """
    if arr is NULL: return None
    cdef jsize i, length
    cdef list lst
    cdef jobject o
    try:
        length = env.GetArrayLength(arr)
        lst = PyList_New(length)
        for i in xrange(length):
            pyobj = conv(env, env.GetObjectArrayElement(arr, i))
            Py_INCREF(pyobj)
            PyList_SET_ITEM(lst, i, pyobj)
    finally: env.DeleteRef(arr)
    return lst
cdef inline list call2list(JEnv env, jobject obj, jmethodID method, obj2py conv, jvalue* args = NULL):
    return objs2list(env, <jobjectArray>env.CallObject(obj, method, args), conv)


########## Java Class Functions ##########
# Each instance of this class represents the collections of functions that are specific to a single
# type, so all the ones that have <type> in them. Additionally, the size of primitive types, the
# signature, and the struct module format specifier for the type.
cdef void create_JCF(JClassFuncs* jcf, char sig, Py_ssize_t itemsize,
        CallMethod call, CallNVMethod call_nv, CallStaticMethod call_static,
        GetField get, SetField set, GetStaticField get_static, SetStaticField set_static,
        NewPrimArray new_array) nogil:
    jcf[0].sig = sig
    jcf[0].itemsize = itemsize
    jcf[0].call = call
    jcf[0].call_nv = call_nv
    jcf[0].call_static = call_static
    jcf[0].get = get
    jcf[0].set = set
    jcf[0].get_static = get_static
    jcf[0].set_static = set_static
    jcf[0].new_array = new_array
cdef JClassFuncs jcf_object, jcf_void, jcf_boolean
cdef JClassFuncs jcf_byte, jcf_char, jcf_short, jcf_int, jcf_long
cdef JClassFuncs jcf_float, jcf_double
cdef int init_jcf(JEnv env) except -1:
    create_JCF(&jcf_object, b'L', -1,
        JEnv.CallObjectMethod, JEnv.CallNonvirtualObjectMethod, JEnv.CallStaticObjectMethod,
        JEnv.GetObjectField, JEnv.SetObjectField, JEnv.GetStaticObjectField, JEnv.SetStaticObjectField,
        NULL) # special array function for objects
    create_JCF(&jcf_void, b'V', -1,
        JEnv.CallVoidMethod, JEnv.CallNonvirtualVoidMethod, JEnv.CallStaticVoidMethod,
        NULL, NULL, NULL, NULL, NULL) # fields cannot be void
    create_JCF(&jcf_boolean, b'Z', sizeof(jboolean),
        JEnv.CallBooleanMethod, JEnv.CallNonvirtualBooleanMethod, JEnv.CallStaticBooleanMethod,
        JEnv.GetBooleanField, JEnv.SetBooleanField, JEnv.GetStaticBooleanField, JEnv.SetStaticBooleanField,
        JEnv.NewBooleanArray)
    create_JCF(&jcf_byte, b'B', sizeof(jbyte),
        JEnv.CallByteMethod, JEnv.CallNonvirtualByteMethod, JEnv.CallStaticByteMethod,
        JEnv.GetByteField, JEnv.SetByteField, JEnv.GetStaticByteField, JEnv.SetStaticByteField,
        JEnv.NewByteArray)
    create_JCF(&jcf_char, b'C', sizeof(jchar),
        JEnv.CallCharMethod, JEnv.CallNonvirtualCharMethod, JEnv.CallStaticCharMethod,
        JEnv.GetCharField, JEnv.SetCharField, JEnv.GetStaticCharField, JEnv.SetStaticCharField,
        JEnv.NewCharArray)
    create_JCF(&jcf_short, b'S', sizeof(jshort),
        JEnv.CallShortMethod, JEnv.CallNonvirtualShortMethod, JEnv.CallStaticShortMethod,
        JEnv.GetShortField, JEnv.SetShortField, JEnv.GetStaticShortField, JEnv.SetStaticShortField,
        JEnv.NewShortArray)
    create_JCF(&jcf_int, b'I', sizeof(jint),
        JEnv.CallIntMethod, JEnv.CallNonvirtualIntMethod, JEnv.CallStaticIntMethod,
        JEnv.GetIntField, JEnv.SetIntField, JEnv.GetStaticIntField, JEnv.SetStaticIntField,
        JEnv.NewIntArray)
    create_JCF(&jcf_long, b'J', sizeof(jlong),
        JEnv.CallLongMethod, JEnv.CallNonvirtualLongMethod, JEnv.CallStaticLongMethod,
        JEnv.GetLongField, JEnv.SetLongField, JEnv.GetStaticLongField, JEnv.SetStaticLongField,
        JEnv.NewLongArray)
    create_JCF(&jcf_float, b'F', sizeof(jfloat),
        JEnv.CallFloatMethod, JEnv.CallNonvirtualFloatMethod, JEnv.CallStaticFloatMethod,
        JEnv.GetFloatField, JEnv.SetFloatField, JEnv.GetStaticFloatField, JEnv.SetStaticFloatField,
        JEnv.NewFloatArray)
    create_JCF(&jcf_double,b'D', sizeof(jdouble),
        JEnv.CallDoubleMethod, JEnv.CallNonvirtualDoubleMethod, JEnv.CallStaticDoubleMethod,
        JEnv.GetDoubleField, JEnv.SetDoubleField, JEnv.GetStaticDoubleField, JEnv.SetStaticDoubleField,
        JEnv.NewDoubleArray)
    return 0
jvm_add_init_hook(init_jcf, 1)


########## Basic Classes and Methods ##########
# These are the classes and methods that are internally used. They are cached in these structures
# upon first use. Mostly these are for reflection or common classes and methods.
cdef void init_ObjectDef(JNIEnv* env) nogil:
    cdef jclass C = FindClass(env, b'java/lang/Object')
    ObjectDef.clazz = <jclass>NewGlobalRef(env, C)
    ObjectDef.equals   = GetMethodID(env, C, b'equals',   b'(Ljava/lang/Object;)Z')
    ObjectDef.toString = GetMethodID(env, C, b'toString', b'()Ljava/lang/String;')
    ObjectDef.clone    = GetMethodID(env, C, b'clone',    b'()Ljava/lang/Object;')
    ObjectDef.hashCode = GetMethodID(env, C, b'hashCode', b'()I')
    # notify(), notifyAll(), wait(), wait(long), wait(long, int)
    DeleteLocalRef(env, C)
cdef void dealloc_ObjectDef(JNIEnv* env) nogil:
    if ObjectDef.clazz is not NULL: DeleteGlobalRef(env, ObjectDef.clazz)
    ObjectDef.clazz    = NULL
    ObjectDef.equals   = NULL
    ObjectDef.toString = NULL
    ObjectDef.clone    = NULL
    ObjectDef.hashCode = NULL

cdef void init_SystemDef(JNIEnv* env) nogil:
    cdef jclass C = FindClass(env, b'java/lang/System')
    SystemDef.clazz       = <jclass>NewGlobalRef(env, C)
    SystemDef.arraycopy   = GetStaticMethodID(env, C, b'arraycopy', b'(Ljava/lang/Object;ILjava/lang/Object;II)V')
    SystemDef.getProperty = GetStaticMethodID(env, C, b'getProperty', b'(Ljava/lang/String;)Ljava/lang/String;')
    SystemDef.gc          = GetStaticMethodID(env, C, b'gc', b'()V')
    SystemDef.identityHashCode = GetStaticMethodID(env, C, b'identityHashCode', b'(Ljava/lang/Object;)I')
    DeleteLocalRef(env, C)
cdef void dealloc_SystemDef(JNIEnv* env) nogil:
    if SystemDef.clazz is not NULL: DeleteGlobalRef(env, SystemDef.clazz)
    SystemDef.clazz       = NULL
    SystemDef.arraycopy   = NULL
    SystemDef.getProperty = NULL
    SystemDef.identityHashCode = NULL

cdef void init_ClassLoaderDef(JNIEnv* env) nogil:
    cdef jclass C = FindClass(env, b'java/lang/ClassLoader')
    ClassLoaderDef.clazz     = <jclass>NewGlobalRef(env, C)
    ClassLoaderDef.getParent = GetMethodID(env, C, b'getParent', b'()Ljava/lang/ClassLoader;')
    ClassLoaderDef.resolveClass = GetMethodID(env, C, b'resolveClass', b'(Ljava/lang/Class;)V')
    ClassLoaderDef.getSystemClassLoader = GetStaticMethodID(env, C, b'getSystemClassLoader', b'()Ljava/lang/ClassLoader;')
    DeleteLocalRef(env, C)
    C = FindClass(env, b'java/net/URLClassLoader')
    URLClassLoaderDef.clazz   = <jclass>NewGlobalRef(env, C)
    URLClassLoaderDef.addURL  = GetMethodID(env, C, b'addURL', b'(Ljava/net/URL;)V')
    URLClassLoaderDef.getURLs = GetMethodID(env, C, b'getURLs', b'()[Ljava/net/URL;')
    DeleteLocalRef(env, C)
cdef void dealloc_ClassLoaderDef(JNIEnv* env) nogil:
    if ClassLoaderDef.clazz is not NULL: DeleteGlobalRef(env, ClassLoaderDef.clazz)
    ClassLoaderDef.clazz     = NULL
    ClassLoaderDef.getParent = NULL
    ClassLoaderDef.resolveClass = NULL
    ClassLoaderDef.getSystemClassLoader = NULL
    if URLClassLoaderDef.clazz is not NULL: DeleteGlobalRef(env, URLClassLoaderDef.clazz)
    URLClassLoaderDef.clazz   = NULL
    URLClassLoaderDef.addURL  = NULL
    URLClassLoaderDef.getURLs = NULL

cdef void init_FileDef(JNIEnv* env) nogil:
    cdef jclass C = FindClass(env, b'java/io/File')
    FileDef.clazz = <jclass>NewGlobalRef(env, C)
    FileDef.ctor  = GetMethodID(env, C, b'<init>', b'(Ljava/lang/String;)V')
    FileDef.toURI = GetMethodID(env, C, b'toURI', b'()Ljava/net/URI;')
    DeleteLocalRef(env, C)
    C = FindClass(env, b'java/net/URI')
    URIDef.clazz = <jclass>NewGlobalRef(env, C)
    URIDef.toURL = GetMethodID(env, C, b'toURL', b'()Ljava/net/URL;')
    DeleteLocalRef(env, C)
cdef void dealloc_FileDef(JNIEnv* env) nogil:
    if FileDef.clazz is not NULL: DeleteGlobalRef(env, FileDef.clazz)
    FileDef.clazz = NULL
    FileDef.ctor  = NULL
    FileDef.toURI = NULL
    if URIDef.clazz is not NULL: DeleteGlobalRef(env, URIDef.clazz)
    URIDef.clazz = NULL
    URIDef.toURL = NULL

cdef void init_PackageDef(JNIEnv* env) nogil:
    cdef jclass C = FindClass(env, b'java/lang/Package')
    PackageDef.clazz      = <jclass>NewGlobalRef(env, C)
    PackageDef.getName    = GetMethodID(env, C, b'getName', b'()Ljava/lang/String;')
    PackageDef.getPackage = GetStaticMethodID(env, C, b'getPackage', b'(Ljava/lang/String;)Ljava/lang/Package;')
    DeleteLocalRef(env, C)
cdef void dealloc_PackageDef(JNIEnv* env) nogil:
    if PackageDef.clazz is not NULL: DeleteGlobalRef(env, PackageDef.clazz)
    PackageDef.clazz      = NULL
    PackageDef.getName    = NULL
    PackageDef.getPackage = NULL

cdef void init_ClassDef(JNIEnv* env) nogil:
    cdef jclass C = FindClass(env, b'java/lang/Class')
    ClassDef.clazz = <jclass>NewGlobalRef(env, C)
    ClassDef.getName            = GetMethodID(env, C, b'getName', b'()Ljava/lang/String;')
    ClassDef.getSimpleName      = GetMethodID(env, C, b'getSimpleName', b'()Ljava/lang/String;')
    ClassDef.getPackage         = GetMethodID(env, C, b'getPackage', b'()Ljava/lang/Package;')
    ClassDef.getEnclosingClass  = GetMethodID(env, C, b'getEnclosingClass', b'()Ljava/lang/Class;')
    ClassDef.getDeclaringClass  = GetMethodID(env, C, b'getDeclaringClass', b'()Ljava/lang/Class;')
    ClassDef.getModifiers       = GetMethodID(env, C, b'getModifiers', b'()I')
    ClassDef.getDeclaredFields  = GetMethodID(env, C, b'getDeclaredFields', b'()[Ljava/lang/reflect/Field;')
    ClassDef.getDeclaredMethods = GetMethodID(env, C, b'getDeclaredMethods', b'()[Ljava/lang/reflect/Method;')
    ClassDef.getDeclaredConstructors = GetMethodID(env, C, b'getDeclaredConstructors', b'()[Ljava/lang/reflect/Constructor;')
    ClassDef.getDeclaredClasses = GetMethodID(env, C, b'getDeclaredClasses', b'()[Ljava/lang/Class;')
    #ClassDef.getSuperclass      = GetMethodID(env, C, b'getSuperclass', b'()Ljava/lang/Class;') # use JNI directly instead
    ClassDef.getInterfaces      = GetMethodID(env, C, b'getInterfaces', b'()[Ljava/lang/Class;')
    ClassDef.isInterface        = GetMethodID(env, C, b'isInterface', b'()Z')
    #ClassDef.isAnnotation       = GetMethodID(env, C, b'isAnnotation', b'()Z')
    #ClassDef.isPrimitive        = GetMethodID(env, C, b'isPrimitive', b'()Z') # primitives are handled specially instead
    ClassDef.isEnum             = GetMethodID(env, C, b'isEnum', b'()Z')
    ClassDef.isArray            = GetMethodID(env, C, b'isArray', b'()Z')
    ClassDef.getComponentType   = GetMethodID(env, C, b'getComponentType', b'()Ljava/lang/Class;')
    ClassDef.isAnonymousClass   = GetMethodID(env, C, b'isAnonymousClass', b'()Z')
    ClassDef.isLocalClass       = GetMethodID(env, C, b'isLocalClass', b'()Z')
    ClassDef.isMemberClass      = GetMethodID(env, C, b'isMemberClass', b'()Z')
    #ClassDef.isSynthetic        = GetMethodID(env, C, b'isSynthetic', b'()Z')
    # Parent: getEnclosingConstructor(), getEnclosingMethod()
    # Generics: getGenericInterfaces(), getGenericSuperclass(), getTypeParameters()
    # Annotations: getDeclaredAnnotations()
    # Other: getEnumConstants()
    DeleteLocalRef(env, C)
cdef void dealloc_ClassDef(JNIEnv* env) nogil:
    if ClassDef.clazz is not NULL: DeleteGlobalRef(env, ClassDef.clazz)
    ClassDef.clazz              = NULL
    ClassDef.getName            = NULL
    ClassDef.getSimpleName      = NULL
    ClassDef.getPackage         = NULL
    ClassDef.getEnclosingClass  = NULL
    ClassDef.getDeclaringClass  = NULL
    ClassDef.getModifiers       = NULL
    ClassDef.getDeclaredFields  = NULL
    ClassDef.getDeclaredMethods = NULL
    ClassDef.getDeclaredConstructors = NULL
    ClassDef.getDeclaredClasses = NULL
    ClassDef.getInterfaces      = NULL
    ClassDef.isInterface        = NULL
    #ClassDef.isAnnotation       = NULL
    ClassDef.isEnum             = NULL
    ClassDef.isArray            = NULL
    ClassDef.getComponentType   = NULL
    ClassDef.isAnonymousClass   = NULL
    ClassDef.isLocalClass       = NULL
    ClassDef.isMemberClass      = NULL
    #ClassDef.isSynthetic        = NULL

cdef void init_FieldDef(JNIEnv* env) nogil:
    cdef jclass C = FindClass(env, b'java/lang/reflect/Field')
    FieldDef.clazz = <jclass>NewGlobalRef(env, C)
    FieldDef.getName      = GetMethodID(env, C, b'getName',      b'()Ljava/lang/String;')
    FieldDef.getType      = GetMethodID(env, C, b'getType',      b'()Ljava/lang/Class;')
    FieldDef.getDeclaringClass = GetMethodID(env, C, b'getDeclaringClass', b'()Ljava/lang/Class;')
    FieldDef.getModifiers = GetMethodID(env, C, b'getModifiers', b'()I')
    #FieldDef.isSynthetic  = GetMethodID(env, C, b'isSynthetic',  b'()Z')
    # Generics: getGenericType()
    # Annotations: getDeclaredAnnotations()
    # Other: isEnumConstant()
    DeleteLocalRef(env, C)
cdef void dealloc_FieldDef(JNIEnv* env) nogil:
    if FieldDef.clazz is not NULL: DeleteGlobalRef(env, FieldDef.clazz)
    FieldDef.clazz        = NULL
    FieldDef.getName      = NULL
    FieldDef.getType      = NULL
    FieldDef.getDeclaringClass = NULL
    FieldDef.getModifiers = NULL
    #FieldDef.isSynthetic  = NULL

cdef void init_MethodDef(JNIEnv* env) nogil:
    cdef jclass C = FindClass(env, b'java/lang/reflect/Method')
    MethodDef.clazz = <jclass>NewGlobalRef(env, C)
    MethodDef.getName           = GetMethodID(env, C, b'getName',           b'()Ljava/lang/String;')
    MethodDef.getReturnType     = GetMethodID(env, C, b'getReturnType',     b'()Ljava/lang/Class;')
    MethodDef.getParameterTypes = GetMethodID(env, C, b'getParameterTypes', b'()[Ljava/lang/Class;')
    MethodDef.getExceptionTypes = GetMethodID(env, C, b'getExceptionTypes', b'()[Ljava/lang/Class;')
    MethodDef.getDeclaringClass = GetMethodID(env, C, b'getDeclaringClass', b'()Ljava/lang/Class;')
    MethodDef.getModifiers      = GetMethodID(env, C, b'getModifiers',      b'()I')
    MethodDef.isVarArgs         = GetMethodID(env, C, b'isVarArgs',         b'()Z')
    #MethodDef.isBridge          = GetMethodID(env, C, b'isBridge',          b'()Z')
    #MethodDef.isSynthetic       = GetMethodID(env, C, b'isSynthetic',       b'()Z')
    # Generics: getGenericParameterTypes(), getGenericReturnType(), getTypeParameters(), getGenericExceptionTypes()
    # Annotations: getDeclaredAnnotations(), getParameterAnnotations(), getDefaultValue()
    DeleteLocalRef(env, C)
cdef void dealloc_MethodDef(JNIEnv* env) nogil:
    if MethodDef.clazz is not NULL: DeleteGlobalRef(env, MethodDef.clazz)
    MethodDef.clazz             = NULL
    MethodDef.getName           = NULL
    MethodDef.getReturnType     = NULL
    MethodDef.getParameterTypes = NULL
    MethodDef.getExceptionTypes = NULL
    MethodDef.getDeclaringClass = NULL
    MethodDef.getModifiers      = NULL
    MethodDef.isVarArgs         = NULL
    #MethodDef.isBridge          = NULL
    #MethodDef.isSynthetic       = NULL

cdef void init_ConstructorDef(JNIEnv* env) nogil:
    cdef jclass C = FindClass(env, b'java/lang/reflect/Constructor')
    ConstructorDef.clazz = <jclass>NewGlobalRef(env, C)
    ConstructorDef.getName           = GetMethodID(env, C, b'getName',           b'()Ljava/lang/String;')
    ConstructorDef.getParameterTypes = GetMethodID(env, C, b'getParameterTypes', b'()[Ljava/lang/Class;')
    ConstructorDef.getExceptionTypes = GetMethodID(env, C, b'getExceptionTypes', b'()[Ljava/lang/Class;')
    ConstructorDef.getDeclaringClass = GetMethodID(env, C, b'getDeclaringClass', b'()Ljava/lang/Class;')
    ConstructorDef.getModifiers      = GetMethodID(env, C, b'getModifiers',      b'()I')
    ConstructorDef.isVarArgs         = GetMethodID(env, C, b'isVarArgs',         b'()Z')
    #ConstructorDef.isSynthetic       = GetMethodID(env, C, b'isSynthetic',       b'()Z')
    # Generics: getGenericParameterTypes(), getTypeParameters(), getGenericExceptionTypes()
    # Annotations: getDeclaredAnnotations(), getParameterAnnotations()
    DeleteLocalRef(env, C)
cdef void dealloc_ConstructorDef(JNIEnv* env) nogil:
    if ConstructorDef.clazz is not NULL: DeleteGlobalRef(env, ConstructorDef.clazz)
    ConstructorDef.clazz             = NULL
    ConstructorDef.getName           = NULL
    ConstructorDef.getParameterTypes = NULL
    ConstructorDef.getExceptionTypes = NULL
    ConstructorDef.getDeclaringClass = NULL
    ConstructorDef.getModifiers      = NULL
    ConstructorDef.isVarArgs         = NULL
    #ConstructorDef.isSynthetic       = NULL

cdef void init_RunnableDef(JNIEnv* env) nogil:
    cdef jclass C = FindClass(env, b'java/lang/Runnable')
    RunnableDef.clazz = <jclass>NewGlobalRef(env, C)
    RunnableDef.run   = GetMethodID(env, C, b'run', b'()V')
    DeleteLocalRef(env, C)
cdef void dealloc_RunnableDef(JNIEnv* env) nogil:
    if RunnableDef.clazz is not NULL: DeleteGlobalRef(env, RunnableDef.clazz)
    RunnableDef.clazz = NULL
    RunnableDef.run   = NULL

cdef void init_ThreadDef(JNIEnv* env) nogil:
    cdef jclass C = FindClass(env, b'java/lang/Thread')
    ThreadDef.clazz = <jclass>NewGlobalRef(env, C)
    ThreadDef.currentThread = GetStaticMethodID(env, C, b'currentThread', b'()Ljava/lang/Thread;')
    ThreadDef.getContextClassLoader = GetMethodID(env, C, b'getContextClassLoader', b'()Ljava/lang/ClassLoader;')
    ThreadDef.setContextClassLoader = GetMethodID(env, C, b'setContextClassLoader', b'(Ljava/lang/ClassLoader;)V')
    ThreadDef.start                 = GetMethodID(env, C, 'start', '()V')
    ThreadDef.interrupt             = GetMethodID(env, C, 'interrupt', '()V')
    ThreadDef.join                  = GetMethodID(env, C, 'join', '()V')
    DeleteLocalRef(env, C)
cdef void dealloc_ThreadDef(JNIEnv* env) nogil:
    if ThreadDef.clazz is not NULL: DeleteGlobalRef(env, ThreadDef.clazz)
    ThreadDef.clazz                 = NULL
    ThreadDef.currentThread         = NULL
    ThreadDef.getContextClassLoader = NULL
    ThreadDef.setContextClassLoader = NULL
    ThreadDef.start                 = NULL
    ThreadDef.interrupt             = NULL
    ThreadDef.join                  = NULL

cdef void init_ThrowableDef(JNIEnv* env) nogil:
    cdef jclass C = FindClass(env, b'java/lang/Throwable')
    ThrowableDef.clazz = <jclass>NewGlobalRef(env, C)
    ThrowableDef.getLocalizedMessage = GetMethodID(env, C, b'getLocalizedMessage', b'()Ljava/lang/String;')
    ThrowableDef.getStackTrace       = GetMethodID(env, C, b'getStackTrace', b'()[Ljava/lang/StackTraceElement;')
    ThrowableDef.getCause            = GetMethodID(env, C, b'getCause', b'()Ljava/lang/Throwable;')
    DeleteLocalRef(env, C)
cdef void dealloc_ThrowableDef(JNIEnv* env) nogil:
    if ThrowableDef.clazz is not NULL: DeleteGlobalRef(env, ThrowableDef.clazz)
    ThrowableDef.clazz               = NULL
    ThrowableDef.getLocalizedMessage = NULL
    ThrowableDef.getStackTrace       = NULL
    ThrowableDef.getCause            = NULL
    
cdef int init_def(JEnv env) except -1:
    with nogil:
        init_ObjectDef     (env.env)
        init_SystemDef     (env.env)
        init_ClassLoaderDef(env.env)
        init_FileDef       (env.env)
        init_PackageDef    (env.env)
        init_ClassDef      (env.env)
        init_FieldDef      (env.env)
        init_MethodDef     (env.env)
        init_ConstructorDef(env.env)
        init_RunnableDef   (env.env)
        init_ThreadDef     (env.env)
        init_ThrowableDef  (env.env)
    return 0
cdef int dealloc_def(JEnv env) except -1:
    with nogil:
        dealloc_ObjectDef     (env.env)
        dealloc_SystemDef     (env.env)
        dealloc_ClassLoaderDef(env.env)
        dealloc_FileDef       (env.env)
        dealloc_PackageDef    (env.env)
        dealloc_ClassDef      (env.env)
        dealloc_FieldDef      (env.env)
        dealloc_MethodDef     (env.env)
        dealloc_ConstructorDef(env.env)
        dealloc_RunnableDef   (env.env)
        dealloc_ThreadDef     (env.env)
        dealloc_ThrowableDef  (env.env)
    return 0
jvm_add_init_hook(init_def, -10)
jvm_add_dealloc_hook(dealloc_def, -10)


########## Basic actions that can be queued in the JVM thread ##########
# Currently only the DeleteGlobalRefAction and UnregisterNativesAction are used, the others are
# just here because they might be useful eventually.
cdef class DeleteGlobalRefAction(JVMAction):
    """Calls DeleteGlobalRef on the object"""
    cpdef run(self, JEnv env):
        assert self.obj is not NULL
        env.DeleteGlobalRef(self.obj)
cdef class UnregisterNativesAction(JVMAction):
    """Calls UnregisterNatives on the object"""
    cpdef run(self, JEnv env):
        assert self.obj is not NULL
        env.UnregisterNatives(self.obj)
cdef class RunnableAction(JVMAction):
    """Calls obj.run() with or without the GIL"""
    cpdef run(self, JEnv env):
        assert self.obj is not NULL
        env.CallVoidMethod(self.obj, RunnableDef.run, NULL, self.withgil)
cdef class GCAction(JVMAction):
    """Calls java.lang.System.gc() and Python's gc.collect()"""
    cpdef run(self, JEnv env):
        env.CallStaticVoidMethod(SystemDef.clazz, SystemDef.gc, NULL, False)
        import gc
        gc.collect()


########## Reference Wrappers ##########
# Basic wrapper classes for jclass, jmethodID, jfieldID, and jobject
cdef dict jclasses = None # dictionary of class name -> JClass

cdef class JClass(object):
    """Wrapper around a jclass pointer along with several properties of the class"""
    @staticmethod
    cdef JClass named(JEnv env, unicode name):
        """Gets or creates a unique JClass for the class name given."""
        if name in jclasses: return jclasses[name]
        return JClass.__create(env, name, env.FindClass(name))

    @staticmethod
    cdef JClass get(JEnv env, jclass clazz):
        """Gets or creates a unique JClass for the jclass object given. The ref is deleted."""
        if clazz is NULL: return None
        cdef JClass c
        cdef unicode name
        try: name = env.CallString(clazz, ClassDef.getName)
        except: env.DeleteRef(clazz)
        if name in jclasses:
            assert env.IsSameObject(clazz, (<JClass>jclasses[name]).clazz)
            env.DeleteRef(clazz)
            return jclasses[name]
        return JClass.__create(env, name, clazz)

    @staticmethod
    cdef JClass __create(JEnv env, unicode name, jclass clazz):
        """
        Creates a JClass for the class name and jclass object given. Copies the jclass object to a
        global reference and deletes the reference given.
        """
        cdef JClass c = JClass(), dc
        c.clazz = <jclass>env.NewGlobalRef(clazz)
        env.DeleteRef(clazz)
        clazz = c.clazz
        c.funcs = &jcf_object
        cdef jvalue val
        val.l = clazz
        c.identity = env.CallStaticInt(SystemDef.clazz, SystemDef.identityHashCode, &val)
        c.name = name
        c.simple_name = env.CallString(clazz, ClassDef.getSimpleName)
        if   env.CallBoolean(clazz, ClassDef.isArray):      c.type = CT_ARRAY
        #elif env.CallBoolean(clazz, ClassDef.isAnnotation): c.type = CT_ANNOTATION
        elif env.CallBoolean(clazz, ClassDef.isInterface):  c.type = CT_INTERFACE
        elif env.CallBoolean(clazz, ClassDef.isEnum):       c.type = CT_ENUM
        #elif env.CallBoolean(clazz, ClassDef.isPrimitive):  c.type = CT_PRIMITIVE
        if   env.CallBoolean(clazz, ClassDef.isAnonymousClass): c.mode = CM_ANONYMOUS
        elif env.CallBoolean(clazz, ClassDef.isLocalClass):     c.mode = CM_LOCAL
        elif env.CallBoolean(clazz, ClassDef.isMemberClass):    c.mode = CM_MEMBER
        #c.is_synthetic = env.CallBoolean(clazz, ClassDef.isSynthetic)
        cdef jobject package = env.CallObject(clazz, ClassDef.getPackage)
        if package is not NULL:
            c.package_name = env.CallString(package, PackageDef.getName)
            env.DeleteLocalRef(package)
        c.modifiers = <Modifiers>env.CallInt(clazz, ClassDef.getModifiers)

        assert name not in jclasses
        jclasses[name] = c # add now in case one of the calls below requires this type, causing a cyclic issue
        cdef list classes, ctors, methods, fields
        cdef JMethod m
        cdef JField f
        try:
            #c.superclass = env.CallClass(clazz, ClassDef.getSuperclass)
            c.superclass = JClass.get(env, env.GetSuperclass(clazz))
            c.enclosing_class = env.CallClass(clazz, ClassDef.getEnclosingClass)
            c.declaring_class = env.CallClass(clazz, ClassDef.getDeclaringClass)
            if c.is_array(): c.component_type = env.CallClass(clazz, ClassDef.getComponentType)
            c.interfaces = call2list(env, clazz, ClassDef.getInterfaces, <obj2py>JClass.get)
            classes = call2list(env, clazz, ClassDef.getDeclaredClasses, <obj2py>JClass.get)
            classes = [dc for dc in classes if dc.mode != CM_ANONYMOUS and dc.mode != CM_LOCAL]
            c.classes        = {dc.attr_name():dc for dc in classes if not dc.is_static()}
            c.static_classes = {dc.attr_name():dc for dc in classes if     dc.is_static()}
            ctors = call2list(env, clazz, ClassDef.getDeclaredConstructors, <obj2py>JMethod.create_ctor)
            c.constructors = ctors
            methods = call2list(env, clazz, ClassDef.getDeclaredMethods, <obj2py>JMethod.create)
            c.methods        = JMethod.group([m for m in methods if not m.is_static()])
            c.static_methods = JMethod.group([m for m in methods if     m.is_static()])
            fields = call2list(env, clazz, ClassDef.getDeclaredFields, <obj2py>JField.create)
            c.fields         = {f.attr_name():f for f in fields if not f.is_static()}
            c.static_fields  = {f.attr_name():f for f in fields if     f.is_static()}
        except:
            del jclasses[c.name]
            raise
        return c

    @staticmethod
    cdef JClass __create_primitive(JNIEnv* env, unicode cn, unicode name, JClassFuncs* funcs):
        """Creates a JClass object for a primitive type given its clazz, name, and functions."""
        # Should not raise errors here, so access functions directly instead of with JEnv wrappers
        cdef jclass clazz = FindClass(env, to_utf8j(cn)), clazz_prim
        cdef JClass c = JClass()
        cdef jfieldID fid = GetStaticFieldID(env, clazz, b'TYPE', b'Ljava/lang/Class;')
        clazz_prim = <jclass>GetStaticObjectField(env, clazz, fid)
        c.clazz = <jclass>NewGlobalRef(env, clazz_prim)
        c.funcs = funcs
        cdef jvalue val
        val.l = clazz
        c.identity = env[0].CallStaticIntMethodA(env, SystemDef.clazz, SystemDef.identityHashCode, &val)
        c.name = name
        c.simple_name = name
        c.type = CT_PRIMITIVE
        #c.mode = 0
        #c.is_synthetic = False
        c.package_name = None
        c.enclosing_class = None
        c.declaring_class = None
        c.modifiers = <Modifiers>(PUBLIC|FINAL|ABSTRACT)
        c.component_type = None
        c.superclass = None
        c.interfaces = []
        c.classes = dict()
        c.static_classes = dict()
        c.constructors = []
        c.methods = dict()
        c.static_methods = dict()
        c.fields = dict()
        c.static_fields = dict()
        DeleteLocalRef(env, clazz)
        DeleteLocalRef(env, clazz_prim)
        return c

    def __dealloc__(self): self.destroy()
    def __hash__(self): return self.identity
    def __repr__(self): return u'<jclass instance at %08x>'%self.identity

    # Comparisons for looking at the class heirarchy
    # if a < b then a is a subclass of b   (including interfaces)
    # if a > b then a is a superclass of b (including interfaces)
    # if a and b don't share any common classes, then all operations will return False
    def __richcmp__(JClass self, JClass c, int op):
        cdef JEnv env = jenv()
        cdef bint diff = False
        if op == 0 or 2 <= op <= 4:
            diff = not env.IsSameObject(self.clazz, c.clazz)
        if op == 0: return diff and env.IsAssignableFrom(self.clazz, c.clazz) # <
        if op == 1: return          env.IsAssignableFrom(self.clazz, c.clazz) # <=
        if op == 2: return not diff # ==
        if op == 3: return diff     # !=
        if op == 4: return diff and env.IsAssignableFrom(c.clazz, self.clazz) # >
        if op == 5: return          env.IsAssignableFrom(c.clazz, self.clazz) # >=
        raise ValueError()

cdef class JMethod(object):
    """Wrapper around a jmethodID along with several properties of the method/constructor"""
    @staticmethod
    cdef JMethod create(JEnv env, jobject method):
        """Creates a JMethod for the reflected Method object given. The ref is deleted."""
        cdef JMethod m = JMethod()
        try:
            m.id = env.FromReflectedMethod(method)
            m.name = env.CallString(method, MethodDef.getName)
            m.modifiers = <Modifiers>env.CallInt(method, MethodDef.getModifiers)
            m.is_var_args = env.CallBoolean(method, MethodDef.isVarArgs)
            #m.is_synthetic = env.CallBoolean(method, MethodDef.isSynthetic)
            #m.is_bridge = env.CallBoolean(method, MethodDef.isBridge)
            m.declaring_class = env.CallClass(method, MethodDef.getDeclaringClass)
            m.return_type = env.CallClass(method, MethodDef.getReturnType)
            m.param_types = call2list(env, method, MethodDef.getParameterTypes, <obj2py>JClass.get)
            m.exc_types = call2list(env, method, MethodDef.getExceptionTypes, <obj2py>JClass.get)
        finally: env.DeleteRef(method)
        return m
    @staticmethod
    cdef JMethod create_ctor(JEnv env, jobject ctor):
        """Creates a JMethod for the reflected Constructor object given. The ref is deleted."""
        cdef JMethod c = JMethod()
        try:
            c.id = env.FromReflectedMethod(ctor)
            c.name = env.CallString(ctor, ConstructorDef.getName)
            c.modifiers = <Modifiers>env.CallInt(ctor, ConstructorDef.getModifiers)
            c.is_var_args = env.CallBoolean(ctor, ConstructorDef.isVarArgs)
            #c.is_synthetic = env.CallBoolean(ctor, ConstructorDef.isSynthetic)
            c.declaring_class = env.CallClass(ctor, ConstructorDef.getDeclaringClass)
            c.return_type = None
            c.param_types = call2list(env, ctor, ConstructorDef.getParameterTypes, <obj2py>JClass.get)
            c.exc_types = call2list(env, ctor, ConstructorDef.getExceptionTypes, <obj2py>JClass.get)
        finally: env.DeleteRef(ctor)
        return c
    @staticmethod
    cdef dict group(list methods):
        """Groups a list of methods by name, returning a dict of attr_name -> list of JMethod"""
        cdef dict out = dict()
        cdef list grp
        cdef JMethod m
        for m in methods:
            grp = out.setdefault(m.attr_name(), [])
            grp.append(m)
        return out
    def __repr__(self): return u'<jmethodID instance at %s>'%str_ptr(self.id)
    def __dealloc__(self): self.id = NULL; self.return_type = None; self.param_types = None

cdef class JField(object):
    """Wrapper around a jfieldID pointer along with several properties of the field"""
    @staticmethod
    cdef JField create(JEnv env, jobject field):
        """Creates a JField for the reflected Field object given. The ref is deleted."""
        cdef JField f = JField()
        try:
            f.id = env.FromReflectedField(field)
            f.name = env.CallString(field, FieldDef.getName)
            f.modifiers = <Modifiers>env.CallInt(field, FieldDef.getModifiers)
            #f.is_synthetic = env.CallBoolean(field, FieldDef.isSynthetic)
            f.declaring_class = env.CallClass(field, FieldDef.getDeclaringClass)
            f.type = env.CallClass(field, FieldDef.getType)
        finally: env.DeleteRef(field)
        return f
    def __repr__(self): return u'<jfieldID instance at %s>'%str_ptr(self.id)
    def __dealloc__(self): self.id = NULL; self.type = None

cdef class JObject(object):
    def destroy(self):
        if self.obj is not NULL:
            delete_global_ref(self.obj)
            self.obj = NULL
    def __destroy_local(self):
        if self.obj is not NULL:
            # local refs should only be used and destroyed on a single thread so there is no need
            # to do the special handling like was done for global refs
            jenv().DeleteLocalRef(self.obj)
            self.obj = NULL
    def __dealloc__(self): self.destroy()
    def __hash__(self): self.identity()
    def __repr__(self): return u'<jobject instance at %08x>'%self.identity()

cdef int init_jclasses(JEnv env) except -1:
    global jclasses; jclasses = {
        u'void'   : JClass.__create_primitive(env.env, u'java/lang/Void',      u'void',    &jcf_void),
        u'boolean': JClass.__create_primitive(env.env, u'java/lang/Boolean',   u'boolean', &jcf_boolean),
        u'byte'   : JClass.__create_primitive(env.env, u'java/lang/Byte',      u'byte',    &jcf_byte),
        u'char'   : JClass.__create_primitive(env.env, u'java/lang/Character', u'char',    &jcf_char),
        u'short'  : JClass.__create_primitive(env.env, u'java/lang/Short',     u'short',   &jcf_short),
        u'int'    : JClass.__create_primitive(env.env, u'java/lang/Integer',   u'int',     &jcf_int),
        u'long'   : JClass.__create_primitive(env.env, u'java/lang/Long',      u'long',    &jcf_long),
        u'float'  : JClass.__create_primitive(env.env, u'java/lang/Float',     u'float',   &jcf_float),
        u'double' : JClass.__create_primitive(env.env, u'java/lang/Double',    u'double',  &jcf_double),
    }
    return 0
cdef int dealloc_jclasses(JEnv env) except -1:
    global jclasses
    # JClasses can easily have cyclic references, so we clean them up here
    cdef JClass c
    for c in VALUES(jclasses): c.destroy()
    c = None
    jclasses = None
    return 0
jvm_add_init_hook(init_jclasses, -8)
jvm_add_dealloc_hook(dealloc_jclasses, -8)


########## Type Boxing Support ##########
cdef jobject Boolean_TRUE, Boolean_FALSE
cdef jclass box_classes[8]
cdef jmethodID box_ctors[8]
cdef int init_boxes(JEnv env) except -1:
    global Boolean_TRUE, Boolean_FALSE
    cdef jclass C
    cdef jobject T, F
    cdef Py_ssize_t i
    cdef const char** class_names = [b'java/lang/Boolean', b'java/lang/Byte', b'java/lang/Character',
        b'java/lang/Short', b'java/lang/Integer', b'java/lang/Long', b'java/lang/Float', b'java/lang/Double']
    cdef const char** ctor_sigs = [b'(Z)V', b'(B)V', b'(C)V', b'(S)V', b'(I)V', b'(J)V', b'(F)V', b'(D)V']
    with nogil:
        C = FindClass(env.env, b'java/lang/Boolean')
        T = GetStaticObjectField(env.env, C, GetStaticFieldID(env.env, C, b'TRUE',  b'Ljava/lang/Boolean;'))
        F = GetStaticObjectField(env.env, C, GetStaticFieldID(env.env, C, b'FALSE', b'Ljava/lang/Boolean;'))
        Boolean_TRUE  = NewGlobalRef(env.env, T)
        Boolean_FALSE = NewGlobalRef(env.env, F)
        DeleteLocalRef(env.env, T)
        DeleteLocalRef(env.env, F)
        DeleteLocalRef(env.env, C)
        for i in xrange(8):
            C = FindClass(env.env, class_names[i])
            box_classes[i] = <jclass>NewGlobalRef(env.env, C)
            box_ctors[i]   = GetMethodID(env.env, C, b'<init>', ctor_sigs[i])
            DeleteLocalRef(env.env, C)
    return 0
cdef int dealloc_boxes(JEnv env) except -1:
    global Boolean_TRUE, Boolean_FALSE
    cdef Py_ssize_t i
    with nogil:
        if Boolean_TRUE  is not NULL: DeleteGlobalRef(env.env, Boolean_TRUE)
        Boolean_TRUE  = NULL
        if Boolean_FALSE is not NULL: DeleteGlobalRef(env.env, Boolean_FALSE)
        Boolean_FALSE = NULL
        for i in xrange(8):
            if box_classes[i] is not NULL: DeleteGlobalRef(env.env, box_classes[i])
            box_classes[i] = NULL
            box_ctors[i]   = NULL
    return 0
jvm_add_init_hook(init_boxes, -7)
jvm_add_dealloc_hook(dealloc_boxes, -7)
