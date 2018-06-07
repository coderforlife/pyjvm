"""
JVM internal Python module. While most of the code is in Cython, this module includes functions for
basic control of the JVM and Java pseudo-modules.

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

Synthetic Java Classes
----------------------
Create Java classes dynamically that map to Python.

Internal functions:
    synth_class - creates a synthetic Java class
    
TODO:
    handle default methods
"""

include "version.pxi"

from libc.stdlib cimport malloc, free
from libc.stdint cimport uint16_t, uint32_t, uint64_t, int32_t, int64_t, uintptr_t

from .utils cimport to_unicode, is_callable, VALUES
from .unicode cimport to_utf8j, unichr

from .jni cimport jclass, jfieldID, jobject, jthrowable, jvalue, jint, JNIEnv, JNINativeMethod

from .core cimport JObject, JClass, JMethod, JField, JEnv, jenv, ClassLoaderDef, ThrowableDef, class_exists, unregister_natives
from .core cimport Modifiers, PUBLIC, PRIVATE, PROTECTED, STATIC, FINAL, SUPER, NATIVE, ABSTRACT, SYNTHETIC
from .core cimport py2boolean, py2byte, py2char, py2short, py2int, py2long, py2float, py2double
from .objects cimport create_java_object, get_object_class, get_object
from .convert cimport object2py, py2object, get_parameter_sig

from io import BytesIO
import struct, operator, ctypes

IF PY_VERSION < PY_VERSION_3_2:
    u1 = struct.Struct('>B').pack
    u2 = struct.Struct('>H').pack
    u4 = struct.Struct('>I').pack
ELSE:
    u1 = operator.methodcaller("to_bytes", 1, "big")
    u2 = operator.methodcaller("to_bytes", 2, "big")
    u4 = operator.methodcaller("to_bytes", 4, "big")

cdef class ConstantPool(object):
    cdef object data
    cdef uint16_t count 
    cdef dict pool # bytes -> id

    def __cinit__(self):
        self.data = BytesIO()
        self.data.write(u2(0))
        self.count = 1
        self.pool = { } # bytes -> id
    
    cdef get_data(self):
        self.data.getbuffer()[:2] = u2(self.count)
        return self.data.getvalue()
    
    cdef uint16_t __get(self, bytes x, uint16_t inc=1) except? 0xFFFF:
        if x in self.pool: return self.pool[x]
        assert self.count < 0xFFFE
        cdef uint16_t i = self.count
        self.count += inc
        self.pool[x] = i
        self.data.write(x)
        return i

    cdef inline uint16_t utf8(self, unicode val) except? 0xFFFF:
        cdef bytes data = to_utf8j(val)
        assert len(data) <= 0xFFFF
        return self.__get(b'\x01'+u2(len(data))+data)

    cdef inline uint16_t int(self, int32_t val) except? 0xFFFF:
        return self.__get(b'\x03'+u4(<uint32_t>val))

    cdef inline uint16_t float(self, float val) except? 0xFFFF:
        return self.__get(b'\x04'+struct.pack('>f', val))

    cdef inline uint16_t long(self, int64_t val) except? 0xFFFF:
        return self.__get(b'\x05'+struct.pack('>Q', <uint64_t>val), 2)

    cdef inline uint16_t double(self, double val) except? 0xFFFF:
        return self.__get(b'\x06'+struct.pack('>d', val), 2)

    cdef inline uint16_t cls_name(self, unicode val) except? 0xFFFF:
        return self.__get(b'\x07'+u2(self.utf8(val.replace(u'.', '/'))))
        
    cdef inline uint16_t cls(self, JClass val) except? 0xFFFF:
        return self.cls_name(val.name)

    cdef inline uint16_t string(self, unicode val) except? 0xFFFF:
        return self.__get(b'\x08'+u2(self.utf8(val)))

    cdef inline uint16_t field_ref_1(self, JField val) except? 0xFFFF:
        return self.__get(b'\x09'+u2(self.cls(val.declaring_class))+u2(self.nt(val.name, val.type.sig())))

    cdef inline uint16_t field_ref_2(self, unicode cls, unicode name, unicode sig) except? 0xFFFF:
        return self.__get(b'\x09'+u2(self.cls_name(cls))+u2(self.nt(name, sig)))

    cdef inline uint16_t method_ref_1(self, JMethod val) except? 0xFFFF:
        cdef bytes tag = b'\x0B' if val.declaring_class.is_interface() else b'\x0A'
        return self.__get(tag+u2(self.cls(val.declaring_class))+u2(self.nt_method(val)))

    cdef inline uint16_t method_ref_2(self, bint iface, unicode cls, unicode name, unicode sig) except? 0xFFFF:
        cdef bytes tag = b'\x0B' if iface else b'\x0A'
        return self.__get(tag+u2(self.cls_name(cls))+u2(self.nt(name, sig)))

    cdef inline uint16_t nt(self, unicode name, unicode type) except? 0xFFFF:
        return self.__get(b'\x0C'+u2(self.utf8(name))+u2(self.utf8(type.replace(u'.', '/'))))

    cdef inline uint16_t nt_method(self, JMethod val) except? 0xFFFF:
        return self.nt(u'<init>' if val.is_ctor() else val.name, val.sig())

    cdef inline uint16_t method_handle(self, unsigned char ref_kind, ref) except? 0xFFFF:
        if 1 <= ref_kind <= 4 and isinstance(ref, JField):
            return self.__get(b'\x0F'+u1(ref_kind)+u2(self.field_ref_1(ref)))
        elif 5 <= ref_kind <= 9 and isinstance(ref, JMethod) and (ref_kind == 9) == (<JMethod>ref).declaring_class.is_interface():
            return self.__get(b'\x0F'+u1(ref_kind)+u2(self.method_ref_1(ref)))
        else: raise ValueError()
        
    cdef inline uint16_t method_type(self, JMethod method) except? 0xFFFF:
        return self.__get(b'\x10'+self.utf8(method.sig().replace(u'.', '/')))

    cdef inline uint16_t invoke_dynamic(self, uint16_t bootstrap_mthd_attr_idx, JMethod method) except? 0xFFFF:
        return self.__get(b'\x12'+u2(bootstrap_mthd_attr_idx)+self.nt_method(method))

cdef random_string():
    import random, string
    opts = string.ascii_letters + string.digits
    return u''.join(random.choice(opts) for _ in range(20))
        
cdef bytes ctor_code_attr(ConstantPool constants, JMethod ctor, unicode clsname=None, unicode method=None):
    """
    Creates a constructor Code attribute including the compiled bytecode. The constructor is
    extremely basic in that it calls the given superclass' ctor first and then optionally calls the
    method with the given name in this class (the method must have the same signature of the ctor
    and a return type of void).
    """
    # Call the super constructor:
    #   aload_0
    #   .. (loading other arguments)
    #   invokespecial <method ref>
    # If there is a method to call:
    #   aload_0
    #   .. (loading other arguments)
    #   invokespecial <method ref>
    # Finally:
    #   return
    assert method.is_ctor()
    # Get bytecode for loading all of the arguments
    cdef bytes loading = b'\x2a' # aload_0 (this)
    cdef JClass c
    cdef unsigned char opcode
    cdef uint16_t i, n = len(ctor.param_types) + 1
    for i in xrange(1, n):
        c = ctor.param_types[i-1]
        if   c.funcs.sig == b'J': opcode = 0x16 # long
        elif c.funcs.sig == b'F': opcode = 0x17 # float
        elif c.funcs.sig == b'D': opcode = 0x18 # double
        elif c.funcs.sig == b'L': opcode = 0x19 # reference
        else: opcode = 0x15 #if c.funcs.sig in b'ZBCSI': # int
        loading += (u1(opcode) + u1(i)) if i > 3 else u1(opcode*4-58+i)
    # Create the entire bytecode
    cdef bytes bytecode = loading + b'\xb7' + u2(constants.method_ref_1(ctor)) # invokespecial
    if method is not None:
        bytecode += loading + b'\xb7' + u2(constants.method_ref_2(False, clsname, method, ctor.sig()))
    bytecode += b'\xb1' # return
    # Create the rest of the Code attribute
    cdef bytes code = u2(n+2) + u2(n+2) + u4(len(bytecode)) + bytecode + b'\x00\x00\x00\x00'
    return u2(constants.utf8(u'Code')) + u4(len(code)) + code
    
cdef bytes exceptions_attr(ConstantPool constants, list excs): # list of JClass
    cdef bytes data = u2(len(excs)) + b''.join(u2(constants.cls(e)) for e in excs)
    return u2(constants.utf8(u'Exceptions')) + u4(len(data)) + data

cdef class MethodInfo(object):
    cdef Modifiers mod
    cdef unicode name
    cdef unicode sig
    cdef list attributes # list of bytes (pre-compiled attributes, e.g. Code)
    cdef set exceptions # set of JClass
    cdef object pymeth
    def __cinit__(self, Modifiers mod, unicode name, unicode sig, exceptions=(), pymeth=None):
        self.mod = mod
        self.name = name
        self.sig = sig
        self.attributes = []
        self.exceptions = set(exceptions)
        self.pymeth = pymeth
    @staticmethod
    cdef ctor_w_init(ConstantPool constants, JMethod ctor, unicode clsname, pymeth=None):
        cdef MethodInfo c = MethodInfo(ctor.modifiers, u'<init>', ctor.sig(), ctor.exc_types)
        cdef MethodInfo i = MethodInfo(PRIVATE|FINAL|NATIVE, u'__pyjvm_init$$', ctor.sig(), ctor.exc_types, pymeth)
        c.attributes = [ctor_code_attr(constants, ctor, clsname, i.name)]
        return c, i
    @staticmethod
    cdef inline MethodInfo create(JMethod method):
        return MethodInfo(method.modifiers, method.name, method.sig(), method.exc_types)

cdef inline bint is_throwable(JEnv env, jclass clazz):
    return env.env[0].IsAssignableFrom(env.env, clazz, ThrowableDef.clazz)

cdef inline int all_methods(list classes, dict abstract, dict concrete) except -1: # [JClass], {(name,param_sig):MethodInfo}
    cdef JClass cls
    for cls in classes: all_methods_1(cls, abstract, concrete)
    return 0

cdef int all_methods_1(JClass cls, dict abstract, dict concrete) except -1:
    # params: JClass, {(name,param_sig):MethodInfo}, {(name,param_sig):MethodInfo}
    # TODO: deal with default methods which were added in Java 1.8, they are concrete but will be found out-of-order
    cdef JMethod method
    cdef MethodInfo mi
    for methods in VALUES(cls.methods):
        for method in methods:
            nt = (method.name, method.param_sig())
            if nt in concrete:
                mi = concrete[nt]
                if mi.sig != method.sig() or mi.exceptions - set(method.exc_types): raise ValueError('unable to resolve methods')
            elif nt in abstract:
                mi = abstract[nt]
                if mi.sig != method.sig(): raise ValueError('unable to resolve methods')
                if method.is_abstract(): mi.exceptions &= method.exc_types # intersection of exception types
            elif method.is_abstract(): abstract[nt] = MethodInfo.create(method)
            else:                      concrete[nt] = MethodInfo.create(method)
    if cls.superclass is not None:
        all_methods_1(cls.superclass, abstract, concrete)
    all_methods(cls.interfaces, abstract, concrete)
    return 0
    
cdef inline break_param_sig(unicode ps):
    param_sigs = []
    while len(ps) > 0:
        if ps[0] == u'L': i = ps.index(u';', 1)+1
        elif ps[0] == u'[':
            for i in xrange(1, len(ps)):
                if ps[i] != u'[': break
            if ps[i] == u'L': i = ps.index(u';', i+1)+1
        else: i = 1
        param_sigs.append(ps[:i])
        ps = ps[i:]
    return param_sigs

cdef dict java2ctypes = {
    u'L': ctypes.c_void_p, u'[': ctypes.c_void_p, u'V': None,
    u'Z': ctypes.c_bool,   u'C': ctypes.c_uint16,
    u'B': ctypes.c_int8,   u'S': ctypes.c_int16,  u'I': ctypes.c_int32, u'I': ctypes.c_int64,
    u'F': ctypes.c_float,  u'D': ctypes.c_double,
}

cdef inline void* ptr(uintptr_t x): return <void*>x

cdef void* create_bridge(JEnv env, method, unicode sig) except NULL:
    from .objects import JavaClass

    # Parse the signature
    last_paren = sig.rindex(u')')
    param_sigs = break_param_sig(sig[1:last_paren])
    return_sig = sig[last_paren+1:]
    cdef JClass return_cls = None
    if   return_sig[0] == u'L': return_cls = JClass.named(env, return_sig[1:-1])
    elif return_sig[0] == u'[': return_cls = JClass.named(env, return_sig)
    return_sig = return_sig[0]
        
    # Create the Python bridge function
    def pyjvm_bridge(_env, _obj, *args):
        cdef JEnv env = JEnv.wrap(<JNIEnv*>ptr(_env))
        cdef jobject obj = <jobject>ptr(_obj)
        try:
            # Convert the arguments
            new_args = []
            for sig,arg in zip(param_sigs, args):
                arg = arg.value
                if sig[0] == 'L' or sig[0] == '[' and arg is not None:
                    arg = object2py(env, <jobject>ptr(arg))
                elif sig[0] == 'C': arg = unichr(arg)
                new_args.append(arg)

            # Call the method
            retval = method(create_java_object(env, JObject.create(env, obj)), *new_args)

            # Convert the return value
            if return_sig == u'L' or return_sig == u'[':
                return <uintptr_t>py2object(env, retval, return_cls)
            if return_sig == u'Z': return py2boolean(retval)
            if return_sig == u'C': return py2char(retval)
            if return_sig == u'B': return py2byte(retval)
            if return_sig == u'S': return py2short(retval)
            if return_sig == u'I': return py2int(retval)
            if return_sig == u'J': return py2long(retval)
            if return_sig == u'F': return py2float(retval)
            if return_sig == u'D': return py2double(retval)
            return None #if return_sig == u'V':
        except BaseException as ex:
            # TODO: could the Python stack trace be integrated into the exception?
            if isinstance(ex, JavaClass) and is_throwable(env, get_object_class(ex).clazz):
                # Already a Java Throwable, just throw it
                env.Throw(<jthrowable>get_object(ex))
            else:
                pass # TODO
    
    # Create the C function
    cfunctype = ctypes.CFUNCTYPE(java2ctypes[return_sig], ctypes.c_void_p, ctypes.c_void_p,
        *[java2ctypes[sig[0]] for sig in param_sigs])
    method.__pyjvm_cfunc__ = cfunctype(pyjvm_bridge)
    return <void*>ptr(ctypes.cast(method.__pyjvm_cfunc__, ctypes.c_void_p).value)
    
def synth_class(cls, methods, JClass superclass, list interfaces):
    """
    Creates a synthetic Java class that maps onto a Python class.
    
    The Java class contains native methods which are given as a list of tuples:
        (name, parameter signature, return type, exceptions, method)
    where name, parameter signature, and return type are unicode strings as given by JMethod.name,
    JMethod.param_sig(), and JMethod.return_sig(). The exceptions are a sequence of Java objects
    that extend from Throwable. The method is the Python unbound method that is called when the
    function is called.
    
    The Java class extends from the given superclass and implements the given interfaces. All of
    the methods must override methods in this superclasses and interfaces. The class is
    appropiately marked as abstract if there are methods that are left not implemented.
    
    Additionally, constructors are created for every non-private constructor in the superclass.
    These constructors call the superclass constructor and then call a native method that forwards
    to the Python class' __init__ method, passing all of the arguments in.

    The class will be placed in the package pyjvm.__synth__ with a name based off of the original
    name of the Python class, possibly with random information after it to make it unique.
    
    This returns the JavaClass representing the newly synthesized class.
    """
    from .objects import JavaClass
    cdef JEnv env = jenv()
    
    # Check the superclass and interfaces
    cdef JClass iface
    if superclass is None: superclass = JClass.named(env, u'java.lang.Object')
    elif superclass.is_primitive() or superclass.is_interface() or superclass.is_final(): raise TypeError("superclass cannot be extended")
    for iface in interfaces:
        if not iface.is_interface(): raise TypeError("interfaces are not all interfaces")

    # Get the name
    cdef unicode name = u'pyjvm.__synth__.'+to_unicode(cls.__name__)
    while class_exists(env, name):
        name = u'pyjvm.__synth__.'+to_unicode(cls.__name__)+'_'+random_string()
    
    # Get the __init__ and __dealloc__ methods
    init = cls.__dict__.get('__init__', lambda self,*args:None)
    prev_dealloc = cls.__dict__.get('__dealloc__', None)
    dealloc = ((lambda self: unregister_natives(clazz)) if prev_dealloc is None else 
               (lambda self: (prev_dealloc(self), unregister_natives(clazz)))) # extend the old dealloc

    # Setup variables
    cdef ConstantPool constants = ConstantPool()
    cdef MethodInfo mi
    cdef list meth_infos = []
    cdef Py_ssize_t ctors = 0, i = 0

    # Create the constructors
    cdef JMethod ctor
    for ctor in superclass.constructors:
        if not ctor.is_private():
            ctors += 1
            meth_infos.extend(MethodInfo.ctor_w_init(constants, ctor, name, init))

    # Create the methods
    cdef dict abstract = {}, concrete = {}
    all_methods_1(superclass, abstract, concrete)
    all_methods(interfaces, abstract, concrete)
    have = set()
    for n,ps,rt,exc,um in methods:
        nt = (n, ps)
        sig = u'(%s)%s' % (ps, rt)
        if nt in have: raise TypeError("duplicate name/paramaters for %s(%s)"%nt)
        have.add(nt)
        if nt in concrete:
            mi = concrete[nt]
            if (mi.mod & (FINAL|PRIVATE)) != 0 or sig != mi.sig or len(set(exc) - mi.exceptions) != 0:
                raise TypeError("can only override methods that are already declared in the superclass or interfaces")
        elif nt in abstract:
            mi = abstract.pop(nt)
            if sig != mi.sig or len(set(exc) - mi.exceptions) != 0: raise TypeError("can only override methods that are already declared in the superclass or interfaces")
        else: raise TypeError("can only override methods that are already declared in the superclass or interfaces")
        meth_infos.append(MethodInfo((mi.mod&(PUBLIC|PROTECTED))|NATIVE, n, sig, exc, um))
    
    ### Create the class file ###
    data = BytesIO()

    # Access Flags / Modifiers
    data.write(u2(SUPER|SYNTHETIC|(0 if len(abstract) == 0 else ABSTRACT)))

    # this and super classes and interfaces
    data.write(u2(constants.cls_name(name)) + u2(constants.cls(superclass)) + u2(len(interfaces)))
    for iface in interfaces: data.write(u2(constants.cls(iface)))

    # Fields (always one for a way to refer to the Python self object)
    data.write(u2(1) + u2(PRIVATE|SYNTHETIC|FINAL) + u2(constants.utf8(u'__pyjvm_self$$')) +
               u2(constants.utf8(u'J')) + u2(0))
    
    # Methods
    data.write(u2(len(meth_infos)))
    for mi in meth_infos:
        data.write(u2(mi.mod) + u2(constants.utf8(mi.name)) + u2(constants.utf8(mi.sig.replace(u'.',u'/'))) +
                   u2(len(mi.attributes) + (1 if len(mi.exceptions) > 0 else 0)))
        for attr in mi.attributes: data.write(attr)
        if len(mi.exceptions) > 0: data.write(exceptions_attr(constants, mi.exceptions))
    
    # Attributes (always none)
    data.write(u2(0))
    
    # Get the entire file contents
    # This is the header plus the constants plus all the other data we just put together
    # We have to do this last since the size of the constants won't be known until now
    data = b'\xca\xfe\xba\xbe\x00\x00' + u2((JNI_VERSION&0xFFFF) + 44) + constants.get_data() + data.getvalue()
    # DEBUG: with open('test.class', 'wb') as f: f.write(data)
    
    ### Define the Java class ###
    cdef jobject class_loader = env.CallStaticObject(ClassLoaderDef.clazz, ClassLoaderDef.getSystemClassLoader)
    cdef jclass clazz = env.DefineClass(name, class_loader, data)
    cdef jvalue val
    val.l = clazz
    env.CallVoidMethod(class_loader, ClassLoaderDef.resolveClass, &val, True)
    
    # Make the JavaClass
    attr = cls.__dict__.copy()
    attr['__java_class_name__'] = name
    attr['__init__'] = init
    attr['__dealloc__'] = dealloc
    slots = attr.get('__slots__')
    if slots is not None:
        if isinstance(slots, str): slots = [slots]
        for slots_var in slots: attr.pop(slots_var)
    attr.pop('__dict__', None)
    attr.pop('__weakref__', None)
    bases = cls.__bases__ if len(cls.__bases__) != 1 or cls.__bases__[0] != object else ()
    jcls = JavaClass.__new__(JavaClass, name, bases, attr)
    
    # Link the Java methods to Python
    cdef jint n_nat_meths = len(meth_infos) - ctors
    cdef list names = [to_utf8j(mi.name) for mi in meth_infos if (mi.mod&NATIVE) != 0] # we need to cache these so we can get the C-temporaries
    cdef list sigs = [to_utf8j(mi.sig.replace(u'.', u'/')) for mi in meth_infos if (mi.mod&NATIVE) != 0]
    cdef JNINativeMethod* nat_meths = <JNINativeMethod*>malloc(n_nat_meths*sizeof(JNINativeMethod))
    try:
        for mi in meth_infos:
            if (mi.mod&NATIVE) == 0: continue
            nat_meths[i].name = names[i]
            nat_meths[i].signature = sigs[i]
            nat_meths[i].fnPtr = create_bridge(env, mi.pymeth, mi.sig)
            i += 1
        env.RegisterNatives(clazz, nat_meths, n_nat_meths)
    finally: free(nat_meths)

    # Return the new JavaClass
    return jcls

########## Decorators for creating synthetic classes ##########
def conv_types(typ, *typs):
    if len(typs) == 0:
        # Single argument - either single type or several types
        try: return [get_parameter_sig(typ)]
        except KeyError: pass
        # Is possibly multiple signatures so break it up
        typs = break_param_sig(typ)
    else:
        # Multiple arguments - each must be its own type
        typs = [typ] + list(typs)
    return [get_parameter_sig(t) for t in typs]
def synth_override(name=None):
    """
    Marks a method as overriding a Java method (including interface methods, abstract methods, and
    concrete methods). By default the name of overridden method will be the same as the method that
    this is applied to. However, since Java can have multiple methods with the same name but Python
    cannot, this is not always possible. You can provide the name of the real method when using
    @Override(name).
    """
    def jvm_override(m):
        if not hasattr(m, '__pyjvm_meth__'): m.__pyjvm_meth__ = {}
        if 'override' in m.__pyjvm_meth__: raise TypeError('method has already been marked as override')
        m.__pyjvm_meth__['override'] = m.__name__ if name is None else name
        return m
    # Check if this was used like @Override instead of @Override()
    if is_callable(name):
        name, m = None, name
        return jvm_override(m)
    return jvm_override
def synth_param(typ, *typs):
    """
    Adds a parameter type for the method. The argument(s) is the type(s) of the parameter(s).
    May be applied multiple times or multiple arguments may be given at a time. The order of
    the arguments or the application is critical to properly match the Java method.
    """
    def jvm_param(m):
        if not hasattr(m, '__pyjvm_meth__'): m.__pyjvm_meth__ = {}
        m.__pyjvm_meth__['params'] = u''.join(conv_types(typ, typs)) + m.__pyjvm_meth__.get('params', u'')
        return m
    return jvm_param
def synth_return(typ):
    """
    Adds a return type for the method. The argument is the type of the return. May only be applied
    once. If not applied the method is assumed to have the return type "void".
    """
    def jvm_return(m):
        if not hasattr(m, '__pyjvm_meth__'): m.__pyjvm_meth__ = {}
        if 'return' in m.__pyjvm_meth__: raise TypeError('method already has a return type')
        m.__pyjvm_meth__['return'] = get_parameter_sig(typ)
        return m
    return jvm_return
def synth_throws(typ, *typs):
    """
    Adds a throws clause to the method. The argument(s) is the type(s) of exception(s) to be
    thrown. May be applied multiple times or multiple arguments may be given at a time. Order is
    unimportant.
    """
    def jvm_throws(m):
        if not hasattr(m, '__pyjvm_meth__'): m.__pyjvm_meth__ = {}
        cdef JEnv env = jenv()
        ts = conv_types(typ, typs)
        for t in ts:
            if t[0] != u'L' or t[-1] != u';' or not is_throwable(env, env.FindClass(t[1:-1])):
                raise TypeError('can only throw subclasses of java.lang.Throwable')
        m.__pyjvm_meth__.setdefault('throws', set()).update(ts)
        return m
    return jvm_throws
def synth_extends(jc, *jcs):
    """
    Extend/implement one or more Java classes/interfaces. If extending a class it must be listed
    first (if the first thing is not a class it is assumed to be extending java.lang.Object). The
    order of the interfaces after that is unimportant.
    """
    def jvm_extends(cls):
        # Get superclass and interfaces
        cdef JClass superclass = jc.__jclass__
        cdef list interfaces = [iface.__jclass__ for iface in jcs]
        if (<JClass>jc.__jclass__).is_interface():
            interfaces.insert(0, superclass)
            superclass = None

        # Get the methods
        methods = []
        for m in VALUES(cls.__dict__):
            if hasattr(m, '__pyjvm_meth__'):
                if not is_callable(m): raise TypeError('attempting to extend a non-method')
                info = m.__pyjvm_meth__
                if 'override' not in info: raise TypeError('method %s did not have @jvm.override specified')
                methods.append((info['override'], info.get('params', u''), info.get('return', 'V'),
                                info.get('throws', ()), m))

        # Create the synthetic class
        return synth_class(cls, methods, superclass, interfaces)
    return jvm_extends
