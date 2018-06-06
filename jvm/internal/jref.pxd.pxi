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

from .unicode cimport unichr
from .jni cimport JNIEnv, jclass, jobject, jmethodID, jfieldID, jarray, jvalue, jsize
from .jni cimport jboolean, JNI_TRUE, jbyte, jchar, jshort, jint, jlong, jfloat, jdouble
#from .jvm cimport JVM, jvm, JVMAction
#from .jenv cimport JEnv, jenv


########## Java Class/Constructor/Method/Field Modifiers ##########
cdef enum Modifiers:        # allowed on Interface, Class, Constructor, Method, Field?
    # package-private = absence of PUBLIC | PRIVATE | PROTECTED
    PUBLIC       = 0x0001   # ICCMF
    PRIVATE      = 0x0002   # ICCMF
    PROTECTED    = 0x0004   # ICCMF
    STATIC       = 0x0008   # IC MF
    FINAL        = 0x0010   #  C MF
    SYNCHRONIZED = 0x0020   #    M   (ignored)
    SUPER        = 0x0020	#  C     (ignored, undocumented in reflection)
    VOLATILE     = 0x0040   #     F  (ignored)
    BRIDGE       = 0x0040   #    M   (ignored, reflection uses a method)
    TRANSIENT    = 0x0080   #     F  (ignored)
    VARARGS      = 0x0080   #   CM   (ignored, reflection uses a method)
    NATIVE       = 0x0100   #    M   (ignored)
    INTERFACE    = 0x0200   # I
    ABSTRACT     = 0x0400   # IC M
    STRICT       = 0x0800   #   CM   (ignored)
    SYNTHETIC    = 0x1000   # ICCMF  (ignored, reflection uses a method)
    ANNOTATION   = 0x2000   # I      (ignored, reflection uses a method)
    ENUM         = 0x4000   #  C  F  (ignored, reflection uses a method)
    #MODULE = 0x8000 # (ignored, new in Java 9, gives a new introspection system)


########## Java Class Functions ##########
# Each instance of this class represents the collections of functions that are specific to a single
# type, so all the ones that have <type> in them. Additionally, the size of primitive types, the
# signature, and the struct module format specifier for the type.
ctypedef object (*GetField)(JEnv env, jobject obj, jfieldID fieldID)
ctypedef int    (*SetField)(JEnv env, jobject obj, JField field, object value) except -1
ctypedef object (*GetStaticField)(JEnv env, jclass clazz, jfieldID fieldID)
ctypedef int    (*SetStaticField)(JEnv env, jclass clazz, JField field, object value) except -1
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


########## Basic Classes and Methods ##########
# These are the classes and methods that are internally used. They are cached in these structures.
# Mostly these are for reflection or common classes and methods.
cdef struct JObjectDef:
    jclass clazz
    jmethodID equals, toString, clone, hashCode
cdef struct JSystemDef:
    jclass clazz
    jmethodID arraycopy, getProperty, gc, identityHashCode # static
cdef struct JClassLoaderDef:
    jclass clazz
    jmethodID getParent, resolveClass
    jmethodID getSystemClassLoader # static
cdef struct JURLClassLoaderDef:
    jclass clazz
    jmethodID addURL, getURLs
cdef struct JFileDef:
    jclass clazz
    jmethodID ctor, toURI
cdef struct JURIDef:
    jclass clazz
    jmethodID toURL
cdef struct JPackageDef:
    jclass clazz
    jmethodID getName
    jmethodID getPackage # static
cdef struct JClassDef:
    jclass clazz
    jmethodID getName, getSimpleName, getPackage, getEnclosingClass, getDeclaringClass, getModifiers
    jmethodID getDeclaredFields, getDeclaredMethods, getDeclaredConstructors, getDeclaredClasses
    jmethodID getInterfaces, isInterface, isEnum, isArray, getComponentType #, isAnnotation
    jmethodID isAnonymousClass, isLocalClass, isMemberClass #, isSynthetic
cdef struct JFieldDef:
    jclass clazz
    jmethodID getName, getType, getDeclaringClass, getModifiers #, isSynthetic
cdef struct JMethodDef:
    jclass clazz
    jmethodID getName, getReturnType, getParameterTypes, getExceptionTypes, getDeclaringClass, getModifiers
    jmethodID isVarArgs #, isBridge, isSynthetic
cdef struct JConstructorDef:
    jclass clazz
    jmethodID getName, getParameterTypes, getExceptionTypes, getDeclaringClass, getModifiers
    jmethodID isVarArgs #, isSynthetic
cdef struct JRunnableDef:
    jclass clazz
    jmethodID run
cdef struct JThreadDef:
    jclass clazz
    jmethodID currentThread # static
    jmethodID getContextClassLoader, setContextClassLoader

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


########## Basic actions that can be queued in the JVM thread ##########
# Currently only the DeleteGlobalRefAction and UnregisterNativesAction are used, the others are
# just here because they might be useful eventually.
cdef class DeleteGlobalRefAction(JVMAction):
    """Calls DeleteGlobalRef on the object"""
    cdef jobject obj
    @staticmethod
    cdef inline DeleteGlobalRefAction create(jobject obj):
        cdef DeleteGlobalRefAction action = DeleteGlobalRefAction()
        action.obj = obj
        return action
    cpdef run(self, JEnv env)
cdef inline int delete_global_ref(jobject obj) except -1:
    """
    Either calls DeleteGlobalRef on the current thread or as an action depending on the attached
    state of the JVM to this thread.
    """
    if jvm is not None:
        # TODO: make sure this JVM is the same JVM that created the jobject?
        if jvm.is_attached(): jenv().DeleteGlobalRef(obj)
        else: jvm.run_action(DeleteGlobalRefAction.create(obj))
    return 0
cdef class UnregisterNativesAction(JVMAction):
    """Calls UnregisterNatives on the object"""
    cdef jobject obj
    @staticmethod
    cdef inline UnregisterNativesAction create(jobject obj):
        cdef UnregisterNativesAction action = UnregisterNativesAction()
        action.obj = obj
        return action
    cpdef run(self, JEnv env)
cdef inline int unregister_natives(jobject obj) except -1:
    """
    Either calls UnregisterNatives on the current thread or as an action depending on the attached
    state of the JVM to this thread.
    """
    if jvm is not None:
        # TODO: make sure this JVM is the same JVM that created the jobject?
        if jvm.is_attached(): jenv().UnregisterNatives(obj)
        else: jvm.run_action(UnregisterNativesAction.create(obj))
    return 0
cdef class RunnableAction(JVMAction):
    """Calls obj.run() with or without the GIL"""
    cdef jobject obj
    cdef bint withgil
    @staticmethod
    cdef inline RunnableAction create(jobject obj, bint withgil=False):
        cdef RunnableAction action = RunnableAction()
        action.obj = obj
        action.withgil = withgil
        return action
    cpdef run(self, JEnv env)
cdef class GCAction(JVMAction):
    """Calls java.lang.System.gc() and Python's gc.collect()"""
    @staticmethod
    cdef inline GCAction create(): return GCAction()
    cpdef run(self, JEnv env)


########## Reference Wrappers ##########
# Basic wrapper classes for jclass, jmethodID, jfieldID, and jobject
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
    if   mod & PUBLIC:    return u''
    elif mod & PROTECTED: return u'_'
    else:                 return u'__' # private OR package-private

cdef class JBase(object):
    cdef readonly unicode name
    cdef Modifiers modifiers
        # In general one of PUBLIC, PRIVATE, PROTECTED then some combination of:
        # Interfaces:   STATIC | ABSTRACT
        # Classes:      STATIC | ABSTRACT | FINAL
        # Constructors: STRICT
        # Methods:      STATIC | ABSTRACT | STRICT | FINAL | SYNCHRONIZED | NATIVE
        # Fields:       STATIC | FINAL | VOLATILE | TRANSIENT
    #cdef bint is_synthetic
    cdef JClass declaring_class # None for anonymous and local classes, enclosing class always works
    cdef inline Modifiers access(self):  return <Modifiers>(self.modifiers&(PUBLIC|PRIVATE|PROTECTED))
    cdef inline bint is_public(self):    return (self.modifiers & PUBLIC)    == PUBLIC
    cdef inline bint is_protected(self): return (self.modifiers & PRIVATE)   == PRIVATE
    cdef inline bint is_private(self):   return (self.modifiers & PROTECTED) == PROTECTED
    cdef inline bint is_static(self): return (self.modifiers & STATIC)   == STATIC
    cdef inline bint is_final(self):  return (self.modifiers & FINAL)    == FINAL

cdef class JClass(JBase):
    """Wrapper around a jclass pointer along with several properties of the class"""
    cdef JClassFuncs* funcs
    cdef jclass clazz
    cdef int identity # from System.identityHashCode
    cdef unicode simple_name
    cdef ClassType type
    cdef ClassMode mode
    cdef unicode package_name
    cdef JClass enclosing_class
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
        return self.name if self.is_array() else (u'L%s;' % self.name)
    #cdef inline bint is_annotation(self):   return self.type == CT_ANNOTATION
    cdef inline bint is_interface(self): return self.type == CT_INTERFACE # or self.type == CT_ANNOTATION
    cdef inline bint is_primitive(self): return self.type == CT_PRIMITIVE
    cdef inline bint is_array(self):     return self.type == CT_ARRAY
    cdef inline bint is_enum(self):      return self.type == CT_ENUM
    cdef inline bint is_anonymous(self): return self.mode == CM_ANONYMOUS
    cdef inline bint is_local(self):     return self.mode == CM_LOCAL
    cdef inline bint is_member(self):    return self.mode == CM_MEMBER # either a static nested or inner class
    cdef inline bint is_nested(self):    return self.mode != 0
    cdef inline bint is_abstract(self):  return (self.modifiers & ABSTRACT) == ABSTRACT

    @staticmethod
    cdef JClass named(JEnv env, unicode name)
    @staticmethod
    cdef JClass get(JEnv env, jclass clazz)
    @staticmethod
    cdef JClass __create(JEnv env, unicode name, jclass clazz)
    @staticmethod
    cdef JClass __create_primitive(JNIEnv* env, unicode cn, unicode name, JClassFuncs* funcs)

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
        if self.clazz is not NULL:
            delete_global_ref(self.clazz)
            self.clazz = NULL
        return 0

    # These functions do the same as <= and == but are a bit more efficient since
    # they take the JEnv and can be inlined.
    cdef inline is_sub(self, JEnv env, JClass b): return env.IsAssignableFrom(self.clazz, b.clazz)
    cdef inline is_same(self, JEnv env, JClass b): return env.IsSameObject(self.clazz, b.clazz)

cdef class JMethod(JBase):
    """Wrapper around a jmethodID along with several properties of the method/constructor"""
    cdef jmethodID id
    cdef JClass return_type # None if it is a constructor
    cdef list param_types, exc_types # lists of JClass
    cdef bint is_var_args #, is_bridge
    cdef inline unicode attr_name(self):    return protection_prefix(self.modifiers) + self.name
    cdef inline unicode param_sig(self):
        cdef JClass t
        return u''.join([t.sig() for t in self.param_types])
    cdef inline bint is_ctor(self):         return self.return_type is None # NOTE: constructor names are the class names, not the special "<init>"
    cdef inline unicode return_sig(self):   return u'V' if self.return_type is None else self.return_type.sig()
    cdef inline unicode sig(self):          return u'(%s)%s' % (self.param_sig(), self.return_sig())
    cdef inline bint is_synchronized(self): return (self.modifiers & SYNCHRONIZED) == SYNCHRONIZED
    cdef inline bint is_native(self):       return (self.modifiers & NATIVE)   == NATIVE
    cdef inline bint is_abstract(self):     return (self.modifiers & ABSTRACT) == ABSTRACT
    cdef inline bint is_strict(self):       return (self.modifiers & STRICT)   == STRICT
    # In Java 1.8+ interfaces can have "default" methods. Could use Method.isDefault() but this
    # does the same thing and works in all versions of Java (will always be False prior to 1.8).
    cdef inline bint is_default(self):      return (self.modifiers&(PUBLIC|ABSTRACT|STATIC)) == PUBLIC and self.declaring_class.is_interface()
    @staticmethod
    cdef JMethod create(JEnv env, jobject method)
    @staticmethod
    cdef JMethod create_ctor(JEnv env, jobject ctor)
    @staticmethod
    cdef dict group(list methods)

cdef class JField(JBase):
    """Wrapper around a jfieldID pointer along with several properties of the field"""
    cdef jfieldID id
    cdef JClass type
    cdef inline unicode attr_name(self): return protection_prefix(self.modifiers) + self.name
    cdef inline bint is_volatile(self):  return (self.modifiers & VOLATILE)  == VOLATILE
    cdef inline bint is_transient(self): return (self.modifiers & TRANSIENT) == TRANSIENT
    @staticmethod
    cdef JField create(JEnv env, jobject field)

cdef class JObject(object):
    cdef jobject obj
    @staticmethod
    cdef inline JObject create(JEnv env, jobject obj):
        cdef JObject o = JObject()
        o.obj = env.NewGlobalRef(obj)
        env.DeleteRef(obj)
        return o
    @staticmethod
    cdef inline JObject wrap(jobject obj):
        cdef JObject o = JObject()
        o.obj = obj
        return o
    @staticmethod
    cdef inline JObject wrap_local(jobject obj):
        cdef JObject o = JObject()
        o.obj = obj
        o.destroy = o.__destroy_local
        return o
    cdef inline jint identity(self) except? -1:
        cdef jvalue val
        val.l = self.obj
        return jenv().CallStaticInt(SystemDef.clazz, SystemDef.identityHashCode, &val)


########## Type Boxing Support ##########
cdef jobject Boolean_TRUE, Boolean_FALSE
cdef jclass box_classes[8]
cdef jmethodID box_ctors[8]

#cdef inline jobject box_boolean(JEnv env, jboolean x) except NULL:
#    cdef jvalue val
#    val.z = x
#    return env.NewObject(box_classes[0], box_ctors[0], &val, True)
cdef inline jobject box_boolean(JEnv env, jboolean x) except NULL:
    return env.NewLocalRef(Boolean_TRUE if x == JNI_TRUE else Boolean_FALSE)
cdef inline jobject box_byte(JEnv env, jbyte x) except NULL:
    cdef jvalue val
    val.b = x
    return env.NewObject(box_classes[1], box_ctors[1], &val, True)
cdef inline jobject box_char(JEnv env, jchar x) except NULL:
    cdef jvalue val
    val.c = x
    return env.NewObject(box_classes[2], box_ctors[2], &val, True)
cdef inline jobject box_short(JEnv env, jshort x) except NULL:
    cdef jvalue val
    val.s = x
    return env.NewObject(box_classes[3], box_ctors[3], &val, True)
cdef inline jobject box_int(JEnv env, jint x) except NULL:
    cdef jvalue val
    val.i = x
    return env.NewObject(box_classes[5], box_ctors[5], &val, True)
cdef inline jobject box_long(JEnv env, jlong x) except NULL:
    cdef jvalue val
    val.j = x
    return env.NewObject(box_classes[5], box_ctors[5], &val, True)
cdef inline jobject box_float(JEnv env, jfloat x) except NULL:
    cdef jvalue val
    val.f = x
    return env.NewObject(box_classes[6], box_ctors[6], &val, True)
cdef inline jobject box_double(JEnv env, jdouble x) except NULL:
    cdef jvalue val
    val.d = x
    return env.NewObject(box_classes[7], box_ctors[7], &val, True)
