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

Java Arrays
-----------
Python wrappers for primitive and reference Java arrays


Public functions:
    <primitive>_array - functions to create a Java primitive array of the given type
    object_array      - function to create an Java object/reference array

Internal classes:
    JArray          - base class for all Java arrays
    JPrimitiveArray - base class for all primitive Java arrays
    JObjectArray    - base class for all reference Java arrays

FUTURE:
    support critical array access
    support buffer protocol (consumer and exporter) for multi-dimensional primitive arrays
    periodically JNI_COMMIT for writable buffers?
    use PyBuffer_SizeFromFormat instead of struct.calcsize
    support java.util.Arrays JDK 8 additions:
        parallelSort, parallelPrefix, parallelSetAll, setAll, spliterator, stream
"""

from libc.string cimport memchr, memset, strchr

from cpython.object  cimport PyTypeObject
from cpython.number  cimport PyNumber_Index
from cpython.ref     cimport Py_INCREF
from cpython.slice   cimport PySlice_Check
from cpython.list    cimport PyList_New, PyList_SET_ITEM
from cpython.unicode cimport PyUnicode_Check, PyUnicode_AsASCIIString, PyUnicode_DecodeUTF16, PyUnicode_AsUTF16String
from cpython.buffer  cimport PyObject_CheckBuffer, PyObject_GetBuffer, PyBuffer_Release
from cpython.buffer  cimport PyBUF_WRITABLE, PyBUF_INDIRECT, PyBUF_SIMPLE, PyBUF_FORMAT, PyBUF_ND
from cpython.bytes   cimport PyBytes_Check, PyBytes_FromStringAndSize, PyBytes_AS_STRING
cdef extern from "Python.h":
    cdef bint PyByteArray_Check(object o)
    cdef bytearray PyByteArray_FromStringAndSize(const char *bytes, Py_ssize_t size)
    cdef char *PyByteArray_AS_STRING(bytearray)
    cdef Py_ssize_t PyByteArray_GET_SIZE(bytearray)
from cpython.array cimport array
cdef extern from *:
    array newarrayobject(type type, Py_ssize_t size, void *descr)


cdef class JArray(object):
    """
    The base type for Java arrays. Contains the Java references and the length of the array, but
    doesn't do much else.
    """
    cdef readonly JObject __object__
    cdef readonly jsize length
    cdef jarray arr # a simple copy of the reference actually stored in __object__

    cdef inline object wrap(self, JEnv env, JObject obj):
        self.__object__ = obj
        self.arr = obj.obj
        self.length = env.GetArrayLength(self.arr)

    @staticmethod
    cdef inline jsize check_index(object index, jsize n) except -1:
        """Checks, and converts, an index. Adjusts it for things like negative indices."""
        cdef jsize i = index
        if i < 0: i += n
        if i < 0 or i >= n: raise IndexError()
        return i
    @staticmethod
    cdef inline tuple check_slice(object start, object stop, object step, jsize n):
        """Checks, and converts, a slice. Adjusts it for things like negative indices."""
        if step is not None and step != 1: raise ValueError('only slices with a step of 1 (default) are supported')
        cdef jsize i = 0 if start is None else start
        cdef jsize j = n if stop is None else stop
        if i < 0:
            i += n
            if i < 0: i = 0
        elif i > n: i = n

        if j < 0: j += n
        elif j > n: j = n

        if i > j: raise IndexError('%d > %d' % (i,j))
        return i,j
    @staticmethod
    cdef inline withgil(Py_ssize_t n):
        """Releasing the GIL takes 100-200ns, so only release it for larger operations"""
        # memcpy can probably copy about 10-20 bytes/ns
        # Doing any operations probably costs about 10-40 ns/element
        # so when called with a copy command, divide n by (100/itemsize, 128/itemsize so a power of two), otherwise use the big-O n
        return n < 1024

    @staticmethod
    cdef int arraycopy(JEnv env, jarray src, jint srcPos, jarray dest, jint destPos, jint length) except -1:
        cdef jvalue[5] val
        val[0].l = src; val[1].i = srcPos; val[2].l = src; val[3].i = destPos; val[4].i = length
        env.CallStaticVoidMethod(SystemDef.clazz, SystemDef.arraycopy, val, JArray.withgil(length*16))
        return 0

    def __len__(self): return self.length

    # Forward clone method (which is inherited as protected, but is actually public)
    def clone(self): return jenv().CallObjectMethod(self.arr, ObjectDef.clone, NULL, JArray.withgil(self.length//4))

    # MutableSequence methods that change the size of the array raise errors
    def __delitem__(self, i): raise TypeError('Java arrays cannot change size')
    def __iadd__(self, vals): raise TypeError('Java arrays cannot change size')
    def __imul__(self, vals): raise TypeError('Java arrays cannot change size')
    def insert(self, i, val): raise TypeError('Java arrays cannot change size')
    def append(self, val): raise TypeError('Java arrays cannot change size')
    def extend(self, itr): raise TypeError('Java arrays cannot change size')
    def remove(self, val): raise TypeError('Java arrays cannot change size')
    def pop(self, i=None): raise TypeError('Java arrays cannot change size')


########## Primitive Types Python Correlates ##########
cdef bytes buffer_formats_bool = b'?'
cdef bytes buffer_formats_char = b'cuw'
cdef bytes buffer_formats_int  = b'bhilq'
cdef bytes buffer_formats_fp   = b'fdg'

cdef bytes array_typecodes_bool = b''
cdef bytes array_typecodes_char = b'u'
IF PY_VERSION >= PY_VERSION_3_3:
    cdef bytes array_typecodes_int = b'bhilq' # q is available since v3.3
ELSE:
    cdef bytes array_typecodes_int = b'bhil'
cdef bytes array_typecodes_fp = b'fd'

 # Lists loaded with size-0 array.arrays of relevant typecodes so we can use newarrayobject directly
cdef list array_templates_bool
cdef list array_templates_char
cdef list array_templates_int
cdef list array_templates_fp


########## Primitive Array Algorithms ##########
# These use the fused type to be used across all the different primitive types
cdef inline primitive2obj(jprimitive* x):
    """Convert a jprimitive to an object"""
    if jprimitive == jboolean: return x[0] == JNI_TRUE
    elif jprimitive == jchar:  return unichr(x[0])
    else:                      return x[0]
cdef inline int obj2primitive(x, jprimitive* y) except -1:
    """Convert an object to a jprimitive"""
    if  jprimitive == jboolean: y[0] = py2boolean(x)
    elif jprimitive == jbyte:   y[0] = py2byte(x)
    elif jprimitive == jchar:   y[0] = py2char(x)
    elif jprimitive == jshort:  y[0] = py2short(x)
    elif jprimitive == jint:    y[0] = py2int(x)
    elif jprimitive == jlong:   y[0] = py2long(x)
    elif jprimitive == jfloat:  y[0] = py2float(x)
    elif jprimitive == jdouble: y[0] = py2double(x)
    return 0
cdef inline jsize find(jprimitive* buf, jsize len, jprimitive x) nogil:
    """Finds x in buf returning the index to the found value."""
    cdef jprimitive* ind
    cdef jsize i
    if jprimitive == jbyte or jprimitive == jboolean:
        ind = <jprimitive*>memchr(buf, x, len)
        if ind is not NULL: return <jsize>(ind - buf)
    else:
        for i in xrange(len):
            if buf[i] == x: return i
    return -1
cdef inline bint contains(jprimitive* arr, jsize n, x) except -1:
    """Finds if x is contained in arr"""
    cdef jprimitive val
    obj2primitive[jprimitive](x, &val)
    cdef PyThreadState* gilstate = NULL if JArray.withgil(n*sizeof(jprimitive)//64) else PyEval_SaveThread()
    cdef bint out = find[jprimitive](arr, n, val) != -1
    if gilstate is not NULL: PyEval_RestoreThread(gilstate)
    return out
cdef inline jsize index(jprimitive* arr, jsize start, jsize stop, x) except -1:
    """Finds the index of the first x in arr[start:stop], raising a ValueError if not found"""
    cdef jprimitive val
    obj2primitive[jprimitive](x, &val)
    cdef jsize n = stop-start
    cdef PyThreadState* gilstate = NULL if JArray.withgil(n*sizeof(jprimitive)//64) else PyEval_SaveThread()
    cdef jsize i = find[jprimitive](arr+start, n, val)
    if gilstate is not NULL: PyEval_RestoreThread(gilstate)
    if i == -1: raise ValueError('%s is not in array'%x)
    return i+start
cdef inline jsize count(jprimitive* arr, jsize n, x) except -1:
    """Count occurences of x in the array"""
    cdef jprimitive val
    obj2primitive[jprimitive](x, &val)
    cdef jprimitive* buf = arr
    cdef jprimitive* end
    cdef jsize i, count = 0
    cdef PyThreadState* gilstate = NULL if JArray.withgil(n*sizeof(jprimitive)//64) else PyEval_SaveThread()
    if jprimitive == jbyte or jprimitive == jboolean:
        end = buf+n
        while n > 0:
            buf = <jprimitive*>memchr(buf, val, n)
            if buf is NULL: break
            count += 1; buf += 1; n = <jsize>(end - buf)
    else:
        for i in xrange(n):
            if buf[i] == val: count += i
    if gilstate is not NULL: PyEval_RestoreThread(gilstate)
    return count
cdef inline int reverse(jprimitive* arr, jsize n) except -1:
    """Reverse the contents of the array"""
    cdef jsize i = 0, j = n - 1
    cdef jprimitive t
    cdef PyThreadState* gilstate = NULL if JArray.withgil(n*sizeof(jprimitive)//64) else PyEval_SaveThread()
    while i < j:
        t = arr[i]; arr[i] = arr[j]; arr[j] = t
        i += 1; j -= 1
    if gilstate is not NULL: PyEval_RestoreThread(gilstate)
    return 0
cdef inline int fill(jprimitive* arr, jsize start, jsize stop, x) except -1:
    """Fill the contents of the arr[start:stop] with `x`"""
    cdef jsize n = stop-start
    cdef jprimitive val
    obj2primitive[jprimitive](x, &val)
    cdef PyThreadState* gilstate = NULL if JArray.withgil(n*sizeof(jprimitive)//128) else PyEval_SaveThread()
    if jprimitive == jbyte or jprimitive == jboolean:
        memset(arr+start, val, n)
    else:
        # non-byte types either just use a standard loop or a simple memset-0
        if val == 0: memset(arr+start, 0, n*sizeof(jprimitive))
        else:
            while start < stop: arr[start] = val; start += 1
    if gilstate is not NULL: PyEval_RestoreThread(gilstate)
    return 0
cdef inline list tolist(jprimitive* arr, jsize start, jsize stop):
    """Get the contents of the array as a list"""
    cdef jsize i
    arr += start
    cdef list out = PyList_New(stop-start)
    for i in xrange(stop-start):
        x = primitive2obj(arr+i)
        Py_INCREF(x)
        PyList_SET_ITEM(out, i, x)
    return out
cdef inline int setseq(jprimitive* arr, seq, jsize off) except -1:
    """Set the array data starting at `off` to the converted contents of a sequence"""
    cdef jsize i
    for i,x in enumerate(seq, off): obj2primitive(x, arr+i)
    return 0

IF PY_VERSION >= PY_VERSION_3_3 or PY_UNICODE_WIDE:
    cdef void set_char_array_from_ucs4(const PyUCS4* src, jsize n, Py_UCS2* dst) nogil:
        cdef PyUCS4 ch
        cdef const PyUCS4* end = src + n
        while src < end:
            ch = src[0]; src += 1
            if ch >= 0x10000:
                dst[0] = 0xD800 | ((ch >> 10) & 0x3FF)
                dst[1] = 0xDC00 | (ch & 0x3FF)
                dst += 2
            else: dst[0] = ch; dst += 1
    cdef int copy_char_array_from_ucs4(JEnv env, const void* src, Py_ssize_t src_off, Py_ssize_t len,
                                        JPrimitiveArray dst, jsize dst_off, jsize n_elems) except -1:
        cdef const PyUCS4* s = (<const PyUCS4*>src)+src_off
        cdef const PyUCS4* end = (<const PyUCS4*>src)+len
        cdef jsize n_src = 0, n_dst = 0
        while s < end and n_dst < n_elems: n_dst += s[0] >= 0x10000; n_dst += 1; n_src += 1; s += 1
        if n_dst < n_elems: raise ValueError('not enough elements in source unicode')
        if n_dst > n_elems: raise ValueError('cannot fit source unicode data into this array due to surrogate pairs')
        cdef JPrimArrayPointer ptr = JPrimArrayPointer(env, dst, readonly=False)
        set_char_array_from_ucs4((<const PyUCS4*>src)+src_off, n_src, (<Py_UCS2*>ptr.ptr)+dst_off)
        return 0
    cdef inline jsize __get_addl_chars_needed(const PyUCS4* s, Py_ssize_t n) except -1:
        cdef const PyUCS4* end = s + n
        n = 0
        while s < end: n += s[0] >= 0x10000; s += 1
        if sizeof(Py_ssize_t) > sizeof(jsize) and n > 0x7FFFFFFF: raise OverflowError()
        return <jsize>n
IF PY_VERSION >= PY_VERSION_3_3:
    cdef inline Py_ssize_t get_unicode_len(unicode uni): return PyUnicode_GET_LENGTH(uni)
ELSE:
    cdef inline Py_ssize_t get_unicode_len(unicode uni): return PyUnicode_GET_SIZE(uni)
cdef inline jsize get_addl_chars_needed(unicode uni, jsize i, jsize n) except -1:
    """Counts the number of surrogate pairs required to encode the unicode string"""
    IF PY_VERSION >= PY_VERSION_3_3:
        if PyUnicode_KIND(uni) == PyUnicode_4BYTE_KIND:
            return __get_addl_chars_needed((<const PyUCS4*>PyUnicode_DATA(uni))+i, n)
        else: return 0
    ELIF PY_UNICODE_WIDE:
        return __get_addl_chars_needed((<const PyUCS4*>PyUnicode_AS_UNICODE(uni))+i, n)
    ELSE: return 0

cdef int set_char_array(JEnv env, unicode src, Py_ssize_t src_i, JPrimitiveArray dst, jsize dst_i, jsize n) except -1:
    """
    Sets char array data from a unicode string. This tries to be as optimal as possible with
    copying of data. n is the number of characters from src, might need more than n elements in dst
    if src is a unicode string in UCS4 encoding.
    """
    cdef JPrimArrayPointer ptr
    IF PY_VERSION >= PY_VERSION_3_3:
        kind = PyUnicode_KIND(src)
        if kind == PyUnicode_4BYTE_KIND:
            ptr = JPrimArrayPointer(env, dst, readonly=False)
            set_char_array_from_ucs4((<PyUCS4*>PyUnicode_DATA(src))+src_i, n, (<Py_UCS2*>ptr.ptr)+dst_i)
        elif kind == PyUnicode_1BYTE_KIND:
            ptr = JPrimArrayPointer(env, dst, readonly=False)
            widen_unicode[Py_UCS1,Py_UCS2]((<Py_UCS1*>PyUnicode_DATA(src))+src_i, n, (<Py_UCS2*>ptr.ptr)+dst_i)
        else: # kind == PyUnicode_2BYTE_KIND
            dst.p.set(env, dst.arr, dst_i, n, (<Py_UCS2*>PyUnicode_DATA(src))+src_i)
    ELIF PY_UNICODE_WIDE:
        ptr = JPrimArrayPointer(env, dst, readonly=False)
        set_char_array_from_ucs4((<PyUCS4*>PyUnicode_AS_UNICODE(src))+src_i, n, (<Py_UCS2*>ptr.ptr)+dst_i)
    ELSE:
        dst.p.set(env, dst.arr, dst_i, n, PyUnicode_AS_UNICODE(src)+src_i)
    return 0


########### Group functions by primitive type ##########
# JEnv function definitions
#ctypedef jarray (*NewPrimArray)(JEnv env, jsize length) except NULL
ctypedef void *(*GetPrimArrayElements)(JEnv env, jarray array, jboolean *isCopy, jsize len) except NULL
ctypedef int (*ReleasePrimArrayElements)(JEnv env, jarray array, void *elems, jint mode) except -1
ctypedef int (*GetPrimArrayRegion)(JEnv env, jarray array, jsize start, jsize len, void *buf) except -1
ctypedef int (*SetPrimArrayRegion)(JEnv env, jarray array, jsize start, jsize len, const void *buf) except -1
# Python function definitions
ctypedef object (*py_primitive2obj)(void* x)
ctypedef int (*py_obj2primitive)(x, void* y) except -1
ctypedef bint (*py_contains)(void* arr, jsize n, x) except -1
ctypedef jsize (*py_index)(void* arr, jsize i, jsize j, x) except -1
ctypedef jsize (*py_count)(void* arr, jsize n, x) except -1
ctypedef int (*py_reverse)(void* arr, jsize n) except -1
ctypedef int (*py_fill)(void* arr, jsize i, jsize j, x) except -1
ctypedef list (*py_tolist)(void* arr, jsize i, jsize j)
ctypedef int (*py_setseq)(void* arr, seq, jsize off) except -1

cdef enum PrimitiveType:
    PT_Boolean
    PT_Char
    PT_Integral # signed
    PT_FloatingPoint

cdef struct JPrimArrayDef:
    # Basic info
    char sig
    jsize itemsize
    PrimitiveType type
    char[3] buffer_format
    const char* buffer_formats
    void* array_descr
    const char* array_typecodes
    # JEnv functions
    NewPrimArray new
    GetPrimArrayElements get_elems
    ReleasePrimArrayElements rel_elems
    GetPrimArrayRegion get
    SetPrimArrayRegion set
    # Python functions
    py_primitive2obj primitive2obj
    py_obj2primitive obj2primitive
    py_contains contains
    py_index index
    py_count count
    py_reverse reverse
    py_fill fill
    py_tolist tolist
    py_setseq setseq
    # Java static methods from java.util.Arrays
    # copyOf, copyOfRange, fill, and fill (range) are all re-coded in Cython
    jmethodID sort, sort_range, binarySearch, binarySearch_range
    jmethodID hashCode, equals, toString

# Would prefer to be able to use PyBuffer_SizeFromFormat, but that method is not implemented
# So instead, we hard-code the boolean and char values and use the struct module for the rest
#cdef inline int get_buffer_format_by_size(jsize itemsize, bytes formats, char* out) except -1:
#    cdef bytes f, F = next((f for f in formats if PyBuffer_SizeFromFormat(f) == itemsize), None)
#    if F is None: F = next((b'='+f for f in formats if PyBuffer_SizeFromFormat(b'='+f) == itemsize), None)
#    if F is None: F = b'%dB'%itemsize # fallback
#    out[0] = F[0]; out[1] = F[1] if len(F) > 1 else 0; out[2] = 0
cdef inline int get_buffer_format_by_size(jsize itemsize, bytes formats, char* out) except -1:
    from struct import calcsize
    cdef bytes f, F = next((f for f in formats if calcsize(f) == itemsize), None)
    if F is None: F = next((b'='+f for f in formats if calcsize(b'='+f) == itemsize), None)
    if F is None: F = b'%dB'%itemsize # fallback
    out[0] = F[0]; out[1] = F[1] if len(F) > 1 else 0; out[2] = 0
cdef inline void* get_array_descr_by_size(jsize itemsize, list templates) except? NULL:
    cdef array t = next((t for t in templates if t.itemsize == itemsize), None)
    return NULL if t is None else t.ob_descr

cdef int create_JPAD(JEnv env, JPrimArrayDef* x, jprimitive p, PrimitiveType type, char sig,
        NewPrimArray new, GetPrimArrayElements get_elems, ReleasePrimArrayElements rel_elems,
        GetPrimArrayRegion get, SetPrimArrayRegion set) except -1:
    x[0].sig = sig
    x[0].itemsize = sizeof(jprimitive)
    x[0].type = type
    if type == PT_Boolean:
        #get_buffer_format_by_size(sizeof(jprimitive), buffer_formats_bool, x[0].buffer_format)
        x[0].buffer_format[0] = b'?'; x[0].buffer_format[1] = 0 # 1 byte boolean
        x[0].buffer_formats = buffer_formats_bool
        x[0].array_descr = get_array_descr_by_size(sizeof(jprimitive), array_templates_bool)
        x[0].array_typecodes = array_typecodes_bool
    elif type == PT_Char:
        #get_buffer_format_by_size(sizeof(jprimitive), buffer_formats_char, x[0].buffer_format)
        x[0].buffer_format[0] = b'u'; x[0].buffer_format[1] = 0 # UCS-2/UTF-16 character
        x[0].buffer_formats = buffer_formats_char
        x[0].array_descr = get_array_descr_by_size(sizeof(jprimitive), array_templates_char)
        x[0].array_typecodes = array_typecodes_char
    elif type == PT_Integral:
        get_buffer_format_by_size(sizeof(jprimitive), buffer_formats_int,  x[0].buffer_format)
        x[0].buffer_formats = buffer_formats_int
        x[0].array_descr = get_array_descr_by_size(sizeof(jprimitive), array_templates_int)
        x[0].array_typecodes = array_typecodes_int
    elif type == PT_FloatingPoint:
        get_buffer_format_by_size(sizeof(jprimitive), buffer_formats_fp,   x[0].buffer_format)
        x[0].buffer_formats = buffer_formats_fp
        x[0].array_descr = get_array_descr_by_size(sizeof(jprimitive), array_templates_fp)
        x[0].array_typecodes = array_typecodes_fp
    else: raise ValueError()

    # The casts here supress MSVC warnings created by Cython substituting int for jint/jsize in some odd places
    x[0].new = <NewPrimArray>new
    x[0].get_elems = <GetPrimArrayElements>get_elems
    x[0].rel_elems = <ReleasePrimArrayElements>rel_elems
    x[0].get = <GetPrimArrayRegion>get
    x[0].set = <SetPrimArrayRegion>set
    x[0].primitive2obj = <py_primitive2obj>primitive2obj[jprimitive]
    x[0].obj2primitive = <py_obj2primitive>obj2primitive[jprimitive]
    x[0].contains = <py_contains>contains[jprimitive]
    x[0].index    = <py_index>index[jprimitive]
    x[0].count    = <py_count>count[jprimitive]
    x[0].reverse  = <py_reverse>reverse[jprimitive]
    x[0].fill     = <py_fill>fill[jprimitive]
    x[0].tolist   = <py_tolist>tolist[jprimitive]
    x[0].setseq   = <py_setseq>setseq[jprimitive]
    cdef unicode u_sig = unichr(sig)
    if type == PT_Boolean:
        x[0].sort         = NULL
        x[0].sort_range   = NULL
        x[0].binarySearch = NULL
        x[0].binarySearch_range = NULL
    else:
        x[0].sort         = env.GetStaticMethodID(Arrays, 'sort', '([%s)V'%u_sig)
        x[0].sort_range   = env.GetStaticMethodID(Arrays, 'sort', '([%sII)V'%u_sig)
        x[0].binarySearch = env.GetStaticMethodID(Arrays, 'binarySearch', '([%s%s)I'%(u_sig,u_sig))
        x[0].binarySearch_range = env.GetStaticMethodID(Arrays, 'binarySearch', '([%sII%s)I'%(u_sig,u_sig))
    x[0].hashCode     = env.GetStaticMethodID(Arrays, 'hashCode', '([%s)I'%u_sig)
    x[0].equals       = env.GetStaticMethodID(Arrays, 'equals',   '([%s[%s)Z'%(u_sig,u_sig))
    x[0].toString     = env.GetStaticMethodID(Arrays, 'toString', '([%s)Ljava/lang/String;'%u_sig)

cdef JPrimArrayDef jpad_boolean, jpad_byte, jpad_char, jpad_short, jpad_int, jpad_long, jpad_float, jpad_double
cdef JPrimArrayDef* jpads[8]

########## Primitive Array Iterator Wrapper ##########
cdef class JPrimArrayIter(object):
    cdef JPrimArrayPointer ptr
    cdef jsize itemsize
    cdef py_primitive2obj convert
    cdef char* cur
    cdef char* end
    def __cinit__(self, JPrimitiveArray arr, reversed=True):
        cdef jsize itemsize = arr.p.itemsize
        self.ptr = JPrimArrayPointer(jenv(), arr, False)
        self.convert = arr.p.primitive2obj
        if reversed:
            self.itemsize = -itemsize
            self.end = (<char*>self.ptr.ptr) - 1
            self.cur = self.end + arr.length*itemsize
        else:
            self.itemsize = itemsize
            self.cur = <char*>self.ptr.ptr
            self.end = self.cur + arr.length*itemsize
    def __iter__(self): return self
    def __next__(self):
        if self.cur == self.end: raise StopIteration()
        x = self.convert(self.cur)
        self.cur += self.itemsize
        return x

########## Primitive Array Pointer Wrapper ##########
cdef class JPrimArrayPointer(object):
    """
    An object that gets the pointer to the primitive array data and upon deallocation automatically
    releases the pointer. Basically create this at the first line of the function, access the 'ptr'
    attribute, and when the function finishes this object will be dealloced and the array released.
    By default it uses the 'critical' functions and does it in a read-only mode.
    """
    cdef JPrimitiveArray arr
    cdef JEnv env
    cdef void* ptr
    cdef bint readonly
    cdef jboolean isCopy
    cdef ReleasePrimArrayElements rel
    def __cinit__(self, JEnv env, JPrimitiveArray arr, bint critical=True, bint readonly=True):
        self.arr = arr
        self.env = env
        self.readonly = readonly
        if env is None: env = jenv()
        if critical:
            self.rel = JEnv.ReleasePrimitiveArrayCritical
            self.ptr = env.GetPrimitiveArrayCritical(arr.arr, &self.isCopy)
        else:
            self.rel = arr.p.rel_elems
            self.ptr = arr.p.get_elems(env, arr.arr, &self.isCopy, arr.length)
    cdef inline release(self):
        cdef JEnv env = self.env
        if self.ptr is not NULL:
            if env is None: env = jenv()
            self.rel(env, self.arr.arr, self.ptr, JNI_ABORT if self.readonly and self.isCopy else 0)
            self.ptr = NULL
            self.arr = None
            self.env = None
    def __dealloc__(self): self.release()
    IF PY_VERSION < PY_VERSION_3:
        # In Python 2.7, the new buffer protocol is supported, but numpy is silly and doesn't use
        # it... so we define the old buffer protocol on this object and pass it back from the
        # __buffer__ attribute of the JPrimitiveArray. We need this indirection so that we can release
        # the array when the buffer object is released.
        def __getreadbuffer__(self, Py_ssize_t segment, void **buf):
            if segment != 0: raise ValueError('primitive arrays are single segment')
            buf[0] = self.ptr
            return self.arr.length*self.arr.p.itemsize
        def __getwritebuffer__(self, Py_ssize_t segment, void **buf):
            if segment != 0: raise ValueError('primitive arrays are single segment')
            buf[0] = self.ptr
            self.readonly = False
            return self.arr.length*self.arr.p.itemsize
        def __getsegcount__(self, Py_ssize_t *lenp):
            if lenp is not NULL: lenp[0] = self.arr.length*self.arr.p.itemsize
            return 1


########## Java Primitive Array ##########
cdef class JPrimitiveArray(JArray):
    """
    Base class for clases that wrap a Java primitive array. This provides the following methods,
    either to emulate Python sequences or to make the java.util.Arrays functions easy to use.
    Additionally, it supports the buffer protocol.

    Initializer:
        nothing         length-0 array
        integer         array of all Falses/0s of the given length
        Java array      copy of array (must be of same primitive type)
        array.array     copy of data (only if same data type)
        bytes/bytearray copy of data (length must be a multiple of the primitive size)
        unicode         copy of data (only for making char arrays)
        buffer-object   copy of data (only if same data type or bytes and length works)
        memoryview      copy of data (only if same data type or bytes and length works)
        sequence/*args  array containing each element converted

    Properties:
        arr.length          the length of the array

    Utility functions:
        arr.tolist([start[, stop]])        copies data to a new list
        arr.tobytearray([start[, stop]])   copies data to a new bytearray
        arr.tobytes([start[, stop]])       copies data to a new bytes
        arr.toarray([start[, stop]])       copies data to a new array.array
        arr.tounicode([start[, stop]])     copies data to new unicode string (char arrays only)
        arr.copyto(dst[, start[, stop[, dst_off]]])   partial copy to a destination object

    Sequence functions:
        len(arr)
        x = arr[i]
        arr[i] = x
        iter(arr)
        reversed(arr)
        x in arr
        arr.index(x[, start[, stop]])
        arr.count(x)
        arr.reverse()

    Extended sequence functions:
        x = arr[:]      copies data to a new Java primitive array
        arr.copyto(dst[, start[, stop[, dst_off]]])
                        copies the data from arr[start:stop] to dst[dst_off:dst_off+stop-start]
                        dst can be a primitive Java array of the same type, bytearray, array.array
                        of the same type or bytes, or a writable buffer-object or memoryview of the
                        same type or bytes; if dst uses bytes then the destination indices are
                        dst_off:dst_off+sizeof(prim)*(stop-start) (notably the dst_off is used
                        as-is)
        arr.copyfrom(src[, start[, stop[, src_off]]])
                        copies the data from src[src_off:src_off+stop-start] to arr[start:stop]
                        src can be a primitive Java array of the same type, bytearray, bytes,
                        unicode (for char arrays), array.array of the same type or bytes, a
                        writable buffer-object or memoryview of the same type or bytes, or a
                        sequence; if src uses bytes then the source indices are
                        src_off:src_off+sizeof(prim)*(stop-start) (notably the src_off is used
                        as-is)
        a[i:j] = x      set the values in i:j to the value(s) of x
                        if x is a primitive Java array of the same type, bytes/bytearray,
                        array.array of the same type or bytes, a writable buffer-object or
                        memoryview of the same type or bytes, a unciode string (if a is a char
                        array), or a sequence, then x must have a suitable length; otherwise x
                        can be a scalar in which case all values in the slice are set to the
                        same value

    java.util.Arrays mapped functions:
        arr.binarySearch(key[, fromIndex[, toIndex]]):
        arr.sort([fromIndex[, toIndex]])
        arr[i:j] = x -> arr.fill(x[, fromIndex[, toIndex]]) when x is a scalar
                        simulated, supports Python negative indices
        x = arr[i:j] -> copyOf/copyOfRange
                        simulated, supports Python negative indices and Java length extension
        arr == other -> equals(arr, other)
        arr != other -> not equals(arr, other)
        hash(arr)    -> hashCode(arr)
        str(arr)     -> toString(arr)
    """
    cdef JPrimArrayDef* p
    """The primitive array definitions for this array."""

    @staticmethod
    cdef JPrimitiveArray new_raw(JEnv env, object cls, Py_ssize_t length, JPrimArrayDef* p):
        """
        Creates a new Java array of the given class, length, and definitions. `cls` must be a
        subclass of JPrimitiveArray and JavaClass. The array is filled with 0s/Falses.
        """
        if sizeof(Py_ssize_t) > sizeof(jsize) and length > 0x7FFFFFFF: raise OverflowError()
        cdef JPrimitiveArray arr = JPrimitiveArray.__new__(cls)
        arr.wrap(env, JObject.create(env, p.new(env, <jsize>length)))
        arr.p = p
        return arr

    @staticmethod
    cdef JPrimitiveArray wrap_arr(JEnv env, object cls, JObject obj, JPrimArrayDef* p):
        """
        Wrap a Java array of the given class and definition. `cls` must be a subclass of
        JPrimitiveArray and JavaClass.
        """
        cdef JPrimitiveArray arr = JPrimitiveArray.__new__(cls)
        arr.wrap(env, obj)
        arr.p = p
        return arr

    @staticmethod
    cdef JPrimitiveArray create(object args, object cls, JPrimArrayDef* p):
        """
        Creates a new array with the contents of `args` of the given class and definitions. `cls`
        must be a subclass of JPrimitiveArray and JavaClass. The `args` must be a sequence of 0 or
        more elements. For a length of 0, a 0-length array is returned. For a length greater then 1
        each value is converted and stored in the array. For a length of 1, the value can be a
        JObject, an instance of `cls`, an integer, byte, bytearray, unicode (if a char array), an
        array.array, an object that exports the buffer protocol, or a sequence-like object.
        """
        cdef JEnv env = jenv()
        cdef Py_ssize_t n
        cdef JPrimArrayPointer ptr
        cdef JPrimitiveArray arr
        cdef int kind
        cdef jsize pairs
        cdef void* data
        cdef bytes b
        cdef Py_buffer buf

        # No arguments -> empty array
        if len(args) == 0: return JPrimitiveArray.new_raw(env, cls, 0, p)

        if len(args) == 1:
            arg = args[0]
            # JObject -> wrap object
            if isinstance(arg, JObject):
                return JPrimitiveArray.wrap_arr(env, cls, arg, p)

            # <Type>Array -> copy of old array
            if isinstance(arg, cls):
                n = (<JPrimitiveArray>arg).length
                arr = JPrimitiveArray.new_raw(env, cls, n, p)
                ptr = JPrimArrayPointer(env, arg)
                p.set(env, arr.arr, 0, <jsize>n, ptr.ptr)
                return arr

            # Integer -> empty array of the given length
            try: n = PyNumber_Index(arg)
            except TypeError: pass
            else:
                if n < 0: raise ValueError('Cannot create negative sized array')
                return JPrimitiveArray.new_raw(env, cls, n, p)

            # bytes/bytearray
            if PyBytes_Check(arg) or PyByteArray_Check(arg):
                n = len(arg)
                if (n%p.itemsize) != 0: raise ValueError('length of bytes or bytearray must be a multiple of %d'%p.itemsize)
                n //= p.itemsize
                arr = JPrimitiveArray.new_raw(env, cls, n, p)
                p.set(env, arr.arr, 0, <jsize>n,
                    PyBytes_AS_STRING(arg) if PyBytes_Check(arg) else PyByteArray_AS_STRING(arg))
                return arr

            # unicode -> CharArray
            if p.type == PT_Char and PyUnicode_Check(arg):
                n = get_unicode_len(arg)
                if sizeof(Py_ssize_t) > sizeof(jsize) and n > 0x7FFFFFFF: raise OverflowError()
                pairs = get_addl_chars_needed(arg, 0, <jsize>n)
                if sizeof(Py_ssize_t) > sizeof(jsize) and n+pairs > 0x7FFFFFFF: raise OverflowError()
                arr = JPrimitiveArray.new_raw(env, cls, <jsize>(n+pairs), p)
                set_char_array(env, arg, 0, arr, 0, <jsize>n)
                return arr
            
            # array.array
            if JPrimitiveArray.check_arrayarray(arg, p):
                n = (len(arg) // p.itemsize) if arg.itemsize == 1 else len(arg)
                arr = JPrimitiveArray.new_raw(env, cls, n, p)
                p.set(env, arr.arr, 0, <jsize>n, (<array>arg).data.as_voidptr)
                return arr

            # object with buffer protocol
            if JPrimitiveArray.get_buffer(arg, p, &buf):
                try:
                    n = buf.len // p.itemsize
                    arr = JPrimitiveArray.new_raw(env, cls, n, p)
                    p.set(env, arr.arr, 0, <jsize>n, buf.buf)
                    return arr
                finally: PyBuffer_Release(&buf)

            # Sequence -> forward to having more than 1 argument
            from collections import Iterable, Sized
            if isinstance(arg, Iterable) and isinstance(arg, Sized): args = arg
        # Go through sequence and convert each argument
        arr = JPrimitiveArray.new_raw(env, cls, len(args), p)
        ptr = JPrimArrayPointer(env, arr, readonly=False)
        arr.p.setseq(ptr.ptr, args, 0)
        return arr

    ##### Buffer Protocol - Consumer and Exporter #####
    # For details on the buffer protocol, see:
    #    https://www.python.org/dev/peps/pep-3118/
    #    https://docs.python.org/2/c-api/buffer.html
    #    http://docs.cython.org/src/userguide/buffer.html
    #PyBUF_SIMPLE         = 0x000                   contiguous buffer of bytes, 1D
    #PyBUF_WRITABLE       = 0x001
    #PyBUF_FORMAT         = 0x004
    #PyBUF_ND             = 0x008                   C-contiguous buffer, ND, shape must not be NULL
    #PyBUF_STRIDES        = 0x010 | PyBUF_ND        strides must not be NULL
    #PyBUF_C_CONTIGUOUS   = 0x020 | PyBUF_STRIDES
    #PyBUF_F_CONTIGUOUS   = 0x040 | PyBUF_STRIDES
    #PyBUF_ANY_CONTIGUOUS = 0x080 | PyBUF_STRIDES
    #PyBUF_INDIRECT       = 0x100 | PyBUF_STRIDES   must have suboffset set, but can be set to NULL
    # Memoryview uses 0x11C (PyBUF_INDIRECT|PyBUF_FORMAT)
    @staticmethod
    cdef bint get_buffer(object o, JPrimArrayDef* p, Py_buffer *buf, bint writable=False) except -1:
        """
        Gets a buffer from a Python object that is compatible with the primitive array definitions
        given. If this is not possible, False is returned. Otherwise True is returned and the
        buffer object is filled out. If True is returned, PyBuffer_Release needs to be called on
        the buffer object.
        """
        cdef bytes format, bo
        cdef jsize itmsz
        cdef bint good, native_bo
        if not PyObject_CheckBuffer(o): return False
        cdef int flags = (PyBUF_WRITABLE if writable else 0)|PyBUF_ND|PyBUF_FORMAT|PyBUF_SIMPLE
        PyObject_GetBuffer(o, buf, flags)
        try:
            # Very basic checks for failure first - readonly flag, length, and number of dimensions
            if writable and buf.readonly or (buf.len%p.itemsize) != 0 or buf.ndim > 1:
                PyBuffer_Release(buf)
                return False
            itmsz, format, native_bo = JPrimitiveArray.get_buffer_info(buf)
            # A good/useable buffer is a simple buffer (B with size 1) or a buffer of the same
            # basic type with the same sized items and the same byte ordering
            good = ((itmsz == 1 and format == b'B') or
                    (native_bo and p.itemsize == itmsz and format in p.buffer_formats))
            if not good: PyBuffer_Release(buf)
            return good
        except: PyBuffer_Release(buf); raise
    @staticmethod
    cdef tuple get_buffer_info(Py_buffer *buf):
        """
        Gets the basic information about a buffer from the buffer pointer, returning a tuple of
        itemsize (calculated if needed), format (without the byte-order mark), and a boolean if the
        byte order is the native byteorder.
        """
        # Get format and itemsize of the buffer
        cdef bytes format = b'B' if buf.format is NULL else buf.format
        cdef Py_ssize_t itmsz = buf.itemsize
        # PyBuffer_SizeFromFormat would be best, but it isn't implemented
        #if itmsz <= 0: buf.itemsize = itmsz = PyBuffer_SizeFromFormat(format)
        if itmsz <= 0:
            from struct import calcsize
            buf.itemsize = itmsz = calcsize(format)
        # Get the byte ordering (@ and = are native, > and ! are big endian, and < is little endian)
        cdef bytes bo = b'@' # default value
        if format[0] in b'@=<>!':
            bo = format[0]
            if bo == b'!': bo = b'>'
            format = format[1:]
        import sys
        cdef bint native_bo = itmsz == 1 or (bo in b'@=') or bo == (b'<' if sys.byteorder=='little' else b'>')
        return itmsz, format, native_bo
    def __getbuffer__(self, Py_buffer *buffer, int flags):
        """
        Gets the 1D buffer of this object, supporting all flags. Regardless of the flags given, if
        fills out all parts of the buffer object (inc format, shape, strides, and suboffsets).

        Writable buffers are dealt with a bit oddly since the JNI probably will not pin the array
        for us, meaning that a copy is made and when released the changes are written back. There
        does not seem to be any good way to periodically commit the changes to the data if in fact
        we do not have a direct pointer to the data.
        """
        cdef jboolean isCopy
        buffer.buf = self.p.get_elems(jenv(), self.arr, &isCopy, self.length)
        buffer.len = self.length*self.p.itemsize
        buffer.readonly = ((flags&PyBUF_WRITABLE) == 0) and isCopy
        buffer.format = self.p.buffer_format
        buffer.ndim = 1
        buffer.shape = <Py_ssize_t*>malloc(sizeof(Py_ssize_t))
        if buffer.shape is NULL:
            self.p.rel_elems(jenv(), self.arr, buffer.buf, JNI_ABORT if buffer.readonly else 0)
            raise MemoryError()
        buffer.shape[0] = self.length
        buffer.strides = &buffer.itemsize
        buffer.suboffsets = NULL
        buffer.itemsize = self.p.itemsize
        buffer.internal = NULL
        buffer.obj = self
    def __releasebuffer__(self, Py_buffer *buffer):
        """
        Releases the buffer acquired through __getbuffer__. If the buffer was aquired as writable
        and was not pinned, the changes are committed at this point.
        """
        # TODO: periodically JNI_COMMIT?
        free(buffer.shape)
        self.p.rel_elems(jenv(), self.arr, buffer.buf, JNI_ABORT if buffer.readonly else 0)
    IF PY_VERSION < PY_VERSION_3:
        property __buffer__:
            def __get__(self): return JPrimArrayPointer(None, self, False, True)


    ##### Conversion to another type #####
    def tolist(self, start=None, stop=None):
        """Return a list with a copy of the array data."""
        cdef jsize i,j
        i,j = JArray.check_slice(start, stop, 1, self.length)
        cdef JPrimArrayPointer ptr = JPrimArrayPointer(jenv(), self)
        return self.p.tolist(ptr.ptr, i, j)
    def tobytearray(self, start=None, stop=None):
        """Return a bytearray with a copy of the array data."""
        cdef jsize i,j
        i,j = JArray.check_slice(start, stop, 1, self.length)
        cdef jsize size = (j-i)*self.p.itemsize
        cdef bytearray b = PyByteArray_FromStringAndSize(NULL, size)
        self.p.get(jenv(), self.arr, i, j-i, PyByteArray_AS_STRING(b))
        return b
    def tobytes(self, start=None, stop=None):
        """Return a bytes with a copy of the array data."""
        cdef jsize i,j
        i,j = JArray.check_slice(start, stop, 1, self.length)
        cdef jsize size = (j-i)*self.p.itemsize
        cdef bytes b = PyBytes_FromStringAndSize(NULL, size)
        self.p.get(jenv(), self.arr, i, <jsize>(j-i), PyBytes_AS_STRING(b))
        return b
    def toarray(self, start=None, stop=None):
        """Return an array with a copy of the array data."""
        cdef jsize i,j
        i,j = JArray.check_slice(start, stop, 1, self.length)
        cdef void* arr_d = self.p.array_descr
        if arr_d is NULL: raise TypeError('Unable to convert to array, no typecode is acceptable')
        cdef array a = newarrayobject(array, j-i, arr_d)
        self.p.get(jenv(), self.arr, i, <jsize>(j-i), a.data.as_chars)
        return a
    def copyto(self, dst, start=None, stop=None, Py_ssize_t dst_off=0):
        """
        Copy the data of this array to another Java array, bytearray, array.array, or
        buffer-object. Copies the data from start (inclusive) to stop (exclusive) to the offset
        dst_off in the destination object. The destintaion offset is interprettd in the data type
        of the destination object.
        """
        cdef jsize i,j,n
        i,j = JArray.check_slice(start, stop, 1, self.length)
        n = j-i
        if n == 0: return

        # Copy data to the destination
        cdef JEnv env = jenv()
        cdef JPrimitiveArray dst_arr
        cdef JPrimArrayPointer ptr
        cdef Py_buffer buf
        if isinstance(dst, type(self)):
            # Copy to Java array
            dst_arr = dst
            if dst_off < 0:
                dst_off += dst_arr.length
                if dst_off < 0: dst_off = 0
            if dst_off+n > dst_arr.length: raise ValueError('not enough space in destination Java array')
            ptr = JPrimArrayPointer(env, self)
            self.p.set(env, dst_arr.arr, <jsize>dst_off, n, (<char*>ptr.ptr)+i*self.p.itemsize)
        elif PyByteArray_Check(dst):
            # Copy to bytearray
            if dst_off < 0:
                dst_off += PyByteArray_GET_SIZE(dst)
                if dst_off < 0: dst_off = 0
            if dst_off+n*self.p.itemsize > PyByteArray_GET_SIZE(dst): raise ValueError('not enough space in destination bytearray')
            self.p.get(env, self.arr, i, n, PyByteArray_AS_STRING(dst)+dst_off)
        elif JPrimitiveArray.check_arrayarray(dst, self.p):
            # Copy to array.array
            if dst_off < 0:
                dst_off += len(dst)
                if dst_off < 0: dst_off = 0
            if dst_off+((n*self.p.itemsize) if dst.itemsize==1 else n) > len(dst): raise ValueError('not enough space in destination array.array')
            self.p.get(env, self.arr, i, n, (<array>dst).data.as_chars+dst_off)
        elif JPrimitiveArray.get_buffer(dst, self.p, &buf, True):
            # Copy to buffer
            try:
                if dst_off < 0:
                    dst_off += buf.len
                    if dst_off < 0: dst_off = 0
                if dst_off+n*self.p.itemsize != buf.len: raise ValueError('not enough space in destination buffer')
                self.p.get(env, self.arr, i, n, (<char*>buf.buf)+dst_off*buf.itemsize)
            finally: PyBuffer_Release(&buf)
        else: raise TypeError('dst')
    def copyfrom(self, JObjectArray src, start=None, stop=None, Py_ssize_t src_off=0):
        """
        Copy the data from another Java array, bytearray, bytes, unicode (for char arrays),
        array.array, buffer-object, or sequence to this array. Copies the data to start
        (inclusive) to stop (exclusive) from the offset src_off in the source object. The source
        offset is interpreted in the data type of the source object.
        """
        cdef jsize i,j,n
        i,j = JArray.check_slice(start, stop, 1, self.length)
        n = j-i
        if n == 0: return
        
        from collections import Iterable, Sized

        # Copy data to this array
        cdef JEnv env = jenv()
        cdef JPrimitiveArray src_arr
        cdef JPrimArrayPointer ptr
        cdef Py_buffer buf
        if isinstance(src, type(self)):
            # Copy from Java array
            src_arr = src
            if src_off < 0:
                src_off += src_arr.length
                if src_off < 0: src_off = 0
            if src_off+n > src_arr.length: raise ValueError('not enough elements in source Java array')
            ptr = JPrimArrayPointer(env, src_arr)
            src_arr.p.set(env, self.arr, i, n, (<char*>ptr.ptr)+src_off*src_arr.p.itemsize)
        elif PyByteArray_Check(src) or PyBytes_Check(src):
            # Copy from bytearray or bytes
            if src_off < 0:
                src_off += len(src)
                if src_off < 0: src_off = 0
            if src_off+n*self.p.itemsize > len(src): raise ValueError('not enough elements in source bytearray/bytes')
            self.p.set(env, self.arr, i, n, (PyByteArray_AS_STRING(src) if PyByteArray_Check(src) else PyBytes_AS_STRING(src))+src_off)
        elif self.p.type == PT_Char and PyUnicode_Check(src):
            # Copy from unicode
            if src_off < 0:
                src_off += get_unicode_len(src)
                if src_off < 0: src_off = 0
            IF PY_VERSION >= PY_VERSION_3_3:
                if PyUnicode_KIND(src) == PyUnicode_4BYTE_KIND:
                    copy_char_array_from_ucs4(env, PyUnicode_DATA(src), src_off, PyUnicode_GET_LENGTH(src), self, i, n)
                else:
                    if src_off+n > get_unicode_len(src): raise ValueError('not enough elements in source unicode')
                    set_char_array(env, src, src_off, self, i, n)
            ELIF PY_UNICODE_WIDE:
                copy_char_array_from_ucs4(env, PyUnicode_AS_UNICODE(src), src_off, PyUnicode_GET_SIZE(src), self, i, n)
            ELSE:
                if src_off+n > get_unicode_len(src): raise ValueError('not enough elements in source unicode')
                set_char_array(env, src, src_off, self, i, n)            
        elif JPrimitiveArray.check_arrayarray(src, self.p):
            # Copy from array.array
            if src_off < 0:
                src_off += len(src)
                if src_off < 0: src_off = 0
            if src_off+((n*self.p.itemsize) if src.itemsize==1 else n) > len(src): raise ValueError('not enough elements in source array.array')
            self.p.set(env, self.arr, i, n, (<array>src).data.as_chars+src_off)
        elif JPrimitiveArray.get_buffer(src, self.p, &buf, True):
            # Copy from buffer
            try:
                if src_off < 0:
                    src_off += buf.len
                    if src_off < 0: src_off = 0
                if src_off+n*self.p.itemsize != buf.len: raise ValueError('not enough elements in source buffer')
                self.p.set(env, self.arr, i, n, (<char*>buf.buf)+src_off*buf.itemsize)
            finally: PyBuffer_Release(&buf)
        elif isinstance(src, Iterable) and isinstance(src, Sized):
            # Copy from sequence
            if src_off < 0:
                src_off += len(src)
                if src_off < 0: src_off = 0
            if src_off+n > len(src): raise ValueError('not enough elements in source sequence')
            ptr = JPrimArrayPointer(env, self, readonly=False)
            self.p.setseq(ptr.ptr, src if src_off == 0 else src[src_off:], i)
        else: raise TypeError('src')
        # unicode
        
    @staticmethod
    cdef inline bint check_arrayarray(object a, JPrimArrayDef* p) except -1:
        """
        Checks that an object is an array.array with appropiate typecode and itemsize for the
        primitive array definition given.
        """
        return isinstance(a, array) and (
                        a.typecode == 'B' and (len(a)%p.itemsize)==0 or
                        a.typecode in p.array_typecodes and a.itemsize == p.itemsize)

    ##### Get Functions #####
    def __getitem__(self, index):
        """
        Get an item, either from a slice with step 1 or a single index. A slice creates a new
        array with a copy. If the upper bound of the slice is greater than the length of the
        array, the length is extended and zeros are added.
        """
        cdef jsize i, j
        if PySlice_Check(index):
            if index.step is not None and index.step != 1: raise ValueError('only slices with a step of 1 (default) are supported')
            i = 0 if index.start is None else index.start
            j = self.length if index.stop is None else index.stop
            return self.copy(i, j)
        cdef jvalue x
        self.p.get(jenv(), self.arr, JArray.check_index(index, self.length), 1, &x)
        return self.p.primitive2obj(&x)
    cdef copy(self, jsize i, jsize j):
        """
        Emulates java.util.Arrays.copyOf and java.util.Arrays.copyOfRange with Python handling of
        negative indices, but still does length extension if j is greater than the length of the
        array.
        """
        #if i == 0: return java.util.Arrays.copyOf[type(self),int](self, j)
        #else:      return java.util.Arrays.copyOfRange[type(self),int,int](self, i, j)
        if i < 0:
            i += self.length
            if i < 0: i = 0
        elif i > self.length: i = self.length
        if j < 0: j += self.length
        if i > j: raise IndexError('%d > %d' % (i,j))
        cdef JEnv env = jenv()
        cdef JPrimitiveArray arr = JPrimitiveArray.new_raw(type(self), env, j-i, self.p)
        cdef JPrimArrayPointer ptr = JPrimArrayPointer(env, self)
        if j > self.length: j = self.length
        self.p.set(env, arr.arr, 0, <jsize>(j-i), (<char*>ptr.ptr) + i*self.p.itemsize)
        return arr

    def __setitem__(self, index, value):
        """
        Sets an item, either from a slice with step 1 or a single index. A slice requires the
        value being set to have the same length of the slice or a scalar which becomes a `fill`.
        This supports data coming from another Java array, bytes, bytearray, unicode (if a char
        array), array.array, buffer-object, or a sequence-like object.
        """
        cdef jsize i, j, n
        cdef Py_buffer buf
        cdef JPrimArrayPointer ptr
        if PySlice_Check(index):
            from collections import Iterable, Sized
            i,j = JArray.check_slice(index.start, index.stop, index.step, self.length)
            n = j-i
            if n == 0: return
            if isinstance(value, type(self)): self.set_from_jpa(value, i, n)
            elif PyBytes_Check(value):        self.set_from_bytes(value, i, n)
            elif PyByteArray_Check(value):    self.set_from_bytearray(value, i, n)
            elif self.p.type == PT_Char and PyUnicode_Check(value): self.set_from_unicode(value, i, n)
            elif JPrimitiveArray.check_arrayarray(value, self.p): self.set_from_arrayarray(value, i, n)
            elif JPrimitiveArray.get_buffer(value, self.p, &buf): self.set_from_buffer(value, i, n, &buf)
            elif isinstance(value, Iterable) and isinstance(value, Sized): self.set_from_seq(value, i, n)
            else:
                ptr = JPrimArrayPointer(jenv(), self, readonly=False)
                self.p.fill(ptr.ptr, i, j, value)
            return
        cdef jvalue x
        self.p.obj2primitive(value, &x)
        self.p.set(jenv(), self.arr, JArray.check_index(index, self.length), 1, &x)
    cdef int set_from_jpa(self, JPrimitiveArray arr, jsize i, jsize n) except -1:
        """Copy n elements from another Java array to index i in this array."""
        if arr.length != n: raise ValueError('can only set from same-sized Java array')
        cdef JEnv env = jenv()
        cdef JPrimArrayPointer ptr = JPrimArrayPointer(env, arr)
        self.p.set(env, self.arr, i, n, ptr.ptr)
        return 0
    cdef int set_from_bytes(self, bytes b, jsize i, jsize n) except -1:
        """Copy n elements from a bytes to index i in this array."""
        if PyBytes_GET_SIZE(b)*self.p.itemsize != n: raise ValueError('can only set from an equivilent number of bytes')
        self.p.set(jenv(), self.arr, i, n, PyBytes_AS_STRING(b))
        return 0
    cdef int set_from_bytearray(self, bytearray b, jsize i, jsize n) except -1:
        """Copy n elements from a bytearray to index i in this array."""
        if PyByteArray_GET_SIZE(b)*self.p.itemsize != n: raise ValueError('can only set from an equivilent number of bytes')
        self.p.set(jenv(), self.arr, i, n, PyByteArray_AS_STRING(b))
        return 0
    cdef int set_from_unicode(self, unicode s, jsize i, jsize n) except -1:
        """Copy n elements from a unicode to index i in this array."""
        cdef Py_ssize_t uni_len = get_unicode_len(s)
        cdef jsize pairs = get_addl_chars_needed(s, 0, <jsize>uni_len)
        if uni_len + pairs != n: raise ValueError('can only set from a same-sized unicode string')
        set_char_array(jenv(), s, 0, self, i, <jsize>uni_len)
        return 0
    cdef int set_from_arrayarray(self, array a, jsize i, jsize n) except -1:
        """Copy n elements from an array.array to index i in this array."""
        cdef Py_ssize_t a_n = (len(a)*self.p.itemsize) if a.itemsize == 1 else len(a)
        if a_n != n: raise ValueError('can only set from a same-sized array.array object')
        self.p.set(jenv(), self.arr, i, n, a.data.as_voidptr)
        return 0
    cdef int set_from_buffer(self, obj, jsize i, jsize n, Py_buffer* buf) except -1:
        """Copy n elements from a buffer-object to index i in this array."""
        try:
            if n != buf.len//self.p.itemsize: raise ValueError('can only set from a same-sized buffer object')
            self.p.set(jenv(), self.arr, i, n, buf.buf)
        finally: PyBuffer_Release(buf)
        return 0
    cdef int set_from_seq(self, seq, jsize i, jsize n) except -1:
        """Copy n elements from a sequence-like object to index i in this array."""
        if len(seq) != n: raise ValueError('can only set from same-sized sequence')
        ptr = JPrimArrayPointer(jenv(), self, readonly=False)
        self.p.setseq(ptr.ptr, seq, i)
        return 0

    def __repr__(self):
        return ("<Java array %s[%d] at 0x%08x>") % (get_object_class(self).component_type.name, self.length, get_identity(self))

    ##### Methods that are forwarded to primitive-type specific functions #####
    def __iter__(self):     return JPrimArrayIter(self, False)
    def __reversed__(self): return JPrimArrayIter(self, True)
    def __contains__(self, val):
        cdef JPrimArrayPointer ptr = JPrimArrayPointer(jenv(), self)
        return self.p.contains(ptr.ptr, self.length, val)
    def index(self, val, start=0, stop=None):
        cdef jsize i,j
        i,j = JArray.check_slice(start, stop, 1, self.length)
        cdef JPrimArrayPointer ptr = JPrimArrayPointer(jenv(), self)
        return self.p.index(ptr.ptr, i, j, val)
    def count(self, val):
        cdef JPrimArrayPointer ptr = JPrimArrayPointer(jenv(), self)
        return self.p.count(ptr.ptr, self.length, val)
    def reverse(self):
        cdef JPrimArrayPointer ptr = JPrimArrayPointer(jenv(), self, readonly=False)
        self.p.reverse(ptr.ptr, self.length)

    ##### Methods that are forwarded to java.util.Arrays #####
    def sort(self, fromIndex=None, toIndex=None):
        if self.p.sort is NULL: raise AttributeError('sort')
        cdef jsize n = self.length
        cdef jvalue val[3]
        val[0].l = self.arr
        if fromIndex is None and toIndex is None:
            jenv().CallStaticVoidMethod(Arrays, self.p.sort, val, JArray.withgil(n*n))
        else:
            val[1].i = 0 if fromIndex is None else fromIndex
            val[2].i = n if toIndex is None else toIndex
            jenv().CallStaticVoidMethod(Arrays, self.p.sort_range, val, JArray.withgil(n*n))
    def binarySearch(self, key, fromIndex=None, toIndex=None):
        if self.p.binarySearch is NULL: raise AttributeError('binarySearch')
        cdef jvalue val[4]
        val[0].l = self.arr
        if fromIndex is None and toIndex is None:
            self.p.obj2primitive(key, &val[1])
            return jenv().CallStaticIntMethod(Arrays, self.p.binarySearch, val, True)
        else:
            val[1].i = 0 if fromIndex is None else fromIndex
            val[2].i = self.length if toIndex is None else toIndex
            self.p.obj2primitive(key, &val[3])
            return jenv().CallStaticIntMethod(Arrays, self.p.binarySearch_range, val, True)
    def __hash__(self):
        cdef jvalue val
        val.l = self.arr
        return jenv().CallStaticIntMethod(Arrays, self.p.hashCode, &val, JArray.withgil(self.length))
    def __richcmp__(self, other, int op):
        if op != 2 and op != 3 or not isinstance(other, type(self)): return NotImplemented
        cdef jvalue val[2]
        cdef JPrimitiveArray a = self, b = other
        val[0].l = a.arr; val[1].l = b.arr
        cdef bint eq = jenv().CallStaticBooleanMethod(Arrays, a.p.equals, val, JArray.withgil(self.length))
        return eq if op == 2 else not eq
    cdef inline unicode str(self):
        cdef jvalue val
        val.l = self.arr
        return jenv().CallStaticObjectMethod(Arrays, self.p.toString, &val, JArray.withgil(self.length//8))
    IF PY_VERSION < PY_VERSION_3:
        def __unicode__(self): return self.str()
        def __str__(self): return utf8(self.str())
    ELSE:
        def __str__(self): return self.str()


##################################
########## Object Array ##########
##################################
cdef class JObjectArray(JArray):
    @staticmethod
    cdef unicode get_objarr_classname(JClass elemClass):
        assert not elemClass.is_primitive()
        return ('[' + elemClass.name) if elemClass.is_array() else ('[L%s;' % elemClass.name)

    @staticmethod
    cdef JObjectArray new_raw(JEnv env, Py_ssize_t length, JClass elementClass, jobject init = NULL):
        """
        Creates a new Java object array that has `length` elements, contains subclasses of
        `elementClass`, with each element set to `init` (default is filled with null).
        """
        if sizeof(Py_ssize_t) > sizeof(jsize) and length > 0x7FFFFFFF: raise OverflowError()
        cdef unicode cn = JObjectArray.get_objarr_classname(elementClass)
        cdef cls = get_java_class(cn) # a subclass of JObjectArray/java.lang.Object
        cdef jobjectArray jarr = env.NewObjectArray(<jsize>length, elementClass.clazz, init)
        cdef JObjectArray arr = cls.__new__(cls, JObject.create(env, jarr))
        return arr

    @staticmethod
    cdef JObjectArray create(object args, JClass elementClass):
        """
        Creates a new array with the contents of `args` of the element class. The `args` must be
        a sequence of 0 or more elements. For a length of 0, a 0-length array is returned. For a
        length greater then 1 each value is converted and stored in the array. For a length of 1,
        the value can be a another JObjectArray, an integer, or a sequence-like object.
        """
        cdef JEnv env = jenv()
        cdef jsize i, n
        cdef jvalue val[3]

        # No arguments -> empty array
        if len(args) == 0: return JObjectArray.new_raw(env, 0, elementClass)

        if len(args) == 1:
            arg = args[0]

            # <Type>Array -> copy of old array
            if isinstance(arg, JObjectArray):
                n = (<JObjectArray>arg).length
                val[0].l = (<JObjectArray>arg).arr; val[1].i = n; val[2].l = elementClass.clazz
                return jenv().CallStaticObjectMethod(Arrays, ObjectArrayDef.copyOf_nt, val, JArray.withgil(n*4))

            # Integer -> empty array of the given length
            try: n = PyNumber_Index(arg)
            except TypeError: pass
            else:
                if n < 0: raise ValueError('Cannot create negative sized array')
                return JObjectArray.new_raw(env, n, elementClass)

            # Sequence -> forward to having more than 1 argument
            from collections import Iterable, Sized
            if isinstance(arg, Iterable) and isinstance(arg, Sized): args = arg
        # Go through sequence and convert each argument
        cdef JObjectArray joa = JObjectArray.new_raw(env, len(args), elementClass)
        cdef jobjectArray arr = <jobjectArray>joa.arr
        cdef jobject obj
        for i,a in enumerate(args):
            obj = py2object(env, a, elementClass)
            try: env.SetObjectArrayElement(arr, i, obj)
            finally: env.DeleteLocalRef(obj)
        return joa

    def __cinit__(self, JObject obj):
        if obj is None: raise ValueError()
        self.wrap(jenv(), obj)

    @staticmethod
    cdef list tolist_prim(JEnv env, jarray arr, JClass prim):
        cdef char pn = prim.funcs.sig
        cdef jsize n = env.GetArrayLength(arr)
        cdef jboolean isCopy
        cdef void *ptr = env.GetPrimitiveArrayCritical(arr, &isCopy)
        try:
            if pn == b'Z': return tolist[jboolean](<jboolean*>ptr, 0, n)
            if pn == b'B': return tolist[jbyte   ](<jbyte*>   ptr, 0, n)
            if pn == b'C': return tolist[jchar   ](<jchar*>   ptr, 0, n)
            if pn == b'S': return tolist[jshort  ](<jshort*>  ptr, 0, n)
            if pn == b'I': return tolist[jint    ](<jint*>    ptr, 0, n)
            if pn == b'L': return tolist[jlong   ](<jlong*>   ptr, 0, n)
            if pn == b'F': return tolist[jfloat  ](<jfloat*>  ptr, 0, n)
            if pn == b'D': return tolist[jdouble ](<jdouble*> ptr, 0, n)
        finally: env.ReleasePrimitiveArrayCritical(arr, ptr, JNI_ABORT if isCopy else 0)
    @staticmethod
    cdef list tolist_deep(JEnv env, jobjectArray arr, jsize start, jsize stop):
        cdef jobject obj
        cdef JClass clazz
        cdef jsize i, n = stop-start
        cdef list out = PyList_New(n)
        for i in xrange(n):
            obj = env.GetObjectArrayElement(arr, start+i)
            clazz = JClass.get(env, env.GetObjectClass(obj))
            x = (object2py(obj) if not clazz.is_array() else
                 JObjectArray.tolist_prim(env, <jarray>obj, clazz.component_type) if clazz.component_type.is_primitive() else
                 JObjectArray.tolist_deep(env, <jobjectArray>obj, 0, env.GetArrayLength(<jarray>obj)))
            Py_INCREF(x)
            PyList_SET_ITEM(out, i, x)
        return out
    @staticmethod
    cdef list tolist_shallow(JEnv env, jobjectArray arr, jsize start, jsize stop):
        cdef jsize i, n = stop-start
        cdef list out = PyList_New(n)
        for i in xrange(n):
            x = object2py(env.GetObjectArrayElement(arr, start+i))
            Py_INCREF(x)
            PyList_SET_ITEM(out, i, x)
        return out
    def tolist(self, start=None, stop=None, bint deep=True):
        cdef jsize i,j
        i,j = JArray.check_slice(start, stop, 1, self.length)
        return (JObjectArray.tolist_deep(jenv(), <jobjectArray>self.arr, i, j) if deep else
                JObjectArray.tolist_shallow(jenv(), <jobjectArray>self.arr, i, j))
    def copyto(self, JObjectArray dst, start=None, stop=None, jsize dst_off=0):
        """
        Copy the data of this array to another Java array. Copies the data from start (inclusive)
        to stop (exclusive) to the offset dst_off in the destination object.
        """
        cdef jsize i,j,n
        i,j = JArray.check_slice(start, stop, 1, self.length)
        n = j-i
        if n == 0: return
        if dst_off < 0:
            dst_off += dst.length
            if dst_off < 0: dst_off = 0
        if dst_off + n > dst.length: raise ValueError('not enough space in destination Java array')
        JArray.arraycopy(jenv(), self.arr, i, dst.arr, dst_off, n)
    def copyfrom(self, JObjectArray src, start=None, stop=None, jsize src_off=0):
        """
        Copy the data from another Java array to this array. Copies the data to start (inclusive)
        to stop (exclusive) from the offset src_off in the destination object.
        """
        cdef jsize i,j,n
        i,j = JArray.check_slice(start, stop, 1, self.length)
        n = j-i
        if n == 0: return
        if src_off < 0:
            src_off += src.length
            if src_off < 0: src_off = 0
        if src_off + n > src.length: raise ValueError('not enough elements in source Java array')
        JArray.arraycopy(jenv(), src.arr, src_off, self.arr, i, n)
    def __getitem__(self, index):
        """
        Get an item, either from a slice with step 1 or a single index. Slicing uses copyOf. If
        the upper bound of the slice is greater than the length of the array, the length is
        extended and nulls are added.
        """
        cdef jsize i, j
        if PySlice_Check(index):
            if index.step is not None and index.step != 1: raise ValueError('only slices with a step of 1 (default) are supported')
            i = 0 if index.start is None else index.start
            j = self.length if index.stop is None else index.stop
            if i < 0:
                i += self.length
                if i < 0: i = 0
            elif i > self.length: i = self.length
            if j < 0: j += self.length
            if i > j: raise IndexError('%d > %d' % (i,j))
            return self.copyOf(i, j)
        return object2py(jenv().GetObjectArrayElement(self.arr, JArray.check_index(index, self.length)))
    def __setitem__(self, index, value):
        """
        Sets an item, either from a slice with step 1 or a single index. A slice requires the
        value being set to have the same length of the slice or a scalar which becomes a `fill`.
        This supports data coming from another Java array or a sequence-like object.
        """
        cdef JEnv env = jenv()
        cdef jobject obj
        cdef jsize i, j, n
        if PySlice_Check(index):
            from collections import Iterable, Sized
            i,j = JArray.check_slice(index.start, index.stop, index.step, self.length)
            n = j-i
            if n == 0: return
            if isinstance(value, JObjectArray): self.set_from_ja(env, value, i, n)
            elif isinstance(value, Iterable) and isinstance(value, Sized): self.set_from_seq(env, value, i, n)
            else: self._fill(env, i, j, value)
        else:
            obj = py2object(env, value, get_object_class(self).component_type)
            try: env.SetObjectArrayElement(<jobjectArray>self.arr, JArray.check_index(index, self.length), obj)
            finally: env.DeleteLocalRef(obj)
    cdef int set_from_ja(self, JEnv env, JArray arr, jsize i, jsize n):
        """Copy n elements from another Java array to index i in this array."""
        if arr.length != n: raise ValueError('can only set from same-sized Java array')
        JArray.arraycopy(env, arr.arr, 0, self.arr, i, n)
        return 0
    cdef int set_from_seq(self, JEnv env, seq, jsize i, jsize n) except -1:
        """Copy n elements from a sequence-like object to index i in this array."""
        if len(seq) != n: raise ValueError('can only set from same-sized sequence')
        cdef JClass clazz = get_object_class(self).component_type
        cdef jobjectArray arr = <jobjectArray>self.arr
        cdef jobject obj
        for i,val in enumerate(seq,i):
            obj = py2object(env, val, clazz)
            try: env.SetObjectArrayElement(arr, i, obj)
            finally: env.DeleteLocalRef(obj)
        return 0
    def __repr__(self):
        cdef JClass clazz = get_object_class(self)
        cdef jsize nd = -1
        while clazz.is_array(): nd += 1; clazz = clazz.component_type
        return ("<Java array %s[%d]%s at 0x%08x>") % (clazz.name, self.length, '[]'*nd, get_identity(self))
    def __iter__(self):
        cdef JEnv env = jenv()
        cdef jobjectArray arr = <jobjectArray>self.arr
        cdef jsize i
        for i in xrange(self.length): yield object2py(env.GetObjectArrayElement(arr, i))
    def __reversed__(self):
        cdef JEnv env = jenv()
        cdef jobjectArray arr = <jobjectArray>self.arr
        cdef jsize i
        for i in xrange(self.length-1, -1, -1): yield object2py(env.GetObjectArrayElement(arr, i))

    ##### Basic sequence algorithms #####
    @staticmethod
    cdef inline jsize elem_eq(JNIEnv* env, jobject a, jobject b) nogil:
        """
        Calls a.equals(b) and deletes the local reference to b. Returns JNI_TRUE or JNI_FALSE for
        the result of equals and -1 if there was a Java exception.
        """
        cdef jvalue val
        val.l = b
        cdef jboolean out = env[0].CallBooleanMethodA(env, a, ObjectDef.equals, &val)
        env[0].DeleteLocalRef(env, b)
        return -1 if env[0].ExceptionCheck(env) else out
    cdef jsize find(self, val, jsize start, jsize stop) except -2:
        cdef JEnv _env = jenv()
        cdef JNIEnv* env = _env.env
        cdef jobject obj, valobj = py2object(_env, val, get_object_class(self).component_type)
        cdef jsize i, out = -1, n = stop-start, eq
        cdef PyThreadState* gilstate = NULL if JArray.withgil(n//16) else PyEval_SaveThread()
        cdef jobjectArray arr = <jobjectArray>self.arr
        for i in xrange(start,stop):
            obj = env[0].GetObjectArrayElement(env, arr, i)
            if env[0].ExceptionCheck(env) == JNI_TRUE: break
            eq = JObjectArray.elem_eq(env, valobj, obj)
            if eq == JNI_TRUE: out = i; break
            elif eq != JNI_FALSE: break
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        try: _env.check_exc()
        finally: _env.DeleteLocalRef(valobj)
        return out
    def __contains__(self, val):
        return self.find(val, 0, self.length) != -1
    def index(self, val, start=0, stop=None):
        cdef jsize i,j
        i,j = JArray.check_slice(start, stop, 1, self.length)
        i = self.find(val, i, j)
        if i == -1: raise ValueError('%s is not in array'%val)
        return i
    def count(self, val):
        cdef JEnv _env = jenv()
        cdef JNIEnv* env = _env.env
        cdef jobject obj, valobj = py2object(_env, val, get_object_class(self).component_type)
        cdef jsize i, count = 0, n = self.length, eq
        cdef PyThreadState* gilstate = NULL if JArray.withgil(n//16) else PyEval_SaveThread()
        cdef jobjectArray arr = <jobjectArray>self.arr
        for i in xrange(n):
            obj = env[0].GetObjectArrayElement(env, arr, i)
            if env[0].ExceptionCheck(env) == JNI_TRUE: break
            eq = JObjectArray.elem_eq(env, valobj, obj)
            if eq == JNI_TRUE: count += 1
            elif eq != JNI_FALSE: break
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        try: _env.check_exc()
        finally: _env.DeleteLocalRef(valobj)
        return count
    def reverse(self):
        cdef JEnv _env = jenv()
        cdef JNIEnv* env = _env.env
        cdef PyThreadState* gilstate = NULL if JArray.withgil(self.length//4) else PyEval_SaveThread()
        cdef jobjectArray arr = <jobjectArray>self.arr
        cdef jsize i = 0, j = self.length - 1
        cdef jobject a, b
        while i < j:
            a = env[0].GetObjectArrayElement(env, arr, i)
            if env[0].ExceptionCheck(env) == JNI_TRUE: break
            b = env[0].GetObjectArrayElement(env, arr, j)
            if env[0].ExceptionCheck(env) == JNI_TRUE: env[0].DeleteLocalRef(env, a); break
            env[0].SetObjectArrayElement(env, arr, j, a)
            if env[0].ExceptionCheck(env) == JNI_TRUE: env[0].DeleteLocalRef(env, a); env[0].DeleteLocalRef(env, b); break
            env[0].SetObjectArrayElement(env, arr, i, b)
            env[0].DeleteLocalRef(env, a); env[0].DeleteLocalRef(env, b);
            if env[0].ExceptionCheck(env) == JNI_TRUE: break
            i += 1; j -= 1
        if gilstate is not NULL: PyEval_RestoreThread(gilstate)
        _env.check_exc()

    ##### Methods that are forwarded to java.util.Arrays #####
    def copyOf(self, from_=None, to=None, newType=None):
        """
        A wrapper for java.util.Arrays.copyOf and java.util.Arrays.copyOfRange supporting
        extending the length of the array by filling in nulls and casting to a new array type.
        """
        cdef jmethodID m
        cdef jsize off = 1, i = 0 if from_ is None else from_, j =  self.length if to is None else to
        cdef jvalue val[4]
        val[0].l = self.arr
        if i == 0:
            m = ObjectArrayDef.copyOf if newType is None else ObjectArrayDef.copyOf_nt
        else:
            off = 2
            val[1].i = i
            m = ObjectArrayDef.copyOfRange if newType is None else ObjectArrayDef.copyOfRange_nt
        val[off+0].i = j
        if newType is None: val[off+1].l = NULL
        elif isinstance(newType, JClass):    val[off+1].l = (<JClass>newType).clazz
        elif isinstance(newType, JavaClass): val[off+1].l = get_class(newType)
        elif isinstance(newType, get_java_class('java.lang.Class')): val[off+1].l = get_object(newType)
        else: raise TypeError('newType argument must be None, a java.util.Class, or a JavaClass')
        return jenv().CallStaticObjectMethod(Arrays, m, val, JArray.withgil((j-i)*4))
    cdef int _fill(self, JEnv env, value, fromIndex=None, toIndex=None) except -1:
        cdef jmethodID m
        cdef jsize off = 1, n
        cdef jvalue val[4]
        val[0].l = self.arr
        if fromIndex is None and toIndex is None:
            m = ObjectArrayDef.fill
            n = self.length
        else:
            off = 3
            val[1].i = 0 if fromIndex is None else fromIndex
            val[2].i = self.length if toIndex is None else toIndex
            m = ObjectArrayDef.fill_r
            n = val[2].i - val[1].i
        val[off].l = py2object(env, value, get_object_class(self).component_type)
        try: return env.CallStaticObjectMethod(Arrays, m, val, JArray.withgil(n*4))
        finally: env.DeleteLocalRef(val[off].l)
    def sort(self, fromIndex=None, toIndex=None, c=None):
        cdef jobject cmp = NULL
        cdef jmethodID m
        if c is not None:
            if not isinstance(c, get_java_class('java.util.Comparator')): raise ValueError('c must be a java.util.Comparator')
            cmp = (<JObject>c.__object__).obj
        cdef jvalue val[4]
        val[0].l = self.arr
        if fromIndex is None and toIndex is None:
            val[1].l = cmp
            m = ObjectArrayDef.sort if cmp is NULL else ObjectArrayDef.sort_c
        else:
            val[1].i = 0 if fromIndex is None else fromIndex
            val[2].i = self.length if toIndex is None else toIndex
            val[3].l = cmp
            m = ObjectArrayDef.sort_r if cmp is NULL else ObjectArrayDef.sort_rc
        jenv().CallStaticVoidMethod(Arrays, m, val, JArray.withgil(self.length//32))
    def binarySearch(self, key, fromIndex=None, toIndex=None, c=None):
        cdef jobject cmp = NULL
        cdef jmethodID m
        if c is not None:
            if not isinstance(c, get_java_class('java.util.Comparator')): raise ValueError('c must be a java.util.Comparator')
            cmp = (<JObject>c.__object__).obj
        cdef jsize off = 1
        cdef JEnv env = jenv()
        cdef jvalue val[5]
        val[0].l = self.arr
        if fromIndex is None and toIndex is None:
            m = ObjectArrayDef.binarySearch if cmp is NULL else ObjectArrayDef.binarySearch_c
        else:
            off = 3
            val[1].i = 0 if fromIndex is None else fromIndex
            val[2].i = self.length if toIndex is None else toIndex
            m = ObjectArrayDef.binarySearch_r if cmp is NULL else ObjectArrayDef.binarySearch_rc
        val[off+0].l = py2object(env, key, get_object_class(self).component_type)
        val[off+1].l = cmp
        try: return env.CallStaticIntMethod(Arrays, m, val, True)
        finally: env.DeleteLocalRef(val[off+0].l)
    cdef inline hash(self, bint deep=True):
        cdef jmethodID m = ObjectArrayDef.deepHashCode if deep else ObjectArrayDef.hashCode
        cdef jvalue val
        val.l = self.arr
        return jenv().CallStaticIntMethod(Arrays, m, &val, JArray.withgil(self.length//16))
    def __hash__(self): return self.hash(True)
    def hashCode(self, bint deep=True): return self.hash(deep)
    cdef inline eqls(self, JObjectArray other, bint deep=True):
        cdef jmethodID m = ObjectArrayDef.deepEquals if deep else ObjectArrayDef.equals
        cdef jvalue val[2]
        val[0].l = self.arr
        val[1].l = other.arr
        return jenv().CallStaticBooleanMethod(Arrays, m, val, JArray.withgil(self.length//16))
    def __richcmp__(self, other, int op):
        if op != 2 and op != 3 or not isinstance(other, JObjectArray): return NotImplemented
        cdef bint eq = self.eqls(other, True)
        return eq if op == 2 else not eq
    def equals(self, other, bint deep=True):
        if not isinstance(other, JObjectArray): raise ValueError('Can only compare two object arrays')
        return self.eqls(other, deep)
    cdef inline unicode str(self, bint deep):
        cdef jvalue val
        val.l = self.arr
        cdef jmethodID m = ObjectArrayDef.deepToString if deep else ObjectArrayDef.toString
        return jenv().CallStaticObjectMethod(Arrays, m, &val, JArray.withgil(self.length//32))
    def toString(self, bint deep=True): return self.str(deep)
    IF PY_VERSION < PY_VERSION_3:
        def __unicode__(self): return self.str(True)
        def __str__(self): return utf8(self.str(True))
    ELSE:
        def __str__(self): return self.str(True)


########## Object Array Definitions ##########
cdef jclass Arrays
cdef struct JObjectArrayDef:
    jmethodID copyOf, copyOf_nt, copyOfRange, copyOfRange_nt
    jmethodID fill, fill_r
    jmethodID sort, sort_r, sort_c, sort_rc
    jmethodID binarySearch, binarySearch_r, binarySearch_c, binarySearch_rc
    jmethodID equals, deepEquals
    jmethodID hashCode, deepHashCode
    jmethodID toString, deepToString
cdef JObjectArrayDef ObjectArrayDef


########## Public Functions ##########
def boolean_array(*args): return JPrimitiveArray.create(args, get_java_class('[Z'), &jpad_boolean)
def byte_array   (*args): return JPrimitiveArray.create(args, get_java_class('[B'), &jpad_byte)
def char_array   (*args): return JPrimitiveArray.create(args, get_java_class('[C'), &jpad_char)
def short_array  (*args): return JPrimitiveArray.create(args, get_java_class('[S'), &jpad_short)
def int_array    (*args): return JPrimitiveArray.create(args, get_java_class('[I'), &jpad_int)
def long_array   (*args): return JPrimitiveArray.create(args, get_java_class('[J'), &jpad_long)
def float_array  (*args): return JPrimitiveArray.create(args, get_java_class('[F'), &jpad_float)
def double_array (*args): return JPrimitiveArray.create(args, get_java_class('[D'), &jpad_double)
def object_array (*args, type=None):
    if type is None: type = get_java_class('java.util.Class')
    return JObjectArray.create(args, type)

    
########## Initialization of Array Definitions ##########
cdef int init_array(JEnv env) except -1:
    # java.util.Arrays utility class
    global Arrays
    cdef jclass clazz = env.FindClass('java/util/Arrays')
    Arrays = env.NewGlobalRef(clazz)
    env.DeleteLocalRef(clazz)

    # array.array templates
    import array
    global array_templates_bool, array_templates_char, array_templates_int, array_templates_fp
    array_templates_bool = [array.array(tc) for tc in array_typecodes_bool]
    array_templates_char = [array.array(tc) for tc in array_typecodes_char]
    array_templates_int  = [array.array(tc) for tc in array_typecodes_int]
    array_templates_fp   = [array.array(tc) for tc in array_typecodes_fp]

    # Primitive array definitions
    create_JPAD[jboolean](env, &jpad_boolean, <jboolean>0, PT_Boolean, b'Z', JEnv.NewBooleanArray,
        <GetPrimArrayElements>JEnv.GetBooleanArrayElements, <ReleasePrimArrayElements>JEnv.ReleaseBooleanArrayElements,
        <GetPrimArrayRegion>JEnv.GetBooleanArrayRegion, <SetPrimArrayRegion>JEnv.SetBooleanArrayRegion)
    create_JPAD[jbyte](env, &jpad_byte, <jbyte>0, PT_Integral, b'B', JEnv.NewByteArray,
        <GetPrimArrayElements>JEnv.GetByteArrayElements, <ReleasePrimArrayElements>JEnv.ReleaseByteArrayElements,
        <GetPrimArrayRegion>JEnv.GetByteArrayRegion, <SetPrimArrayRegion>JEnv.SetByteArrayRegion)
    create_JPAD[jchar](env, &jpad_char, <jchar>0, PT_Char, b'C', JEnv.NewCharArray,
        <GetPrimArrayElements>JEnv.GetCharArrayElements, <ReleasePrimArrayElements>JEnv.ReleaseCharArrayElements,
        <GetPrimArrayRegion>JEnv.GetCharArrayRegion, <SetPrimArrayRegion>JEnv.SetCharArrayRegion)
    create_JPAD[jshort](env, &jpad_short, <jshort>0, PT_Integral, b'S', JEnv.NewShortArray,
        <GetPrimArrayElements>JEnv.GetShortArrayElements, <ReleasePrimArrayElements>JEnv.ReleaseShortArrayElements,
        <GetPrimArrayRegion>JEnv.GetShortArrayRegion, <SetPrimArrayRegion>JEnv.SetShortArrayRegion,)
    create_JPAD[jint](env, &jpad_int, <jint>0, PT_Integral, b'I', JEnv.NewIntArray,
        <GetPrimArrayElements>JEnv.GetIntArrayElements, <ReleasePrimArrayElements>JEnv.ReleaseIntArrayElements,
        <GetPrimArrayRegion>JEnv.GetIntArrayRegion, <SetPrimArrayRegion>JEnv.SetIntArrayRegion)
    create_JPAD[jlong](env, &jpad_long, <jlong>0, PT_Integral, b'J', JEnv.NewLongArray,
        <GetPrimArrayElements>JEnv.GetLongArrayElements, <ReleasePrimArrayElements>JEnv.ReleaseLongArrayElements,
        <GetPrimArrayRegion>JEnv.GetLongArrayRegion, <SetPrimArrayRegion>JEnv.SetLongArrayRegion)
    create_JPAD[jfloat](env, &jpad_float, <jfloat>0, PT_FloatingPoint, b'F', JEnv.NewFloatArray,
        <GetPrimArrayElements>JEnv.GetFloatArrayElements, <ReleasePrimArrayElements>JEnv.ReleaseFloatArrayElements,
        <GetPrimArrayRegion>JEnv.GetFloatArrayRegion, <SetPrimArrayRegion>JEnv.SetFloatArrayRegion)
    create_JPAD[jdouble](env, &jpad_double, <jdouble>0, PT_FloatingPoint, b'D', JEnv.NewDoubleArray,
        <GetPrimArrayElements>JEnv.GetDoubleArrayElements, <ReleasePrimArrayElements>JEnv.ReleaseDoubleArrayElements,
        <GetPrimArrayRegion>JEnv.GetDoubleArrayRegion, <SetPrimArrayRegion>JEnv.SetDoubleArrayRegion)
    jpads[0] = &jpad_boolean; jpads[1] = &jpad_byte; jpads[2] = &jpad_char; jpads[3] = &jpad_short
    jpads[4] = &jpad_int; jpads[5] = &jpad_long; jpads[6] = &jpad_float; jpads[7] = &jpad_double
        
    # Object array utilities
    ObjectArrayDef.copyOf         = env.GetStaticMethodID(Arrays, 'copyOf', '([Ljava/lang/Object;I)[Ljava/lang/Object;')
    ObjectArrayDef.copyOf_nt      = env.GetStaticMethodID(Arrays, 'copyOf', '([Ljava/lang/Object;ILjava/lang/Class;)[Ljava/lang/Object;')
    ObjectArrayDef.copyOfRange    = env.GetStaticMethodID(Arrays, 'copyOfRange', '([Ljava/lang/Object;II)[Ljava/lang/Object;')
    ObjectArrayDef.copyOfRange_nt = env.GetStaticMethodID(Arrays, 'copyOfRange', '([Ljava/lang/Object;IILjava/lang/Class;)[Ljava/lang/Object;')
    ObjectArrayDef.fill    = env.GetStaticMethodID(Arrays, 'fill', '([Ljava/lang/Object;Ljava/lang/Object;)V')
    ObjectArrayDef.fill_r  = env.GetStaticMethodID(Arrays, 'fill', '([Ljava/lang/Object;IILjava/lang/Object;)V')
    ObjectArrayDef.sort    = env.GetStaticMethodID(Arrays, 'sort', '([Ljava/lang/Object;)V')
    ObjectArrayDef.sort_r  = env.GetStaticMethodID(Arrays, 'sort', '([Ljava/lang/Object;II)V')
    ObjectArrayDef.sort_c  = env.GetStaticMethodID(Arrays, 'sort', '([Ljava/lang/Object;Ljava/util/Comparator;)V')
    ObjectArrayDef.sort_rc = env.GetStaticMethodID(Arrays, 'sort', '([Ljava/lang/Object;IILjava/util/Comparator;)V')
    ObjectArrayDef.binarySearch    = env.GetStaticMethodID(Arrays, 'binarySearch', '([Ljava/lang/Object;Ljava/lang/Object;)I')
    ObjectArrayDef.binarySearch_r  = env.GetStaticMethodID(Arrays, 'binarySearch', '([Ljava/lang/Object;IILjava/lang/Object;)I')
    ObjectArrayDef.binarySearch_c  = env.GetStaticMethodID(Arrays, 'binarySearch', '([Ljava/lang/Object;Ljava/lang/Object;Ljava/util/Comparator;)I')
    ObjectArrayDef.binarySearch_rc = env.GetStaticMethodID(Arrays, 'binarySearch', '([Ljava/lang/Object;IILjava/lang/Object;Ljava/util/Comparator;)I')
    ObjectArrayDef.equals       = env.GetStaticMethodID(Arrays, 'equals',       '([Ljava/lang/Object;[Ljava/lang/Object;)Z')
    ObjectArrayDef.deepEquals   = env.GetStaticMethodID(Arrays, 'deepEquals',   '([Ljava/lang/Object;[Ljava/lang/Object;)Z')
    ObjectArrayDef.hashCode     = env.GetStaticMethodID(Arrays, 'hashCode',     '([Ljava/lang/Object;)I')
    ObjectArrayDef.deepHashCode = env.GetStaticMethodID(Arrays, 'deepHashCode', '([Ljava/lang/Object;)I')
    ObjectArrayDef.toString     = env.GetStaticMethodID(Arrays, 'toString',     '([Ljava/lang/Object;)Ljava/lang/String;')
    ObjectArrayDef.deepToString = env.GetStaticMethodID(Arrays, 'deepToString', '([Ljava/lang/Object;)Ljava/lang/String;')

    # Array classes
    Object = get_java_class('java.lang.Object')
    class BooleanArray(JPrimitiveArray, Object):
        """The type for Java boolean[] objects"""
        __java_class_name__ = '[Z'
        def __new__(cls, *args): return JPrimitiveArray.create(args, cls, &jpad_boolean)
    class ByteArray(JPrimitiveArray, Object):
        """The type for Java byte[] objects"""
        __java_class_name__ = '[B'
        def __new__(cls, *args): return JPrimitiveArray.create(args, cls, &jpad_byte)
    class CharArray(JPrimitiveArray, Object):
        """The type for Java char[] objects"""
        __java_class_name__ = '[C'
        def __new__(cls, *args): return JPrimitiveArray.create(args, cls, &jpad_char)
        def tounicode(self, errors=None):
            cdef const char* errs
            if errors is None: errs = NULL
            elif PyBytes_Check(errors): errs = PyBytes_AS_STRING(errors)
            elif PyUnicode_Check(errors):
                errors = PyUnicode_AsASCIIString(errors)
                errs = PyBytes_AS_STRING(errors)
            else: raise TypeError('errors')
            cdef JPrimArrayPointer ptr = JPrimArrayPointer(jenv(), self)
            return PyUnicode_DecodeUTF16(<char*>ptr.ptr, (<JPrimitiveArray>self).length*sizeof(jchar), errs, NULL)
    class ShortArray(JPrimitiveArray, Object):
        """The type for Java short[] objects"""
        __java_class_name__ = '[S'
        def __new__(cls, *args): return JPrimitiveArray.create(args, cls, &jpad_short)
    class IntArray(JPrimitiveArray, Object):
        """The type for Java int[] objects"""
        __java_class_name__ = '[I'
        def __new__(cls, *args): return JPrimitiveArray.create(args, cls, &jpad_int)
    class LongArray(JPrimitiveArray, Object):
        """The type for Java long[] objects"""
        __java_class_name__ = '[J'
        def __new__(cls, *args): return JPrimitiveArray.create(args, cls, &jpad_long)
    class FloatArray(JPrimitiveArray, Object):
        """The type for Java float[] objects"""
        __java_class_name__ = '[F'
        def __new__(cls, *args): return JPrimitiveArray.create(args, cls, &jpad_float)
    class DoubleArray(JPrimitiveArray, Object):
        """The type for Java double[] objects"""
        __java_class_name__ = '[D'
        def __new__(cls, *args): return JPrimitiveArray.create(args, cls, &jpad_double)
    from collections import MutableSequence
    MutableSequence.register(JPrimitiveArray)
    MutableSequence.register(JObjectArray)
cdef int dealloc_array(JEnv env) except -1:
    global Arrays
    if Arrays is not NULL: env.DeleteGlobalRef(Arrays)
    Arrays = NULL
JVM.add_init_hook(init_array)
JVM.add_dealloc_hook(dealloc_array)
