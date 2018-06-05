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

Conversions between Java and Python
-----------------------------------
The extensible conversion system for converting between Java and Python objects. Defines the common
converters along with the conversion system itself.

Public functions:
    register_converter - registers a new Python to Java converter

Internal enums:
    P2JQuality - the quality rating of a potential Python to Java conversion

Internal classes:
    P2JConvert - the class containing a Python to Java conversion

Internal functions:
    object2py        - converts a non-primitive Java object to Python object
    py2object        - converts a Python object to a Java object of a target class
    py2object_py     - as above, but accessible from Python
    reg_conv_cy      - registers a new Python to Java converter that is written in Cython
    p2j_lookup       - lookup the best converter for a Python to Java conversion 
    p2j_prim_lookup  - lookup the best converter for a Python to Java primitive conversion
    p2j_obj_lookup   - lookup the best converter for a Python to Java object conversion
    select_method    - select a method from a list of signatures based on a signature given
    conv_method_args - select a method from a list and convert method arguments based on arguments given
    conv_method_args_single - convert method arguments for a single Java method (not a list)
    free_method_args - free converted method arguments

Internal function types:
    p2j_check - function that checks the quality of a Python-to-Java conversion
    p2j_conv  - convert a Python object to a Java object, return a new local reference or NULL
    p2j_prim  - functions that converts a Python object to a Java primitive

FUTURE:
    more conversions (they are listed under 'Future:' later on)
"""

from __future__ import absolute_import

include "version.pxi"

from libc.stdlib cimport malloc, free
from libc.string cimport memset
from cpython.long     cimport PyLong_AsLongLong, PyLong_AsUnsignedLongMask, PY_LONG_LONG
from cpython.float    cimport PyFloat_AsDouble
from cpython.object   cimport PyObject_IsTrue
from cpython.datetime cimport PyDate_Check, PyDateTime_Check, PyTZInfo_Check
from cpython.datetime cimport PyDateTime_GET_YEAR, PyDateTime_GET_MONTH, PyDateTime_GET_DAY, PyDateTime_DATE_GET_HOUR
from cpython.datetime cimport PyDateTime_DATE_GET_MINUTE, PyDateTime_DATE_GET_SECOND, PyDateTime_DATE_GET_MICROSECOND
cdef extern from "Python.h":
    PY_LONG_LONG PyLong_AsLongLongAndOverflow(object vv, int *overflow) except? -1
    
from .utils cimport is_string, to_unicode
from .unicode cimport from_utf8j

from .jni cimport jobject, jarray, jobjectArray, jvalue, jsize, jstring
from .jni cimport jboolean, jbyte, jchar, jshort, jint, jlong, jfloat, jdouble
from .jni cimport JNI_TRUE, JNI_FALSE, JBYTE_MIN, JBYTE_MAX, JCHAR_MAX, JSHORT_MIN, JSHORT_MAX, JINT_MIN, JINT_MAX, JLONG_MIN, JLONG_MAX, JFLOAT_MAX

from .core cimport JObject, JClass, JMethod, JField, JEnv, jenv
from .core cimport jvm_add_init_hook, jvm_add_dealloc_hook
from .core cimport box_boolean, box_byte, box_char, box_short, box_int, box_long, box_float, box_double
from .objects cimport get_java_class, create_java_object, get_object_class, get_class, get_object


########## Java to Python Conversion ##########
# Java primitives are dealt with directly by the functions in JEnv
# void                 -> None (only void returning functions)
# boolean              -> bool
# byte/short/int/long  -> int/long
# float/double         -> float
# char                 -> unicode (single character)
# --------------------------------------------------
# Java objects are mostly just wrapped in a Python object (which, using template classes,
# automatically gives the objects lots of Python-like features, including for arrays). Only the
# null value and java.lang.String objects are converted (to None and unicodes). This does mean
# that the end user can never get an actual java.lang.String object - ever.

cdef object object2py(JEnv env, jobject obj):
    """Convert a Java object to a Python object. The jobject reference is deleted."""
    # NOTE: if this function is updated, JEnv.__object2py needs to be updated as well
    if obj is NULL: return None # null -> None
    cdef JClass clazz = JClass.get(env, env.GetObjectClass(obj))
    if clazz.name == u'java.lang.String': return env.pystr(<jstring>obj)
    return create_java_object(obj)


########## Python to Java General Conversion Classes/Functions ##########
# Enum Types
# P2JQuality      quality of matches of a type conversion
#
# Function Types
# p2j_check       check that a Python object can be converted to a specific Java class that
#                 returns a p2j_conv that can perform the conversion along with a quality rating
# p2j_conv        convert a Python object to a Java object, return a new local reference or NULL
# p2j_prim        functions that converts a Python object to a Java primitive
#
# Class Types
# P2J             wraps a Python type, Java Class, and a p2j_check or equivilent Python function
# P2JConvert      wraps a p2j_conv, p2j_prim, and Python functions like p2j_conv
#
# Functions
# p2j_lookup      runs either p2j_prim_lookup or p2j_obj_lookup depending on target type
# p2j_prim_lookup finds a function for converting a Python object to a particular Java primitive
# p2j_obj_lookup  finds a function for converting a Python object to a particular Java class

def py2object_py(JEnv env, object x, JClass target):
    """
    Python-accessible version of the function above, returnning a JObject instead of a jobject.
    """
    return JObject.wrap_local(env, py2object(env, x, target))

cdef inline P2JQuality AVG_QUAL(P2JQuality a, P2JQuality b): return <P2JQuality>((a+b)//2)
ctypedef P2JConvert (*p2j_any_lookup)(JEnv env, object x, JClass target, P2JQuality* q)

cdef class P2J(object):
    cdef object pytype
    cdef JClass jtype
    cdef p2j_check check_cy
    cdef object    check_py
    @staticmethod
    cdef inline P2J create_cy(JEnv env, pytype, unicode cn, p2j_check check):
        cdef P2J p2j = P2J(pytype, None if cn is None else JClass.named(env, cn))
        p2j.check_cy = check
        return p2j
    @staticmethod
    cdef inline P2J create_py(pytype, JClass jtype, object check):
        cdef P2J p2j = P2J(pytype, jtype)
        p2j.check_py = check
        return p2j
    def __cinit__(self, pytype, JClass jtype):
        self.pytype = pytype
        self.jtype = jtype
    cdef inline P2JConvert check(self, JEnv env, object x, JClass jclazz, object java_class, P2JQuality* q):
        if ((self.pytype is not None and not isinstance(x, self.pytype)) or 
            (self.jtype is not None and not self.jtype.is_sub(env, jclazz))): return None
        if self.check_cy is not NULL:
            q[0] = FAIL if self.jtype is None else (PERFECT if self.jtype.is_same(env, jclazz) else GREAT)
            return self.check_cy(env, x, jclazz, q)
        assert self.check_py is not None
        cdef object conv
        cdef P2JQuality qual
        qual,conv = self.check_py(x, java_class)
        q[0] = qual
        return P2JConvert.create_py(conv)


########## Python to Java Primitive Conversion ##########
# Java primitives each have their own method. Additionally, since the Python wrappers for the
# boxing classes have __bool__, __int__, __long__, and __float__ as appropiate, these
# inherently support auto-unboxing.
# bool        -> boolean                  (includes anything implementing __bool__/__nonzero__)
# int/long    -> byte/char/short/int/long (includes anything implementing __int__/__long__)
# float       -> float/double             (includes anything implementing __float__)
# bytes/bytearray -> byte                 (length 1 only)
# unicode     -> char                     (length 1 only)
cdef int __p2j_prim_boolean(JEnv env, object x, jvalue* val) except -1: val[0].z = PyObject_IsTrue(x); return 0
cdef int __p2j_prim_byte (JEnv env, object x, jvalue* val) except -1: val[0].b = <jbyte>PyLong_AsUnsignedLongMask(x); return 0
cdef int __p2j_prim_char (JEnv env, object x, jvalue* val) except -1: val[0].c = <jchar>PyLong_AsUnsignedLongMask(x); return 0
cdef int __p2j_prim_short(JEnv env, object x, jvalue* val) except -1: val[0].s = <jshort>PyLong_AsUnsignedLongMask(x); return 0
cdef int __p2j_prim_int  (JEnv env, object x, jvalue* val) except -1: val[0].i = <jint>PyLong_AsUnsignedLongMask(x); return 0
cdef int __p2j_prim_long (JEnv env, object x, jvalue* val) except -1: val[0].j = <jlong>PyLong_AsLongLong(x); return 0
cdef int __p2j_prim_float (JEnv env, object x, jvalue* val) except -1: val[0].f = <jfloat>PyFloat_AsDouble(x); return 0
cdef int __p2j_prim_double(JEnv env, object x, jvalue* val) except -1: val[0].d = <jdouble>PyFloat_AsDouble(x); return 0
cdef int __p2j_prim_byte_ind(JEnv env, object x, jvalue* val) except -1: val[0].c = <jchar>x[0]; return 0
cdef int __p2j_prim_byte_ord(JEnv env, object x, jvalue* val) except -1: val[0].c = <jchar>ord(x); return 0
cdef int __p2j_prim_char_ord(JEnv env, object x, jvalue* val) except -1: val[0].c = <jbyte>ord(x); return 0
cdef int __p2j_prim_overflow(JEnv env, object x, jvalue* val) except -1: raise OverflowError()
cdef P2JConvert p2j_prim_byte, p2j_prim_byte_ind, p2j_prim_byte_ord, p2j_prim_short, p2j_prim_int, p2j_prim_long
cdef P2JConvert p2j_prim_boolean, p2j_prim_char, p2j_prim_char_ord, p2j_prim_float, p2j_prim_double,
cdef P2JConvert p2j_prim_overflow
cdef inline bint is_bool_like(x):
    """
    This checks if a Python is bool-like. Does not check directly for the bool or java.lang.Boolean
    type. Also, PyObject_IsTrue thinks most objects are true even if they should not be convertible
    to bool (it will report any non-None object as True unless it is Sized and has a length of 0).
    
    We instead check for the __bool__ or __nonzero__ methods and require that object to either be
    not Sized or exactly length 1 (for Numpy scalar of boolean). Regular Sized objects in Python
    (list, tuple, dict) don't have __bool__ or __nonzero__ so they fail.
    """
    from collections import Sized
    return (hasattr(x, '__bool__') or hasattr(x, '__nonzero__')) and (not isinstance(x, Sized) or len(x) == 1)
cdef inline P2JConvert _p2j_prim_long(object x, jlong mn, jlong mx, P2JQuality* q, P2JConvert conv):
    cdef int overflow = 0
    cdef jlong out = PyLong_AsLongLongAndOverflow(x, &overflow)
    if overflow == 0 and mn <= out <= mx:
        q[0] = GREAT
        return conv
    q[0] = BAD
    return p2j_prim_overflow
cdef P2JConvert p2j_prim_lookup(JEnv env, object x, JClass target, P2JQuality* q):
    from numbers import Real
    q[0] = PERFECT
    try:
        if target.name == u'boolean':
            if not isinstance(x, bool):
                if isinstance(x, get_java_class(u'java.lang.Boolean')): q[0] = GREAT
                elif is_bool_like(x): q[0] = GOOD
                else: q[0] = FAIL
            return p2j_prim_boolean
        elif target.name == u'byte':
            if isinstance(x, bytearray):
                if len(x) != 1: q[0] = FAIL
                return p2j_prim_byte_ind
            if isinstance(x, bytes):
                if len(x) != 1: q[0] = FAIL
                return p2j_prim_byte_ord
            return _p2j_prim_long(x, JBYTE_MIN, JBYTE_MAX, q, p2j_prim_byte)
        elif target.name == u'char':
            if isinstance(x, unicode):
                if len(x) != 1: q[0] = FAIL
                return p2j_prim_char_ord
            q[0] = GOOD
            return _p2j_prim_long(x, 0, JCHAR_MAX, q, p2j_prim_char)
        elif target.name == u'short': return _p2j_prim_long(x, JSHORT_MIN, JSHORT_MAX, q, p2j_prim_short)
        elif target.name == u'int':   return _p2j_prim_long(x, JINT_MIN,   JINT_MAX,   q, p2j_prim_int)
        elif target.name == u'long':  return _p2j_prim_long(x, JLONG_MIN,  JLONG_MAX,  q, p2j_prim_long)
        elif target.name == u'float' and isinstance(x, Real):
            if -JFLOAT_MAX <= PyFloat_AsDouble(x) <= JFLOAT_MAX:
                q[0] = GREAT if get_java_class(u'java.lang.Float') else GOOD; return p2j_prim_float
            q[0] = BAD; return p2j_prim_overflow
        elif target.name == u'double' and isinstance(x, Real): return p2j_prim_double
    except TypeError, ValueError: pass
    q[0] = FAIL
    return None


########## Python to Java Object Conversion ##########
# Object           -> Object
# bool             -> Boolean       (includes anything implementing __bool__/__nonzero__)
# numbers.Integral -> Byte, Character, Short, Integer, Long
# numbers.Real     -> Float, Double
# unicode          -> Character, String, Enum value
# datetime.date    -> java.util.Date
#
# FUTURE:
# datetime.date     -> Calendar
# datetime.tzinfo   -> TimeZone

cdef P2JConvert p2j_obj_lookup(JEnv env, object x, JClass target, P2JQuality* best):
    """
    Performs a lookup of how to convert a Python object to a given target class (or a subclass).
    Returns a function for converting the Python object (or NULL if no conversion is possible)
    along with setting the quality of the returned match.
    """
    cdef P2JConvert best_conv = None, conv
    cdef P2JQuality quality = FAIL
    best[0] = FAIL
    cdef object target_jc = get_java_class(target.name)
    cdef P2J p2j
    for p2j in p2js:
        conv = p2j.check(env, x, target, target_jc, &quality)
        if quality > best[0]:
            best[0] = quality
            best_conv = conv
            if quality >= PERFECT: break
    return best_conv

def register_converter(type python_type, java_class, check_func):
    """
    Register a Python-to-Java converter.

      python_type the type of Python objects this converter can recieve, or None for all
      java_class  the class of Java objects this converter can output, or None for all
      check_func  the function that performs additional checks, it has the following signature:
                      quality,conv_func = check_func(pyobj, jclass)
                  where:
                    pyobj     a python object which is an instance of python_type
                    jclass    a JavaClass which we are trying to convert to, subclass of java_class
                    quality   a number from -1 (FAIL) to 100 (PERFECT), recommended values are
                                 -1 FAIL
                                 25 BAD
                                 50 GOOD
                                 75 GREAT
                                100 PERFECT
                    conv_func a function that takes a Python object and returns a Java Object
                              matching the jclass given

    When converting a Python object to a Java Object, several internal converters are used first,
    this includes None to null, unicode to String, basic types to boxed primitives, and more.

    As soon as a checker returns a PERFECT quality, the process is stopped and its converter is
    used. If no checkers give PERFECT, the best non-FAIL converter is used. If there are ties, the
    first one found with the best quality is used.
    """
    from .objects import JavaClass
    IF PY_VERSION >= PY_VERSION_3_2 or PY_VERSION < PY_VERSION_3:
        if not isinstance(java_class, JavaClass) or not callable(check_func): raise TypeError()
    ELSE:
        from collections import Callable
        if not isinstance(java_class, JavaClass) or not isinstance(check_func, Callable): raise TypeError()
    p2js.append(P2J.create_py(python_type, java_class.__jclass__, check_func))

cdef reg_conv_cy(JEnv env, pytype, unicode cn, p2j_check check):
    p2js.append(P2J.create_cy(env, pytype, cn, check))
    
cdef jobject __p2j_conv_none(JEnv env, object x) except? NULL: return NULL
cdef jobject __p2j_conv_object(JEnv env, object x) except? NULL: return env.NewLocalRef(get_object(x))
cdef jobject __p2j_conv_javaclass(JEnv env, object x) except? NULL: return env.NewLocalRef(get_class(x))

cdef jobject __p2j_conv_unicode(JEnv env, object x) except? NULL: return env.NewString(x)
cdef jobject __p2j_conv_char_ord_box(JEnv env, object x) except? NULL: return box_char(env, <jchar>ord(x))
IF PY_VERSION < PY_VERSION_3:
    cdef jobject __p2j_conv_bytes2str(JEnv env, object x) except? NULL: return env.NewString(from_utf8j(x))
cdef jobject __p2j_conv_byte_ord_box(JEnv env, object x) except? NULL: return box_byte(env, <jbyte>ord(x))
cdef jobject __p2j_conv_byte_ind_box(JEnv env, object x) except? NULL: return box_byte(env, <jbyte>x[0])

cdef jobject __p2j_conv_boolean_box(JEnv env, object x) except? NULL: return box_boolean(env, JNI_TRUE if PyObject_IsTrue(x) else JNI_FALSE)
cdef jobject __p2j_conv_byte_box(JEnv env, object x) except? NULL: return box_byte(env, <jbyte>PyLong_AsUnsignedLongMask(x))
cdef jobject __p2j_conv_char_box(JEnv env, object x) except? NULL: return box_char(env, <jchar>PyLong_AsUnsignedLongMask(x))
cdef jobject __p2j_conv_short_box(JEnv env, object x) except? NULL: return box_short(env, <jshort>PyLong_AsUnsignedLongMask(x))
cdef jobject __p2j_conv_int_box(JEnv env, object x) except? NULL: return box_int(env, <jint>PyLong_AsUnsignedLongMask(x))
cdef jobject __p2j_conv_long_box(JEnv env, object x) except? NULL: return box_long(env, <jlong>PyLong_AsLongLong(x))
cdef jobject __p2j_conv_float_box(JEnv env, object x) except? NULL: return box_float(env, <jfloat>PyFloat_AsDouble(x))
cdef jobject __p2j_conv_double_box(JEnv env, object x) except? NULL: return box_double(env, <jdouble>PyFloat_AsDouble(x))
cdef jobject __p2j_conv_overflow(JEnv env, object x) except? NULL: raise OverflowError()
    
cdef jobject __p2j_conv_date(JEnv env, object x) except? NULL:
    import calendar
    cdef Py_ssize_t timestamp
    if isinstance(x, PyDateTime_Check(x)):
        timestamp = calendar.timegm(x.utctimetuple())
        timestamp *= 1000
        timestamp += PyDateTime_DATE_GET_MICROSECOND(x)//1000
    else:
        timestamp = calendar.timegm(x.timetuple())
        timestamp *= 1000
    return __p2j_conv_object(env, get_java_class(u'java.util.Date')(timestamp))
#cdef jobject __p2j_conv_calendar(JEnv env, object x) except? NULL:
#    import calendar
#    tz = x.tzinfo
#    Calendar = get_java_class(u'java.util.Calendar')
#    if tz is None:
#        cal = Calendar.getInstance()
#    else:
#        cal = Calendar.getInstance(TODO)
#    cal.set(PyDateTime_GET_YEAR(x), PyDateTime_GET_MONTH(x)-1, PyDateTime_GET_DAY(x),
#            PyDateTime_DATE_GET_HOUR(x), PyDateTime_DATE_GET_MINUTE(x), PyDateTime_DATE_GET_SECOND(x))
#    cal.set(Calendar.MILLISECOND, PyDateTime_DATE_GET_MICROSECOND(x)//1000)
#    return __p2j_conv_object(env, cal)
    
cdef P2JConvert p2j_conv_none, p2j_conv_object, p2j_conv_javaclass
cdef P2JConvert p2j_conv_unicode, p2j_conv_char_ord_box, p2j_conv_byte_ord_box, p2j_conv_byte_ind_box
IF PY_VERSION < PY_VERSION_3:
    cdef P2JConvert p2j_conv_bytes2str
cdef P2JConvert p2j_conv_boolean_box, p2j_conv_byte_box, p2j_conv_char_box, p2j_conv_short_box
cdef P2JConvert p2j_conv_int_box, p2j_conv_long_box, p2j_conv_float_box, p2j_conv_double_box, p2j_conv_overflow
cdef P2JConvert p2j_conv_date

cdef P2JConvert p2j_check_none(JEnv env, object x, JClass p, P2JQuality* q): q[0] = PERFECT; return p2j_conv_none
cdef P2JConvert p2j_check_object(JEnv env, object x, JClass p, P2JQuality* q):
    cdef JClass cls = get_object_class(x)
    if not cls.is_sub(env, p): return None
    q[0] = PERFECT if cls.is_same(env, p) else GREAT
    return p2j_conv_object
cdef P2JConvert p2j_check_enum(JEnv env, object x, JClass p, P2JQuality* q):
    cdef JField enum = p.static_fields.get(x)
    if enum is None and enum.type is not p: q[0] = FAIL; return None
    q[0] = GREAT
    return P2JConvert.create_py(lambda x:enum.type.funcs.get_static(jenv(), enum.type.clazz, enum.id))
cdef P2JConvert p2j_check_javaclass(JEnv env, object x, JClass p, P2JQuality* q): return p2j_conv_javaclass

cdef P2JConvert p2j_check_unicode(JEnv env, object x, JClass p, P2JQuality* q): return p2j_conv_unicode
cdef P2JConvert p2j_check_char_ord(JEnv env, object x, JClass p, P2JQuality* q):
    if len(x) != 1: q[0] = FAIL
    return p2j_conv_char_ord_box
cdef P2JConvert p2j_check_byte_ord(JEnv env, object x, JClass p, P2JQuality* q):
    if len(x) != 1: q[0] = FAIL
    return p2j_conv_byte_ord_box
cdef P2JConvert p2j_check_byte_ind(JEnv env, object x, JClass p, P2JQuality* q):
    if len(x) != 1: q[0] = FAIL
    return p2j_conv_byte_ind_box
IF PY_VERSION < PY_VERSION_3:
    cdef P2JConvert p2j_check_bytes2str(JEnv env, object x, JClass p, P2JQuality* q):
        q[0] = AVG_QUAL(PERFECT,GREAT) if p.is_same(env, JClass.named(env, u'java.lang.String')) else AVG_QUAL(GREAT,GOOD)
        return p2j_conv_bytes2str

cdef P2JConvert p2j_check_boolean(JEnv env, object x, JClass p, P2JQuality* q):
    q[0] = GREAT if isinstance(x, bool) else (GOOD if is_bool_like(x) else FAIL)
    return p2j_conv_boolean_box
cdef inline P2JConvert _p2j_check_long(object x, jlong mn, jlong mx, P2JQuality* q, P2JConvert conv):
    cdef int overflow = 0
    cdef jlong out
    try: out = PyLong_AsLongLongAndOverflow(x, &overflow)
    except TypeError: q[0] = FAIL; return None
    if overflow == 0 and mn <= out <= mx: return conv
    q[0] = BAD
    return p2j_conv_overflow
cdef P2JConvert p2j_check_byte(JEnv env, object x, JClass p, P2JQuality* q): q[0] = GREAT; return _p2j_check_long(x, JBYTE_MIN, JBYTE_MAX, q, p2j_conv_byte_box)
cdef P2JConvert p2j_check_char(JEnv env, object x, JClass p, P2JQuality* q): q[0] = GOOD; return _p2j_check_long(x, 0, JCHAR_MAX, q, p2j_conv_char_box)
cdef P2JConvert p2j_check_short(JEnv env, object x, JClass p, P2JQuality* q): q[0] = GREAT; return _p2j_check_long(x, JSHORT_MIN, JSHORT_MAX, q, p2j_conv_short_box)
cdef P2JConvert p2j_check_int(JEnv env, object x, JClass p, P2JQuality* q): q[0] = GREAT; return _p2j_check_long(x, JINT_MIN, JINT_MAX, q, p2j_conv_int_box)
cdef P2JConvert p2j_check_long(JEnv env, object x, JClass p, P2JQuality* q): q[0] = GREAT; return _p2j_check_long(x, JLONG_MIN, JLONG_MAX, q, p2j_conv_long_box)
cdef P2JConvert p2j_check_float(JEnv env, object x, JClass p, P2JQuality* q):
    try:
        if -JFLOAT_MAX <= PyFloat_AsDouble(x) <= JFLOAT_MAX:
            q[0] = GOOD
            return p2j_conv_float_box
        q[0] = BAD
        return p2j_conv_overflow
    except TypeError: q[0] = FAIL; return None
cdef P2JConvert p2j_check_double(JEnv env, object x, JClass p, P2JQuality* q):
    try: PyFloat_AsDouble(x)
    except TypeError: q[0] = FAIL; return None
    q[0] = GREAT
    return p2j_conv_double_box

cdef P2JConvert p2j_check_date(JEnv env, object x, JClass p, P2JQuality* q): return p2j_conv_date

cdef list p2js = None # list of P2J objects
cdef int init_p2j(JEnv env) except -1:
    global p2j_prim_byte, p2j_prim_short, p2j_prim_int, p2j_prim_long
    global p2j_prim_boolean, p2j_prim_char, p2j_prim_float, p2j_prim_double, p2j_prim_overflow
    p2j_prim_boolean  = P2JConvert.create_prim(__p2j_prim_boolean)
    p2j_prim_byte     = P2JConvert.create_prim(__p2j_prim_byte)
    p2j_prim_char     = P2JConvert.create_prim(__p2j_prim_char)
    p2j_prim_short    = P2JConvert.create_prim(__p2j_prim_short)
    p2j_prim_int      = P2JConvert.create_prim(__p2j_prim_int)
    p2j_prim_long     = P2JConvert.create_prim(__p2j_prim_long)
    p2j_prim_float    = P2JConvert.create_prim(__p2j_prim_float)
    p2j_prim_double   = P2JConvert.create_prim(__p2j_prim_double)
    p2j_prim_byte_ind = P2JConvert.create_prim(__p2j_prim_byte_ind)
    p2j_prim_byte_ord = P2JConvert.create_prim(__p2j_prim_byte_ord)
    p2j_prim_char_ord = P2JConvert.create_prim(__p2j_prim_char_ord)
    p2j_prim_overflow = P2JConvert.create_prim(__p2j_prim_overflow)

    global p2j_conv_none, p2j_conv_object, p2j_conv_javaclass
    global p2j_conv_unicode, p2j_conv_char_ord_box, p2j_conv_byte_ord_box, p2j_conv_byte_ind_box
    global p2j_conv_boolean_box, p2j_conv_byte_box, p2j_conv_char_box, p2j_conv_short_box
    global p2j_conv_int_box, p2j_conv_long_box, p2j_conv_float_box, p2j_conv_double_box, p2j_conv_overflow
    global p2j_conv_date
    p2j_conv_none          = P2JConvert.create_cy(__p2j_conv_none)
    p2j_conv_object        = P2JConvert.create_cy(__p2j_conv_object)
    p2j_conv_javaclass     = P2JConvert.create_cy(__p2j_conv_javaclass)
    p2j_conv_unicode       = P2JConvert.create_cy(__p2j_conv_unicode)
    p2j_conv_char_ord_box  = P2JConvert.create_cy(__p2j_conv_char_ord_box)
    p2j_conv_byte_ord_box  = P2JConvert.create_cy(__p2j_conv_byte_ord_box)
    p2j_conv_byte_ind_box  = P2JConvert.create_cy(__p2j_conv_byte_ind_box)
    p2j_conv_boolean_box   = P2JConvert.create_cy(__p2j_conv_boolean_box)
    p2j_conv_byte_box      = P2JConvert.create_cy(__p2j_conv_byte_box)
    p2j_conv_char_box      = P2JConvert.create_cy(__p2j_conv_char_box)
    p2j_conv_short_box     = P2JConvert.create_cy(__p2j_conv_short_box)
    p2j_conv_int_box       = P2JConvert.create_cy(__p2j_conv_int_box)
    p2j_conv_long_box      = P2JConvert.create_cy(__p2j_conv_long_box)
    p2j_conv_float_box     = P2JConvert.create_cy(__p2j_conv_float_box)
    p2j_conv_double_box    = P2JConvert.create_cy(__p2j_conv_double_box)
    p2j_conv_date          = P2JConvert.create_cy(__p2j_conv_date)
    p2j_conv_overflow      = P2JConvert.create_cy(__p2j_conv_overflow)
    IF PY_VERSION < PY_VERSION_3:
        global p2j_conv_bytes2str
        p2j_conv_bytes2str = P2JConvert.create_cy(__p2j_conv_bytes2str)

    import numbers, decimal, datetime
    from .objects import JavaClass
    global p2js; p2js = [
        P2J.create_cy(env, type(None), None, p2j_check_none),
        P2J.create_cy(env, get_java_class(u'java.lang.Object'), None, p2j_check_object),
        P2J.create_cy(env, JavaClass,         u'java.lang.Class',       p2j_check_javaclass),
        P2J.create_cy(env, unicode,           u'java.lang.Enum',        p2j_check_enum),
        P2J.create_cy(env, unicode,           u'java.lang.String',      p2j_check_unicode),
        P2J.create_cy(env, unicode,           u'java.lang.Character',   p2j_check_char_ord),
        P2J.create_cy(env, bytes,             u'java.lang.Byte',        p2j_check_byte_ord),
        P2J.create_cy(env, bytearray,         u'java.lang.Byte',        p2j_check_byte_ind),
        P2J.create_cy(env, None,              u'java.lang.Boolean',     p2j_check_boolean),
        
        P2J.create_cy(env, numbers.Integral,  u'java.lang.Byte',        p2j_check_byte),
        P2J.create_cy(env, numbers.Integral,  u'java.lang.Character',   p2j_check_char),
        P2J.create_cy(env, numbers.Integral,  u'java.lang.Short',       p2j_check_short),
        P2J.create_cy(env, numbers.Integral,  u'java.lang.Integer',     p2j_check_int),
        P2J.create_cy(env, numbers.Integral,  u'java.lang.Long',        p2j_check_long),
        P2J.create_cy(env, numbers.Real,      u'java.lang.Float',       p2j_check_float),
        P2J.create_cy(env, numbers.Real,      u'java.lang.Double',      p2j_check_double),
        P2J.create_cy(env, datetime.date,     u'java.util.Date',        p2j_check_date),
    ]
    IF PY_VERSION < PY_VERSION_3:
        p2js.append(P2J.create_cy(env, bytes, u'java.lang.String',      p2j_check_bytes2str))
        
cdef int dealloc_p2j(JEnv env) except -1: global p2js; p2js = None
jvm_add_init_hook(init_p2j, 3)
jvm_add_dealloc_hook(dealloc_p2j, 3)


########## Method Lookup ##########
# Lookup methods by the arguments and convert the arguments

cdef enum MATCH_TYPE: MATCH_ERR = -1, NO_MATCH = 0, MATCH = 1, MATCH_VA_DIRECT = 2, AMBIGUOUS_MATCH = 3
cdef MATCH_TYPE check_method(JEnv env, JMethod m, tuple args, P2JQuality* quals, list convs) except MATCH_ERR:
    """
    Lookup the converters for a method and the arguments to the method. Each converter is given a
    quality. Before calling this, the qualities and convs must be allocated with len(args)
    elements. This returns False if the method is impossible, True otherwise.
    """
    cdef Py_ssize_t i, n = len(args)
    cdef bint is_va = m.is_var_args
    cdef list ps = m.param_types # list of JClass
    cdef JClass va, p # var-args and param classes

    # Check the number of arguments
    if is_va and n < len(ps)-1 or not is_va and n != len(ps): return NO_MATCH

    # Separate out the var-args parameter and values
    if is_va:
        ps,va = ps[:-1], ps[-1]
        n = len(ps)

    # Matching the non-var-args params
    for i in xrange(n):
        p = ps[i]
        convs[i] = p2j_lookup(env, args[i], p, &quals[i])
        if quals[i] <= FAIL: return NO_MATCH

    if not is_va: return MATCH # no var-args, done!

    # Match var-args
    p = va.component_type
    cdef p2j_any_lookup lookup
    if p.is_primitive(): lookup = p2j_prim_lookup
    else:                lookup = p2j_obj_lookup
    if len(args) != n+1: # all arguments must each be one argument within the var-args
        for i in xrange(n,len(args)):
            convs[i] = lookup(env, args[i], p, &quals[i])
            if quals[i] <= FAIL: return NO_MATCH
        return MATCH
    # Possible that the argument is either a member of the var-args OR the entire var-args
    cdef P2JQuality va_qual = FAIL
    cdef P2JConvert va_conv = p2j_obj_lookup(env, args[n], va, &va_qual) # convert to array of var-args
    convs[n] = lookup(env, args[n], p, &quals[n]) # convert to var-arg
    if quals[n] > FAIL:
        if va_qual > FAIL: return AMBIGUOUS_MATCH
        # We got a single argument converted to a var-args
        # We want this to not be as good of a conversion for a non-var-args conversion of the same type
        quals[n] = <P2JQuality>max(quals[n]-5, 0)
        return MATCH
    elif va_qual <= FAIL: return NO_MATCH # both lookups failed
    # We were given the entire array of the var-args
    convs[n] = va_conv
    quals[n] = va_qual
    return MATCH_VA_DIRECT

cdef Py_ssize_t cmp_quals(P2JQuality* a, P2JQuality* b, Py_ssize_t n) except? -10000:
    if b[0] == FAIL: return 1
    cdef Py_ssize_t i, a_n_bad = 0, b_n_bad = 0, a_sum = 0, b_sum = 0
    for i in xrange(n):
        if a[i] <= BAD: a_n_bad += 1
        if b[i] <= BAD: b_n_bad += 1
        a_sum += a[i]; b_sum += b[i]
    if   a_n_bad < b_n_bad: return  1 # if the number of BAD items decreased, accept automatically
    elif a_n_bad > b_n_bad: return -1 # if the number of BAD items increased, reject automatically
    else: return a_sum - b_sum        # otherwise compare the sums of the qualities

cdef JMethod conv_method_args_0(JEnv env, list methods, jvalue** jargs):
    """
    Like conv_method_args but with 0 arguments given. Note that jargs may still need to be freed
    and a reference deleted if the returned method is a var-args method.
    """
    cdef JMethod m, best = None
    cdef bint ambiguous = False
    for m in methods:
        if len(m.param_types) == 0: jargs[0] = NULL; return m
        if len(m.param_types) == 1 and m.is_var_args:
            ambiguous = best is not None
            best = m
    if best is None: raise ValueError(u'No acceptable method found for the given paramters')
    if ambiguous: raise ValueError(u'Ambiguous method call')
    jargs[0] = __alloc_len0_array(env, <JClass>best.param_types[0])
    return best

cdef JMethod conv_method_args(JEnv env, list methods, tuple args, jvalue** _jargs):
    """
    Given a list of JMethods and the arguments to be passed to them, select the best method, if
    possible. Raises an expection if none of them could possibly work. Also allocates the jvalue
    arguments list and converts the arguments, returning a jvalue* that needs to be freed with
    free_method_args.
    """
    cdef Py_ssize_t i, n = len(args)

    # 0 argument case - fairly easy and allows us to make more assumptions later
    if n == 0: return conv_method_args_0(env, methods, _jargs)
    if n > 0x7FFFFFFF: raise OverflowError()
    
    cdef JMethod m, best = None
    cdef bint ambiguous = False
    cdef list convs = [None]*n, best_convs = [None]*n, temp_convs
    cdef P2JQuality* quals      = <P2JQuality*>malloc(n*sizeof(P2JQuality))
    cdef P2JQuality* best_quals = <P2JQuality*>malloc(n*sizeof(P2JQuality))
    cdef P2JQuality* temp_quals
    cdef MATCH_TYPE best_mtype = NO_MATCH, mtype
    if quals is NULL or best_quals is NULL:
        free(quals); free(best_quals)
        raise MemoryError()

    # Find the best method
    best_quals[0] = FAIL
    try:
        for m in methods:
            mtype = check_method(env, m, args, quals, convs)
            if mtype == NO_MATCH: continue
            i = cmp_quals(quals, best_quals, n)
            if i == 0: ambiguous = True
            elif i > 0:
                best = m
                best_mtype = mtype
                temp_quals = quals; quals = best_quals; best_quals = temp_quals
                temp_convs = convs; convs = best_convs; best_convs = temp_convs
                ambiguous = False
                if all(quals[i] >= PERFECT for i in xrange(n)): break
    finally: free(quals); free(best_quals)

    # No best found or ambiguous
    if best_mtype == NO_MATCH: raise ValueError(u'No acceptable method found for the given arguments')
    if ambiguous or best_mtype == AMBIGUOUS_MATCH: raise ValueError(u'Ambiguous method call')

    # Best found
    _jargs[0] = __conv_method_args(env, best, best_mtype, best_convs, args)
    return best

cdef jvalue* conv_method_args_single_0(JEnv env, JMethod method) except? NULL:
    """
    Like conv_method_args_single but with 0 arguments given. Note that jargs may still need to be
    freed and a reference deleted if the returned method is a var-args method.
    """
    if len(method.param_types) == 0: return NULL
    if len(method.param_types) != 1 or not method.is_var_args:
        raise ValueError(u'No acceptable method found for the given paramters')
    return __alloc_len0_array(env, <JClass>method.param_types[0])

cdef jvalue* conv_method_args_single(JEnv env, JMethod method, tuple args) except? NULL:
    """
    Given a single JMethod and the arguments to be passed to it converts the arguments, returning
    a jvalue* that needs to be freed with free_method_args. Raises an expection if none of them
    could possibly work.
    """
    cdef Py_ssize_t n = len(args)
    if n == 0: return conv_method_args_single_0(env, method)
    if n > 0x7FFFFFFF: raise OverflowError()
    cdef list convs = [None]*n
    cdef P2JQuality* quals = <P2JQuality*>malloc(n*sizeof(P2JQuality))
    cdef MATCH_TYPE mtype
    if quals is NULL: free(quals); raise MemoryError()
    try: mtype = check_method(env, method, args, quals, convs)
    finally: free(quals)
    if mtype == NO_MATCH: raise ValueError(u'Could not call the method with the given arguments')
    if mtype == AMBIGUOUS_MATCH: raise ValueError(u'Ambiguous method call')
    return __conv_method_args(env, method, mtype, convs, args)

cdef jvalue* __alloc_len0_array(JEnv env, JClass array_type) except NULL:
    cdef jvalue* jargs = <jvalue*>malloc(sizeof(jvalue))
    if jargs is NULL: raise MemoryError()
    cdef JClass ct = array_type.component_type
    try: jargs[0].l = ct.funcs.new_array(env, 0) if ct.is_primitive() else env.NewObjectArray(0, ct.clazz, NULL)
    except: free(jargs); raise
    return jargs

cdef jvalue* __conv_method_args(JEnv env, JMethod m, MATCH_TYPE mtype, list convs, tuple args) except NULL:
    # Allocate output
    cdef jsize i, n = <jsize>len(m.param_types)
    cdef bint is_va = m.is_var_args and mtype != MATCH_VA_DIRECT
    cdef jvalue* jargs = <jvalue*>malloc(n*sizeof(jvalue))
    if jargs is NULL: raise MemoryError()
    memset(jargs, 0, n*sizeof(jvalue))
    if is_va: n -= 1

    # Convert non-var-args
    try:
        for i in xrange(n): (<P2JConvert>convs[i]).convert_val(env, args[i], &jargs[i])
    except: free_method_args(env, m, jargs); raise
    if not is_va: return jargs

    # Convert var-args
    cdef JClass ct = (<JClass>m.param_types[n]).component_type
    try:
        if ct.is_primitive(): __conv_va_args_prim(env, args, convs, n, ct, jargs+n)
        else:                 __conv_va_args_obj (env, args, convs, n, ct, jargs+n)
    except: free_method_args(env, m, jargs); raise

    return jargs

cdef inline int __conv_va_args_prim(JEnv env, tuple args, list convs, jsize n, JClass clazz, jvalue* val) except -1:
    cdef jsize i, nva = <jsize>len(args)-n, itemsize = <jsize>clazz.funcs.itemsize
    cdef jarray arr
    val[0].l = arr = clazz.funcs.new_array(env, nva)
    cdef char* ptr = <char*>env.GetPrimitiveArrayCritical(arr, NULL)
    try:
        for i in xrange(nva): (<P2JConvert>convs[n+i]).convert_val(env, args[n+i], <jvalue*>(ptr+i*itemsize))
    finally: env.ReleasePrimitiveArrayCritical(arr, ptr, 0)

cdef inline int __conv_va_args_obj(JEnv env, tuple args, list convs, jsize n, JClass clazz, jvalue* val) except -1:
    cdef jsize i, nva = <jsize>len(args)-n
    cdef jobjectArray arr
    cdef jobject obj
    val[0].l = arr = env.NewObjectArray(nva, clazz.clazz, NULL)
    for i in xrange(nva):
        obj = (<P2JConvert>convs[n+i]).convert(env, args[n+i])
        try:     env.SetObjectArrayElement(arr, i, obj)
        finally: env.DeleteLocalRef(obj)

cdef inline int free_method_args(JEnv env, JMethod m, jvalue* jargs) except -1:
    cdef jsize i
    for i in xrange(len(m.param_types)):
        if not (<JClass>m.param_types[i]).is_primitive() and jargs[i].l is not NULL:
            env.DeleteLocalRef(jargs[i].l)
            jargs[i].l = NULL
    free(jargs)

cdef JMethod select_method(list methods, key, unicode pre=None):
    """
    Given a signature of a method, find the method that has a matching signature. The signature
    can be a unicode string of just the parameters or include the return type, or a tuple of
    signatures of individual arguments as unicode strings or JavaClasses. Also supports the types
    unicode (for java.lang.String), bool (for Z), int (for I), long (for J), and float (for D).
    
    For constructors of a bound inner class, `pre` is the name of the declaring class which is
    prefixed onto the key.
    """
    cdef JMethod m
    cdef unicode sig
    if is_string(key):
        key = to_unicode(key)
        sig = key.replace(u'/', u'.')
        if u'(' in sig: # match full signature
            if pre is not None: sig = u'(L%s;%s'%(pre, sig[1:])
            for m in methods:
                if m.sig() == sig: return m
            raise KeyError(u'No method with signature %s'%sig)
        # match param signature
        if pre is not None: sig = u'L%s;%s'%(pre, sig)
        for m in methods:
            if m.param_sig() == sig: return m
        # else we assume it is for a single-argument signature
        key = (key,)
    elif not isinstance(key, tuple): key = (key,)
    # a tuple of parameter types, either names or JavaClasses
    sig = u''.join(get_parameter_sig(c) for c in key)
    if pre is not None: sig = u'L%s;%s'%(pre, sig)
    for m in methods:
        if m.param_sig() == sig: return m
    raise KeyError(u'No method with signature %s'%sig)

cdef dict primitive_sigs = {
    u'void' : u'V', u'boolean' : u'Z', u'float' : u'F', u'double' : u'D',
    u'byte' : u'B', u'char' : u'C', u'short' : u'S', u'int' : u'I', u'long' : u'J',
}

cdef unicode get_parameter_sig(c):
    from .objects import JavaClass
    if c is object:  return u'Ljava.lang.Object;'
    if c is unicode: return u'Ljava.lang.String;'
    if c is bytes:   return u'[B'
    if c is bool:    return u'Z'
    if c is int:     return u'I'
    IF PY_VERSION < PY_VERSION_3:
        if c is long: return u'J'
    if c is float:   return u'D'
    if isinstance(c, JavaClass): return (<JClass>c.__jclass__).sig()
    cdef Py_ssize_t i = 0
    cdef unicode comp_type
    if is_string(c) and len(c) > 0 and c[-1] != u'[':
        c = to_unicode(c).replace(u'/', u'.')
        while c[i] == u'[': i += 1 # i = depth of array
        comp_type = c[i:]
        if len(comp_type) == 1:
            if comp_type in u'ZBCSIJFD': return c
            raise KeyError(u"Invalid type signature '%s'"%c)
        if comp_type in primitive_sigs: return c[:i]+primitive_sigs[comp_type]
        if comp_type[0] == u'L' and comp_type[-1] == u';': return c
        if u';' in comp_type: raise KeyError(u"Invalid type signature '%s'"%c)
        return u'%sL%s;' % (c[:i],comp_type)
    raise KeyError(u"Invalid type signature '%s'"%c)
