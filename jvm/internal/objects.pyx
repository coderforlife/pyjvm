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
    template       - class decorator for defining Java Class templates

Public classes:
    JavaClass         - the type of all Java objects, not a replacement for java.lang.Class
    JavaMethods       - wrapper for a collection of same-named Java methods of an object
    JavaStaticMethods - wrapper for a collection of same-named Java static methods of a class
    JavaMethod        - wrapper for a single Java method of an object
    JavaStaticMethod  - wrapper for a single Java static method of a class
    JavaConstructor   - wrapper for a single Java contructor for a class

Internal functions:
    create_java_object - creates a Python object from a JObject
    get_object_class   - gets the JClass from a Python object
    get_class          - gets the jclass from a JavaClass
    get_object         - gets the jobject from a Python object
    java_id            - gets the identity of a Java object
    
TODO:
    inner classes automatically know the outer class instance and incorporate it into the constructor
"""

from __future__ import absolute_import

include "version.pxi"

from cpython.number cimport PyNumber_Index
from cpython.bytes  cimport PyBytes_Check
from cpython.slice  cimport PySlice_Check
from cpython.unicode cimport PyUnicode_AsUTF8String

from .utils cimport to_unicode, KEYS

from .jni cimport jclass, jobject, jfieldID, jvalue, jstring, jint

from .core cimport JClass, JObject, JMethod, JField, JEnv, jenv, SystemDef, ObjectDef, class_exists, protection_prefix
from .core cimport jvm_add_init_hook, jvm_add_dealloc_hook
from .convert cimport P2JQuality, FAIL, P2JConvert, p2j_lookup, p2j_prim_lookup, p2j_obj_lookup
from .convert cimport select_method, conv_method_args, conv_method_args_single, free_method_args
from .arrays cimport JObjectArray
from .packages cimport add_class_to_packages

cdef dict classes = None # class-name (using . and without L;) -> JavaClass
cpdef get_java_class(unicode classname):
    """Gets the unique JavaClass for a given class name"""
    if classname in classes: return classes[classname]
    return JavaClass.__new__(JavaClass, classname, (), {'__java_class_name__':classname})

cdef dict java_objects = None # TODO: would like this to contain weak references but that causes problems
cpdef create_java_object(JEnv env, JObject _obj):
    """Creates a Java Object wrapper around the given object. The object is deleted."""
    cdef jobject obj = _obj.obj
    cdef JClass clazz = JClass.get(env, env.GetObjectClass(obj))
    
    # Check if this object has a self-id and is already created
    # TODO: could use a is_synthetic check to possibly make this faster...
    cdef jfieldID self_fid = env.GetFieldID_(clazz.clazz, u'__pyjvm_self$$', u'J'), fid
    if self_fid is not NULL:
        self_id = env.GetLongField(obj, self_fid)
        if self_id != 0: return java_objects[self_id]
    
    # Get the Java class
    cls = get_java_class(clazz.name)
    
    # Check if this is an inner class
    if clazz.is_member() and not clazz.is_static() and clazz.declaring_class is not None:
        fid = env.GetFieldID_(clazz.clazz, u'this$0', clazz.declaring_class.sig())
        if fid is not NULL: cls = cls._bind_inner_class_to(env.GetObjectField(obj, fid))
    
    # Create the Python wrapper
    py_obj = cls.__new__(cls, _obj)
    if self_fid is not NULL:
        # Save the id of this class so that in the future it always loads this instance
        self_id = id(py_obj)
        java_objects[self_id] = py_obj
        env.env[0].SetLongField(env.env, obj, self_fid, self_id)
        env.check_exc()
    return py_obj
    
cdef inline new_java_object(JEnv env, jclass clazz, JMethod m, jvalue* jargs, bint withgil):
    try: return create_java_object(env, JObject.create(env, env.NewObject(clazz, m.id, jargs, withgil)))
    finally: free_method_args(env, m, jargs)
    
def template(class_name, *bases):
    """Makes the decorated class a Java Class template with the given class name."""
    # Mostly inspired from six.add_metaclass
    def java_class_wrapper(cls):
        nonlocal bases
        cls.__java_class_name__ = to_unicode(class_name)
        attr = cls.__dict__.copy()
        slots = attr.get('__slots__')
        if slots is not None:
            if isinstance(slots, str): slots = [slots]
            for slots_var in slots: attr.pop(slots_var)
        attr.pop('__dict__', None)
        attr.pop('__weakref__', None)
        if len(bases) == 0 or len(cls.__bases__) != 1 or cls.__bases__[0] != object:
            bases += cls.__bases__
        return JavaClass.__new__(JavaClass, cls.__name__, bases, attr)
    return java_class_wrapper

class JavaClass(type):
    """
    The type of Java objects in Python. This defines lookups for static attributes and
    constructors. It does *not* represent a java.lang.Class object directly.

    To use it, either be a sub-class of Object or have the JavaClass metaclass. In both cases
    you need the attribute __java_class_name__ which gives the fully qualified clsas name. These
    can be accomplished by using the @template decorator. For non-interfaces the base classes
    must be supplied to the decorator instead of the class itself.

    The actual subclasses and interfaces are added as necessary and do not need to be specified
    manually. The superclass is placed in the MRU wherever the Object (or other non-interface
    class) is placed in the MRU.
    """
    def __new__(cls, name, tuple bases, dict attr):
        if '__java_class_name__' not in attr: raise NameError(u'Java object classes must define __java_class_name__')
        cdef unicode cn = to_unicode(attr['__java_class_name__'])
        del attr['__java_class_name__']
        if cn in classes: raise TypeError(u"Class '%s' is already defined"%cn)
        
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
        attr['__qualname__'] = u'.'.join(reversed(qual_names))

        cdef bint is_objarr = clazz.is_array() and not clazz.component_type.is_primitive()
        cdef bint has_super = s is not None
        cdef tuple old_bases = tuple(b for b in bases if not isinstance(b, JavaClass))
        cdef list interfaces = clazz.interfaces[:]
        cdef list new_bases = []
        for b in bases:
            if not isinstance(b, JavaClass): new_bases.append(b)
            elif not (<JClass>b.__jclass__).is_interface():
                if not has_super: raise TypeError(u"Invalid base classes for '%s' - two super-classes specified"%cn)
                if is_objarr: new_bases.append(JObjectArray)
                new_bases.append(get_java_class(s.name))
                has_super = False
            elif b.__jclass__ in interfaces:
                c = interfaces.pop(interfaces.index(b.__jclass__))
                new_bases.append(get_java_class(c.name))
        if has_super:
            if is_objarr: new_bases.append(JObjectArray)
            new_bases.append(get_java_class(s.name))
        for c in interfaces: new_bases.append(get_java_class(c.name))
        
        IF PY_VERSION < PY_VERSION_3: name = PyUnicode_AsUTF8String(name)
        if len(new_bases) > 1 and object in new_bases: new_bases.remove(object)
        obj = type.__new__(cls, name, tuple(new_bases), attr)
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
        if field.is_final(): raise AttributeError(u"Can't set final static field")
        field.type.funcs.set_static(jenv(), clazz.clazz, field, value)
    def __call__(self, *args, withgil=False):
        """
        Call a Java constructor for this class based on the arguments and return a new instance of
        this class. Constructors do not inherit so must be declared on this class. If there is
        issues with ambiguous constructors then use [...] on the class to select a constructor.
        """
        cdef JClass clazz = self.__jclass__
        if clazz.is_interface(): raise TypeError(u'Cannot instantiate interfaces')
        if clazz.is_abstract(): raise TypeError(u'Cannot instantiate abstract classes')
        if hasattr(self, '__self__'): args = (self.__self__,) + tuple(args)
        cdef JEnv env = jenv()
        cdef jvalue* jargs
        cdef JMethod m = conv_method_args(env, clazz.constructors, args, &jargs)
        return new_java_object(env, clazz.clazz, m, jargs, withgil)
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
            if n < 0: raise ValueError(u'Cannot create negative sized array')
            return JObjectArray.new_raw(jenv(), n, clazz)
        if PySlice_Check(ind):
            if ind.start is not None or ind.stop is not None or ind.step is not None:
                raise ValueError(u'Slice can only be an empty slice')
            return get_java_class(JObjectArray.get_objarr_classname(clazz))
        if clazz.is_interface(): raise TypeError(u'Cannot instantiate interfaces')
        if clazz.is_abstract(): raise TypeError(u'Cannot instantiate abstract classes')
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
        if clazz.is_interface(): raise TypeError(u'Cannot instantiate interfaces')
        if clazz.is_abstract(): raise TypeError(u'Cannot instantiate abstract classes')
        cdef JMethod m
        for m in clazz.constructors: yield JavaConstructor(self, m, getattr(self, '__self__', None))
    def __dir__(self):
        """Lists all static members of the class."""
        cdef JClass c = self.__jclass__
        return list(KEYS(c.static_fields)) + list(KEYS(c.static_methods)) + list(KEYS(c.static_classes))
    IF PY_VERSION < PY_VERSION_3:
        def __unicode__(self): return repr(self)
        def __str__(self): return PyUnicode_AsUTF8String(repr(self))
    ELSE:
        def __str__(self): return repr(self)
    def __repr__(self):
        cdef JClass clazz = self.__jclass__, c
        cdef Py_ssize_t n
        if clazz.is_primitive(): return u"<Java primitive class '%s'>"%clazz.name
        if clazz.is_array():
            c = clazz.component_type; n = 1
            while c.is_array(): c = c.component_type; n += 1
            if n == 1: return u"<Java array of '%s'>"%c.name
            else:      return u"<Java %dd array of '%s'>"%(n,c.name)
        typ = u'enum' if clazz.is_enum() else (u'interface' if clazz.is_interface() else u'class')
        x = (typ,clazz.name)
        if clazz.is_anonymous(): return u"<Java anonymous %s '%s'>"%x
        if clazz.is_local():     return u"<Java local %s '%s'>"%x
        if clazz.is_member():
            if clazz.is_static(): return u"<Java nested %s '%s'>"%x
            if not hasattr(self, '__self__'): return u"<Java inner %s '%s'>"%x
            return u"<Java inner %s '%s' bound to instance of '%s' at 0x%08x>"%(x+
                    (get_object_class(self.__self__).name, java_id(get_object(self.__self__))))
        return u"<Java %s '%s'>"%x
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
            if name in cls.fields or name in cls.classes: break
            for m in cls.methods.get(name, []):
                sig = m.param_sig()
                if not m.is_abstract() and sig not in sigs:
                    methods.append(m)
                    sigs.add(sig)
            cls = cls.superclass
        return methods
    def __call__(self, *args, withgil=False):
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
        return u"<Java methods %s.%s of instance at 0x%08x>" % (cname, name, java_id(get_object(self.__self__)))
cdef class JavaStaticMethods(JavaMethods):
    """
    Like JavaMethods but for a group of static methods. `__self__` is a JavaClass instead of an
    object. Generates JavaStaticMethod objects when iteratored or indexed instead of JavaMethod
    objects.
    """
    # __self__ is a JavaClass
    _JavaMethod = JavaStaticMethod
    def _get_methods(self, obj, unicode name): return (<JClass>obj.__jclass__).static_methods[name]
    def __call__(self, *args, withgil=False):
        cdef JEnv env = jenv()
        cdef jvalue* jargs = NULL
        cdef JMethod m = conv_method_args(env, self.methods, args, &jargs)
        try: return m.return_type.funcs.call_static(env, get_class(self.__self__), m.id, jargs, withgil)
        finally: free_method_args(env, m, jargs)
    def __repr__(self):
        cdef unicode cname = (<JClass>self.__self__.__jclass__).name, name = self.__name__
        return u"<Java static methods %s.%s>" % (cname, name)

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
        return u"<Java method %s.%s(%s) of instance at 0x%08x>" % (cname, name, psig, java_id(get_object(self.__self__)))
cdef class JavaStaticMethod(JavaMethod):
    """A single Java static method."""
    # __self__ is a JavaClass
    def __call__(self, *args, withgil=False):
        cdef JEnv env = jenv()
        cdef JMethod m = self.method
        cdef jvalue* jargs = conv_method_args_single(env, m, args)
        try: m.return_type.funcs.call_static(env, get_class(self.__self__), m.id, jargs, withgil)
        finally: free_method_args(env, self.method, jargs)
    def __repr__(self):
        cdef JClass clazz = self.__self__.__jclass__
        cdef unicode cname = clazz.name, name = self.method.name, psig = self.method.param_sig()
        return u"<Java static method %s.%s(%s)>" % (cname, name, psig)

cdef class JavaConstructor(object):
    """A single Java Constructor for a class. Supports being bound to an enclosing class."""
    cdef readonly object im_class  # JavaClass
    cdef readonly object __self__  # Object - the enclosing class, if any
    cdef JMethod method
    def __cinit__(self, clazz, JMethod method, obj=None):
        self.im_class = clazz
        self.__self__ = obj
        self.method = method
    def __call__(self, *args, withgil=False):
        cdef JEnv env = jenv()
        if self.__self__ is not None: args = (self.__self__,) + tuple(args)
        cdef jvalue* jargs = conv_method_args_single(env, self.method, args)
        return new_java_object(env, get_class(self.im_class), self.method, jargs, withgil)
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
        if self.__self__ is None: return u"<Java constructor %s(%s)>" % (clazz.name, self.signature)
        return u"<Java constructor %s(%s) enclosed by %s>" % (clazz.name, self.signature, self.__self__)

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
    if not isinstance(obj, get_java_class(u'java.lang.Object')):
        raise ValueError(u'Can only synchronize on Java objects')
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
    if not isinstance(o, get_java_class(u'java.lang.Object')): return o
    cdef unicode cn = get_object_class(o).name
    if   cn == u'java.lang.Boolean':   return o._jcall0(u'booleanValue')
    elif cn == u'java.lang.Byte':      return o._jcall0(u'byteValue')
    elif cn == u'java.lang.Character': return o._jcall0(u'charValue')
    elif cn == u'java.lang.Short':     return o._jcall0(u'shortValue')
    elif cn == u'java.lang.Integer':   return o._jcall0(u'intValue')
    elif cn == u'java.lang.long':      return o._jcall0(u'longValue')
    elif cn == u'java.lang.Float':     return o._jcall0(u'floatValue')
    elif cn == u'java.lang.Double':    return o._jcall0(u'doubleValue')
    else: return o

cdef int init_objects(JEnv env) except -1:
    global classes, java_objects
    classes = dict()
    java_objects = dict()

    ### Core Classes and Interfaces ###
    @template(u'java.lang.Object')
    class Object(object): # implements collections.Hashable
        """
        The base class of all Java objects. Interfaces are not subclasses of this, but any
        non-interface is.
        """
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
                    raise AttributeError(u'Cannot access static members from an instance of the class')
                cls = cls.superclass
            raise AttributeError(name)
        def _jsetattr(self, unicode name, value):
            cdef JClass c = get_object_class(self)
            cdef JField f
            while c is not None:
                f = c.fields.get(name)
                if f is not None:
                    if f.is_final(): raise AttributeError(u'Cannot set final field')
                    f.type.funcs.set(jenv(), get_object(self), f, value)
                    return
                if name in c.static_fields:
                    raise AttributeError(u'Cannot set static fields from an instance of the class')
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
            if name in self.__dict__ or name in self.__class__.__dict__:
                self.__dict__[name] = value
            else:
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
            def __str__(self): return PyUnicode_AsUTF8String(jenv().CallObjectMethod(get_object(self), ObjectDef.toString, NULL, True))
        ELSE:
            def __str__(self): return jenv().CallObjectMethod(get_object(self), ObjectDef.toString, NULL, True)
        def __repr__(self):
            return u"<Java instance of '%s' at 0x%08x>" % (get_object_class(self).name, java_id(get_object(self)))

    @template(u'java.lang.AutoCloseable')
    class AutoCloseable(object):
        def __enter__(self): return self
        def __exit__(self ,type, value, traceback): self._jcall0(u'close'); return False
    @template(u'java.lang.Cloneable')
    class Cloneable(object):
        def __copy__(self): return jenv().CallObjectMethod(get_object(self), ObjectDef.clone, NULL, False)
    @template(u'java.lang.Comparable')
    class Comparable(object):
        def __lt__(self, other): return self._jcall1(u'compareTo', other) < 0
        def __gt__(self, other): return self._jcall1(u'compareTo', other) > 0
        def __le__(self, other): return self._jcall1(u'compareTo', other) <= 0
        def __ge__(self, other): return self._jcall1(u'compareTo', other) >= 0
    @template(u'java.lang.String', Object)
    class String(object):
        # This class template is never usuable since Strings are ALWAYS converted to unicode objects
        def __getitem__(self, i): return self._jcall1(u'charAt', i)
        def __len__(self): return self._jcall0(u'length')
        IF PY_VERSION < PY_VERSION_3:
            def __unicode__(self): return jenv().pystr(<jstring>get_object(self), False)
            def __str__(self): return PyUnicode_AsUTF8String(jenv().pystr(<jstring>get_object(self), False))
        ELSE:
            def __str__(self): return jenv().pystr(<jstring>get_object(self), False)
    @template(u'java.lang.Enum', Object)
    class Enum(object):
        def __int__(self): return self._jcall0(u'ordinal')
        def __long__(self): return self._jcall0(u'ordinal')
        def __repr__(self):
            return (u"<Java enum value %s.%s>") % (get_object_class(self).name, self._jcall0(u'name'))


    ### Exceptions ###
    def cls(cn, base):
        if class_exists(env, cn): # some of these exceptions are part of newer java versions so skip them
            return JavaClass.__new__(JavaClass, cn, (Object,base), {'__java_class_name__':cn})
    @template(u'java.lang.Throwable', Object, Exception)
    class Throwable(object):
        IF PY_VERSION < PY_VERSION_3:
            def __unicode__(self): return self._jcall0(u'getLocalizedMessage')
            def __str__(self): return PyUnicode_AsUTF8String(self._jcall0(u'getLocalizedMessage'))
        ELSE:
            def __str__(self): return self._jcall0(u'getLocalizedMessage')

    # One-to-one and obvious mappings
    cls(u'java.lang.ArithmeticException',      ArithmeticError)
    cls(u'java.lang.AssertionError',           AssertionError)
    cls(u'java.lang.InterruptedException',     KeyboardInterrupt)
    cls(u'java.lang.LinkageError',             ImportError)
    cls(u'java.lang.VirtualMachineError',      SystemError)
    cls(u'java.lang.OutOfMemoryError',         MemoryError)
    IF PY_VERSION >= PY_VERSION_3_5:
        cls(u'java.lang.StackOverflowError',   RecursionError)
    ELSE:
        cls(u'java.lang.StackOverflowError',   RuntimeError)
    cls(u'java.lang.IllegalArgumentException', ValueError) # a few others have ValueError as well
    cls(u'java.lang.UnsupportedOperationException', NotImplementedError)
    cls(u'java.util.NoSuchElementException',   StopIteration)
    cls(u'java.io.IOException',                IOError)
    cls(u'java.io.IOError',                    IOError)
    cls(u'java.io.EOFException',               EOFError)
    # NameError
    cls(u'java.lang.NoClassDefFoundError',    NameError)
    cls(u'java.lang.ClassNotFoundException',  NameError)
    cls(u'java.lang.TypeNotPresentException', NameError)
    # AttributeError
    cls(u'java.lang.IllegalAccessException',  AttributeError)
    cls(u'java.lang.NoSuchFieldError',        AttributeError)
    cls(u'java.lang.NoSuchMethodError',       AttributeError)
    # ValueError
    cls(u'java.lang.EnumConstantNotPresentException', ValueError)
    cls(u'java.lang.NullPointerException',            ValueError)
    # TypeError
    cls(u'java.lang.ArrayStoreException',                  TypeError)
    cls(u'java.lang.ClassCastException',                   TypeError)
    cls(u'java.lang.InstantiationException',               TypeError)
    cls(u'java.lang.IllegalStateException',                TypeError)
    cls(u'java.lang.reflect.UndeclaredThrowableException', TypeError)
    # IndexError
    cls(u'java.lang.IndexOutOfBoundsException',  IndexError)
    cls(u'java.lang.NegativeArraySizeException', IndexError)
    cls(u'java.util.EmptyStackException',        IndexError)
    cls(u'java.nio.BufferOverflowException',     IndexError)
    cls(u'java.nio.BufferUnderflowException',    IndexError)
    # UnicodeError
    cls(u'java.util.IllegalFormatCodePointException', UnicodeError)
    cls(u'java.nio.charset.CharacterCodingException', UnicodeError)
    cls(u'java.nio.charset.CoderMalfunctionError',    UnicodeError)
    cls(u'java.io.UTFDataFormatException',            UnicodeError)
    cls(u'java.io.UnsupportedEncodingException',      UnicodeError)
    cls(u'java.io.CharConversionException',           UnicodeError)

    return 0

cdef int dealloc_objects(JEnv env) except -1:
    global classes, java_objects; classes = java_objects = None; return 0
    # Note: ABCMeta uses a weak reference set for subclass registrations, no need to deregister

jvm_add_init_hook(init_objects, 2)
jvm_add_dealloc_hook(dealloc_objects, 2)
