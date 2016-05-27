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

Internal functions:
    long2bigint      - convert a Python int/long to a java.math.BigInteger
"""

cdef extern from "Python.h":
    ctypedef PyObject PyLongObject
    object _PyLong_FromByteArray(const unsigned char* bytes, size_t n, bint little_endian, bint is_signed)
    int _PyLong_AsByteArray(PyLongObject* v, unsigned char* bytes, size_t n, bint little_endian, bint is_signed) except -1

cdef bigint2long(JEnv env, x):
    cdef JPrimitiveArray arr = x._jcall0('toByteArray')
    cdef JPrimArrayPointer ptr = JPrimArrayPointer(env, arr)
    return _PyLong_FromByteArray(<unsigned char*>ptr.ptr, arr.length, False, True)

cdef long2bigint(JEnv env, x):
    IF PY_VERSION < PY_VERSION_3:
        # In Python 2 we need to convert int to long
        if isinstance(x, int): x = long(x)
    cdef Py_ssize_t n = (x.bit_length() + 7) // 8
    cdef JPrimitiveArray arr = JPrimitiveArray.new_raw(env, get_java_class('[B'), n, &jpad_byte)
    cdef JPrimArrayPointer ptr = JPrimArrayPointer(env, arr)
    _PyLong_AsByteArray(<PyLongObject*><PyObject*>x, <unsigned char*>ptr.ptr, n, False, True)
    ptr.release()
    return get_java_class('java.math.BigInteger')(arr)
    
IF PY_VERSION < PY_VERSION_3:
    builtin_int_type = (int,long)
ELSE:
    builtin_int_type = int

cdef object BI_ONE
cdef object BI_TEN
    
cdef int init_numbers(JEnv env) except -1:
    import operator, numbers
    Object = get_java_class('java.lang.Object')

    ### Number Boxing Types ###
    class Boolean(Object):
        __java_class_name__ = 'java.lang.Boolean'
        def __nonzero__(self): return self._jcall0('booleanValue')
        def __bool__(self): return self._jcall0('booleanValue')
    class Number(Object):
        __java_class_name__ = 'java.lang.Number'
        def __nonzero__(self): return bool(self._jcall0('longValue'))
        def __bool__(self): return bool(self._jcall0('longValue'))
        def __int__(self): return self._jcall0('longValue')
        def __long__(self): return self._jcall0('longValue')
        def __float__(self): return self._jcall0('doubleValue')
    class Byte(Number):
        __java_class_name__ = 'java.lang.Byte'
        def __index__(self): return self._jcall0('byteValue')
    class Short(Number):
        __java_class_name__ = 'java.lang.Short'
        def __index__(self): return self._jcall0('shortValue')
    class Integer(Number):
        __java_class_name__ = 'java.lang.Integer'
        def __index__(self): return self._jcall0('intValue')
    class Long(Number):
        __java_class_name__ = 'java.lang.Long'
        def __index__(self): return self._jcall0('longValue')
    class Float(Number):
        __java_class_name__ = 'java.lang.Float'
    class Double(Number):
        __java_class_name__ = 'java.lang.Double'
        
    ### BigInteger ###
    class BigInteger(Number): # implements numbers.Integral
        __java_class_name__ = 'java.math.BigInteger'
        @property
        def real(self): return self
        @property
        def imag(self): return BigInteger.ZERO
        @property
        def numerator(self): return self
        @property
        def denominator(self): return BI_ONE
        def conjugate(self): return self
        def __complex__(self): return complex(self._jcall0('doubleValue'))
        def __float__(self): return self._jcall0('doubleValue')
        def __int__(self): return bigint2long(jenv(), self)
        def __long__(self): return bigint2long(jenv(), self)
        def __nonzero__(self): return self._jcall0('signum') != 0
        def __bool__(self): return self._jcall0('signum') != 0
        def __hex__(self): return self._jcall1('toString', 16)
        def __oct__(self): return self._jcall1('toString', 8)
        def __trunc__(self): return self
        def __ceil__(self): return self
        def __floor__(self): return self
        def __round__(self, n):
            if n >= 0: return self
            factor = BI_TEN.pow(-n)
            x, rem =  self._jcall1('divideAndRemainder', factor)
            if rem._jcall1('shiftLeft', 1)._jcall1('compareTo', factor) >= 0:
                x = x._jcall1('add', 1) # round 0.5 up
            return x._jcall1('multiply', factor)
        def __abs__(self): return self._jcall0('abs')
        def __pos__(self): return self
        def __neg__(self): return self._jcall0('negate')
        def __invert__(self): return self._jcall0('not')
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
                if isinstance(a, numbers.Integral): return long2bigint(jenv(), long(a))._jcall1(method, b)
                if isinstance(a, numbers.Real):     return fallback(float(a),   float(b))
                if isinstance(a, numbers.Complex):  return fallback(complex(a), complex(b))
                return NotImplemented
            rop.__name__ = str('__r' + fallback.__name__ + '__')
            return op, rop
        def __operator_int(method, fallback): # operator must have `other` as a 32-bit signed int
            def op(a, b):
                if isinstance(b, BigInteger):
                    if b._jcall0('bitLength') >= 32: raise OverflowError()
                    return a._jcall1(method, b._jcall0('intValue'))
                if isinstance(b, numbers.Integral): return a._jcall1(method, b)
                if isinstance(b, float): return fallback(float(a), b)
                return NotImplemented
            op.__name__ = str('__' + fallback.__name__ + '__')
            def rop(b, a):
                if isinstance(a, BigInteger):
                    if b._jcall0('bitLength') >= 32: raise OverflowError()
                    return a._jcall1(method, b._jcall0('intValue'))
                if isinstance(a, builtin_int_type): return fallback(a, int(b))
                if isinstance(a, numbers.Integral): return fallback(int(a), int(b))
                if isinstance(a, numbers.Real):     return fallback(float(a), float(b))
                return NotImplemented
            rop.__name__ = str('__r' + fallback.__name__ + '__')
            return op, rop
        __add__, __radd__ = __operator('add', operator.add)
        __sub__, __rsub__ = __operator('subtract', operator.sub)
        __mul__, __rmul__ = __operator('multiply', operator.mul)
        IF PY_VERSION < PY_VERSION_3:
            __div__, __rdiv__ = __operator('divide', operator.div)
        def __truediv__(self, other):  return BigDecimal(self) / other
        def __rtruediv__(self, other): return other / BigDecimal(self)
        __floordiv__, __rfloordiv__ = __operator('divide', operator.floordiv)
        __divmod__, __rdivmod__ = __operator('divideAndRemainder', divmod)
        __mod__, __rmod__ = __operator('mod', operator.mod)
        __pow_nomod, __rpow__ = __operator_int('pow', pow)
        __lshift__, __rlshift__ = __operator_int('shiftLeft',  operator.lshift)
        __rshift__, __rrshift__ = __operator_int('shiftRight', operator.rshift)
        __and__, __rand__ = __operator('and', operator.and_)
        __xor__, __rxor__ = __operator('xor', operator.xor)
        __or__,  __ror__  = __operator('or',  operator.or_)
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
        __java_class_name__ = 'java.math.BigDecimal'
        @property
        def real(self): return self
        @property
        def imag(self): return BigDecimal.ZERO
        @property
        def numerator(self):
            if self._jcall0('signum') == 0 or self._jcall0('scale') <= 0: return self
            decimal = self._jcall0('stripTrailingZeros')
            scale = decimal._jcall0('scale')
            if scale <= 0: return decimal
            numerator = decimal._jcall0('unscaledValue')
            denominator = BI_TEN._jcall1('pow', scale)
            return numerator._jcall1('divide', numerator._jcall1('gcd', denominator))
        @property
        def denominator(self):
            if self._jcall0('signum') == 0 or self._jcall0('scale') <= 0: return BI_ONE
            decimal = self._jcall0('stripTrailingZeros')
            scale = decimal._jcall0('scale')
            if scale <= 0: return BI_ONE
            numerator = decimal._jcall0('unscaledValue')
            denominator = BI_TEN._jcall1('pow', scale)
            return denominator._jcall1('divide', numerator._jcall1('gcd', denominator))
        def conjugate(self): return self
        def __complex__(self): return complex(self._jcall0('doubleValue'))
        def __float__(self): return self._jcall0('doubleValue')
        def __int__(self): return int(self._jcall0('toBigInteger'))
        def __long__(self): return int(self._jcall0('toBigInteger'))
        def __nonzero__(self): return not self._jcall0('signum') != 0
        def __bool__(self): return self._jcall0('signum') != 0
        def __trunc__(self): return self._jcall2('setScale', 0, 1) # BigDecimal.ROUND_DOWN
        def __ceil__(self): return self._jcall2('setScale', 0, 2) # BigDecimal.ROUND_CEILING
        def __floor__(self): return self._jcall2('setScale', 0, 3) # BigDecimal.ROUND_FLOOR
        def __round__(self, n): return self._jcall2('setScale', n, 4) # BigDecimal.ROUND_HALF_UP
        def __abs__(self): return self._jcall0('abs')
        def __pos__(self): return self._jcall0('plus')
        def __neg__(self): return self._jcall0('negate')
        def __operator(method, fallback):
            import decimal
            def op(a, b):
                if isinstance(b, BigDecimal): return a._jcall1(method, b)
                if isinstance(b, BigInteger): return a._jcall1(method, BigDecimal(b))
                if isinstance(b, decimal.Decimal):  return a._jcall1(method, BigDecimal(unicode(b)))
                if isinstance(b, builtin_int_type): return a._jcall1(method, BigDecimal(long2bigint(jenv(), b)))
                if isinstance(b, float):   return a._jcall1(method, BigDecimal(b))
                if isinstance(b, complex): return fallback(complex(a), b)
                return NotImplemented
            op.__name__ = str('__' + fallback.__name__ + '__')
            def rop(b, a):
                if isinstance(a, BigDecimal): return a._jcall1(method, b)
                if isinstance(a, BigInteger): return BigDecimal(a)._jcall1(method, b)
                if isinstance(a, decimal.Decimal):  return BigDecimal(unicode(b))._jcall1(method, b)
                if isinstance(a, builtin_int_type): return BigDecimal(long2bigint(jenv(), a))._jcall1(method, b)
                if isinstance(a, numbers.Integral): return BigDecimal(long2bigint(jenv(), long(a)))._jcall1(method, b)
                if isinstance(a, numbers.Real):     return BigDecimal(float(a))._jcall1(method, b)
                if isinstance(a, numbers.Complex):  return fallback(complex(a), complex(b))
                return NotImplemented
            rop.__name__ = str('__r' + fallback.__name__ + '__')
            return op, rop
        __add__, __radd__ = __operator('add', operator.add)
        __sub__, __rsub__ = __operator('subtract', operator.sub)
        __mul__, __rmul__ = __operator('multiply', operator.mul)
        IF PY_VERSION < PY_VERSION_3:
            __div__, __rdiv__ = __operator('divide', operator.div)
        __truediv__, __rtruediv__ = __operator('divide', operator.truediv)
        __floordiv__, __rfloordiv__ = __operator('divideToIntegralValue', operator.floordiv)
        __divmod__, __rdivmod__ = __operator('divideAndRemainder', divmod)
        __mod__, __rmod__ = __operator('remainder', operator.mod)
        def __pow__(self, other, mod=None):
            if mod is not None: raise ValueError('mod not supported')
            if isinstance(other, numbers.Integral): return self._jcall1('pow', other)
            if isinstance(other, float): return pow(float(self), other)
            return NotImplemented
        def __rpow__(self, other):
            if isinstance(other, builtin_int_type): return pow(other, int(self))
            if isinstance(other, numbers.Integral): return pow(int(other), int(self))
            if isinstance(other, numbers.Real): return pow(float(other), float(self))
            return NotImplemented
            
    global BI_ONE, BI_TEN
    BI_ONE  = BigInteger.ONE
    BI_TEN  = BigInteger.TEN
        
    numbers.Number.register(Number)
    numbers.Integral.register(Byte)
    numbers.Integral.register(Short)
    numbers.Integral.register(Integer)
    numbers.Integral.register(Long)
    numbers.Real.register(Float)
    numbers.Real.register(Double)
    numbers.Integral.register(BigInteger)
    numbers.Rational.register(BigDecimal)
    return 0

cdef int dealloc_numbers(JEnv env) except -1:
    global BI_ONE, BI_TEN
    BI_ONE  = None; BI_TEN  = None
    # Note: ABCMeta uses a weak reference set for subclass registrations, no need to deregister
JVM.add_init_hook(init_numbers)
JVM.add_dealloc_hook(dealloc_numbers)
