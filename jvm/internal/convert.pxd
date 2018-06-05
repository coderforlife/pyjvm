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

from .jni cimport jobject, jvalue
from .core cimport JObject, JClass, JMethod, JEnv
from .objects cimport get_object


cdef object object2py(JEnv env, jobject obj)
cdef inline jobject py2object(JEnv env, object x, JClass target) except? NULL:
    """
    Converts a Python object to an instance of the given target class (or a subclass). A new local
    reference if returned and the caller is responsible for deleting when finished (unless is it
    NULL). If no conversion is possible, a TypeError is raised.
    """
    cdef P2JQuality quality
    cdef P2JConvert conv = p2j_obj_lookup(env, x, target, &quality)
    if quality > FAIL: return conv.convert(env, x)
    raise TypeError(u'Could not convert "%s" to "%s"' % (x, target))


##### Python-to-Java conversion internals #####
ctypedef P2JConvert (*p2j_check)(JEnv env, object x, JClass p, P2JQuality* quality)
ctypedef jobject (*p2j_conv)(JEnv env, object x) except? NULL
ctypedef int (*p2j_prim)(JEnv env, object x, jvalue* val) except -1
cdef enum P2JQuality: PERFECT = 100, GREAT = 75, GOOD = 50, BAD = 25, FAIL = -1

cdef inline P2JConvert p2j_lookup(JEnv env, object x, JClass target, P2JQuality* q):
    return p2j_prim_lookup(env, x, target, q) if target.is_primitive() else p2j_obj_lookup(env, x, target, q)
cdef P2JConvert p2j_prim_lookup(JEnv env, object x, JClass target, P2JQuality* q)
cdef P2JConvert p2j_obj_lookup(JEnv env, object x, JClass target, P2JQuality* best)
cdef reg_conv_cy(JEnv env, pytype, unicode cn, p2j_check check)


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
        return self.conv_cy(env, x) if self.conv_py is None else env.NewLocalRef(get_object(self.conv_py(x)))


##### Python-to-Java method arguments #####
cdef JMethod select_method(list methods, key, unicode pre=*)
cdef JMethod conv_method_args(JEnv env, list methods, tuple args, jvalue** _jargs)
cdef jvalue* conv_method_args_single(JEnv env, JMethod method, tuple args) except? NULL
cdef int free_method_args(JEnv env, JMethod m, jvalue* jargs) except -1
