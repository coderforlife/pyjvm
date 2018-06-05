include "version.pxi"

from libc.stdlib cimport malloc, free
from libc.stdint cimport uint16_t, uint32_t, uint64_t, int32_t, int64_t, uintptr_t

from .utils cimport VALUES
from .unicode cimport to_utf8j, unichr

from .jni cimport jclass, jfieldID, jobject, jvalue, jint, JNIEnv, JNINativeMethod

from .core cimport JClass, JMethod, JField, JEnv, jenv, ClassLoaderDef
from .core cimport Modifiers, PUBLIC, PRIVATE, PROTECTED, STATIC, FINAL, SUPER, NATIVE, ABSTRACT, SYNTHETIC
from .core cimport py2boolean, py2byte, py2char, py2short, py2int, py2long, py2float, py2double
from .objects cimport get_java_class
from .convert cimport object2py, py2object

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
        return self.__get(b'\x0C'+u2(self.utf8(name))+u2(self.utf8(type)))

    cdef inline uint16_t nt_method(self, JMethod val) except? 0xFFFF:
        return self.nt(u'<init>' if val.is_ctor() else val.name, val.sig())

    cdef inline uint16_t method_handle(self, unsigned char ref_kind, ref) except? 0xFFFF:
        if 1 <= ref_kind <= 4 and isinstance(ref, JField):
            return self.__get(b'\x0F'+u1(ref_kind)+u2(self.field_ref(ref)))
        elif 5 <= ref_kind <= 9 and isinstance(ref, JMethod) and (ref_kind == 9) == (<JMethod>ref).declaring_class.is_interface():
            return self.__get(b'\x0F'+u1(ref_kind)+u2(self.method_ref_1(ref)))
        else: raise ValueError()
        
    cdef inline uint16_t method_type(self, JMethod method) except? 0xFFFF:
        return self.__get(b'\x10'+self.utf8(method.sig()))

    cdef inline uint16_t invoke_dynamic(self, uint16_t bootstrap_mthd_attr_idx, JMethod method) except? 0xFFFF:
        return self.__get(b'\x12'+u2(bootstrap_mthd_attr_idx)+self.nt_method(method))

cdef random_string(n=20):
    import random, string
    opts = string.ascii_letters + string.digits
    return u''.join(random.choice(opts) for _ in range(n))
        
cdef bint class_exists(JEnv env, unicode name):
    """Checks if a class already exists with the given name."""
    cdef jclass clazz = env.env[0].FindClass(env.env, to_utf8j(name.replace(u'.', u'/')))
    if clazz is NULL: env.env[0].ExceptionClear(env.env); return False
    env.DeleteLocalRef(clazz)
    return True

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
        c = ctor.param_types[i]
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

cdef inline int all_methods(classes, dict abstract, dict concrete) except -1: # [JClass], {(name,param_sig):MethodInfo}
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
                if mi.sig != method.sig() or mi.exceptions - method.exc_types: raise ValueError('unable to resolve methods')
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

cdef dict java2ctypes = {
    'L' : ctypes.c_void_p,
    '[' : ctypes.c_void_p,
    'V' : None,
    'Z' : ctypes.c_bool,
    'B' : ctypes.c_int8,
    'C' : ctypes.c_uint16,
    'S' : ctypes.c_int16,
    'I' : ctypes.c_int32,
    'I' : ctypes.c_int64,
    'F' : ctypes.c_float,
    'D' : ctypes.c_double,
}
cdef inline void* ptr(uintptr_t x): return <void*>x
cdef dict selfs = { }
cdef void* create_bridge(JEnv env, cls, method, unicode sig, is_init) except NULL:
    # Parse the signature
    last_paren = sig.rindex(u')')
    return_sig = sig[last_paren+1:]
    cdef JClass return_cls = None
    if   return_sig[0] == u'L': return_cls = JClass.named(env, return_sig[1:-1])
    elif return_sig[0] == u'[': return_cls = JClass.named(env, return_sig)
    param_sig = sig[1:last_paren]
    param_sigs = []
    while len(param_sig) > 0:
        if param_sig[0] == u'L': i = sig.index(u';')+1
        elif param_sig[0] == u'[':
            for i in xrange(1, len(param_sig)):
                if param_sig[i] != u'[': break
            if param_sig[i] == u'L': i = sig.index(u';')+1
        else: i = 1
        param_sigs.append(param_sig[:i])
        param_sig = param_sig[i:]
        
    # Create the Python bridge function
    cdef jfieldID self_fid = <jfieldID>ptr(cls.__pyjvm_self_fid__)
    def pyjvm_bridge(_env, _obj, *args):
        cdef JEnv env = JEnv.wrap(<JNIEnv*>ptr(_env))
        cdef jobject obj = <jobject>ptr(_obj)
        # Convert the arguments
        new_args = []
        for sig,arg in zip(param_sigs, args):
            arg = arg.value
            if sig[0] == 'L' or sig[0] == '[' and arg is not None:
                arg = object2py(env, <jobject>ptr(arg))
            elif sig[0] == 'C': arg = unichr(arg)
            new_args.append(arg)
        # Call the method
        if is_init:
            self = cls.__new__(cls) # TODO: should be from the JavaClass
            selfs[id(self)] = self
            env.env[0].SetLongField(env.env, obj, self_fid, id(self))
            env.check_exc()
        else:
            self = selfs[env.GetLongField(obj, self_fid)]
        retval = method(self, *new_args)
        # Convert the return value
        if return_sig[0] == u'L' or return_sig[0] == u'[':
            return <uintptr_t>py2object(env, retval, return_cls)
        if return_sig == u'V': return None
        if return_sig == u'Z': return py2boolean(retval)
        if return_sig == u'B': return py2byte(retval)
        if return_sig == u'C': return py2char(retval)
        if return_sig == u'S': return py2short(retval)
        if return_sig == u'I': return py2int(retval)
        if return_sig == u'J': return py2long(retval)
        if return_sig == u'F': return py2float(retval)
        if return_sig == u'D': return py2double(retval)
    method.__pyjvm_bridge__ = pyjvm_bridge
    
    # Create the C function
    cfunctype = ctypes.CFUNCTYPE(java2ctypes[return_sig], ctypes.c_void_p, ctypes.c_void_p,
        *[java2ctypes[sig[0]] for sig in param_sigs])
    method.__pyjvm_cfunc__ = cfunctype(pyjvm_bridge)
    return <void*>ptr(ctypes.cast(method.__pyjvm_cfunc__, ctypes.c_void_p).value)
    
def synth_class(cls, methods, superclass=None, interfaces=()):
    """
    Creates a synthetic Java class that maps onto a Python class.
    
    The Java class contains native methods which are given as a list of tuples:
        (name, parameter signature, return type, exceptions, method)
    where name, parameter signature, and return type are unicode strings as given by JMethod.name,
    JMethod.param_sig(), and JMethod.return_sig(). The exceptions are a sequence of Java objects
    that extend from Throwable. The method is the Python unbound method that is called when the
    function is called.
    
    The Java class extends from the given superclass (default java.lang.Object) and implements the
    given interfaces (default none). All of the methods must override methods in this superclasses
    and interfaces. The class is appropiately marked as abstract if there are methods not
    implemented.
    
    Additionally, constructors are created for every non-private constructor in the superclass.
    These constructors call the superclass constructor and then call a native method that forwards
    to the Python class' __init__ method, passing all of the arguments in.

    The class will be placed in the package pyjvm.__synth__ with a name based off of the original
    name of the Python class, possibly with random information after it to make it unique.
    
    This returns the JavaClass representing the newly synthesized class.
    """
    cdef JEnv env = jenv()
    
    # Check the superclass and interfaces
    if superclass is None: superclass = get_java_class(u'java.lang.Object')
    cdef JClass sup = superclass.__jclass__, intrfc
    cdef list intrfcs = [iface.__jclass__ for iface in interfaces]
    if sup.is_primitive() or sup.is_interface() or sup.is_final(): raise ValueError("superclass")
    for intrfc in intrfcs:
        if not intrfc.is_interface(): raise ValueError("interfaces")

    # Check the name
    name = u'pyjvm.__synth__.'+cls.__name__
    while class_exists(env, name):
        name = u'pyjvm.__synth__.'+cls.__name__+'_'+random_string()

    # Setup variables
    cdef ConstantPool constants = ConstantPool()
    cdef MethodInfo mi
    cdef list meth_infos = []
    cdef Py_ssize_t ctors = 0, i = 0

    # Create the constructors
    cdef JMethod ctor
    for ctor in sup.constructors:
        if not ctor.is_private():
            ctors += 1
            meth_infos.extend(MethodInfo.ctor_w_init(constants, ctor, name, cls.__init__))

    # Create the methods
    cdef dict abstract = {}, concrete = {}
    all_methods_1(sup, abstract, concrete)
    all_methods(intrfcs, abstract, concrete)
    have = set()
    for n,ps,rt,exc,um in methods:
        nt = (n, ps)
        sig = u'(%s)%s' % (ps, rt)
        if nt in have: raise ValueError("duplicate name/paramaters for %s(%s)"%nt)
        have.add(nt)
        if nt in concrete:
            mi = concrete[nt]
            if (mi.mod & (FINAL|PRIVATE)) != 0 or sig != mi.sig or len(set(exc) - mi.exceptions) != 0:
                raise ValueError("can only override methods that are already declared in the super-class or interfaces")
        elif nt in abstract:
            mi = abstract.pop(nt)
            if sig != mi.sig or len(set(exc) - mi.exceptions) != 0: raise ValueError("can only override methods that are already declared in the super-class or interfaces")
        else: raise ValueError("can only override methods that are already declared in the super-class or interfaces")
        meth_infos.append(MethodInfo((mi.mod&(PUBLIC|PROTECTED))|NATIVE, n, sig, exc, um))
    
    ### Create the class file ###
    data = BytesIO()

    # Access Flags / Modifiers
    data.write(u2(SUPER|SYNTHETIC|(0 if len(abstract) == 0 else ABSTRACT)))

    # this and super classes and interfaces
    data.write(u2(constants.cls_name(name)) + u2(constants.cls(sup)) + u2(len(interfaces)))
    for intrfc in intrfcs: data.write(u2(constants.cls(intrfc)))

    # Fields (always one for a way to refer to the Python self object)
    data.write(u2(1) + u2(PRIVATE|SYNTHETIC|FINAL) + u2(constants.utf8(u'__pyjvm_self$$')) +
               u2(constants.utf8(u'J')) + u2(0))
    
    # Methods
    data.write(u2(len(meth_infos)))
    for mi in meth_infos:
        data.write(u2(mi.mod) + u2(constants.utf8(mi.name)) + u2(constants.utf8(mi.sig)) +
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
    
    # Load the class
    cdef jobject class_loader = env.CallStaticObject(ClassLoaderDef.clazz, ClassLoaderDef.getSystemClassLoader)
    cdef jclass jcls = env.DefineClass(name, class_loader, data)
    cdef jvalue val
    val.l = jcls
    env.CallVoidMethod(class_loader, ClassLoaderDef.resolveClass, &val, True)
    
    # Link the Java methods to Python
    cls.__pyjvm_self_fid__ = <uintptr_t>env.GetFieldID(jcls, u'__pyjvm_self$$', u'J')
    cdef jint n_nat_meths = len(meth_infos) - ctors
    cdef JNINativeMethod* nat_meths = <JNINativeMethod*>malloc(n_nat_meths*sizeof(JNINativeMethod))
    cdef list temps = []
    try:
        for mi in meth_infos:
            if (mi.mod&NATIVE) == 0: continue
            temps.append(to_utf8j(mi.name)); nat_meths[i].name = temps[-1]
            temps.append(to_utf8j(mi.sig));  nat_meths[i].signature = temps[-1]
            nat_meths[i].fnPtr = create_bridge(env, cls, mi.pymeth, mi.sig, (mi.mod&PRIVATE)==PRIVATE)
            i += 1
        env.RegisterNatives(jcls, nat_meths, n_nat_meths)
    finally: free(nat_meths)
    # TODO: should be put onto new JavaClass class
    cls.__dealloc__ = lambda self : unregister_natives(jcls)

    # Load the JavaClass
    return get_java_class(name)
