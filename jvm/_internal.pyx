#cython: cdivision=True
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

Internal Library
----------------
This brings together all of the PXI files along with defining some basic functions and definitions.
"""
from __future__ import division
from __future__ import unicode_literals
from __future__ import print_function

from jni cimport *

DEF JNI_VERSION_1_1=0x00010001
DEF JNI_VERSION_1_2=0x00010002
DEF JNI_VERSION_1_4=0x00010004
DEF JNI_VERSION_1_6=0x00010006

DEF PY_VERSION_2=0x02000000
#DEF PY_VERSION_2_7=0x02070000
DEF PY_VERSION_3=0x03000000
DEF PY_VERSION_3_2=0x03020000
DEF PY_VERSION_3_3=0x03030000
#DEF PY_VERSION_3_5=0x03050000

# Target Java SE 6 - pretty old already and it does help
# The code requires at least JNI_VERSION_1_2. If lowered to JNI_VERSION_1_4 a fallback for deleting
# references is provided, although it might be slower. If lowered to JNI_VERSION_1_2 native
# ByteBuffers can no longer be used.
DEF JNI_VERSION=JNI_VERSION_1_6

include "config.pxi"

from cpython.unicode cimport PyUnicode_DecodeASCII, PyUnicode_AsUTF8String as utf8
from cpython.bytes cimport PyBytes_Check
from cpython.unicode cimport PyUnicode_Check

def __debug(*args):
    import sys
    if len(args) == 1: args = args[0]
    print(args)
    sys.stdout.flush()
    sys.stderr.flush()

# For displaying pointers
cdef unicode __str_ptr = "%0"+str(sizeof(void*)*2)+"X"
cdef inline unicode str_ptr(const void* p): return __str_ptr % (<long>p)

# For dealing with Python 2/3 differences
cdef inline unicode to_unicode(basestring s):
    """
    Make sure a value is unicode. This is necessary in Python 2 since attribute names are always
    bytes and strings default to bytes. This assumes the data is ASCII and does strict error
    processing, which is purposely restrictive. In Python 3 only unicode strings are allowed.
    """
    IF PY_VERSION >= PY_VERSION_3: return s
    ELSE: return PyUnicode_DecodeASCII(<bytes>s, len(s), NULL) if PyBytes_Check(s) else s
IF PY_VERSION >= PY_VERSION_3:
    cdef inline bint is_string(s):     return PyUnicode_Check(s)
    cdef inline object KEYS(dict d):   return d.keys()
    cdef inline object ITEMS(dict d):  return d.items()
    cdef inline object VALUES(dict d): return d.values()
ELSE:
    cdef inline bint is_string(s):     return PyBytes_Check(s) or PyUnicode_Check(s) 
    cdef inline object KEYS(dict d):   return d.viewkeys()
    cdef inline object ITEMS(dict d):  return d.viewitems()
    cdef inline object VALUES(dict d): return d.viewvalues()
    
# For conditional GIL release
from cpython.pystate cimport PyThreadState
cdef extern from "Python.h":
    PyThreadState* PyEval_SaveThread()
    void PyEval_RestoreThread(PyThreadState *tstate)

include "unicode.pxi"
include "jvm.pxi"
include "jref.pxi"
include "jenv.pxi"
include "objects.pxi"
include "convert.pxi"
include "arrays.pxi"
include "numbers.pxi"
include "collections.pxi"
include "packages.pxi"

publicfuncs = {
    'get_java_class':get_java_class,'synchronized':synchronized,'unbox':unbox,'register_converter':register_converter,
    'JavaClass':JavaClass,'JavaMethods':JavaMethods,'JavaMethod':JavaMethod,'JavaConstructor':JavaConstructor,
    'boolean_array':boolean_array,'char_array':char_array,'object_array':object_array,
    'byte_array':byte_array,'short_array':short_array,'int_array':int_array,'long_array':long_array,
    'float_array':float_array,'double_array':double_array,
}
