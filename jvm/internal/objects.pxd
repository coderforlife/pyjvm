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

from .jni cimport jclass, jobject, jvalue, jint
from .core cimport JClass, JObject, JEnv, jenv, SystemDef

cpdef get_java_class(unicode classname)
cpdef create_java_object(JEnv env, JObject obj)
cdef inline JClass get_object_class(obj):
    """Gets the JClass of an Object"""
    return type(obj).__jclass__
cdef inline jclass get_class(cls):
    """Gets the jclass of a JavaClass"""
    return (<JClass>cls.__jclass__).clazz
cdef inline jobject get_object(obj):
    """Gets the jobject of an Object"""
    return (<JObject>obj.__object__).obj
cdef inline jint java_id(jobject obj):
    """Like id() but for jobjects, getting the identity of the object"""
    cdef jvalue val
    val.l = obj
    return jenv().CallStaticInt(SystemDef.clazz, SystemDef.identityHashCode, &val)
