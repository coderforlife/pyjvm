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

Utility Functions
"""

from __future__ import absolute_import

include "version.pxi"

# For displaying pointers
cdef unicode __str_ptr = u"%0"+str(sizeof(void*)*2)+u"X"
cdef inline unicode str_ptr(const void* p): return __str_ptr % (<size_t>p)

# Python 2/3 interoperability
from cpython.unicode cimport PyUnicode_Check, PyUnicode_DecodeASCII
from cpython.bytes cimport PyBytes_Check
cdef inline unicode to_unicode(basestring s):
    """
    Make sure a value is unicode. This is necessary in Python 2 since attribute names are always
    bytes and strings default to bytes. This assumes the data is ASCII and does strict error
    processing, which is purposely restrictive. In Python 3 only unicode strings are allowed.
    """
    IF PY_VERSION >= PY_VERSION_3: return s
    ELSE: return PyUnicode_DecodeASCII(<bytes>s, len(s), NULL) if PyBytes_Check(s) else s
IF PY_VERSION >= PY_VERSION_3:
    cdef inline bint is_string(s): return PyUnicode_Check(s)
    cdef inline object KEYS(d):    return d.keys()
    cdef inline object ITEMS(d):   return d.items()
    cdef inline object VALUES(d):  return d.values()
ELSE:
    cdef inline bint is_string(s): return PyBytes_Check(s) or PyUnicode_Check(s)
    cdef inline object KEYS(d):    return d.viewkeys()
    cdef inline object ITEMS(d):   return d.viewitems()
    cdef inline object VALUES(d):  return d.viewvalues()
cdef inline is_callable(f):
    IF PY_VERSION >= PY_VERSION_3_2 or PY_VERSION < PY_VERSION_3:
        return callable(f)
    ELSE:
        from collections import Callable
        return isinstance(f, Callable)
        
# For conditional GIL release
from cpython.pystate cimport PyThreadState
cdef extern from "Python.h":
    PyThreadState* PyEval_SaveThread()
    void PyEval_RestoreThread(PyThreadState *tstate)
