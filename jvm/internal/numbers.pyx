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

Java Number Templates
---------------------
Object templates for number boxing types and java.math.BigInteger and java.math.BigDecimal.

Provides the conversions:
    numbers.Integral -> java.math.BigInteger
    numbers.Real     -> java.math.BigDecimal
    decimal.Decimal  -> java.math.BigDecimal
    decimal.Context  -> java.math.MathContext
"""

from __future__ import absolute_import
from __future__ import division

include "version.pxi"

from cpython.object cimport PyObject
from cpython.long   cimport PY_LONG_LONG
cdef extern from "Python.h":
    ctypedef PyObject PyLongObject
    PY_LONG_LONG PyLong_AsLongAndOverflow(object vv, int *overflow) except? -1
    object _PyLong_FromByteArray(const unsigned char* bytes, size_t n, bint little_endian, bint is_signed)
    int _PyLong_AsByteArray(PyLongObject* v, unsigned char* bytes, size_t n, bint little_endian, bint is_signed) except -1

from .jni cimport jobject

from .core cimport jvm_add_init_hook, jvm_add_dealloc_hook, JClass, JEnv, jenv
from .objects cimport get_java_class, get_object
from .convert cimport P2JConvert, P2JQuality, FAIL, reg_conv_cy
from .arrays cimport JPrimitiveArray, JPrimArrayPointer


cdef bigint2long(JEnv env, x):
    cdef JPrimitiveArray arr = x._jcall0(u'toByteArray')
    cdef JPrimArrayPointer ptr = JPrimArrayPointer(env, arr)
    return _PyLong_FromByteArray(<unsigned char*>ptr.ptr, arr.length, False, True)

cdef long2bigint(JEnv env, x):
    IF PY_VERSION < PY_VERSION_3:
        # In Python 2 we need to convert int to long
        if isinstance(x, int): x = long(x)
    cdef Py_ssize_t n = (x.bit_length() + 7) // 8
    cdef JPrimitiveArray arr = JPrimitiveArray.new(env, n, JClass.named(env, u'byte'))
    cdef JPrimArrayPointer ptr = JPrimArrayPointer(env, arr)
    _PyLong_AsByteArray(<PyLongObject*><PyObject*>x, <unsigned char*>ptr.ptr, n, False, True)
    ptr.release()
    return get_java_class(u'java.math.BigInteger')(arr)
    
IF PY_VERSION < PY_VERSION_3:
    builtin_int_type = (int,long)
ELSE:
    builtin_int_type = int

cdef object BI_ONE
cdef object BI_TEN

### Conversions ###
cdef P2JConvert p2j_conv_bigint, p2j_conv_bigdec, p2j_conv_mathcntxt
cdef jobject __p2j_conv_bigint(JEnv env, object x) except? NULL: return env.NewLocalRef(get_object(long2bigint(env, long(x))))
cdef jobject __p2j_conv_bigdec(JEnv env, object x) except? NULL:
    from decimal import Decimal
    x = unicode(x) if isinstance(x, Decimal) else float(x)
    return env.NewLocalRef(get_object(get_java_class(u'java.math.BigDecimal')(x)))
cdef jobject __p2j_conv_mathcntxt(JEnv env, object x) except? NULL:
    import decimal
    rm = get_java_class(u'java.math.RoundingMode')
    if   x.rounding == decimal.ROUND_CEILING:   rm = rm.CEILING
    elif x.rounding == decimal.ROUND_DOWN:      rm = rm.DOWN
    elif x.rounding == decimal.ROUND_FLOOR:     rm = rm.FLOOR
    elif x.rounding == decimal.ROUND_HALF_DOWN: rm = rm.HALF_DOWN
    elif x.rounding == decimal.ROUND_HALF_EVEN: rm = rm.HALF_EVEN
    elif x.rounding == decimal.ROUND_HALF_UP:   rm = rm.HALF_UP
    elif x.rounding == decimal.ROUND_UP:        rm = rm.UP
    else: raise ValueError(u'Unconvertable rounding mode %s'%(x.rounding))
    return env.NewLocalRef(get_object(get_java_class(u'java.math.MathContext')(x.prec, rm)))
cdef P2JConvert p2j_check_bigint(JEnv env, object x, JClass p, P2JQuality* q):
    cdef int overflow = 0
    try: PyLong_AsLongAndOverflow(x, &overflow)
    except TypeError: q[0] = FAIL; return None
    return p2j_conv_bigint
cdef P2JConvert p2j_check_bigdec(JEnv env, object x, JClass p, P2JQuality* q): return p2j_conv_bigdec
cdef P2JConvert p2j_check_mathcntxt(JEnv env, object x, JClass p, P2JQuality* q): return p2j_conv_mathcntxt


cdef int init_numbers(JEnv env) except -1:
    import operator, numbers
    from numbers import Integral, Rational, Real, Complex
    from decimal import Decimal, Context
    Object = get_java_class(u'java.lang.Object')

    ### Number Boxing Types ###
    class Boolean(Object):
        __java_class_name__ = u'java.lang.Boolean'
        def __nonzero__(self): return self._jcall0(u'booleanValue')
        def __bool__(self): return self._jcall0(u'booleanValue')
    class Number(Object):
        __java_class_name__ = u'java.lang.Number'
        def __nonzero__(self): return bool(self._jcall0(u'longValue'))
        def __bool__(self): return bool(self._jcall0(u'longValue'))
        def __int__(self): return self._jcall0(u'longValue')
        def __long__(self): return self._jcall0(u'longValue')
        def __float__(self): return self._jcall0(u'doubleValue')
    class Byte(Number):
        __java_class_name__ = u'java.lang.Byte'
        def __index__(self): return self._jcall0(u'byteValue')
    class Short(Number):
        __java_class_name__ = u'java.lang.Short'
        def __index__(self): return self._jcall0(u'shortValue')
    class Integer(Number):
        __java_class_name__ = u'java.lang.Integer'
        def __index__(self): return self._jcall0(u'intValue')
    class Long(Number):
        __java_class_name__ = u'java.lang.Long'
        def __index__(self): return self._jcall0(u'longValue')
    class Float(Number):
        __java_class_name__ = u'java.lang.Float'
    class Double(Number):
        __java_class_name__ = u'java.lang.Double'
        
    ### BigInteger ###
    class BigInteger(Number): # implements numbers.Integral
        __java_class_name__ = u'java.math.BigInteger'
        @property
        def real(self): return self
        @property
        def imag(self): return BigInteger.ZERO
        @property
        def numerator(self): return self
        @property
        def denominator(self): return BI_ONE
        def conjugate(self): return self
        def __complex__(self): return complex(self._jcall0(u'doubleValue'))
        def __float__(self): return self._jcall0(u'doubleValue')
        def __int__(self): return bigint2long(jenv(), self)
        def __long__(self): return bigint2long(jenv(), self)
        def __nonzero__(self): return self._jcall0(u'signum') != 0
        def __bool__(self): return self._jcall0(u'signum') != 0
        def __hex__(self): return self._jcall1(u'toString', 16)
        def __oct__(self): return self._jcall1(u'toString', 8)
        def __trunc__(self): return self
        def __ceil__(self): return self
        def __floor__(self): return self
        def __round__(self, n):
            if n >= 0: return self
            factor = BI_TEN.pow(-n)
            x, rem =  self._jcall1(u'divideAndRemainder', factor)
            if rem._jcall1(u'shiftLeft', 1)._jcall1(u'compareTo', factor) >= 0:
                x = x._jcall1(u'add', 1) # round 0.5 up
            return x._jcall1(u'multiply', factor)
        def __abs__(self): return self._jcall0(u'abs')
        def __pos__(self): return self
        def __neg__(self): return self._jcall0(u'negate')
        def __invert__(self): return self._jcall0(u'not')
        def __operator(method, fallback):
            def op(a, b):
                if isinstance(b, BigInteger): return a._jcall1(method, b)
                if isinstance(b, builtin_int_type): return a._jcall1(method, long2bigint(jenv(), b))
                if isinstance(b, float):   return fallback(float(a),   b)
                if isinstance(b, complex): return fallback(complex(a), b)
                return NotImplemented
            op.__name__ = str('__' + fallback.__name__ + '__')
            def rop(b, a):
                if isinstance(a, BigInteger): return a._jcall1(method, b)
                if isinstance(a, builtin_int_type): return long2bigint(jenv(), a)._jcall1(method, b)
                if isinstance(a, Integral):   return long2bigint(jenv(), long(a))._jcall1(method, b)
                if isinstance(a, Real):       return fallback(float(a),   float(b))
                if isinstance(a, Complex):    return fallback(complex(a), complex(b))
                return NotImplemented
            rop.__name__ = str('__r' + fallback.__name__ + '__')
            return op, rop
        def __operator_int(method, fallback): # operator must have `other` as a 32-bit signed int
            def op(a, b):
                if isinstance(b, BigInteger):
                    if b._jcall0(u'bitLength') >= 32: raise OverflowError()
                    return a._jcall1(method, b._jcall0(u'intValue'))
                if isinstance(b, Integral): return a._jcall1(method, b)
                if isinstance(b, float):    return fallback(float(a), b)
                return NotImplemented
            op.__name__ = str('__' + fallback.__name__ + '__')
            def rop(b, a):
                if isinstance(a, BigInteger):
                    if b._jcall0(u'bitLength') >= 32: raise OverflowError()
                    return a._jcall1(method, b._jcall0(u'intValue'))
                if isinstance(a, builtin_int_type): return fallback(a, int(b))
                if isinstance(a, Integral): return fallback(int(a), int(b))
                if isinstance(a, Real):     return fallback(float(a), float(b))
                return NotImplemented
            rop.__name__ = str(u'__r' + fallback.__name__ + u'__')
            return op, rop
        __add__, __radd__ = __operator(u'add', operator.add)
        __sub__, __rsub__ = __operator(u'subtract', operator.sub)
        __mul__, __rmul__ = __operator(u'multiply', operator.mul)
        IF PY_VERSION < PY_VERSION_3:
            __div__, __rdiv__ = __operator(u'divide', operator.div)
        def __truediv__(self, other):  return BigDecimal(self) / other
        def __rtruediv__(self, other): return other / BigDecimal(self)
        __floordiv__, __rfloordiv__ = __operator(u'divide', operator.floordiv)
        __divmod__, __rdivmod__ = __operator(u'divideAndRemainder', divmod)
        __mod__, __rmod__ = __operator(u'mod', operator.mod)
        __pow_nomod, __rpow__ = __operator_int(u'pow', pow)
        __lshift__, __rlshift__ = __operator_int(u'shiftLeft',  operator.lshift)
        __rshift__, __rrshift__ = __operator_int(u'shiftRight', operator.rshift)
        __and__, __rand__ = __operator(u'and', operator.and_)
        __xor__, __rxor__ = __operator(u'xor', operator.xor)
        __or__,  __ror__  = __operator(u'or',  operator.or_)
        def __pow__(self, other, mod=None):
            if mod is None: return self.__pow_nomod(other)
            IF PY_VERSION < PY_VERSION_3:
                ints = (BigInteger, int, long)
                reals = (BigInteger, int, long, float)
            ELSE:
                ints = (BigInteger, int)
                reals = (BigInteger, int, float)
            if isinstance(other, ints) and isinstance(mod, ints):
                if isinstance(other, builtin_int_type): other = long2bigint(jenv(), other)
                if isinstance(mod,   builtin_int_type): mod   = long2bigint(jenv(), other)
                return self._jcall2('modPow', other, mod)
            if isinstance(other, reals) and isinstance(mod, reals):
                return pow(float(self), float(other), float(mod))
            return NotImplemented

    ### BigDecimal ###
    class BigDecimal(Number): # implements numbers.Rational
        __java_class_name__ = u'java.math.BigDecimal'
        @property
        def real(self): return self
        @property
        def imag(self): return BigDecimal.ZERO
        @property
        def numerator(self):
            if self._jcall0(u'signum') == 0 or self._jcall0(u'scale') <= 0: return self
            dec = self._jcall0(u'stripTrailingZeros')
            scale = dec._jcall0(u'scale')
            if scale <= 0: return dec
            numerator = dec._jcall0(u'unscaledValue')
            denominator = BI_TEN._jcall1(u'pow', scale)
            return numerator._jcall1(u'divide', numerator._jcall1(u'gcd', denominator))
        @property
        def denominator(self):
            if self._jcall0(u'signum') == 0 or self._jcall0(u'scale') <= 0: return BI_ONE
            dec = self._jcall0(u'stripTrailingZeros')
            scale = dec._jcall0(u'scale')
            if scale <= 0: return BI_ONE
            numerator = dec._jcall0(u'unscaledValue')
            denominator = BI_TEN._jcall1(u'pow', scale)
            return denominator._jcall1(u'divide', numerator._jcall1(u'gcd', denominator))
        def conjugate(self): return self
        def __complex__(self): return complex(self._jcall0(u'doubleValue'))
        def __float__(self): return self._jcall0(u'doubleValue')
        def __int__(self): return int(self._jcall0(u'toBigInteger'))
        def __long__(self): return int(self._jcall0(u'toBigInteger'))
        def __nonzero__(self): return not self._jcall0(u'signum') != 0
        def __bool__(self): return self._jcall0(u'signum') != 0
        def __trunc__(self): return self._jcall2(u'setScale', 0, 1) # BigDecimal.ROUND_DOWN
        def __ceil__(self): return self._jcall2(u'setScale', 0, 2) # BigDecimal.ROUND_CEILING
        def __floor__(self): return self._jcall2(u'setScale', 0, 3) # BigDecimal.ROUND_FLOOR
        def __round__(self, n): return self._jcall2(u'setScale', n, 4) # BigDecimal.ROUND_HALF_UP
        def __abs__(self): return self._jcall0(u'abs')
        def __pos__(self): return self._jcall0(u'plus')
        def __neg__(self): return self._jcall0(u'negate')
        def __operator(method, fallback):
            def op(a, b):
                if isinstance(b, BigDecimal): return a._jcall1(method, b)
                if isinstance(b, BigInteger): return a._jcall1(method, BigDecimal(b))
                if isinstance(b, Decimal):    return a._jcall1(method, BigDecimal(unicode(b)))
                if isinstance(b, builtin_int_type): return a._jcall1(method, BigDecimal(long2bigint(jenv(), b)))
                if isinstance(b, float):   return a._jcall1(method, BigDecimal(b))
                if isinstance(b, complex): return fallback(complex(a), b)
                return NotImplemented
            op.__name__ = str('__' + fallback.__name__ + '__')
            def rop(b, a):
                if isinstance(a, BigDecimal): return a._jcall1(method, b)
                if isinstance(a, BigInteger): return BigDecimal(a)._jcall1(method, b)
                if isinstance(a, Decimal):    return BigDecimal(unicode(b))._jcall1(method, b)
                if isinstance(a, builtin_int_type): return BigDecimal(long2bigint(jenv(), a))._jcall1(method, b)
                if isinstance(a, Integral): return BigDecimal(long2bigint(jenv(), long(a)))._jcall1(method, b)
                if isinstance(a, Real):     return BigDecimal(float(a))._jcall1(method, b)
                if isinstance(a, Complex):  return fallback(complex(a), complex(b))
                return NotImplemented
            rop.__name__ = str('__r' + fallback.__name__ + '__')
            return op, rop
        __add__, __radd__ = __operator(u'add', operator.add)
        __sub__, __rsub__ = __operator(u'subtract', operator.sub)
        __mul__, __rmul__ = __operator(u'multiply', operator.mul)
        IF PY_VERSION < PY_VERSION_3:
            __div__, __rdiv__ = __operator(u'divide', operator.div)
        __truediv__, __rtruediv__ = __operator(u'divide', operator.truediv)
        __floordiv__, __rfloordiv__ = __operator(u'divideToIntegralValue', operator.floordiv)
        __divmod__, __rdivmod__ = __operator(u'divideAndRemainder', divmod)
        __mod__, __rmod__ = __operator(u'remainder', operator.mod)
        def __pow__(self, other, mod=None):
            if mod is not None: raise ValueError('mod not supported')
            if isinstance(other, Integral): return self._jcall1(u'pow', other)
            if isinstance(other, float): return pow(float(self), other)
            return NotImplemented
        def __rpow__(self, other):
            if isinstance(other, builtin_int_type): return pow(other, int(self))
            if isinstance(other, Integral): return pow(int(other), int(self))
            if isinstance(other, Real): return pow(float(other), float(self))
            return NotImplemented
            
    global BI_ONE, BI_TEN
    BI_ONE = BigInteger.ONE
    BI_TEN = BigInteger.TEN
    
    ### Numerical ABC registration ###
    numbers.Number.register(Number)
    Integral.register(Byte)
    Integral.register(Short)
    Integral.register(Integer)
    Integral.register(Long)
    Real.register(Float)
    Real.register(Double)
    Integral.register(BigInteger)
    Rational.register(BigDecimal)

    ### Conversions ###
    global p2j_conv_bigint, p2j_conv_bigdec, p2j_conv_mathcntxt, 
    p2j_conv_bigint    = P2JConvert.create_cy(__p2j_conv_bigint)
    p2j_conv_bigdec    = P2JConvert.create_cy(__p2j_conv_bigdec)
    p2j_conv_mathcntxt = P2JConvert.create_cy(__p2j_conv_mathcntxt)
    reg_conv_cy(env, Integral,        u'java.math.BigInteger',  p2j_check_bigint),
    reg_conv_cy(env, (Decimal, Real), u'java.math.BigDecimal',  p2j_check_bigdec),
    reg_conv_cy(env, Context,         u'java.math.MathContext', p2j_check_mathcntxt),

    return 0

cdef int dealloc_numbers(JEnv env) except -1:
    global BI_ONE, BI_TEN
    BI_ONE = None; BI_TEN = None
    # Note: ABCMeta uses a weak reference set for subclass registrations, no need to deregister

jvm_add_init_hook(init_numbers, 11)
jvm_add_dealloc_hook(dealloc_numbers, 11)
