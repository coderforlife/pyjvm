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
"""

from __future__ import absolute_import

include "version.pxi"

IF PY_VERSION >= PY_VERSION_3:
    cdef inline unicode unichr(int x): return chr(x)
ELSE:
    unichr

cpdef bytes any_to_utf8j(basestring s)
cpdef bytes to_utf8j(unicode s)
cpdef unicode from_utf8j(bytes b)

cdef Py_ssize_t addl_chars_needed(unicode s, Py_ssize_t i, Py_ssize_t n) except -1
cdef Py_ssize_t n_chars_fit(unicode s, Py_ssize_t i, Py_ssize_t n, Py_ssize_t n_elems) except -1
cdef void* get_direct_copy_ptr(unicode s)
cdef int copy_uni_to_ucs2(unicode src, Py_ssize_t src_i, Py_ssize_t n, void* dst, Py_ssize_t dst_i) except -1
