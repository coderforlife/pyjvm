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

Public Classes for Java Objects
-------------------------------
The public Python classes for dealing with Java objects along with Java object templates for core
classes and interfaces to make them more Python-like.

Public functions:
    get_java_class - gets a JavaClass from a unicode string

Public classes:
    JavaClass         - the type of all Java objects, roughly a java.lang.Class
    JavaMethods       - wrapper for a collection of same-named Java methods of an object
    JavaStaticMethods - wrapper for a collection of same-named Java static methods of a class
    JavaMethod        - wrapper for a single Java method of an object
    JavaStaticMethod  - wrapper for a single Java static method of a class
    JavaConstructor   - wrapper for a single Java contructor for a class

Internal functions:
    create_java_object - creates a Python object from a jobject
    get_object_class   - gets the JClass from a Python object
    get_class          - gets the jclass from a JavaClass
    get_object         - gets the jobject from a Python object
    
TODO:
    inner classes automatically know the outer class instance and incorporate it into the constructor
"""

from cpython.ref cimport Py_INCREF
from cpython.tuple cimport PyTuple_New, PyTuple_SET_ITEM
from cpython.bytes cimport PyBytes_Check
from cpython.slice cimport PySlice_Check

cdef dict classes = None # class-name (using . and without L;) -> JavaClass
cpdef get_java_class(unicode classname):
    """Gets the unique JavaClass for a given class name"""
    if classname in classes: return classes[classname]
    return JavaClass.__new__(JavaClass, classname, (), {'__java_class_name__':classname})
cdef create_java_object(jobject obj):
    """Creates a Java Object wrapper around the given object. The object is deleted."""
    cdef JEnv env = jenv()
    cdef JClass clazz = JClass.get(env, env.GetObjectClass(obj))
    cdef jfieldID fid
    cls = get_java_class(clazz.name)
    if clazz.is_member() and not clazz.is_static() and clazz.declaring_class is not None:
        try:
            fid = env.GetFieldID(clazz.clazz, 'this$0', clazz.declaring_class.sig())
            cls = cls._bind_inner_class_to(env.GetObjectField(obj, fid))
        except Exception as ex: pass
    return cls.__new__(cls, JObject.create(env, obj))
cdef inline JClass get_object_class(obj):
    """Gets the JClass of an Object"""
    return type(obj).__jclass__
cdef inline jclass get_class(cls):
    """Gets the jclass of a JavaClass"""
    return (<JClass>cls.__jclass__).clazz
cdef inline jobject get_object(obj):
    """Gets the jobject of an Object"""
    return (<JObject>obj.__object__).obj
cdef inline jint get_identity(obj):
    """Gets the identity (hash code) of an Object"""
    cdef jvalue val
    val.l = (<JObject>obj.__object__).obj
    return jenv().CallStaticInt(SystemDef.clazz, SystemDef.identityHashCode, &val)

cdef inline Py_ssize_t tuple_put(tuple t, Py_ssize_t i, x) except -1:
    Py_INCREF(x)
    PyTuple_SET_ITEM(t, i, x)
    return i + 1
cdef inline Py_ssize_t tuple_put_class(tuple t, Py_ssize_t i, JClass x) except -1:
    Py_INCREF(x)
    PyTuple_SET_ITEM(t, i, get_java_class(x.name))
    return i + 1
    
class JavaClass(type):
    """
    The type of Java objects in Python. This defines lookups for static attributes and
    constructors. It does not represent a java.lang.Class object directly.

    To use it, either be a sub-class of Object or have __metaclass__ = JavaClass in the class
    definition. In both cases you need the attribute __java_class_name__ which gives the fully
    qualified clsas name.

    The actual subclasses and interfaces are added as necessary and do not need to be specified
    manually. The superclass is placed in the MRU wherever the Object (or other non-interface
    class) is placed in the MRU.
    """
    def __new__(cls, name, tuple bases, dict attr):
        if '__java_class_name__' not in attr: raise NameError('Java object classes must define __java_class_name__')
        cdef unicode cn = to_unicode(attr['__java_class_name__'])
        del attr['__java_class_name__']
        if cn in classes: raise TypeError("Class '%s' is already defined"%cn)
        
        cdef JEnv env = jenv()
        cdef JClass clazz = JClass.named(env, cn)
        if clazz.declaring_class is None: add_class_to_packages(cn)

        cdef JClass c = clazz, s = clazz.superclass
        name = clazz.simple_name
        
        attr['__jclass__'] = clazz
        attr['__module__'] = clazz.package_name
        cdef list qual_names = []
        while c is not None:
            qual_names.append(protection_prefix(c.modifiers) + c.simple_name)
            c = c.declaring_class
        attr['__qualname__'] = '.'.join(reversed(qual_names))

        cdef bint is_objarr = clazz.is_array() and not clazz.component_type.is_primitive()
        cdef bint has_super = s is not None
        cdef tuple old_bases = tuple(b for b in bases if not isinstance(b, JavaClass))
        cdef Py_ssize_t n_bases = is_objarr + has_super + len(old_bases) + len(clazz.interfaces), i = 0
        cdef list interfaces = clazz.interfaces[:]
        cdef tuple new_bases = PyTuple_New(n_bases)
        for b in bases:
            if not isinstance(b, JavaClass):
                i = tuple_put(new_bases, i, b)
            elif not (<JClass>b.__jclass__).is_interface():
                if not has_super: raise TypeError("Invalid base classes for '%s' - two super-classes specified"%cn)
                if is_objarr: i = tuple_put(new_bases, i, JObjectArray)
                i = tuple_put_class(new_bases, i, s)
                has_super = False
            elif b.__jclass__ in interfaces:
                c = interfaces.pop(interfaces.index(b.__jclass__))
                tuple_put_class(new_bases, i, c)
        if has_super:
            if is_objarr: i = tuple_put(new_bases, i, JObjectArray)
            i = tuple_put_class(new_bases, i, s)
        for c in interfaces: i = tuple_put_class(new_bases, i, c)

        IF PY_VERSION < PY_VERSION_3: name = utf8(name)
        obj = type.__new__(cls, name, new_bases, attr)
        classes[cn] = obj
        return obj
    def __getattr__(self, _name):
        """
        Get a static Java 'attribute' - either a field value, nested classes, or a JavaMethods. The
        member must be on this class and not a superclass or interface since static members do not
        inherit.
        """
        cdef JClass clazz = self.__jclass__
        cdef unicode name = to_unicode(_name)
        if name in clazz.static_methods:
            return JavaStaticMethods(self, name)
        elif name in clazz.static_classes:
            return get_java_class((<JClass>clazz.static_classes[name]).name)
        elif name not in clazz.static_fields: raise AttributeError(name)
        cdef JField field = clazz.static_fields[name]
        return field.type.funcs.get_static(jenv(), clazz.clazz, field.id)
    def __setattr__(self, _name, value):
        """Set a static Java field value for this class"""
        cdef JClass clazz = self.__jclass__
        cdef unicode name = to_unicode(_name)
        if name not in clazz.static_fields: raise AttributeError(name)
        cdef JField field = clazz.static_fields[name]
        if field.is_final(): raise AttributeError("Can't set final static field")
        field.type.funcs.set_static(jenv(), clazz.clazz, field, value)
    def __call__(self, *args):
        """
        Call a Java constructor for this class based on the arguments and return a new instance of
        this class. Constructors do not inherit so must be declared on this class. If there is
        issues with ambiguous constructors then use [...] on the class to select a constructor.
        """
        cdef JClass clazz = self.__jclass__
        if clazz.is_abstract(): raise TypeError('Cannot instantiate abstract classes')
        if hasattr(self, '__self__'): args = (self.__self__,) + tuple(args)
        cdef JEnv env = jenv()
        cdef jvalue* jargs
        cdef JMethod m = conv_method_args(env, clazz.constructors, args, &jargs)
        try: return create_java_object(env.NewObject(clazz.clazz, m.id, jargs))
        finally: free_method_args(env, m, jargs)
    def __getitem__(self, ind):
        """
        Several operations go through the class[x] operator, depending on the type of `x`
            integer:
                create an array with the length of `x` and the component type of `class`
                filled with nulls
                e.g.   arr = java.lang.Object[5]

            colon:
                get the class of the array with the component type of `class`
                e.g.   clazz = java.lang.Object[:]

            ellipsis:
                get all signatures of constructors for `class`
                e.g.   for sig in java.lang.Object[...]: print(sig)

            signature:
                get a particular JavaConstructor for a signature, which can be given as a single
                string, a tuple of strings - one for each argument, or a tuple of JavaClass
                objects for the argument types
        """
        cdef JClass clazz = self.__jclass__
        cdef Py_ssize_t n
        try: n = PyNumber_Index(ind)
        except TypeError: pass
        else:
            if n < 0: raise ValueError('Cannot create negative sized array')
            return JObjectArray.new_raw(jenv(), n, clazz)
        if PySlice_Check(ind):
            if ind.start is not None or ind.stop is not None or ind.step is not None:
                raise ValueError('Slice can only be an empty slice')
            return get_java_class(JObjectArray.get_objarr_classname(clazz))
        if clazz.is_abstract(): raise TypeError('Cannot instantiate abstract classes')
        cdef list ctors = clazz.constructors
        cdef bint bound = hasattr(self, '__self__')
        if ind is Ellipsis:
            sigs = tuple((<JMethod>m).param_sig() for m in ctors)
            if bound: sigs = tuple(sig[sig.index(';')+1:] for sig in sigs)
            return sigs
        if not bound: return JavaConstructor(self, select_method(ctors, ind))
        return JavaConstructor(self, select_method(ctors, ind, clazz.declaring_class.name), self.__self__)
    def __iter__(self):
        """Iterates over the constructors of the class, yielding JavaConstructor objects."""
        cdef JClass clazz = self.__jclass__
        if clazz.is_abstract(): raise TypeError('Cannot instantiate abstract classes')
        cdef JMethod m
        for m in clazz.constructors: yield JavaConstructor(self, m, getattr(self, '__self__', None))
    def __dir__(self):
        """Lists all static members of the class."""
        cdef JClass c = self.__jclass__
        return list(KEYS(c.static_fields)) + list(KEYS(c.static_methods)) + list(KEYS(c.static_classes))
    IF PY_VERSION < PY_VERSION_3:
        def __unicode__(self): return repr(self)
        def __str__(self): return utf8(repr(self))
    ELSE:
        def __str__(self): return repr(self)
    def __repr__(self):
        cdef JClass clazz = self.__jclass__, c
        cdef Py_ssize_t n
        if clazz.is_primitive(): return "<Java primitive class '%s'>"%clazz.name
        if clazz.is_array():
            c = clazz.component_type; n = 1
            while c.is_array(): c = c.component_type; n += 1
            if n == 1: return "<Java array of '%s'>"%c.name
            else:      return "<Java %dd array of '%s'>"%(n,c.name)
        typ = 'enum' if clazz.is_enum() else ('interface' if clazz.is_interface() else 'class')
        x = (typ,clazz.name)
        if clazz.is_anonymous(): return "<Java anonymous %s '%s'>"%x
        if clazz.is_local():     return "<Java local %s '%s'>"%x
        if clazz.is_member():
            if clazz.is_static(): return "<Java nested %s '%s'>"%x
            if not hasattr(self, '__self__'): return "<Java inner %s '%s'>"%x
            return "<Java inner %s '%s' bound to instance of '%s' at 0x%08x>"%(x+
                    (get_object_class(self.__self__).name, get_identity(self.__self__)))
        return "<Java %s '%s'>"%x
    def _bind_inner_class_to(self, obj):
        cdef JClass clazz = self.__jclass__
        if (not clazz.is_member() or clazz.is_static() or clazz.declaring_class is None or
            not jenv().IsInstanceOf(get_object(obj), clazz.declaring_class.clazz)): raise TypeError()
        cdef dict attr = dict(self.__dict__)
        attr['__self__'] = obj
        return type.__new__(JavaClass, self.__name__, self.__bases__, attr)
    def __subclasscheck__(cls, subcls):
        # This only helps include bound inner classes properly, otherwise it is not necessary
        return hasattr(subcls, '__jclass__') and isinstance(subcls.__jclass__, JClass) and (<JClass>subcls.__jclass__).is_sub(jenv(), cls.__jclass__)
    def __instancecheck__(cls, inst):
        # This only helps include bound inner classes properly, otherwise it is not necessary
        return any(cls.__subclasscheck__(c) for c in {type(inst), inst.__class__})
        
cdef class JavaMethods(object):
    """
    Collection of Java methods for an object. This object can be called in which case the method
    that is selected based on the arguments or an exception is raised if one cannot be picked
    un-ambiguously. The methods can be iterated over, generating JavaMethod objects. The property
    `signatures` gives a list of all of the available method signatures. The properties `__self__`
    and `__name__` give the Object the method is from and the name of the method. Using the indexer
    (x[]) allows accessing a particular method by signature, where the signature can be given as a
    single string (including or not including the return type), a tuple of strings - one for each
    argument, or a tuple of JavaClass objects for the argument types. Additionally, the ellipsis
    (x[...]) can be used to get a list of all of the signuatres.
    """
    _JavaMethod = JavaMethod # class-static variable for which type of method to create
    cdef readonly object __self__ # java.lang.Object STATIC: JavaClass
    cdef readonly unicode __name__
    cdef list methods
    def __cinit__(self, obj, unicode name):
        self.__self__ = obj
        self.__name__ = name
        self.methods = self._get_methods(obj, name)
    def _get_methods(self, obj, unicode name):
        cdef JClass cls = get_object_class(obj)
        cdef JMethod m
        cdef list methods = []
        cdef set sigs = set()
        while cls is not None:
            if name in cls.fields or name in cls.classes or name in cls.static_methods or name in cls.static_fields or name in cls.static_classes:
                break
            for m in cls.methods.get(name, []):
                sig = m.param_sig()
                if not m.is_abstract() and sig not in sigs:
                    methods.append(m)
                    sigs.add(sig)
            cls = cls.superclass
        return methods
    def __call__(self, *args, withgil=True):
        cdef JEnv env = jenv()
        cdef jvalue* jargs = NULL
        cdef JMethod m = conv_method_args(env, self.methods, args, &jargs)
        try: return m.return_type.funcs.call(env, get_object(self.__self__), m.id, jargs, withgil)
        finally: free_method_args(env, m, jargs)
    def __iter__(self):
        cdef JMethod m
        for m in self.methods: yield self._JavaMethod(self.__self__, m)
    def __getitem__(self, key):
        if key == Ellipsis: return tuple((<JMethod>m).sig() for m in self.methods)
        return self._JavaMethod(self.__self__, select_method(self.methods, key))
    property signatures:
        def __get__(self): return tuple((<JMethod>m).sig() for m in self.methods)
    def __repr__(self):
        cdef unicode cname = get_object_class(self.__self__).name, name = self.__name__
        return ("<Java methods %s.%s of instance at 0x%08x>") % (cname, name, get_identity(self.__self__))
cdef class JavaStaticMethods(JavaMethods):
    """
    Like JavaMethods but for a group of static methods. `__self__` is a JavaClass instead of an
    object. Generates JavaStaticMethod objects when iteratored or indexed instead of JavaMethod
    objects.
    """
    # __self__ is a JavaClass
    _JavaMethod = JavaStaticMethod
    def _get_methods(self, obj, unicode name): return (<JClass>obj.__jclass__).static_methods[name]
    def __call__(self, *args, withgil=True):
        cdef JEnv env = jenv()
        cdef jvalue* jargs = NULL
        cdef JMethod m = conv_method_args(env, self.methods, args, &jargs)
        try: return m.return_type.funcs.call_static(env, get_class(self.__self__), m.id, jargs, withgil)
        finally: free_method_args(env, m, jargs)
    def __repr__(self):
        cdef unicode cname = (<JClass>self.__self__.__jclass__).name, name = self.__name__
        return "<Java static methods %s.%s>" % (cname, name)

cdef class JavaMethod(object):
    """A single Java method."""
    cdef readonly object __self__ # java.lang.Object
    cdef JMethod method
    def __cinit__(self, obj, JMethod method):
        self.__self__ = obj
        self.method = method
    def __call__(self, *args, withgil=True):
        cdef JEnv env = jenv()
        cdef JMethod m = self.method
        cdef jvalue* jargs = conv_method_args_single(env, m, args)
        try: m.return_type.funcs.call(env, get_object(self.__self__), m.id, jargs, withgil)
        finally: free_method_args(env, self.method, jargs)
    property __name__:
        def __get__(self): return self.method.name
    property signature:
        def __get__(self): return self.method.sig()
    property return_type:
        def __get__(self): return get_java_class(self.method.return_type.name)
    property param_types:
        def __get__(self): return tuple(get_java_class((<JClass>p).name) for p in self.method.param_types)
    def __repr__(self):
        cdef JClass clazz = get_object_class(self.__self__)
        cdef unicode cname = clazz.name, name = self.method.name, psig = self.method.param_sig()
        return ("<Java method %s.%s(%s) of instance at 0x%08x>") % (cname, name, psig, get_identity(self.__self__))
cdef class JavaStaticMethod(JavaMethod):
    """A single Java static method."""
    # __self__ is a JavaClass
    def __call__(self, *args, withgil=True):
        cdef JEnv env = jenv()
        cdef JMethod m = self.method
        cdef jvalue* jargs = conv_method_args_single(env, m, args)
        try: m.return_type.funcs.call_static(env, get_class(self.__self__), m.id, jargs, withgil)
        finally: free_method_args(env, self.method, jargs)
    def __repr__(self):
        cdef JClass clazz = self.__self__.__jclass__
        cdef unicode cname = clazz.name, name = self.method.name, psig = self.method.param_sig()
        return "<Java static method %s.%s(%s)>" % (cname, name, psig)

cdef class JavaConstructor(object):
    """A single Java Constructor for a class. Supports being bound to an enclosing class."""
    cdef readonly object im_class  # JavaClass
    cdef readonly object __self__  # Object - the enclosing class, if any
    cdef JMethod method
    def __cinit__(self, clazz, JMethod method, obj=None):
        self.im_class = clazz
        self.__self__ = obj
        self.method = method
    def __call__(self, *args, withgil=True):
        cdef JEnv env = jenv()
        if self.__self__ is not None: args = (self.__self__,) + tuple(args)
        cdef jvalue* jargs = conv_method_args_single(env, self.method, args)
        try: return create_java_object(env.NewObject(get_class(self.im_class), self.method.id, jargs, withgil))
        finally: free_method_args(env, self.method, jargs)
    property __name__:
        def __get__(self): return (<JClass>self.im_class.__jclass__).simple_name
    property signature:
        def __get__(self):
            cdef unicode sig = self.method.param_sig()
            if self.__self__ is not None: sig = sig[sig.index(';')+1:]
            return sig
    property param_types:
        def __get__(self):
            cdef list pt = self.method.param_types
            if self.__self__ is not None: pt = pt[1:]
            return tuple(get_java_class((<JClass>p).name) for p in pt)
    def __repr__(self):
        cdef JClass clazz = self.im_class.__jclass__
        if self.__self__ is None: return "<Java constructor %s(%s)>" % (clazz.name, self.signature)
        return "<Java constructor %s(%s) enclosed by %s>" % (clazz.name, self.signature, self.__self__)

from contextlib import contextmanager
@contextmanager
def synchronized(obj):
    """
    Enter a synchronized block for a Java object. This is to be used as:
    
        with synchronized(obj):
            ...
        
    Which is equivilent to the Java code:
    
        synchronized(obj) {
            ...
        }
    """
    if not isinstance(obj, get_java_class('java.lang.Object')):
        raise ValueError('Can only synchronize on Java objects')
    cdef JEnv env = jenv()
    cdef jobject o = get_object(obj)
    assert o is not NULL
    env.MonitorEnter(o)
    try: yield
    finally: env.MonitorExit(o)

def unbox(o):
    """
    Unboxes a Java Object to a primitive. If the given object is not a Java Object or not a
    primitive wrapper, it is returned as-is.
    """
    if not isinstance(o, get_java_class('java.lang.Object')): return o
    cdef unicode cn = get_object_class(o).name
    if   cn == 'java.lang.Boolean':   return o._jcall0('booleanValue')
    elif cn == 'java.lang.Byte':      return o._jcall0('byteValue')
    elif cn == 'java.lang.Character': return o._jcall0('charValue')
    elif cn == 'java.lang.Short':     return o._jcall0('shortValue')
    elif cn == 'java.lang.Integer':   return o._jcall0('intValue')
    elif cn == 'java.lang.long':      return o._jcall0('longValue')
    elif cn == 'java.lang.Float':     return o._jcall0('floatValue')
    elif cn == 'java.lang.Double':    return o._jcall0('doubleValue')
    else: return o

cdef int init_templates(JEnv env) except -1:
    global classes; classes = dict()

    ### Core Classes and Interfaces ###
    class Object(object): # implements collections.Hashable
        """
        The base class of all Java objects. Interfaces are not subclasses of this, but any
        non-interface is.
        """
        __metaclass__ = JavaClass
        __java_class_name__ = 'java.lang.Object'
        def __new__(cls, JObject obj, *args):
            if obj is None: raise ValueError()
            o = super(Object, cls).__new__(cls)
            o.__dict__['__object__'] = obj
            return o
        def _jgetattr(self, unicode name):
            cdef JClass cls = get_object_class(self), c
            cdef JField f
            while cls is not None:
                if name in cls.methods: return JavaMethods(self, name)
                f = cls.fields.get(name)
                if f is not None: return f.type.funcs.get(jenv(), get_object(self), f.id)
                c = cls.classes.get(name)
                if c is not None: return get_java_class(c.name)._bind_inner_class_to(self)
                if name in cls.static_methods or name in cls.static_fields or name in cls.static_classes:
                    raise AttributeError('Cannot access static members from an instance of the class')
                cls = cls.superclass
            raise AttributeError(name)
        def _jsetattr(self, unicode name, value):
            cdef JClass c = get_object_class(self)
            cdef JField f
            while c is not None:
                f = c.fields.get(name)
                if f is not None:
                    if f.is_final(): raise AttributeError('Cannot set final field')
                    f.type.funcs.set(jenv(), get_object(self), f, value)
                    return
                if name in c.static_fields:
                    raise AttributeError('Cannot set static fields from an instance of the class')
                if name in c.static_methods or name in c.static_classes or name in c.methods or name in c.classes:
                    raise AttributeError(name)
                c = c.superclass
            raise AttributeError(name)
        def _jcall0(self, unicode name):
            """
            Calls a method that takes 0 arguments without the abstraction of a JavaMethods. Takes
            several shortcuts including ignoring shadowing and var-args (but does do inheritance).
            Does not release the GIL.
            """
            cdef JClass c = get_object_class(self)
            cdef list methods
            cdef JMethod m
            while c is not None:
                methods = c.methods.get(name, [])
                for m in methods:
                    if len(m.param_types) != 0: continue
                    return m.return_type.funcs.call(jenv(), get_object(self), m.id, NULL, True)
                c = c.superclass
            raise AttributeError(name)
        def _jcall1(self, unicode name, object arg):
            """
            Calls a method that takes 1 argument without the abstraction of a JavaMethod. Takes
            several shortcuts including ignoring shadowing and var-args (but does do inheritance).
            Does not release the GIL.
            """
            cdef JClass c = get_object_class(self), p
            cdef list methods
            cdef JMethod m
            cdef JEnv env = jenv()
            cdef P2JQuality qual = FAIL
            cdef P2JConvert conv
            cdef jvalue val
            while c is not None:
                methods = c.methods.get(name, [])
                for m in methods:
                    if len(m.param_types) != 1: continue
                    p = m.param_types[0]
                    conv = p2j_lookup(env, arg, p, &qual)
                    if qual <= FAIL: continue
                    conv.convert_val(env, arg, &val)
                    try: return m.return_type.funcs.call(env, get_object(self), m.id, &val, True)
                    finally:
                        if not p.is_primitive() and val.l is not NULL: env.DeleteLocalRef(val.l)
                c = c.superclass
            raise AttributeError(name)
        def _jcall1prim(self, unicode name, object arg):
            """
            Calls a method that takes 1 primitive argument without the abstraction of a JavaMethod.
            Takes several shortcuts including ignoring shadowing and var-args (but does do
            inheritance). Does not release the GIL.
            """
            cdef JClass c = get_object_class(self), p
            cdef list methods
            cdef JMethod m
            cdef JEnv env = jenv()
            cdef P2JQuality qual = FAIL
            cdef P2JConvert conv
            cdef jvalue val
            while c is not None:
                methods = c.methods.get(name, [])
                for m in methods:
                    if len(m.param_types) != 1 or not m.param_types[0].is_primitive(): continue
                    conv = p2j_prim_lookup(env, arg, m.param_types[0], &qual)
                    if qual <= FAIL: continue
                    conv.convert_val(env, arg, &val)
                    return m.return_type.funcs.call(env, get_object(self), m.id, &val, True)
                c = c.superclass
            raise AttributeError(name)
        def _jcall1obj(self, unicode name, object arg):
            """
            Calls a method that takes 1 reference argument without the abstraction of a JavaMethod.
            Takes several shortcuts including ignoring shadowing and var-args (but does do
            inheritance). Does not release the GIL.
            """
            cdef JClass c = get_object_class(self), p
            cdef list methods
            cdef JMethod m
            cdef JEnv env = jenv()
            cdef P2JQuality qual = FAIL
            cdef P2JConvert conv
            cdef jvalue val
            while c is not None:
                methods = c.methods.get(name, [])
                for m in methods:
                    if len(m.param_types) != 1 or m.param_types[0].is_primitive(): continue
                    conv = p2j_obj_lookup(env, arg, m.param_types[0], &qual)
                    if qual <= FAIL: continue
                    conv.convert_val(env, arg, &val)
                    try: return m.return_type.funcs.call(env, get_object(self), m.id, &val, True)
                    finally:
                        if val.l is not NULL: env.DeleteLocalRef(val.l)
                c = c.superclass
            raise AttributeError(name)
        def _jcall2(self, unicode name, object arg1, object arg2):
            """
            Calls a method that takes 2 arguments without the abstraction of a JavaMethod. Takes
            several shortcuts including ignoring shadowing and var-args (but does do inheritance).
            Does not release the GIL.
            """
            cdef JClass c = get_object_class(self), p1, p2
            cdef list methods
            cdef JMethod m
            cdef JEnv env = jenv()
            cdef P2JQuality qual1 = FAIL, qual2 = FAIL
            cdef P2JConvert conv1, conv2
            cdef jvalue val[2]
            while c is not None:
                methods = c.methods.get(name, [])
                for m in methods:
                    if len(m.param_types) != 2: continue
                    p1 = m.param_types[0]
                    conv1 = p2j_lookup(env, arg1, p1, &qual1)
                    if qual1 <= FAIL: continue
                    p2 = m.param_types[0]
                    conv2 = p2j_lookup(env, arg2, p2, &qual2)
                    if qual2 <= FAIL: continue
                    conv1.convert_val(env, arg1, &val[0])
                    conv2.convert_val(env, arg2, &val[1])
                    try: return m.return_type.funcs.call(env, get_object(self), m.id, val, True)
                    finally:
                        if not p1.is_primitive() and val[0].l is not NULL: env.DeleteLocalRef(val[0].l)
                        if not p2.is_primitive() and val[1].l is not NULL: env.DeleteLocalRef(val[1].l)
                c = c.superclass
            raise AttributeError(name)
        def __getattr__(self, name):
            """
            Get a Java 'attribute' - either a field value, inner class, or a JavaMethods. All of
            these can be inherited.
            """
            return self._jgetattr(to_unicode(name))
        def __setattr__(self, name, value):
            """
            Set a Java field value. The field value can be on this class or any of the
            superclasses.
            """
            self._jsetattr(to_unicode(name), value)
        def __dir__(self):
            cdef JClass c = get_object_class(self)
            cdef set members = set(), shadowed = set()
            while c is not None:
                members.update(KEYS(c.methods) - shadowed)
                members.update(KEYS(c.fields)  - shadowed)
                members.update(KEYS(c.classes) - shadowed)
                shadowed.update(KEYS(c.static_methods))
                shadowed.update(KEYS(c.static_fields))
                shadowed.update(KEYS(c.static_classes))
                c = c.superclass
            return list(members)
        def __hash__(self): return jenv().CallIntMethod(get_object(self), ObjectDef.hashCode, NULL, True)
        def __eq__(self, other):
            cdef jvalue val
            val.l = get_object(other)
            return jenv().CallBooleanMethod(get_object(self), ObjectDef.equals, &val, True)
        def __ne__(self, other):
            cdef jvalue val
            val.l = get_object(other)
            return not jenv().CallBooleanMethod(get_object(self), ObjectDef.equals, &val, True)
        IF PY_VERSION < PY_VERSION_3:
            def __unicode__(self): return jenv().CallObjectMethod(get_object(self), ObjectDef.toString, NULL, True)
            def __str__(self): return utf8(jenv().CallObjectMethod(get_object(self), ObjectDef.toString, NULL, True))
        ELSE:
            def __str__(self): return jenv().CallObjectMethod(get_object(self), ObjectDef.toString, NULL, True)
        def __repr__(self):
            return ("<Java instance of '%s' at 0x%08x>") % (get_object_class(self).name, get_identity(self))

    class AutoCloseable(object):
        __metaclass__ = JavaClass
        __java_class_name__ = 'java.lang.AutoCloseable'
        def __enter__(self): return self
        def __exit__(self ,type, value, traceback): self._jcall0('close'); return False
    class Cloneable(object):
        __metaclass__ = JavaClass
        __java_class_name__ = 'java.lang.Cloneable'
        def __copy__(self): return jenv().CallObjectMethod(get_object(self), ObjectDef.clone, NULL, True)
    class Comparable(object):
        __metaclass__ = JavaClass
        __java_class_name__ = 'java.lang.Comparable'
        def __lt__(self, other): return self._jcall1('compareTo', other) < 0
        def __gt__(self, other): return self._jcall1('compareTo', other) > 0
        def __le__(self, other): return self._jcall1('compareTo', other) <= 0
        def __ge__(self, other): return self._jcall1('compareTo', other) >= 0
    class String(Object):
        # This class template is never usuable since Strings are ALWAYS converted to unicode objects
        __java_class_name__ = 'java.lang.String'
        def __getitem__(self, i): return self._jcall1('charAt', i)
        def __len__(self): return self._jcall0('length')
        IF PY_VERSION < PY_VERSION_3:
            def __unicode__(self): return jenv().pystr(<jstring>get_object(self), False)
            def __str__(self): return utf8(jenv().pystr(<jstring>get_object(self), False))
        ELSE:
            def __str__(self): return jenv().pystr(<jstring>get_object(self), False)
    class Enum(Object):
        __java_class_name__ = 'java.lang.Enum'
        def __int__(self): return self._jcall0('ordinal')
        def __long__(self): return self._jcall0('ordinal')
        def __repr__(self):
            return ("<Java enum value %s.%s>") % (get_object_class(self).name, self._jcall0('name'))


    ### Exceptions ###
    def cls(cn, base): return JavaClass.__new__(JavaClass, cn, (Object,base), {'__java_class_name__':cn})
    class Throwable(Object, Exception):
        __java_class_name__ = 'java.lang.Throwable'
        IF PY_VERSION < PY_VERSION_3:
            def __unicode__(self): return self._jcall0('getLocalizedMessage')
            def __str__(self): return utf8(self._jcall0('getLocalizedMessage'))
        ELSE:
            def __str__(self): return self._jcall0('getLocalizedMessage')

    # One-to-one and obvious mappings
    cls('java.lang.ArithmeticException',      ArithmeticError)
    cls('java.lang.AssertionError',           AssertionError)
    cls('java.lang.InterruptedException',     KeyboardInterrupt)
    cls('java.lang.LinkageError',             ImportError)
    cls('java.lang.VirtualMachineError',      SystemError)
    cls('java.lang.OutOfMemoryError',         MemoryError)
    cls('java.lang.StackOverflowError',       OverflowError)
    cls('java.lang.IllegalArgumentException', ValueError) # a few others have ValueError as well
    cls('java.util.NoSuchElementException',   StopIteration)
    cls('java.io.IOException',                IOError)
    cls('java.io.IOError',                    IOError)
    cls('java.io.EOFException',               EOFError)
    # NameError
    cls('java.lang.ClassNotFoundException',  NameError)
    cls('java.lang.TypeNotPresentException', NameError)
    # AttributeError
    cls('java.lang.IllegalAccessException',  AttributeError)
    cls('java.lang.NoSuchFieldError',        AttributeError)
    cls('java.lang.NoSuchMethodError',       AttributeError)
    # ValueError
    cls('java.lang.EnumConstantNotPresentException', ValueError)
    cls('java.lang.NullPointerException',            ValueError)
    # TypeError
    cls('java.lang.ArrayStoreException',                  TypeError)
    cls('java.lang.ClassCastException',                   TypeError)
    cls('java.lang.InstantiationException',               TypeError)
    cls('java.lang.IllegalStateException',                TypeError)
    cls('java.lang.UnsupportedOperationException',        TypeError)
    cls('java.lang.reflect.UndeclaredThrowableException', TypeError)
    # IndexError
    cls('java.lang.IndexOutOfBoundsException',  IndexError)
    cls('java.lang.NegativeArraySizeException', IndexError)
    cls('java.util.EmptyStackException',        IndexError)
    cls('java.nio.BufferOverflowException',     IndexError)
    cls('java.nio.BufferUnderflowException',    IndexError)
    # UnicodeError
    cls('java.nio.charset.CharacterCodingException', UnicodeError)
    cls('java.nio.charset.CoderMalfunctionError',    UnicodeError)
    cls('java.io.UTFDataFormatException',            UnicodeError)
    cls('java.io.UnsupportedEncodingException',      UnicodeError)
    cls('java.io.CharConversionException',           UnicodeError)

    return 0

cdef int dealloc_templates(JEnv env) except -1:
    global classes; classes = None; return 0
    # Note: ABCMeta uses a weak reference set for subclass registrations, no need to deregister
JVM.add_init_hook(init_templates)
JVM.add_dealloc_hook(dealloc_templates)
