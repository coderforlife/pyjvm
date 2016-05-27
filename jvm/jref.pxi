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
    
Internal functions:
    box_<primitive>   - box a primitive value, one function for each primitive type
    protection_prefix - get the Python prefix (e.g. '__') for an access modifier

TODO:
    should all JObjects be dealloced when JVM deallocs?

FUTURE:
    handle generics and annotations
"""


########## Java Class/Constructor/Method/Field Modifiers ##########
cdef enum Modifiers:        # allowed on Interface, Class, Constructor, Method, Field?
    # package-private = absence of PUBLIC | PRIVATE | PROTECTED
    PUBLIC       = 0x001    # ICCMF
    PRIVATE      = 0x002    # ICCMF
    PROTECTED    = 0x004    # ICCMF
    STATIC       = 0x008    # IC MF
    FINAL        = 0x010    #  C MF  (ignored for classes and methods)
    SYNCHRONIZED = 0x020    #    M   (ignored)
    VOLATILE     = 0x040    #     F  (ignored)
    TRANSIENT    = 0x080    #     F  (ignored)
    NATIVE       = 0x100    #    M   (ignored)
    INTERFACE    = 0x200
    ABSTRACT     = 0x400    # IC M   (ignored)
    STRICT       = 0x800    # IC M   (ignored)
    # Undocumented values:
    # BRIDGE     = 0x0040
    # VARARGS    = 0x0080
    # SYNTHETIC  = 0x1000
    # ANNOTATION = 0x2000
    # ENUM       = 0x4000
    # MANDATED   = 0x8000

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

########## Java Class Functions ##########
# Each instance of this class represents the collections of functions that are specific to a single
# type, so all the ones that have <type> in them. Additionally, the size of primitive types, the
# signature, and the struct module format specifier for the type.
ctypedef object (*GetField)(JEnv env, jobject obj, jfieldID fieldID)
ctypedef int (*SetField)(JEnv env, jobject obj, JField field, object value) except -1
ctypedef object (*GetStaticField)(JEnv env, jclass clazz, jfieldID fieldID)
ctypedef int (*SetStaticField)(JEnv env, jclass clazz, JField field, object value) except -1
ctypedef object (*CallMethod)(JEnv env, jobject obj, jmethodID methodID, const jvalue *args, bint withgil)
ctypedef object (*CallNVMethod)(JEnv env, jobject obj, jclass clazz, jmethodID methodID, const jvalue *args, bint withgil)
ctypedef object (*CallStaticMethod)(JEnv env, jclass clazz, jmethodID methodID, const jvalue *args, bint withgil)
ctypedef jarray (*NewPrimArray)(JEnv env, jsize length) except NULL
cdef struct JClassFuncs:
    char sig
    Py_ssize_t itemsize
    CallMethod call
    CallNVMethod call_nv
    CallStaticMethod call_static
    GetField get
    SetField set
    GetStaticField get_static
    SetStaticField set_static
    NewPrimArray new_array
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
JVM.add_init_hook(init_jcf)


########## Basic Classes and Methods ##########
# These are the classes and methods that are internally used. They are cached in these structures
# upon first use. Mostly these are for reflection or common classes and methods.
cdef struct JObjectDef:
    jclass clazz
    jmethodID equals, toString, clone, hashCode
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

cdef struct JSystemDef:
    jclass clazz
    jmethodID arraycopy, getProperty, gc, identityHashCode # static
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

cdef struct JClassLoaderDef:
    jclass clazz
    jmethodID getParent
    jmethodID getSystemClassLoader # static
cdef struct JURLClassLoaderDef:
    jclass clazz
    jmethodID addURL, getURLs
cdef void init_ClassLoaderDef(JNIEnv* env) nogil:
    cdef jclass C = FindClass(env, b'java/lang/ClassLoader')
    ClassLoaderDef.clazz     = <jclass>NewGlobalRef(env, C)
    ClassLoaderDef.getParent = GetMethodID(env, C, b'getParent', b'()Ljava/lang/ClassLoader;')
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
    ClassLoaderDef.getSystemClassLoader = NULL
    if URLClassLoaderDef.clazz is not NULL: DeleteGlobalRef(env, URLClassLoaderDef.clazz)
    URLClassLoaderDef.clazz   = NULL
    URLClassLoaderDef.addURL  = NULL
    URLClassLoaderDef.getURLs = NULL

cdef struct JFileDef:
    jclass clazz
    jmethodID ctor, toURI
cdef struct JURIDef:
    jclass clazz
    jmethodID toURL
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
    
cdef struct JPackageDef:
    jclass clazz
    jmethodID getName
    jmethodID getPackage # static
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

cdef struct JClassDef:
    jclass clazz
    jmethodID getName, getSimpleName, getPackage, getEnclosingClass, getDeclaringClass, getModifiers
    jmethodID getDeclaredFields, getDeclaredMethods, getDeclaredConstructors, getDeclaredClasses
    jmethodID getInterfaces, isInterface, isEnum, isArray, getComponentType
    jmethodID isAnonymousClass, isLocalClass, isMemberClass #, isSynthetic
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
    ClassDef.isEnum             = NULL
    ClassDef.isArray            = NULL
    ClassDef.getComponentType   = NULL
    ClassDef.isAnonymousClass   = NULL
    ClassDef.isLocalClass       = NULL
    ClassDef.isMemberClass      = NULL
    #ClassDef.isSynthetic        = NULL

cdef struct JFieldDef:
    jclass clazz
    jmethodID getName, getType, getModifiers #, isSynthetic
cdef void init_FieldDef(JNIEnv* env) nogil:
    cdef jclass C = FindClass(env, b'java/lang/reflect/Field')
    FieldDef.clazz = <jclass>NewGlobalRef(env, C)
    FieldDef.getName      = GetMethodID(env, C, b'getName',      b'()Ljava/lang/String;')
    FieldDef.getType      = GetMethodID(env, C, b'getType',      b'()Ljava/lang/Class;')
    FieldDef.getModifiers = GetMethodID(env, C, b'getModifiers', b'()I')
    #FieldDef.isSynthetic  = GetMethodID(env, C, b'isSynthetic',  b'()Z')
    # Parent: getDeclaringClass()
    # Generics: getGenericType()
    # Annotations: getDeclaredAnnotations()
    # Other: isEnumConstant()
    DeleteLocalRef(env, C)
cdef void dealloc_FieldDef(JNIEnv* env) nogil:
    if FieldDef.clazz is not NULL: DeleteGlobalRef(env, FieldDef.clazz)
    FieldDef.clazz        = NULL
    FieldDef.getName      = NULL
    FieldDef.getType      = NULL
    FieldDef.getModifiers = NULL
    #FieldDef.isSynthetic  = NULL

cdef struct JMethodDef:
    jclass clazz
    jmethodID getName, getReturnType, getParameterTypes, getModifiers, isVarArgs #, isBridge, isSynthetic
cdef void init_MethodDef(JNIEnv* env) nogil:
    cdef jclass C = FindClass(env, b'java/lang/reflect/Method')
    MethodDef.clazz = <jclass>NewGlobalRef(env, C)
    MethodDef.getName           = GetMethodID(env, C, b'getName',           b'()Ljava/lang/String;')
    MethodDef.getReturnType     = GetMethodID(env, C, b'getReturnType',     b'()Ljava/lang/Class;')
    MethodDef.getParameterTypes = GetMethodID(env, C, b'getParameterTypes', b'()[Ljava/lang/Class;')
    MethodDef.getModifiers      = GetMethodID(env, C, b'getModifiers',      b'()I')
    MethodDef.isVarArgs         = GetMethodID(env, C, b'isVarArgs',         b'()Z')
    #MethodDef.isBridge          = GetMethodID(env, C, b'isBridge',          b'()Z')
    #MethodDef.isSynthetic       = GetMethodID(env, C, b'isSynthetic',       b'()Z')
    # Parent: getDeclaringClass()
    # Generics: getGenericParameterTypes(), getGenericReturnType(), getTypeParameters()
    # Annotations: getDeclaredAnnotations(), getParameterAnnotations(), getDefaultValue()
    # Exceptions: getExceptionTypes(), getGenericExceptionTypes()
    DeleteLocalRef(env, C)
cdef void dealloc_MethodDef(JNIEnv* env) nogil:
    if MethodDef.clazz is not NULL: DeleteGlobalRef(env, MethodDef.clazz)
    MethodDef.clazz             = NULL
    MethodDef.getName           = NULL
    MethodDef.getReturnType     = NULL
    MethodDef.getParameterTypes = NULL
    MethodDef.getModifiers      = NULL
    MethodDef.isVarArgs         = NULL
    #MethodDef.isBridge          = NULL
    #MethodDef.isSynthetic       = NULL

cdef struct JConstructorDef:
    jclass clazz
    jmethodID getName, getParameterTypes, getModifiers, isVarArgs #, isSynthetic
cdef void init_ConstructorDef(JNIEnv* env) nogil:
    cdef jclass C = FindClass(env, b'java/lang/reflect/Constructor')
    ConstructorDef.clazz = <jclass>NewGlobalRef(env, C)
    ConstructorDef.getName           = GetMethodID(env, C, b'getName',           b'()Ljava/lang/String;')
    ConstructorDef.getParameterTypes = GetMethodID(env, C, b'getParameterTypes', b'()[Ljava/lang/Class;')
    ConstructorDef.getModifiers      = GetMethodID(env, C, b'getModifiers',      b'()I')
    ConstructorDef.isVarArgs         = GetMethodID(env, C, b'isVarArgs',         b'()Z')
    #ConstructorDef.isSynthetic       = GetMethodID(env, C, b'isSynthetic',       b'()Z')
    # Parent: getDeclaringClass()
    # Generics: getGenericParameterTypes(), getTypeParameters()
    # Annotations: getDeclaredAnnotations(), getParameterAnnotations()
    # Exceptions: getExceptionTypes(), getGenericExceptionTypes()
    DeleteLocalRef(env, C)
cdef void dealloc_ConstructorDef(JNIEnv* env) nogil:
    if ConstructorDef.clazz is not NULL: DeleteGlobalRef(env, ConstructorDef.clazz)
    ConstructorDef.clazz             = NULL
    ConstructorDef.getName           = NULL
    ConstructorDef.getParameterTypes = NULL
    ConstructorDef.getModifiers      = NULL
    ConstructorDef.isVarArgs         = NULL
    #ConstructorDef.isSynthetic       = NULL

cdef struct JRunnableDef:
    jclass clazz
    jmethodID run
cdef void init_RunnableDef(JNIEnv* env) nogil:
    cdef jclass C = FindClass(env, b'java/lang/Runnable')
    RunnableDef.clazz = <jclass>NewGlobalRef(env, C)
    RunnableDef.run   = GetMethodID(env, C, b'run', b'()V')
    DeleteLocalRef(env, C)
cdef void dealloc_RunnableDef(JNIEnv* env) nogil:
    if RunnableDef.clazz is not NULL: DeleteGlobalRef(env, RunnableDef.clazz)
    RunnableDef.clazz = NULL
    RunnableDef.run   = NULL

cdef struct JThreadDef:
    jclass clazz
    jmethodID currentThread # static
    jmethodID getContextClassLoader, setContextClassLoader
cdef void init_ThreadDef(JNIEnv* env) nogil:
    cdef jclass C = FindClass(env, b'java/lang/Thread')
    ThreadDef.clazz = <jclass>NewGlobalRef(env, C)
    ThreadDef.currentThread = GetStaticMethodID(env, C, b'currentThread', b'()Ljava/lang/Thread;')
    ThreadDef.getContextClassLoader = GetMethodID(env, C, b'getContextClassLoader', b'()Ljava/lang/ClassLoader;')
    ThreadDef.setContextClassLoader = GetMethodID(env, C, b'setContextClassLoader', b'(Ljava/lang/ClassLoader;)V')
    DeleteLocalRef(env, C)
cdef void dealloc_ThreadDef(JNIEnv* env) nogil:
    if ThreadDef.clazz is not NULL: DeleteGlobalRef(env, ThreadDef.clazz)
    ThreadDef.clazz                 = NULL
    ThreadDef.currentThread         = NULL
    ThreadDef.getContextClassLoader = NULL
    ThreadDef.setContextClassLoader = NULL

cdef JObjectDef      ObjectDef
cdef JSystemDef      SystemDef
cdef JClassLoaderDef ClassLoaderDef
cdef JURLClassLoaderDef URLClassLoaderDef
cdef JFileDef        FileDef
cdef JURIDef         URIDef
cdef JPackageDef     PackageDef
cdef JClassDef       ClassDef
cdef JFieldDef       FieldDef
cdef JMethodDef      MethodDef
cdef JConstructorDef ConstructorDef
cdef JRunnableDef    RunnableDef
cdef JThreadDef      ThreadDef
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
    return 0
JVM.add_early_init_hook(init_def)
JVM.add_dealloc_hook(dealloc_def)


########## Basic actions that can be queued in the JVM thread ##########
# Currently only the DeleteGlobalRefAction is used, the other are just here because they might be
# useful eventually.
cdef class DeleteGlobalRefAction(JVMAction):
    """Calls DeleteGlobalRef on the object"""
    cdef jobject obj
    @staticmethod
    cdef DeleteGlobalRefAction create(jobject obj):
        cdef DeleteGlobalRefAction action = DeleteGlobalRefAction()
        action.obj = obj
        return action
    cpdef int run(self, JEnv env) except -1:
        assert self.obj is not NULL
        DeleteGlobalRef(env.env, self.obj)
cdef class RunnableAction(JVMAction):
    """Calls obj.run() with or without the GIL"""
    cdef jobject obj
    cdef bint withgil
    @staticmethod
    cdef RunnableAction create(jobject obj, bint withgil=False):
        cdef RunnableAction action = RunnableAction()
        action.obj = obj
        action.withgil = withgil
        return action
    cpdef int run(self, JEnv env) except -1:
        assert self.obj is not NULL
        env.CallVoidMethod(self.obj, RunnableDef.run, NULL, False)
cdef class GCAction(JVMAction):
    """Calls java.lang.System.gc()"""
    @staticmethod
    cdef GCAction create(): return GCAction()
    cpdef int run(self, JEnv env) except -1:
        env.CallStaticVoidMethod(SystemDef.clazz, SystemDef.gc, NULL, False)
        import gc
        gc.collect()


########## Reference Wrappers ##########
# Basic wrapper classes for jclass, jmethodID, jfieldID, and jobject
cdef dict jclasses = None # dictionary of class name -> JClass

cdef enum ClassType:
    CT_INTERFACE  = 1,
    CT_PRIMITIVE  = 2,
    CT_ARRAY      = 3,
    CT_ENUM       = 4,
    #CT_ANNOTATION = 5,
    
cdef enum ClassMode:
    CM_ANONYMOUS  = 1, # an anonymous class is a local class without a name
    CM_LOCAL      = 2, # a class within a method/constructor
    CM_MEMBER     = 3, # a class within a class, may be an inner class or a static nested class
    
cdef inline unicode protection_prefix(Modifiers mod):
    """
    Gets one of (empty string), _, or __ if the modifiers indicate public, protected, or
    (package-)private.
    """
    if   mod & PUBLIC:    return ''
    elif mod & PROTECTED: return '_'
    else:                 return '__' # private OR package-private
    
cdef class JClass(object):
    """Wrapper around a jclass pointer along with several properties of the class"""
    cdef JClassFuncs* funcs
    cdef jclass clazz
    cdef int identity # from System.identityHashCode
    cdef readonly unicode name
    cdef unicode simple_name
    cdef ClassType type
    cdef ClassMode mode
    #cdef bint is_synthetic
    cdef unicode package_name
    cdef JClass enclosing_class
    cdef JClass declaring_class # null for anonymous and local classes, enclosing class always works
    cdef Modifiers modifiers # mask = PUBLIC | PRIVATE | PROTECTED | STATIC | ABSTRACT | STRICT (for interfaces)
        # mask |= FINAL (for classes)
    cdef JClass component_type # None for all classes except arrays
    cdef JClass superclass   # None for base interfaces, primitive, and the Object type
    cdef list interfaces     # list of JClass
    cdef dict classes        # dict of attribute name -> JClass
    cdef dict static_classes # dict of attribute name -> JClass
    cdef list constructors   # list of JConstructor
    cdef dict methods        # dict of attribute name -> list of JMethod
    cdef dict static_methods # dict of attribute name -> list of JMethod
    cdef dict fields         # dict of attribute name -> JField
    cdef dict static_fields  # dict of attribute name -> JField

    cdef inline unicode attr_name(self): return protection_prefix(self.modifiers) + self.simple_name
    cdef inline unicode sig(self):
        if self.is_primitive(): return unichr(self.funcs.sig)
        return self.name if self.is_array() else ('L%s;' % self.name)
    cdef inline bint is_interface(self):    return self.type == CT_INTERFACE
    cdef inline bint is_primitive(self):    return self.type == CT_PRIMITIVE
    cdef inline bint is_array(self):        return self.type == CT_ARRAY
    cdef inline bint is_enum(self):         return self.type == CT_ENUM
    cdef inline bint is_anonymous(self):    return self.mode == CM_ANONYMOUS
    cdef inline bint is_local(self):        return self.mode == CM_LOCAL
    cdef inline bint is_member(self):       return self.mode == CM_MEMBER # either a static nested or inner class
    cdef inline bint is_nested(self):       return self.mode != 0
    cdef inline Modifiers get_access(self): return <Modifiers>(self.modifiers&(PUBLIC|PRIVATE|PROTECTED))
    cdef inline bint is_static(self):       return (self.modifiers & STATIC)   == STATIC
    cdef inline bint is_final(self):        return (self.modifiers & FINAL)    == FINAL
    cdef inline bint is_abstract(self):     return (self.modifiers & ABSTRACT) == ABSTRACT
    cdef inline bint is_strict(self):       return (self.modifiers & STRICT)   == STRICT

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
        if   env.CallBoolean(clazz, ClassDef.isArray):     c.type = CT_ARRAY
        elif env.CallBoolean(clazz, ClassDef.isInterface): c.type = CT_INTERFACE
        elif env.CallBoolean(clazz, ClassDef.isEnum):      c.type = CT_ENUM
        #elif env.CallBoolean(clazz, ClassDef.isPrimitive): c.type = CT_PRIMITIVE
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
            c.interfaces = env.CallClasses(clazz, ClassDef.getInterfaces)
            classes = env.CallClasses(clazz, ClassDef.getDeclaredClasses)
            classes = [dc for dc in classes if dc.mode != CM_ANONYMOUS and dc.mode != CM_LOCAL]
            c.classes        = {dc.attr_name():dc for dc in classes if not dc.is_static()}
            c.static_classes = {dc.attr_name():dc for dc in classes if     dc.is_static()}
            ctors = env.CallObjects(clazz, ClassDef.getDeclaredConstructors, <obj2py>JMethod.create_ctor)
            c.constructors = ctors
            methods = env.CallObjects(clazz, ClassDef.getDeclaredMethods, <obj2py>JMethod.create)
            c.methods        = JMethod.group([m for m in methods if not m.is_static()])
            c.static_methods = JMethod.group([m for m in methods if     m.is_static()])
            fields = env.CallObjects(clazz, ClassDef.getDeclaredFields, <obj2py>JField.create)
            c.fields         = {f.attr_name():f for f in fields if not f.is_static()}
            c.static_fields  = {f.attr_name():f for f in fields if     f.is_static()}
        except:
            del jclasses[c.name]
            raise
        return c

    @staticmethod
    cdef inline JClass create_primitive(JNIEnv* env, unicode cn, unicode name, JClassFuncs* funcs):
        """Creates a JClass object for a primitive type given its clazz, name, and functions."""
        # Should not raise errors here, so access functions directly instead of with JEnv wrappers
        cdef jclass clazz = FindClass(env, cn), clazz_prim
        cdef JClass c = JClass()
        cdef jfieldID fid = GetStaticFieldID(env, clazz, b'TYPE', b'Ljava/lang/Class;')
        clazz_prim = <jclass>GetStaticObjectField(env, clazz, fid)
        c.clazz = <jclass>NewGlobalRef(env, clazz_prim)
        c.funcs = funcs
        cdef jvalue val
        val.l = clazz
        c.identity = env[0].CallStaticIntMethodA(env, SystemDef.clazz, SystemDef.identityHashCode, &val)
        c.name = name
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

    cdef inline int destroy(self) except -1:
        # Make sure to remove cyclic references
        self.enclosing_class = None
        self.declaring_class = None
        self.component_type = None
        self.superclass = None
        self.interfaces = None
        self.classes = None
        self.static_classes = None
        self.constructors = None
        self.methods = None
        self.static_methods = None
        self.fields = None
        self.static_fields = None
        
        cdef JVM j
        if self.clazz is not NULL:
            j = jvm()
            if j is not None:
                if j.is_attached(): DeleteGlobalRef(j.env().env, self.clazz)
                else: j.run_action(DeleteGlobalRefAction.create(self.clazz))
            self.clazz = NULL
        return 0
    def __dealloc__(self): self.destroy()
    def __hash__(self): return self.identity

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
    # These functions do the same as <= and == but are a bit more efficient since
    # they take the JEnv and can be inlined.
    cdef inline is_sub(self, JEnv env, JClass b): return env.IsAssignableFrom(self.clazz, b.clazz)
    cdef inline is_same(self, JEnv env, JClass b): return env.IsSameObject(self.clazz, b.clazz)

    def __repr__(self): return '<jclass instance at %08x>'%self.identity

cdef class JMethod(object):
    """Wrapper around a jmethodID along with several properties of the method/constructor"""
    cdef jmethodID id
    cdef readonly unicode name
    cdef Modifiers modifiers # mask = PUBLIC | PRIVATE | PROTECTED (for constructors)
        # mask |= STATIC | FINAL | SYNCHRONIZED | NATIVE | ABSTRACT | STRICT (for methods)
    cdef JClass return_type # None if it is a constructor
    cdef list param_types # list of JClass
    cdef bint is_var_args #, is_synthetic, is_bridge
    cdef inline unicode attr_name(self): return protection_prefix(self.modifiers) + self.name
    cdef inline unicode param_sig(self): return ''.join((<JClass>t).sig() for t in self.param_types)
    cdef inline unicode return_sig(self): return 'V' if self.return_type is None else self.return_type.sig()
    cdef inline unicode sig(self): return '(%s)%s' % (self.param_sig(), self.return_sig())
    cdef inline Modifiers get_access(self): return <Modifiers>(self.modifiers&(PUBLIC|PRIVATE|PROTECTED))
    cdef inline bint is_static(self):       return self.modifiers & STATIC
    cdef inline bint is_final(self):        return self.modifiers & FINAL
    cdef inline bint is_synchronized(self): return self.modifiers & SYNCHRONIZED
    cdef inline bint is_native(self):       return self.modifiers & NATIVE
    cdef inline bint is_abstract(self):     return self.modifiers & ABSTRACT
    cdef inline bint is_strict(self):       return self.modifiers & STRICT

    @staticmethod
    cdef JMethod create(JEnv env, jobject method):
        """Creates a JMethod for the reflected Method object given. The ref is deleted."""
        cdef JMethod m = JMethod()
        cdef jobject return_type
        cdef jobjectArray param_types
        try:
            m.id = env.FromReflectedMethod(method)
            m.name = env.CallString(method, MethodDef.getName)
            m.modifiers = <Modifiers>env.CallInt(method, MethodDef.getModifiers)
            m.is_var_args = env.CallBoolean(method, MethodDef.isVarArgs)
            #m.is_synthetic = env.CallBoolean(method, MethodDef.isSynthetic)
            #m.is_bridge = env.CallBoolean(method, MethodDef.isBridge)
            return_type = env.CallObject(method, MethodDef.getReturnType)
            param_types = env.CallObject(method, MethodDef.getParameterTypes)
        finally: env.DeleteRef(method)
        m.return_type = JClass.get(env, return_type)
        m.param_types = env.objs2list(param_types, <obj2py>JClass.get)
        return m
    @staticmethod
    cdef JMethod create_ctor(JEnv env, jobject ctor):
        """Creates a JMethod for the reflected Constructor object given. The ref is deleted."""
        cdef JMethod c = JMethod()
        cdef jobjectArray param_types
        try:
            c.id = env.FromReflectedMethod(ctor)
            c.name = env.CallString(ctor, ConstructorDef.getName)
            c.modifiers = <Modifiers>env.CallInt(ctor, ConstructorDef.getModifiers)
            c.is_var_args = env.CallBoolean(ctor, ConstructorDef.isVarArgs)
            #c.is_synthetic = env.CallBoolean(ctor, ConstructorDef.isSynthetic)
            param_types = env.CallObject(ctor, ConstructorDef.getParameterTypes)
        finally: env.DeleteRef(ctor)
        c.return_type = None
        c.param_types = env.objs2list(param_types, <obj2py>JClass.get)
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
    def __repr__(self): return '<jmethodID instance at %s>'%str_ptr(self.id)
    def __dealloc__(self): self.id = NULL; self.return_type = None; self.param_types = None

cdef class JField(object):
    """Wrapper around a jfieldID pointer along with several properties of the field"""
    cdef jfieldID id
    cdef readonly unicode name
    cdef Modifiers modifiers # mask = PUBLIC | PRIVATE | PROTECTED | STATIC | FINAL | VOLATILE | TRANSIENT
    #cdef bint is_synthetic
    cdef JClass type
    cdef inline unicode attr_name(self): return protection_prefix(self.modifiers) + self.name
    cdef inline Modifiers get_access(self): return <Modifiers>(self.modifiers&(PUBLIC|PRIVATE|PROTECTED))
    cdef inline bint is_static(self):       return self.modifiers & STATIC
    cdef inline bint is_final(self):        return self.modifiers & FINAL
    cdef inline bint is_volatile(self):     return self.modifiers & VOLATILE
    cdef inline bint is_transient(self):    return self.modifiers & TRANSIENT

    @staticmethod
    cdef JField create(JEnv env, jobject field):
        """Creates a JField for the reflected Field object given. The ref is deleted."""
        cdef JField f = JField()
        cdef jobject type
        try:
            f.id = env.FromReflectedField(field)
            f.name = env.CallString(field, FieldDef.getName)
            f.modifiers = <Modifiers>env.CallInt(field, FieldDef.getModifiers)
            #f.is_synthetic = env.CallBoolean(field, FieldDef.isSynthetic)
            type = env.CallObject(field, FieldDef.getType)
        finally: env.DeleteRef(field)
        f.type = JClass.get(env, type)
        return f
    def __repr__(self): return '<jfieldID instance at %s>'%str_ptr(self.id)
    def __dealloc__(self): self.id = NULL; self.type = None

cdef class JObject(object):
    cdef jobject obj
    @staticmethod
    cdef JObject create(JEnv env, jobject obj):
        cdef JObject o = JObject()
        o.obj = env.NewGlobalRef(obj)
        env.DeleteRef(obj)
        return o
    @staticmethod
    cdef JObject wrap(JEnv env, jobject obj):
        cdef JObject o = JObject()
        o.obj = obj
        return o
    cdef inline int destroy(self) except -1:
        cdef JVM j
        if self.obj is not NULL:
            j = jvm()
            if j is not None:
                # TODO: make sure this JVM is the same JVM that created the jobject
                if j.is_attached(): DeleteGlobalRef(j.env().env, self.obj)
                else: j.run_action(DeleteGlobalRefAction.create(self.obj))
            self.obj = NULL
        return 0
    def __dealloc__(self): self.destroy()
    cdef inline jint identity(self) except? -1:
        cdef jvalue val
        val.l = self.obj
        return jenv().CallStaticInt(SystemDef.clazz, SystemDef.identityHashCode, &val)
    def __hash__(self): self.identity()
    def __repr__(self): return '<jobject instance at %08x>'%self.identity()

cdef int init_jclasses(JEnv env) except -1:
    global jclasses; jclasses = {
        'void'   : JClass.create_primitive(env.env, 'java/lang/Void',      'void',    &jcf_void),
        'boolean': JClass.create_primitive(env.env, 'java/lang/Boolean',   'boolean', &jcf_boolean),
        'byte'   : JClass.create_primitive(env.env, 'java/lang/Byte',      'byte',    &jcf_byte),
        'char'   : JClass.create_primitive(env.env, 'java/lang/Character', 'char',    &jcf_char),
        'short'  : JClass.create_primitive(env.env, 'java/lang/Short',     'short',   &jcf_short),
        'int'    : JClass.create_primitive(env.env, 'java/lang/Integer',   'int',     &jcf_int),
        'long'   : JClass.create_primitive(env.env, 'java/lang/Long',      'long',    &jcf_long),
        'float'  : JClass.create_primitive(env.env, 'java/lang/Float',     'float',   &jcf_float),
        'double' : JClass.create_primitive(env.env, 'java/lang/Double',    'double',  &jcf_double),
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
JVM.add_early_init_hook(init_jclasses)
JVM.add_dealloc_hook(dealloc_jclasses)


########## Type Boxing Support ##########
cdef jobject Boolean_TRUE, Boolean_FALSE
cdef jclass box_classes[8]
cdef jmethodID box_ctors[8]

#cdef inline jobject box_boolean(JEnv env, jboolean x) except NULL:
#    cdef jvalue val
#    val.z = x
#    return env.NewObject(box_classes[0], box_ctors[0], &val)
cdef inline jobject box_boolean(JEnv env, jboolean x) except NULL:
    return env.NewLocalRef(Boolean_TRUE if x == JNI_TRUE else Boolean_FALSE)
cdef inline jobject box_byte(JEnv env, jbyte x) except NULL:
    cdef jvalue val
    val.b = x
    return env.NewObject(box_classes[1], box_ctors[1], &val)
cdef inline jobject box_char(JEnv env, jchar x) except NULL:
    cdef jvalue val
    val.c = x
    return env.NewObject(box_classes[2], box_ctors[2], &val)
cdef inline jobject box_short(JEnv env, jshort x) except NULL:
    cdef jvalue val
    val.s = x
    return env.NewObject(box_classes[3], box_ctors[3], &val)
cdef inline jobject box_int(JEnv env, jint x) except NULL:
    cdef jvalue val
    val.i = x
    return env.NewObject(box_classes[5], box_ctors[5], &val)
cdef inline jobject box_long(JEnv env, jlong x) except NULL:
    cdef jvalue val
    val.j = x
    return env.NewObject(box_classes[5], box_ctors[5], &val)
cdef inline jobject box_float(JEnv env, jfloat x) except NULL:
    cdef jvalue val
    val.f = x
    return env.NewObject(box_classes[6], box_ctors[6], &val)
cdef inline jobject box_double(JEnv env, jdouble x) except NULL:
    cdef jvalue val
    val.d = x
    return env.NewObject(box_classes[7], box_ctors[7], &val)
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
JVM.add_early_init_hook(init_boxes)
JVM.add_dealloc_hook(dealloc_boxes)
