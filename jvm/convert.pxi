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
    py2<primitive>   - converts a Python object to a specific Java primitive
    py2object        - converts a Python object to a Java object of a target class
    p2j_lookup       - lookup the best converter for a Python to Java conversion 
    select_method    - select a method from a list of signatures based on a signature given
    conv_method_args - select a method from a list and convert method arguments based on arguments given
    conv_method_args_single - convert method arguments for a single Java method (not a list)
    free_method_args - free converted method arguments

FUTURE:
    more conversions (they are listed under 'Future:' later on)
"""

from libc.stdlib cimport malloc, free
from libc.string cimport memset
from cpython.long     cimport PyLong_AsLongLong, PyLong_AsUnsignedLongMask, PY_LONG_LONG
from cpython.float    cimport PyFloat_AsDouble
from cpython.object   cimport PyObject_IsTrue
from cpython.datetime cimport PyDate_Check, PyDateTime_Check, PyTZInfo_Check
from cpython.datetime cimport PyDateTime_GET_YEAR, PyDateTime_GET_MONTH, PyDateTime_GET_DAY, PyDateTime_DATE_GET_HOUR
from cpython.datetime cimport PyDateTime_DATE_GET_MINUTE, PyDateTime_DATE_GET_SECOND, PyDateTime_DATE_GET_MICROSECOND
cdef extern from "Python.h":
    PY_LONG_LONG PyLong_AsLongAndOverflow(object vv, int *overflow) except? -1
    PY_LONG_LONG PyLong_AsLongLongAndOverflow(object vv, int *overflow) except? -1

import numbers

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

cdef object object2py(jobject obj):
    """Convert a Java object to a Python object. The jobject reference is deleted."""
    if obj is NULL: return None # null -> None
    cdef JEnv env = jenv()
    cdef JClass clazz = JClass.get(env, env.GetObjectClass(obj))
    if clazz.name == 'java.lang.String': return env.pystr(<jstring>obj)
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

ctypedef P2JConvert (*p2j_any_lookup)(JEnv env, object x, JClass target, P2JQuality* q)
cdef inline P2JConvert p2j_lookup(JEnv env, object x, JClass target, P2JQuality* q):
    return p2j_prim_lookup(env, x, target, q) if target.is_primitive() else p2j_obj_lookup(env, x, target, q)

cdef enum P2JQuality: PERFECT = 100, GREAT = 75, GOOD = 50, BAD = 25, FAIL = -1
cdef inline P2JQuality AVG_QUAL(P2JQuality a, P2JQuality b): return <P2JQuality>((a+b)//2)
ctypedef P2JConvert (*p2j_check)(JEnv env, object x, JClass p, P2JQuality* quality)
ctypedef jobject (*p2j_conv)(JEnv env, object x) except? NULL
ctypedef int (*p2j_prim)(JEnv env, object x, jvalue* val) except -1

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

cdef class P2JConvert(object):
    cdef p2j_conv conv_cy
    cdef p2j_prim conv_prim
    cdef object   conv_py
    @staticmethod
    cdef inline P2JConvert create_cy(p2j_conv conv):
        cdef P2JConvert p2j = P2JConvert()
        p2j.conv_cy = conv
        return p2j
    @staticmethod
    cdef inline P2JConvert create_prim(p2j_prim conv):
        cdef P2JConvert p2j = P2JConvert()
        p2j.conv_prim = conv
        return p2j
    @staticmethod
    cdef inline P2JConvert create_py(object conv):
        cdef P2JConvert p2j = P2JConvert()
        p2j.conv_py = conv
        return p2j

    cdef inline int convert_val(self, JEnv env, object x, jvalue* val) except -1:
        if self.conv_prim is NULL: val[0].l = self.convert(env, x)
        else: self.conv_prim(env, x, val)
    cdef inline jobject convert(self, JEnv env, object x) except? NULL:
        assert self.conv_cy is not NULL or self.conv_py is not None
        return self.conv_cy(env, x) if self.conv_py is None else __p2j_conv_object(env, self.conv_py(x))


########## Python to Java Primitive Conversion ##########
# Java primitives each have their own method. Additionally, since the Python wrappers for the
# boxing classes have __bool__, __int__, __long__, and __float__ as appropiate, these
# inherently support auto-unboxing.
# bool        -> boolean                  (includes anything implementing __bool__/__nonzero__)
# int/long    -> byte/char/short/int/long (includes anything implementing __int__/__long__)
# float       -> float/double             (includes anything implementing __float__)
# unicode     -> char                     (length 1 only)

# These functions are used in JEnv when setting fields
cdef jlong _p2j_long(object x, jlong mn, jlong mx) except? -1:
    cdef jlong out = PyLong_AsLongLong(x)
    if mn <= out <= mx: return out
    raise OverflowError()
cdef inline jboolean py2boolean(object x) except -1: return JNI_TRUE if PyObject_IsTrue(x) else JNI_FALSE
cdef inline jbyte  py2byte (object x) except? -1:
    if isinstance(x, bytearray): return <jbyte>x[0]
    if isinstance(x, bytes): return <jbyte>ord(x)
    return <jbyte>_p2j_long(x, JBYTE_MIN, JBYTE_MAX)
cdef inline jchar  py2char (object x) except? -1: return <jchar>(ord(x) if isinstance(x, unicode) else _p2j_long(x, 0, JCHAR_MAX))
cdef inline jshort py2short(object x) except? -1: return <jshort>_p2j_long(x, JSHORT_MIN, JSHORT_MAX)
cdef inline jint   py2int  (object x) except? -1: return <jint>_p2j_long(x, JINT_MIN, JINT_MAX)
cdef inline jlong  py2long (object x) except? -1: return <jlong>_p2j_long(x, JLONG_MIN, JLONG_MAX)
cdef inline jfloat py2float(object x) except? -1.0:
    cdef double dbl = PyFloat_AsDouble(x)
    if -JFLOAT_MAX <= dbl <= JFLOAT_MAX: return <jfloat>dbl
    raise OverflowError()
cdef inline jdouble py2double(object x) except? -1.0: return PyFloat_AsDouble(x)

# These functions are used when calling methods/constructors
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
cdef p2j_prim_overflow
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
    q[0] = PERFECT
    try:
        if target.name == 'boolean':
            if not isinstance(x, bool):
                if isinstance(x, get_java_class('java.lang.Boolean')): q[0] = GREAT
                elif is_bool_like(x): q[0] = GOOD
                else: q[0] = FAIL
            return p2j_prim_boolean
        elif target.name == 'byte':
            if isinstance(x, bytearray):
                if len(x) != 1: q[0] = FAIL
                return p2j_prim_byte_ind
            if isinstance(x, bytes):
                if len(x) != 1: q[0] = FAIL
                return p2j_prim_byte_ord
            return _p2j_prim_long(x, JBYTE_MIN, JBYTE_MAX, q, p2j_prim_byte)
        elif target.name == 'char':
            if isinstance(x, unicode):
                if len(x) != 1: q[0] = FAIL
                return p2j_prim_char_ord
            q[0] = GOOD
            return _p2j_prim_long(x, 0, JCHAR_MAX, q, p2j_prim_char)
        elif target.name == 'short': return _p2j_prim_long(x, JSHORT_MIN, JSHORT_MAX, q, p2j_prim_short)
        elif target.name == 'int':   return _p2j_prim_long(x, JINT_MIN,   JINT_MAX,   q, p2j_prim_int)
        elif target.name == 'long':  return _p2j_prim_long(x, JLONG_MIN,  JLONG_MAX,  q, p2j_prim_long)
        elif target.name == 'float' and isinstance(x, numbers.Real):
            if -JFLOAT_MAX <= PyFloat_AsDouble(x) <= JFLOAT_MAX:
                q[0] = GREAT if get_java_class('java.lang.Float') else GOOD; return p2j_prim_float
            q[0] = BAD; return p2j_prim_overflow
        elif target.name == 'double' and isinstance(x, numbers.Real): return p2j_prim_double
    except TypeError, ValueError: pass
    q[0] = FAIL
    return None


########## Python to Java Object Conversion ##########
# Object      -> Object
# bool        -> Boolean                     (includes anything implementing __bool__/__nonzero__)
# Integral    -> Byte, Character, Short, Integer, Long, java.math.BigInteger
# Real        -> Float, Double, java.math.BigDecimal
# unicode     -> Character, char[], String, Enum value
# bytes       -> byte[]
# bytearray   -> byte[]
# array.array -> primitive array
# buffer/memoryview -> primitive array
# decimal.Decimal   -> java.math.BigDecimal
# decimal.Context   -> java.math.MathContext
# datetime.date     -> java.util.Date
#
# FUTURE:
# bytes             -> ByteBuffer
# bytearray         -> ByteBuffer
# array.array       -> <type>Buffer
# buffer/memoryview -> <type>Buffer
# datetime.date     -> Calendar
# datetime.tzinfo   -> TimeZone
# list
# tuple
# dict
# set
# frozenset

cdef inline jobject py2object(JEnv env, object x, JClass target) except? NULL:
    """
    Converts a Python object to an instance of the given target class (or a subclass). A new local
    reference if returned and the caller is responsible for deleting when finished (unless is it
    NULL). If no conversion is possible, a TypeError is raised.
    """
    cdef P2JQuality quality
    cdef P2JConvert conv = p2j_obj_lookup(env, x, target, &quality)
    if quality > FAIL: return conv.convert(env, x)
    raise TypeError('Could not convert "%s" to "%s"' % (x, target))

cdef inline P2JConvert p2j_obj_lookup(JEnv env, object x, JClass target, P2JQuality* best):
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
    IF PY_VERSION >= PY_VERSION_3_2 or PY_VERSION < PY_VERSION_3:
        if not isinstance(java_class, JavaClass) or not callable(check_func): raise TypeError()
    ELSE:
        from collections import Callable
        if not isinstance(java_class, JavaClass) or not isinstance(check_func, Callable): raise TypeError()
    p2js.append(P2J.create_py(python_type, java_class.__jclass__, check_func))


# p2j_obj_lookup  finds a function for converting a Python object to a particular Java class
# p2j_prim_lookup finds a function for converting a Python object to a particular Java primitive
cdef jobject __p2j_conv_none(JEnv env, object x) except? NULL: return NULL
cdef jobject __p2j_conv_object(JEnv env, object x) except? NULL: return env.NewLocalRef(get_object(x))
cdef jobject __p2j_conv_javaclass(JEnv env, object x) except? NULL: return env.NewLocalRef(get_class(x))

cdef jobject __p2j_conv_unicode(JEnv env, object x) except? NULL: return env.NewString(x)
cdef jobject __p2j_conv_char_ord_box(JEnv env, object x) except? NULL: return box_char(env, <jchar>ord(x))
cdef jobject __p2j_conv_bytes(JEnv env, object x) except? NULL: return env.NewLocalRef(get_object(byte_array(x)))
cdef jobject __p2j_conv_bytearray(JEnv env, object x) except? NULL: return env.NewLocalRef(get_object(byte_array(x)))
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
cdef jobject __p2j_conv_bigint(JEnv env, object x) except? NULL: return __p2j_conv_object(env, long2bigint(env, long(x)))
cdef jobject __p2j_conv_bigdec(JEnv env, object x) except? NULL:
    import decimal
    x = unicode(x) if isinstance(x, decimal.Decimal) else float(x)
    return __p2j_conv_object(env, get_java_class('java.math.BigDecimal')(x))
cdef jobject __p2j_conv_mathcntxt(JEnv env, object x) except? NULL:
    import decimal
    rm = get_java_class('java.math.RoundingMode')
    if   x.rounding == decimal.ROUND_CEILING:   rm = rm.CEILING
    elif x.rounding == decimal.ROUND_DOWN:      rm = rm.DOWN
    elif x.rounding == decimal.ROUND_FLOOR:     rm = rm.FLOOR
    elif x.rounding == decimal.ROUND_HALF_DOWN: rm = rm.HALF_DOWN
    elif x.rounding == decimal.ROUND_HALF_EVEN: rm = rm.HALF_EVEN
    elif x.rounding == decimal.ROUND_HALF_UP:   rm = rm.HALF_UP
    elif x.rounding == decimal.ROUND_UP:        rm = rm.UP
    else: raise ValueError('Unconvertable rounding mode %s'%(x.rounding))
    return __p2j_conv_object(env, get_java_class('java.math.MathContext')(x.prec, rm))
    
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
    return __p2j_conv_object(env, get_java_class('java.util.Date')(timestamp))
#cdef jobject __p2j_conv_calendar(JEnv env, object x) except? NULL:
#    import calendar
#    tz = x.tzinfo
#    Calendar = get_java_class('java.util.Calendar')
#    if tz is None:
#        cal = Calendar.getInstance()
#    else:
#        cal = Calendar.getInstance(TODO)
#    cal.set(PyDateTime_GET_YEAR(x), PyDateTime_GET_MONTH(x)-1, PyDateTime_GET_DAY(x),
#            PyDateTime_DATE_GET_HOUR(x), PyDateTime_DATE_GET_MINUTE(x), PyDateTime_DATE_GET_SECOND(x))
#    cal.set(Calendar.MILLISECOND, PyDateTime_DATE_GET_MICROSECOND(x)//1000)
#    return __p2j_conv_object(env, cal)
    
cdef jobject __p2j_conv_boolean_array(JEnv env, object x) except? NULL: return env.NewLocalRef(get_object(boolean_array(x)))
cdef jobject __p2j_conv_byte_array(JEnv env, object x) except? NULL: return env.NewLocalRef(get_object(byte_array(x)))
cdef jobject __p2j_conv_char_array(JEnv env, object x) except? NULL: return env.NewLocalRef(get_object(char_array(x)))
cdef jobject __p2j_conv_short_array(JEnv env, object x) except? NULL: return env.NewLocalRef(get_object(short_array(x)))
cdef jobject __p2j_conv_int_array(JEnv env, object x) except? NULL: return env.NewLocalRef(get_object(int_array(x)))
cdef jobject __p2j_conv_long_array(JEnv env, object x) except? NULL: return env.NewLocalRef(get_object(long_array(x)))
cdef jobject __p2j_conv_float_array(JEnv env, object x) except? NULL: return env.NewLocalRef(get_object(float_array(x)))
cdef jobject __p2j_conv_double_array(JEnv env, object x) except? NULL: return env.NewLocalRef(get_object(double_array(x)))

cdef P2JConvert p2j_conv_none, p2j_conv_object, p2j_conv_javaclass
cdef P2JConvert p2j_conv_unicode, p2j_conv_char_ord_box
cdef P2JConvert p2j_conv_bytes, p2j_conv_bytearray, p2j_conv_byte_ord_box, p2j_conv_byte_ind_box
IF PY_VERSION < PY_VERSION_3:
    cdef P2JConvert p2j_conv_bytes2str
cdef P2JConvert p2j_conv_boolean_box, p2j_conv_byte_box, p2j_conv_char_box, p2j_conv_short_box
cdef P2JConvert p2j_conv_int_box, p2j_conv_long_box, p2j_conv_float_box, p2j_conv_double_box
cdef P2JConvert p2j_conv_bigint, p2j_conv_bigdec, p2j_conv_mathcntxt, p2j_conv_overflow
cdef P2JConvert p2j_conv_date
cdef P2JConvert p2j_conv_boolean_array, p2j_conv_byte_array, p2j_conv_char_array, p2j_conv_short_array
cdef P2JConvert p2j_conv_int_array, p2j_conv_long_array, p2j_conv_float_array, p2j_conv_double_array

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
cdef P2JConvert p2j_check_bytes(JEnv env, object x, JClass p, P2JQuality* q): return p2j_conv_bytes
cdef P2JConvert p2j_check_bytearray(JEnv env, object x, JClass p, P2JQuality* q): return p2j_conv_bytearray
cdef P2JConvert p2j_check_byte_ord(JEnv env, object x, JClass p, P2JQuality* q):
    if len(x) != 1: q[0] = FAIL
    return p2j_conv_byte_ord_box
cdef P2JConvert p2j_check_byte_ind(JEnv env, object x, JClass p, P2JQuality* q):
    if len(x) != 1: q[0] = FAIL
    return p2j_conv_byte_ind_box
IF PY_VERSION < PY_VERSION_3:
    cdef P2JConvert p2j_check_bytes2str(JEnv env, object x, JClass p, P2JQuality* q):
        q[0] = AVG_QUAL(PERFECT,GREAT) if p.is_same(env, JClass.named(env, 'java.lang.String')) else AVG_QUAL(GREAT,GOOD)
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
cdef P2JConvert p2j_check_bigint(JEnv env, object x, JClass p, P2JQuality* q):
    cdef int overflow = 0
    try: PyLong_AsLongAndOverflow(x, &overflow)
    except TypeError: q[0] = FAIL; return None
    return p2j_conv_bigint
cdef P2JConvert p2j_check_bigdec(JEnv env, object x, JClass p, P2JQuality* q): return p2j_conv_bigdec
cdef P2JConvert p2j_check_mathcntxt(JEnv env, object x, JClass p, P2JQuality* q): return p2j_conv_mathcntxt

cdef P2JConvert p2j_check_date(JEnv env, object x, JClass p, P2JQuality* q): return p2j_conv_date

cdef P2JConvert p2j_check_chararr(JEnv env, object x, JClass p, P2JQuality* q): q[0] = GREAT; return p2j_conv_char_array
cdef JPrimArrayDef* _p2j_check_array(JClass p, P2JQuality* q):
    if not p.is_array() or not p.component_type.is_primitive(): q[0] = FAIL; return NULL
    cdef char pn = p.component_type.funcs.sig
    for i in xrange(8):
        if pn == jpads[i].sig: return jpads[i]
    q[0] = FAIL
    return NULL
cdef P2JConvert _p2j_array_conv(JPrimArrayDef* jpad):
    if jpad.sig == b'Z': return p2j_conv_boolean_array
    if jpad.sig == b'B': return p2j_conv_byte_array
    if jpad.sig == b'C': return p2j_conv_char_array
    if jpad.sig == b'S': return p2j_conv_short_array
    if jpad.sig == b'I': return p2j_conv_int_array
    if jpad.sig == b'L': return p2j_conv_long_array
    if jpad.sig == b'F': return p2j_conv_float_array
    if jpad.sig == b'D': return p2j_conv_double_array
cdef P2JConvert p2j_check_array(JEnv env, object x, JClass p, P2JQuality* q):
    cdef Py_ssize_t i
    if p.name == 'java.lang.Object':
        for i in xrange(8):
            if x.itemsize == jpads[i].itemsize and x.typecode in jpads[i].array_typecodes:
                q[0] = GREAT
                return _p2j_array_conv(jpads[i])
        q[0] = FAIL
        return None
    cdef JPrimArrayDef* jpad = _p2j_check_array(p, q)
    if jpad is NULL: return None
    if not JPrimitiveArray.check_arrayarray(x, jpad): q[0] = FAIL; return None
    q[0] = GOOD if x.typecode == 'B' and p.component_type.funcs.sig != b'B' else PERFECT
    return _p2j_array_conv(jpad)
cdef P2JConvert p2j_check_buffer(JEnv env, object x, JClass p, P2JQuality* q):
    if not PyObject_CheckBuffer(x): q[0] = FAIL; return None
    cdef Py_ssize_t i, itmsz
    cdef Py_buffer buf
    cdef bytes format
    cdef bint native_bo
    if p.name == 'java.lang.Object':
        try:
            PyObject_GetBuffer(x, &buf, PyBUF_ND|PyBUF_FORMAT|PyBUF_SIMPLE)
            try:
                itmsz, format, native_bo = JPrimitiveArray.get_buffer_info(&buf)
                if buf.ndim > 1 or not native_bo: q[0] = FAIL; return None
            finally: PyBuffer_Release(&buf)
            for i in xrange(8):
                if itmsz == jpads[i].itemsize and format in jpads[i].buffer_formats:
                    q[0] = GREAT
                    return _p2j_array_conv(jpads[i])
        except Exception: pass
        q[0] = FAIL
        return None
    cdef JPrimArrayDef* jpad = _p2j_check_array(p, q)
    if jpad is NULL: return None
    if not JPrimitiveArray.get_buffer(x, jpad, &buf, False): q[0] = FAIL; return None
    q[0] = GOOD if (buf.format is NULL or bytes(buf.format).endswith(b'B')) and p.component_type.funcs.sig != b'B' else PERFECT
    PyBuffer_Release(&buf)
    return _p2j_array_conv(jpad)
    
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
    global p2j_conv_unicode, p2j_conv_char_ord_box
    global p2j_conv_bytes, p2j_conv_bytearray, p2j_conv_byte_ord_box, p2j_conv_byte_ind_box
    global p2j_conv_boolean_box, p2j_conv_byte_box, p2j_conv_char_box, p2j_conv_short_box
    global p2j_conv_int_box, p2j_conv_long_box, p2j_conv_float_box, p2j_conv_double_box
    global p2j_conv_bigint, p2j_conv_bigdec, p2j_conv_mathcntxt, p2j_conv_overflow
    global p2j_conv_date
    global p2j_conv_boolean_array, p2j_conv_byte_array, p2j_conv_char_array, p2j_conv_short_array
    global p2j_conv_int_array, p2j_conv_long_array, p2j_conv_float_array, p2j_conv_double_array
    p2j_conv_none          = P2JConvert.create_cy(__p2j_conv_none)
    p2j_conv_object        = P2JConvert.create_cy(__p2j_conv_object)
    p2j_conv_javaclass     = P2JConvert.create_cy(__p2j_conv_javaclass)
    p2j_conv_unicode       = P2JConvert.create_cy(__p2j_conv_unicode)
    p2j_conv_char_ord_box  = P2JConvert.create_cy(__p2j_conv_char_ord_box)
    p2j_conv_bytes         = P2JConvert.create_cy(__p2j_conv_bytes)
    p2j_conv_bytearray     = P2JConvert.create_cy(__p2j_conv_bytearray)
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
    p2j_conv_bigint        = P2JConvert.create_cy(__p2j_conv_bigint)
    p2j_conv_bigdec        = P2JConvert.create_cy(__p2j_conv_bigdec)
    p2j_conv_mathcntxt     = P2JConvert.create_cy(__p2j_conv_mathcntxt)
    p2j_conv_date          = P2JConvert.create_cy(__p2j_conv_date)
    p2j_conv_overflow      = P2JConvert.create_cy(__p2j_conv_overflow)
    p2j_conv_boolean_array = P2JConvert.create_cy(__p2j_conv_boolean_array)
    p2j_conv_byte_array    = P2JConvert.create_cy(__p2j_conv_byte_array)
    p2j_conv_char_array    = P2JConvert.create_cy(__p2j_conv_char_array)
    p2j_conv_short_array   = P2JConvert.create_cy(__p2j_conv_short_array)
    p2j_conv_int_array     = P2JConvert.create_cy(__p2j_conv_int_array)
    p2j_conv_long_array    = P2JConvert.create_cy(__p2j_conv_long_array)
    p2j_conv_float_array   = P2JConvert.create_cy(__p2j_conv_float_array)
    p2j_conv_double_array  = P2JConvert.create_cy(__p2j_conv_double_array)
    IF PY_VERSION < PY_VERSION_3:
        global p2j_conv_bytes2str
        p2j_conv_bytes2str = P2JConvert.create_cy(__p2j_conv_bytes2str)

    import types, array, decimal, datetime
    global p2js; p2js = [
        P2J.create_cy(env, types.NoneType, None, p2j_check_none),
        P2J.create_cy(env, get_java_class('java.lang.Object'), None, p2j_check_object),
        P2J.create_cy(env, JavaClass,         'java.lang.Class',       p2j_check_javaclass),
        P2J.create_cy(env, unicode,           'java.lang.Enum',        p2j_check_enum),
        P2J.create_cy(env, unicode,           'java.lang.String',      p2j_check_unicode),
        P2J.create_cy(env, unicode,           'java.lang.Character',   p2j_check_char_ord),
        P2J.create_cy(env, unicode,           '[C',                    p2j_check_chararr),
        P2J.create_cy(env, None,              'java.lang.Boolean',     p2j_check_boolean),
        P2J.create_cy(env, numbers.Integral,  'java.lang.Byte',        p2j_check_byte),
        P2J.create_cy(env, numbers.Integral,  'java.lang.Character',   p2j_check_char),
        P2J.create_cy(env, numbers.Integral,  'java.lang.Short',       p2j_check_short),
        P2J.create_cy(env, numbers.Integral,  'java.lang.Integer',     p2j_check_int),
        P2J.create_cy(env, numbers.Integral,  'java.lang.Long',        p2j_check_long),
        P2J.create_cy(env, numbers.Real,      'java.lang.Float',       p2j_check_float),
        P2J.create_cy(env, numbers.Real,      'java.lang.Double',      p2j_check_double),
        P2J.create_cy(env, numbers.Integral,  'java.math.BigInteger',  p2j_check_bigint),
        P2J.create_cy(env, (decimal.Decimal, numbers.Real), 'java.math.BigDecimal', p2j_check_bigdec),
        P2J.create_cy(env, decimal.Context,   'java.math.MathContext', p2j_check_mathcntxt),
        P2J.create_cy(env, datetime.date,     'java.util.Date',        p2j_check_date),
        P2J.create_cy(env, bytes,             'java.lang.Byte',        p2j_check_byte_ord),
        P2J.create_cy(env, bytes,             '[B',                    p2j_check_bytes),
        P2J.create_cy(env, bytearray,         'java.lang.Byte',        p2j_check_byte_ind),
        P2J.create_cy(env, bytearray,         '[B',                    p2j_check_bytearray),
        #IF JNI_VERSION >= JNI_VERSION_1_4:
        #    P2J.create_cy(env, bytes,     'java.nio.ByteBuffer', p2j_check_bytes2bbuf),
        #    P2J.create_cy(env, bytearray, 'java.nio.ByteBuffer', p2j_check_bytes2bbuf),
        P2J.create_cy(env, array.array, None, p2j_check_array),
        P2J.create_cy(env, None,        None, p2j_check_buffer),
    ]
    IF PY_VERSION < PY_VERSION_3:
        p2js.append(P2J.create_cy(env, bytes, 'java.lang.String', p2j_check_bytes2str))
        
cdef int dealloc_p2j(JEnv env) except -1: global p2js; p2js = None
JVM.add_init_hook(init_p2j)
JVM.add_dealloc_hook(dealloc_p2j)


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
    if best is None: raise ValueError('No acceptable method found for the given paramters')
    if ambiguous: raise ValueError('Ambiguous method call')
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
    if best_mtype == NO_MATCH: raise ValueError('No acceptable method found for the given arguments')
    if ambiguous or best_mtype == AMBIGUOUS_MATCH: raise ValueError('Ambiguous method call')

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
        raise ValueError('No acceptable method found for the given paramters')
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
    if mtype == NO_MATCH: raise ValueError('Could not call the method with the given arguments')
    if mtype == AMBIGUOUS_MATCH: raise ValueError('Ambiguous method call')
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
        sig = key.replace('/', '.')
        if '(' in sig: # match full signature
            if pre is not None: sig = '(L%s;%s'%(pre, sig[1:])
            for m in methods:
                if m.sig() == sig: return m
            raise KeyError('No method with signature %s'%sig)
        # match param signature
        if pre is not None: sig = 'L%s;%s'%(pre, sig)
        for m in methods:
            if m.param_sig() == sig: return m
        # else we assume it is for a single-argument signature
        key = (key,)
    elif not isinstance(key, tuple): key = (key,)
    # a tuple of parameter types, either names or JavaClasses
    sig = ''.join(get_parameter_sig(c) for c in key)
    if pre is not None: sig = 'L%s;%s'%(pre, sig)
    for m in methods:
        if m.param_sig() == sig: return m
    raise KeyError('No method with signature %s'%sig)

cdef dict primitive_sigs = {
    'void' : 'V', 'boolean' : 'Z', 'float' : 'F', 'double' : 'D',
    'byte' : 'B', 'char' : 'C', 'short' : 'S', 'int' : 'I', 'long' : 'J',
}

cdef unicode get_parameter_sig(c):
    if c is object:  return 'Ljava.lang.Object;'
    if c is unicode: return 'Ljava.lang.String;'
    if c is bytes:   return '[B'
    if c is bool:    return 'Z'
    if c is int:     return 'I'
    IF PY_VERSION < PY_VERSION_3:
        if c is long: return 'J'
    if c is float:   return 'D'
    if isinstance(c, JavaClass): return (<JClass>c.__jclass__).sig()
    cdef Py_ssize_t i = 0
    cdef unicode comp_type
    if is_string(c) and len(c) > 0 and c[-1] != '[':
        c = to_unicode(c).replace('/', '.')
        while c[i] == '[': i += 1 # i = depth of array
        comp_type = c[i:]
        if len(comp_type) == 1:
            if comp_type in 'ZBCSIJFD': return c
            raise KeyError("Invalid type signature '%s'"%c)
        if comp_type in primitive_sigs: return c[:i]+primitive_sigs[comp_type]
        if comp_type[0] == 'L' and comp_type[-1] == ';': return c
        if ';' in comp_type: raise KeyError("Invalid type signature '%s'"%c)
        return '%sL%s;' % (c[:i],comp_type)
    raise KeyError("Invalid type signature '%s'"%c)
