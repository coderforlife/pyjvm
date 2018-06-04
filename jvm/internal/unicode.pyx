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

Unicode Functions
-----------------
Functions for dealing with the modified UTF-8 encoded strings used by JNI and the internals of
Java. Here this codec is being called utf-8-java or utf8j. There are two differences from
official UTF-8 standard:

    1) The codepoint U+0000 is encoded as 0xC0 0x80 instead of 0x00 (so that there are no embedded
       null bytes so that a null byte can still be used as the end-of-string marker)
    2) The supplemental characters (codepoints above U+010000) are encoded as a pair of 3-byte
       surrogates instead of a single 4-byte symbol and 4-byte symbols are not used at all

The codecs here are simple. They do not support incremental encoding/decoding, always operate in
native byte order, and do not take an error handler. The encoders essentially use the
'surrogatepass' error handler except for in Python 2 when given bytes which requires the range of
values to be in (1,128). The decoders use essentially the 'strict' error handler.

A lot of the code is for dealing with the wide variety of ways that Python stores unicode strings
in different circumstances.

Internal functions:
    unichr       - added for support in Python 2, just calls chr
    unicode_len  - gets the length of a Python unicode string 
    any_to_utf8j - encodes either byte (in Python 2) or unicode (in Python 2/3) string to utf8j
    to_utf8j     - encodes a unicode string to utf8j
    from_utf8j   - decodes utf8j data to a unicode string
    
Additional internal functions for dealing with Python unicode data directly:
    addl_chars_needed   - counts the number of additional characters needed to store a Python
                          unicode string as a Java string due to surrogate pairs
    n_chars_fit         - counts the number of characters that fit into a destination array
                          accounting for surrogate pairs
    get_direct_copy_ptr - gets a direct pointer to the unicode string if it can be directly
                          copied to a UCS2 (Java char) array
    copy_uni_to_ucs2    - copy a unicode string to a UCS2 array
"""

from __future__ import absolute_import

include "version.pxi"

cdef extern from "stddef.h":
    ctypedef size_t uintptr_t
from libc.string cimport memchr, memcpy
from cpython.bytes cimport PyBytes_Check, PyBytes_FromStringAndSize, PyBytes_AS_STRING, PyBytes_GET_SIZE, _PyBytes_Resize
from cpython.object cimport PyObject
from cpython.ref cimport Py_INCREF, Py_DECREF
cdef extern from "Python.h":
    cdef enum: PY_SSIZE_T_MAX
    ctypedef unsigned int Py_UCS4 # included with Cython as well, but this doesn't hurt
    ctypedef unsigned int PyUCS4 "Py_UCS4" # Py_UCS4 that coerces to an integer instead of a unicode string
ctypedef unsigned char byte
ctypedef unsigned char* p_byte
ctypedef const unsigned char* cp_byte
IF PY_VERSION < PY_VERSION_3_3:
    # Older versions of Python don't define these at all
    ctypedef unsigned char  Py_UCS1
    ctypedef unsigned short Py_UCS2 # assumed that short is 16-bits
ELSE:
    cdef extern from "Python.h":
        ctypedef unsigned char  Py_UCS1
        ctypedef unsigned short Py_UCS2
        
DEF CODEC_NAME='utf-8-java'
DEF INVALID_START_BYTE='invalid start byte'
DEF UNEXPECTED_END_OF_DATA='unexpected end of data'
DEF INVALID_CONTINUATION_BYTE='invalid continuation byte'

IF PY_VERSION < PY_VERSION_3_3:
    from cpython.unicode cimport PyUnicode_AS_UNICODE, PyUnicode_GET_SIZE
    cdef extern from "Python.h":
        cdef unicode PyUnicode_FromStringAndSize(const char *u, Py_ssize_t size)
        IF PY_UNICODE_WIDE:
            cdef int PyUnicode_Resize "PyUnicodeUCS4_Resize" (PyObject **unicode, Py_ssize_t length) except -1
        ELSE:
            cdef int PyUnicode_Resize "PyUnicodeUCS2_Resize" (PyObject **unicode, Py_ssize_t length) except -1
ELSE:
    cdef extern from "Python.h":
        cdef enum:
            PyUnicode_1BYTE_KIND
            PyUnicode_2BYTE_KIND
            PyUnicode_4BYTE_KIND
        cdef object PyUnicode_New(Py_ssize_t size, Py_UCS4 maxchar)
        cdef int PyUnicode_READY(object) except -1
        cdef int PyUnicode_KIND(object)
        cdef void* PyUnicode_DATA(object)
        cdef Py_ssize_t PyUnicode_GET_LENGTH(object)
        cdef bint PyUnicode_IS_ASCII(object)


########## UTF-8-Java Encoders ##########
cpdef bytes any_to_utf8j(basestring s):
    """
    Encodes a string to UTF-8-Java. In Python 3 this is equivalent to to_utf8j and does not accept
    bytes. In Python 2 this accepts bytes or unicode. For bytes it simply checks that all values
    are allowed in ASCII (except for null) then returned as-is.
    """
    IF PY_VERSION >= PY_VERSION_3: return to_utf8j(s)
    ELSE: return bytes_to_utf8j(<bytes>s) if PyBytes_Check(s) else to_utf8j(s)
IF PY_VERSION < PY_VERSION_3:
    cdef bytes bytes_to_utf8j(bytes s):
        """
        Checks that all bytes are ASCII (except for null), thus allowing 0x01-0x7F and returns the
        string as-is.
        """
        cdef cp_byte p = <cp_byte>PyBytes_AS_STRING(s)
        cdef Py_ssize_t sz = PyBytes_GET_SIZE(s)
        cdef Py_ssize_t n = count_leading_ascii_nz(p, p + sz)
        if n == sz: return s
        raise UnicodeEncodeError(CODEC_NAME, unichr(p[n]), n, n+1, b'ordinal not in range(1,128)')

cpdef bytes to_utf8j(unicode s):
    """
    Encodes a unicode string to UTF-8-Java. The delegates to one of
    (ascii|ucs1|ucs2|ucs4)_utf8java_encode based on the data storage of the unicode string.
    """
    IF PY_VERSION < PY_VERSION_3_3:
        IF PY_UNICODE_WIDE:
            return ucs4_utf8java_encode(<Py_UCS4*>PyUnicode_AS_UNICODE(s), PyUnicode_GET_SIZE(s))
        ELSE:
            return ucs2_utf8java_encode(<Py_UCS2*>PyUnicode_AS_UNICODE(s), PyUnicode_GET_SIZE(s))
    ELSE:
        PyUnicode_READY(s)
        cdef int kind = PyUnicode_KIND(s)
        if   kind == PyUnicode_1BYTE_KIND:
            if PyUnicode_IS_ASCII(s):
                return ascii_utf8java_encode(<char*>PyUnicode_DATA(s), PyUnicode_GET_LENGTH(s))
            else:
                return ucs1_utf8java_encode(<Py_UCS1*>PyUnicode_DATA(s), PyUnicode_GET_LENGTH(s))
        elif kind == PyUnicode_2BYTE_KIND:
            return ucs2_utf8java_encode(<Py_UCS2*>PyUnicode_DATA(s), PyUnicode_GET_LENGTH(s))
        elif kind == PyUnicode_4BYTE_KIND:
            return ucs4_utf8java_encode(<Py_UCS4*>PyUnicode_DATA(s), PyUnicode_GET_LENGTH(s))
        else: raise TypeError(u'Unknown unicode data kind')

IF PY_VERSION >= PY_VERSION_3_3:
    cdef bytes ascii_utf8java_encode(const char *data, Py_ssize_t size):
        if size > PY_SSIZE_T_MAX//2: raise MemoryError()
        if size == 0: return b''

        # Common case is that ASCII string has no embedded null/zero bytes
        # Simply create a bytes object from the data
        cdef const char* zero = <const char*>memchr(data, 0, size)
        if zero is NULL: return PyBytes_FromStringAndSize(data, size)

        # Scan through the entire string and count number of zero bytes
        cdef const char* end = data + size
        size += 1
        zero = <const char*>memchr(zero+1, 0, end-(zero+1))
        while zero is not NULL: size += 1; zero = <const char*>memchr(zero+1, 0, end-(zero+1))

        # Allocate the output
        cdef Py_ssize_t n
        cdef bytes buf
        cdef char small_buf[1024]
        cdef char* p
        if size <= sizeof(small_buf): buf = None; p = small_buf
        else: buf = PyBytes_FromStringAndSize(NULL, size); p = PyBytes_AS_STRING(buf)

        # Copy all data in chunks between zero bytes
        while data < end:
            n = end-data
            zero = <const char*>memchr(data, 0, n)
            if zero is NULL: memcpy(p, data, n); break
            n = zero-data
            memcpy(p, data, n)
            p += n
            p[0] = 0xC0; p[1] = 0x80; p += 2
            data = zero + 1

        # Output data
        return PyBytes_FromStringAndSize(small_buf, size) if buf is None else buf

    cdef bytes ucs1_utf8java_encode(const Py_UCS1 *data, Py_ssize_t size):
        if size > PY_SSIZE_T_MAX//2: raise MemoryError()
        cdef Py_ssize_t i = 0
        cdef Py_UCS1 ch
        cdef bytes buf
        cdef char* start
        cdef char small_buf[1024]
        if size*2 <= sizeof(small_buf): buf = None; start = small_buf
        else: buf = PyBytes_FromStringAndSize(NULL, size*2); start = PyBytes_AS_STRING(buf)
        cdef char* p = start
        while i < size:
            ch = data[i]; i += 1
            if 0 < ch < 0x80: p[0] = <char>ch; p += 1 # Encode ASCII (excluding null byte)
            else: # Encode Latin-1
                p[0] = <char>(0xC0|(ch >>   6))
                p[1] = <char>(0x80|(ch & 0x3F)); p += 2
        size = p - start
        if size == 0 or buf is None: return PyBytes_FromStringAndSize(start, size)
        cdef PyObject* buf_p
        if size != PyBytes_GET_SIZE(buf):
            buf_p = <PyObject*>buf; Py_INCREF(buf); buf = None
            _PyBytes_Resize(&buf_p, size)
            buf = <bytes>buf_p; Py_DECREF(buf)
        return buf

IF PY_VERSION >= PY_VERSION_3_3 or not PY_UNICODE_WIDE:
    cdef bytes ucs2_utf8java_encode(const Py_UCS2 *data, Py_ssize_t size):
        if size > PY_SSIZE_T_MAX//3: raise MemoryError()
        cdef Py_ssize_t i = 0
        cdef Py_UCS2 ch
        cdef bytes buf
        cdef char* start
        cdef char small_buf[1024]
        if size*3 <= sizeof(small_buf): buf = None; start = small_buf
        else: buf = PyBytes_FromStringAndSize(NULL, size*3); start = PyBytes_AS_STRING(buf)
        cdef char* p = start
        while i < size:
            ch = data[i]; i += 1
            if 0 < ch < 0x80: p[0] = <char>ch; p += 1 # Encode ASCII (excluding null byte)
            elif ch < 0x0800: # Encode Latin-1
                p[0] = <char>(0xC0|(ch >>   6))
                p[1] = <char>(0x80|(ch & 0x3F)); p += 2
            else:
                # This also catches surrogates which automatically get passed through
                p[0] = <char>(0xE0|((ch>>12)     ))
                p[1] = <char>(0x80|((ch>> 6)&0x3F))
                p[2] = <char>(0x80|((ch    )&0x3F)); p += 3
        size = p - start
        if size == 0 or buf is None: return PyBytes_FromStringAndSize(start, size)
        cdef PyObject* buf_p
        if size != PyBytes_GET_SIZE(buf):
            buf_p = <PyObject*>buf; Py_INCREF(buf); buf = None
            _PyBytes_Resize(&buf_p, size)
            buf = <bytes>buf_p; Py_DECREF(buf)
        return buf

IF PY_VERSION >= PY_VERSION_3_3 or PY_UNICODE_WIDE:
    cdef bytes ucs4_utf8java_encode(const Py_UCS4 *data, Py_ssize_t size):
        if size > PY_SSIZE_T_MAX//6: raise MemoryError()
        cdef Py_ssize_t i = 0
        cdef PyUCS4 ch
        cdef bytes buf
        cdef char* start
        cdef char small_buf[1024]
        if size*6 <= sizeof(small_buf): buf = None; start = small_buf
        else: buf = PyBytes_FromStringAndSize(NULL, size*6); start = PyBytes_AS_STRING(buf)
        cdef char* p = start
        while i < size:
            ch = data[i]; i += 1
            if 0 < ch < 0x80: p[0] = <char>ch; p += 1 # Encode ASCII (excluding null byte)
            elif ch < 0x0800: # Encode Latin-1
                p[0] = <char>(0xC0|(ch >>   6))
                p[1] = <char>(0x80|(ch & 0x3F)); p += 2
            elif ch < 0x10000:
                # This also catches surrogates which automatically get passed through
                p[0] = <char>(0xE0|((ch>>12)     ))
                p[1] = <char>(0x80|((ch>> 6)&0x3F))
                p[2] = <char>(0x80|((ch    )&0x3F)); p += 3
            else: # Encode UCS4 Unicode ordinals as a surrogate pair of 3-bytes
                p[0] = 0xED
                p[1] = <char>(0xA0|((ch>>16)&0x0F))
                p[2] = <char>(0x80|((ch>>10)&0x3F))
                p[3] = 0xED
                p[4] = <char>(0xB0|((ch>> 6)&0x0F))
                p[5] = <char>(0x80|((ch    )&0x3F)); p += 6
        size = p - start
        if size == 0 or buf is None: return PyBytes_FromStringAndSize(start, size)
        cdef PyObject* buf_p
        if size != PyBytes_GET_SIZE(buf):
            buf_p = <PyObject*>buf; Py_INCREF(buf); buf = None
            _PyBytes_Resize(&buf_p, size)
            buf = <bytes>buf_p; Py_DECREF(buf)
        return buf


########## UTF-8-Java Decoders ##########
IF PY_VERSION < PY_VERSION_3_3:
    cpdef unicode from_utf8j(bytes b):
        """
        Decodes a UTF-8-Java byte string to unicode. Most of the work in done in
        internal_utf8j_decode which uses a fused/template type to handle different character
        widths.
        """
        cdef Py_ssize_t size = PyBytes_GET_SIZE(b), pos = 0
        cdef cp_byte s = <cp_byte>PyBytes_AS_STRING(b), start = s, end = s + size

        # Size will always be at least as long as the resulting Unicode character count
        # It will be exactly equal if the bytes represent ASCII-only characters
        cdef unicode uni = PyUnicode_FromStringAndSize(NULL, size)
        if size == 0: return uni
        cdef Py_UNICODE *p = PyUnicode_AS_UNICODE(uni)
        IF PY_UNICODE_WIDE:
            cdef PyUCS4 result = internal_utf8j_decode[PyUCS4](&s, end, <PyUCS4*>p, &pos)
        ELSE:
            cdef PyUCS4 result = internal_utf8j_decode[Py_UCS2](&s, end, <Py_UCS2*>p, &pos)
        check_unicode_error(start, s, end, result)

        # Remove trailing extra bytes
        cdef PyObject* uni_p = <PyObject*>uni;
        Py_INCREF(uni); uni = None
        PyUnicode_Resize(&uni_p, size)
        uni = <unicode>uni_p; Py_DECREF(uni)
        return uni

ELSE:
    cpdef unicode from_utf8j(bytes b):
        """
        Decodes a UTF-8-Java byte string to unicode. Most of the work in done in
        internal_utf8j_decode which uses a fused/template type to handle different character
        widths. This function starts out assuming ASCII data and progressively widens the
        characters in the string when it hits a wider value.
        """
        cdef Py_ssize_t size = PyBytes_GET_SIZE(b)
        cdef cp_byte s = <cp_byte>PyBytes_AS_STRING(b), start = s, end = s + size

        if size == 0: return u''
        if size == 1 and 0 < s[0] < 0x80: return chr(s[0])
        if size == 2 and s[0] == 0xC0 and s[1] == 0x80: return u'\0'

        cdef Py_ssize_t pos = count_leading_ascii_nz(start, end)
        if pos == size:
            # Most common situation: all ASCII (except null byte)
            # Create an ASCII unicode string which does a direct copy of the data
            u = PyUnicode_New(size, 0x7F)
            memcpy(PyUnicode_DATA(u), start, size)
            return u
        s += pos

        cdef object oldbuf = None # the previous-width buffer or None if using the input data
        cdef const void *p = start # start of oldbuf or the input data
        cdef int oldkind = PyUnicode_1BYTE_KIND # the kind of data in p/oldbuf

        cdef unicode buf # the current buffer being written to
        cdef void *q # start of buf
        cdef int kind # the kind of data in q/buf

        # s is the input data, with s[0] being the next byte to be read
        # pos is the position within the output buffer, with q[pos] being the next value to be written to
        cdef PyUCS4 ch # the next character to be written to the output buffer

        if pos + 2 <= size and s[0] == 0xC0 and s[1] == 0x80:
            # ASCII data still, just had an encoded null byte
            buf = PyUnicode_New(size-1, 0x7F)
            q = PyUnicode_DATA(buf)
            memcpy(q, p, pos)
            ch = internal_utf8j_decode[char](&s, end, <char*>q, &pos)
            if check_unicode_error(start, s, end, ch) == 1:
                # All data was ASCII or null bytes - done!
                return buf[:pos] if size != pos else buf
            oldbuf = buf; p = q
        else:
            # At least UCS1 data - run internal_utf8j_decode to get the non-ASCII char
            ch = internal_utf8j_decode[char](&s, end, <char*>NULL, &pos)
            check_unicode_error(start, s, end, ch)

        buf = PyUnicode_New(end-s+pos-1, ch)
        q = PyUnicode_DATA(buf)
        kind = PyUnicode_KIND(buf)

        if kind == PyUnicode_1BYTE_KIND:
            memcpy(q, p, pos)
            (<Py_UCS1*>q)[pos] = <Py_UCS1>ch; pos += 1
            ch = internal_utf8j_decode[Py_UCS1](&s, end, <Py_UCS1*>q, &pos)
            if check_unicode_error(start, s, end, ch) == 1:
                return buf[:pos] if len(buf) != pos else buf
            oldbuf = buf; p = q; # oldkind = PyUnicode_1BYTE_KIND
            buf = PyUnicode_New(end-s+pos-2, ch); q = PyUnicode_DATA(buf); kind = PyUnicode_KIND(buf)

        if kind == PyUnicode_2BYTE_KIND:
            widen_unicode(<Py_UCS1*>p, <Py_UCS2*>q, pos)
            (<Py_UCS2*>q)[pos] = <Py_UCS2>ch; pos += 1
            ch = internal_utf8j_decode[Py_UCS2](&s, end, <Py_UCS2*>q, &pos)
            if check_unicode_error(start, s, end, ch) == 1:
                return buf[:pos] if len(buf) != pos else buf
            oldbuf = buf; p = q; oldkind = PyUnicode_2BYTE_KIND
            buf = PyUnicode_New(end-s+pos-5, ch); q = PyUnicode_DATA(buf); kind = PyUnicode_4BYTE_KIND

        # kind == PyUnicode_4BYTE_KIND:
        if oldkind == PyUnicode_1BYTE_KIND:
            widen_unicode(<Py_UCS1*>p, <PyUCS4*>q, pos)
        else:
            widen_unicode(<Py_UCS2*>p, <PyUCS4*>q, pos)
        (<PyUCS4*>q)[pos] = ch; pos += 1
        ch = internal_utf8j_decode[PyUCS4](&s, end, <PyUCS4*>q, &pos)
        check_unicode_error(start, s, end, ch)
        return buf[:pos] if len(buf) != pos else buf

##### Utilities #####
cdef unsigned long ASCII_CHAR_MASK = 0x80808080UL if sizeof(long) == 4 else 0x8080808080808080UL
cdef unsigned long NULL_DETECT_MASK = 0x01010101UL if sizeof(long) == 4 else 0x0101010101010101UL
cdef uintptr_t LONG_PTR_MASK = sizeof(long) - 1
IF PY_VERSION < PY_VERSION_3_3:
    cdef fused Py_UCS:
        Py_UCS2
        PyUCS4
ELSE:
    cdef fused Py_UCS:
        char # ASCII
        Py_UCS1
        Py_UCS2
        PyUCS4
    cdef fused Py_UCS_24:
        Py_UCS2
        PyUCS4
    cdef inline void widen_unicode(Py_UCS* s, Py_UCS_24* d, Py_ssize_t n):
        """Widen UCS data from one width to another."""
        cdef const Py_UCS *end = s + n
        cdef const Py_UCS *unrolled_end = s + (n & ~<size_t>3)
        while s < unrolled_end:
            d[0] = <Py_UCS_24>s[0]; d[1] = <Py_UCS_24>s[1]
            d[2] = <Py_UCS_24>s[2]; d[3] = <Py_UCS_24>s[3]
            s += 4; d += 4
        while s < end:
            d[0] = <Py_UCS_24>s[0]
            s += 1; d += 1
cdef inline Py_ssize_t count_leading_ascii_nz(cp_byte start, cp_byte end):
    """Get the count of number of ASCII characters (excluding 0) as the start of a string."""
    cdef cp_byte p = start, aligned_end = <cp_byte>((<uintptr_t>end) & ~LONG_PTR_MASK)
    cdef unsigned long x
    while ((<uintptr_t>p) & LONG_PTR_MASK) != 0:
        if p == end or p[0] == 0 or p[0] & 0x80: return p - start
        p += 1
    while p < aligned_end:
        x = (<const unsigned long *>p)[0]
        if ((((x - NULL_DETECT_MASK) & ~x) | x) & ASCII_CHAR_MASK) != 0: break
        p += sizeof(long)
    while p < end:
        if p[0] == 0 or p[0] & 0x80: return p - start
        p += 1
    return p - start

##### Internal code that does most of the processing #####
DEF DATA_END=0
DEF INV_CONT_1=1
DEF INV_CONT_2=2
DEF INV_CONT_3=3
DEF INV_CONT_4=4
DEF INV_CONT_5=5
DEF INV_START=6
cdef inline int check_unicode_error(cp_byte start, cp_byte s, cp_byte end, PyUCS4 ch) except -1:
    if ch == DATA_END:
        if s == end: return 1
        raise UnicodeDecodeError(CODEC_NAME, PyBytes_FromStringAndSize(<const char *>s, end-s), s-start, end-start, UNEXPECTED_END_OF_DATA)
    elif ch == INV_START:
        raise UnicodeDecodeError(CODEC_NAME, PyBytes_FromStringAndSize(<const char *>s, 1), s-start, s-start+1, INVALID_START_BYTE)
    elif ch <= INV_CONT_5:
        raise UnicodeDecodeError(CODEC_NAME, PyBytes_FromStringAndSize(<const char *>s, ch), s-start, s-start+ch, INVALID_CONTINUATION_BYTE)
    return 0

cdef PyUCS4 internal_utf8j_decode(cp_byte *s_ptr, cp_byte end, Py_UCS *dest, Py_ssize_t *d_pos):
    """
    Decode UTF-8-Java byte data to a Python unicode string.

    s_ptr   a pointer to a byte pointer, s_ptr[0] is use as the starting point of the decoding
            on return, it is updated to contain the next byte to be read
    end     the end of s_ptr[0], pointing to one past the last byte
    dest    output unicode string with an element type of char, Py_UCS1, Py_UCS2, or PyUCS4
    d_pos   a pointer to the position in dest to begin writing to
            on return, it is updated with the position of the next character to be written

    Returns `DATA_END` meaning the end of the data was reached, if s_ptr[0] != end then it was
    an unexpected end of the data, otherwise it was a good end of the data. Returns `INV_START` if
    the nest byte to be read is an invalid start byte. Returns one of `INV_CONT_#` where # is a
    number from 1 to 5 if the next set of bytes represent an invalid continuation of the starting
    byte. The next byte to be read is the starting byte. The # in the constant is the number of
    bytes after the starting byte to get to the invalid continuation byte (so `INV_CONT_1` means
    that there is a starting byte and an invalid continuation byte with no bytes inbetween).
    Otherwise, the next character to be written is returned, which cannot be written to the current
    destination. The destination must be widened and the function recalled.

    Before Python v3.3 this can only be called with Py_UCS2 or PyUCS4 and a request to widden is
    never returned, instead surrogate pairs are written if needed. In Python v3.3 and after all
    types are accepted and this is called first with char, then if needed widened and then
    repeated.
    """
    cdef PyUCS4 ch, ch2, ch3, uch1, uch2
    cdef cp_byte s = s_ptr[0], aligned_end = <cp_byte>((<uintptr_t>end) & ~LONG_PTR_MASK)
    cdef Py_UCS *p = dest + d_pos[0]
    cdef unsigned long x

    while s < end:
        ch = s[0]
        if ch < 0x80:
            if ((<uintptr_t>s) & LONG_PTR_MASK) == 0:
                while s < aligned_end:
                    # Detect if any byte in the long is 0x00 or >=0x80
                    x = (<unsigned long *>s)[0]
                    if ((((x - NULL_DETECT_MASK) & ~x) | x) & ASCII_CHAR_MASK) != 0: break
                    # Copy values
                    p[0] = s[0]; p[1] = s[1]; p[2] = s[2]; p[3] = s[3]
                    if sizeof(long) == 8: p[4] = s[4]; p[5] = s[5]; p[6] = s[6]; p[7] = s[7]
                    p += sizeof(long); s += sizeof(long)
                if s == end: ch = DATA_END; break
                ch = s[0]
            if ch < 0x80:
                if ch == 0x00: ch = INV_START; break
                p[0] = ch; p += 1; s += 1
                continue
        if ch == 0xC0:
            # C080  ->  0
            if s+2 > end: ch = DATA_END; break
            if s[1] != 0x80: ch = INV_CONT_1; break
            p[0] = 0; p += 1; s += 2
        elif ch < 0xE0: # C280-DFBF  ->  0080-07FF
            # Note: 80-BF are continuation bytes, C0-C1 should have been encoded with one byte or as a null byte
            if ch < 0xC2: ch = INV_START; break
            if s+2 > end: ch = DATA_END; break
            ch2 = s[1]
            if (ch2 & 0xC0) != 0x80: ch = INV_CONT_1; break
            s += 2
            ch = ((ch & 0x1F) << 6) | (ch2 & 0x3F)
            IF PY_VERSION >= PY_VERSION_3_3:
                if Py_UCS is char or (Py_UCS is Py_UCS1 and ch > 0xFF): break # out-of-range
                else: p[0] = ch; p += 1
            ELSE: p[0] = ch; p += 1
        elif ch < 0xF0: # E0A080-EFBFBF  ->  0800-FFFF
            if s+3 > end:
                if s+2 > end or ((s[1] & 0xC0) == 0x80 and ch != (0xE0 if s[1] < 0xA0 else 0xED)):
                    ch = DATA_END; break
                ch = INV_CONT_1; break
            ch2 = s[1]; ch3 = s[2]
            # E08080-E09FBF should have been encoded with two bytes
            if (ch2 & 0xC0) != 0x80 or ch == 0xE0 and ch2 < 0xA0: ch = INV_CONT_1; break
            if (ch3 & 0xC0) != 0x80: ch = INV_CONT_2; break
            uch1 = ((ch & 0x0F) << 12) | ((ch2 & 0x3F) << 6) | (ch3 & 0x3F); s += 3
            if ch == 0xED and ch2 >= 0xA0:
                # Surrogate in the range D800-DFFF - valid in modified-UTF8-Java
                # Need to read the second half of the surrogate pair
                # Output range is 100000 to 10FFFF
                if s+3 > end:
                    s -= 3
                    if s+4 <= end and s[3] != 0xED: ch = INV_CONT_3; break
                    if s+5 <= end and s[4] < 0xA0:  ch = INV_CONT_4; break
                    ch = DATA_END; break
                ch = s[0]; ch2 = s[1]; ch3 = s[2]
                uch2 = ((ch & 0x0F) << 12) | ((ch2 & 0x3F) << 6) | (ch3 & 0x3F)
                if ch != 0xED: s -= 3; ch = INV_CONT_3; break
                if ch2 < 0xA0 or (uch1 < 0xDC00 ==  uch2 < 0xDC00): s -= 3; ch = INV_CONT_4; break
                if (ch3 & 0xC0) != 0x80: s -= 3; ch = INV_CONT_5; break
                if uch1 >= 0xDC00: ch = uch1; uch1 = uch2; uch2 = ch # swap low and high surrogate
                s += 3
                IF PY_VERSION >= PY_VERSION_3_3:
                    ch = ((uch1 & 0x3FF) << 10) | (uch2 & 0x3FF)
                    if Py_UCS is not PyUCS4: break # out-of-range
                    else: p[0] = ch; p += 1
                ELIF PY_UNICODE_WIDE:
                    p[0] = ((uch1 & 0x3FF) << 10) | (uch2 & 0x3FF); p += 1
                ELSE:
                    p[0] = uch1; p[1] = uch2; p += 2
            else:
                ch = uch1
                IF PY_VERSION >= PY_VERSION_3_3:
                    if sizeof(Py_UCS) == 1: break # out-of-range
                p[0] = ch; p += 1
        else: ch = INV_START; break
    else: ch = DATA_END
    s_ptr[0] = s; d_pos[0] = p - dest
    return ch


##### Unicode Strings as Arrays #####
IF PY_VERSION >= PY_VERSION_3_3 or PY_UNICODE_WIDE:
    cdef inline Py_ssize_t __addl_chars_needed(const PyUCS4* s, Py_ssize_t n) nogil:
        cdef const PyUCS4* end = s + n
        n = 0
        while s < end: n += s[0] >= 0x10000; s += 1
        return n
    cdef inline Py_ssize_t __n_chars_fit(const PyUCS4* s, Py_ssize_t n, Py_ssize_t n_elems) nogil:
        cdef const PyUCS4* end = s+n
        cdef Py_ssize_t n_src = 0, n_dst = 0
        while s < end and n_dst < n_elems: n_dst += s[0] >= 0x10000; n_dst += 1; n_src += 1; s += 1
        return n_src
    cdef inline void __copy_ucs4_to_ucs2(const PyUCS4* src, Py_UCS2* dst, Py_ssize_t n) nogil:
        cdef PyUCS4 ch
        cdef const PyUCS4* end = src + n
        while src < end:
            ch = src[0]; src += 1
            if ch >= 0x10000:
                dst[0] = 0xD800 | ((ch >> 10) & 0x3FF)
                dst[1] = 0xDC00 | (ch & 0x3FF)
                dst += 2
            else: dst[0] = ch; dst += 1

cdef Py_ssize_t addl_chars_needed(unicode s, Py_ssize_t i, Py_ssize_t n) except -1:
    """Counts the number of surrogate pairs required to encode the unicode string as UCS2."""
    IF PY_VERSION >= PY_VERSION_3_3:
        return __addl_chars_needed((<const PyUCS4*>PyUnicode_DATA(s))+i, n) if PyUnicode_KIND(s) == PyUnicode_4BYTE_KIND else 0
    ELIF PY_UNICODE_WIDE:
        return __addl_chars_needed((<const PyUCS4*>PyUnicode_AS_UNICODE(s))+i, n)
    ELSE: return 0

cdef Py_ssize_t n_chars_fit(unicode s, Py_ssize_t i, Py_ssize_t n, Py_ssize_t n_elems) except -1:
    """
    Counts the number of characters from the source that can be stored in an array of n_elems as
    UCS2 after accounting for surrogate pairs.
    """
    IF PY_VERSION >= PY_VERSION_3_3:
        return __n_chars_fit((<const PyUCS4*>PyUnicode_DATA(s))+i, n, n_elems) if PyUnicode_KIND(s) == PyUnicode_4BYTE_KIND else (n if n < n_elems else n_elems)
    ELIF PY_UNICODE_WIDE:
        return __n_chars_fit((<const PyUCS4*>PyUnicode_AS_UNICODE(s))+i, n, n_elems)
    ELSE: return n if n < n_elems else n_elems 

cdef void* get_direct_copy_ptr(unicode s):
    """
    If the unicode string can be directly copied to a UCS2 (Java char) array the pointer to the
    string data is returned, otherwise NULL is returned.
    """
    IF PY_VERSION >= PY_VERSION_3_3:
        return PyUnicode_DATA(s) if PyUnicode_KIND(s) == PyUnicode_2BYTE_KIND else NULL
    ELIF PY_UNICODE_WIDE: return NULL
    ELSE: return PyUnicode_AS_UNICODE(s)

cdef int copy_uni_to_ucs2(unicode src, Py_ssize_t src_i, Py_ssize_t n, void* _dst, Py_ssize_t dst_i) except -1:
    """
    Copy unicode data from a unicode string to a UCS2 string (like a Java char array). This tries
    to be as optimal as possible with copying of data. n is the number of characters from src,
    might need more than n elements in dst if src is a unicode string in UCS4 encoding.
    """
    cdef Py_UCS2* dst = (<Py_UCS2*>_dst)+dst_i
    IF PY_VERSION >= PY_VERSION_3_3:
        kind = PyUnicode_KIND(src)
        if kind == PyUnicode_4BYTE_KIND:
            __copy_ucs4_to_ucs2((<PyUCS4*>PyUnicode_DATA(src))+src_i, dst, n)
        elif kind == PyUnicode_1BYTE_KIND:
            widen_unicode[Py_UCS1,Py_UCS2]((<Py_UCS1*>PyUnicode_DATA(src))+src_i, dst, n)
        else: # kind == PyUnicode_2BYTE_KIND
            memcpy(dst, (<Py_UCS2*>PyUnicode_DATA(src))+src_i, n*sizeof(Py_UCS2))
    ELIF PY_UNICODE_WIDE:
        __copy_ucs4_to_ucs2((<PyUCS4*>PyUnicode_AS_UNICODE(src))+src_i, dst, n)
    ELSE:
        memcpy(dst, PyUnicode_AS_UNICODE(src)+src_i, n*sizeof(Py_UCS2))
    return 0
