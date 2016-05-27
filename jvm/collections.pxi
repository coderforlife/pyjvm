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

Java Collections
----------------
Object templates for List, Set, Map, and other simple collections types.


FUTURE:
    add Java wrappers for Python collection types
        use them in the List function when recieving a non-Java collection
    in Set, all 'other's should be any iterable, not just Java Collections
"""

cdef jclass Collections
cdef struct JCollectionsDef:
    jmethodID copy
    jmethodID fill
    jmethodID frequency
    jmethodID reverse
    jmethodID sort, sort_c
cdef JCollectionsDef CollectionsDef

cdef int init_collections(JEnv env) except -1:
    # java.util.Collections utility class
    global Collections
    cdef jclass clazz = env.FindClass('java/util/Collections')
    Collections = env.NewGlobalRef(clazz)
    env.DeleteLocalRef(clazz)
    
    # Collections utilities
    CollectionsDef.copy      = env.GetStaticMethodID(Collections, 'copy',      '(Ljava/util/List;Ljava/util/List;)V')
    CollectionsDef.fill      = env.GetStaticMethodID(Collections, 'fill',      '(Ljava/util/List;Ljava/lang/Object;)V')
    CollectionsDef.frequency = env.GetStaticMethodID(Collections, 'frequency', '(Ljava/util/Collection;Ljava/lang/Object;)I')
    CollectionsDef.reverse   = env.GetStaticMethodID(Collections, 'reverse',   '(Ljava/util/List;)V')
    CollectionsDef.sort      = env.GetStaticMethodID(Collections, 'sort',      '(Ljava/util/List;)V')
    CollectionsDef.sort_c    = env.GetStaticMethodID(Collections, 'sort',      '(Ljava/util/List;Ljava/util/Comparator;)V')

    ##### Object templates for basic collection classes #####
    #class Comparator(object):
    #    __metaclass__ = JavaClass
    #    __java_class_name__ = 'java.util.Comparator'
    class Iterable(object): # implements collections.Iterable
        __metaclass__ = JavaClass
        __java_class_name__ = 'java.lang.Iterable'
        def __iter__(self): return self._jcall0('iterator')
    class Enumeration(object): # implements collections.Iterator
        __metaclass__ = JavaClass
        __java_class_name__ = 'java.util.Enumeration'
        def __iter__(self): return self
        def __next__(self):
            if not self._jcall0('hasMoreElements'): raise StopIteration()
            return self._jcall0('nextElement')
        IF PY_VERSION < PY_VERSION_3: next = __next__
    class Iterator(object): # implements collections.Iterator
        __metaclass__ = JavaClass
        __java_class_name__ = 'java.util.Iterator'
        def __iter__(self): return self
        def __next__(self):
            if not self._jcall0('hasNext'): raise StopIteration()
            return self._jcall0('next')
        IF PY_VERSION < PY_VERSION_3: next = __next__
    class Collection(Iterable): # implements collections.Sized and collections.Container
        __java_class_name__ = 'java.util.Collection'
        def __contains__(self, value): return self._jcall1('contains', value)
        def __len__(self): return self._jcall0('size')

    ##### Object templates for the core collection types #####
    class Set(Collection, Iterable): # implements collections.MutableSet
        __java_class_name__ = 'java.util.Set'
        def add(self, value): self._jcall1('add', value)
        def clear(self): self._jcall0('clear')
        def discard(self, value): self._jcall1('remove', value)
        def remove(self, value):
            if not self._jcall1('remove', value): raise KeyError(value)
        def pop(self):
            it = self._jcall0('iterator')
            if not it._jcall0('hasNext'): raise KeyError()
            value = it._jcall0('next')
            it._jcall0('remove')
            return value
        def __ior__(self, other):  self._jcall1('addAll', other)    # union
        def __iand__(self, other): self._jcall1('retainAll', other) # intersection
        def __isub__(self, other): self._jcall1('removeAll', other) # set difference
        def __ixor__(self, other): self|=other; self -= self&other  # symmetric difference
        def __or__(self, other):  x = type(self)(self); x |= other; return x
        def __and__(self, other): x = type(self)(self); x &= other; return x
        def __sub__(self, other): x = type(self)(self); x -= other; return x
        def __xor__(self, other): x = self|other; x -= self&other;  return x
        def isdisjoint(self, other): return get_java_class('java.util.Collections').disjoint(self, other)
        def __ge__(self, other): return self._jcall1('containsAll', other) # superset
        def __gt__(self, other): return self >= other and self != other
        def __le__(self, other): return other._jcall1('containsAll', self) # subset
        def __lt__(self, other): return self <= other and self != other
        def issubset(self, other): return self <= other
        def issuperset(self, other): return self >= other
        def union(self, other, *others):
            x = self | other
            for other in others: x._jcall1('addAll', other)
            return x
        def intersection(self, other, *others):
            x = self & other
            for other in others: x._jcall1('retainAll', other)
            return x
        def difference(self, other, *others):
            x = self - other
            for other in others: x._jcall1('removeAll', other)
            return x
        def symmetric_difference(self, other): return self ^ other
        def update(self, other, *others):
            self._jcall1('addAll', other)
            for other in others: self._jcall1('addAll', other)
        def intersection_update(self, other, *others):
            self._jcall1('retainAll', other)
            for other in others: self._jcall1('retainAll', other)
        def difference_update(self, other, *others):
            self._jcall1('removeAll', other)
            for other in others: self._jcall1('removeAll', other)
        def symmetric_difference_update(self, other): self ^= other
            
    def _set_list_slice(sub, value, Py_ssize_t n):
        """Function for doing lst[i:j] = value when i != n; n = j-i; sub = lst[i:j]"""
        cdef JEnv env = jenv()
        cdef jvalue val[2]
        cdef Py_ssize_t i, nv
        if isinstance(value, Collection):
            val[0].l = get_object(sub)
            nv = value._jcall0('size')
            if nv == n:
                val[1].l = get_object(value)
                env.CallStaticVoidMethod(Collections, CollectionsDef.copy, val, n <= 100)
            elif nv < n:
                val[1].l = get_object(value)
                env.CallStaticVoidMethod(Collections, CollectionsDef.copy, val, nv <= 100)
                sub._jcall2('subList', nv, n)._jcall0('clear')
            else: # n > nv
                val[1].l = get_object(value._jcall2('subList', 0, n))
                env.CallStaticVoidMethod(Collections, CollectionsDef.copy, val, n <= 100)
                sub._jcall1('addAll', value._jcall2('subList', n, nv))
        elif isinstance(value, collections.Iterable):
            it = iter(value)
            try:
                for i in xrange(n): sub._jcall2('set', i, next(it))
            except StopIteration: sub._jcall2('subList', i, n)._jcall0('clear')
            for x in it: sub._jcall2('add', x)
        else:
            val[0].l = get_object(sub)
            val[1].l = py2object(env, value, JClass.named(env, 'java.lang.Object'))
            try: env.CallStaticVoidMethod(Collections, CollectionsDef.fill, val, n <= 100)
            finally:
                if val[1].l is not NULL: env.DeleteLocalRef(val[1].l)
    
    class List(Collection, Iterable): # implements collections.MutableSequence
        __java_class_name__ = 'java.util.List'
        def __getitem__(self, i):
            if isinstance(i, slice):
                start,stop,step = i.indices(self._jcall0('size'))
                if step != 1: raise ValueError('only a step of 1 is supported')
                return self._jcall2('subList', start, stop)
            i = int(i)
            if i < 0: i += self._jcall0('size')
            return self._jcall1('get', i)
        def __setitem__(self, i, value):
            n = self._jcall0('size')
            if isinstance(i, slice):
                start,stop,step = i.indices(n)
                if step != 1: raise ValueError('only a step of 1 is supported')
                if start != n:
                    _set_list_slice(self._jcall2('subList', start, stop), value, stop - start)
                elif isinstance(value, Collection): self._jcall1('addAll', value)
                elif isinstance(value, collections.Iterable):
                    for v in value: self._jcall1('add', v)
                else: self._jcall1('add', value)
            i = int(i)
            if i < 0: i += n
            self._jcall2('set', i, value)
        def __delitem__(self, i):
            if isinstance(i, slice):
                n = self._jcall0('size')
                start,stop,step = i.indices(n)
                if step != 1: raise ValueError('only a step of 1 is supported')
                if start == 0 and stop == n: self._jcall0('clear')
                else: self._jcall2('subList', start, stop)._jcall0('clear')
            i = int(i)
            if i < 0: i += self._jcall0('size')
            self._jcall1prim('remove', i)
        def index(self, value, start=None, stop=None):
            cdef int i
            if start is None and stop is None:
                i = self._jcall1('indexOf', value)
                if i == -1: raise ValueError()
                return i
            start, stop, _ = slice(start, stop, 1).indices(self._jcall0('size'))
            return self._jcall2('subList', start, stop)._jcall1('indexOf', value)
        def append(self, value): self._jcall1('add', value)
        def insert(self, index, value): self._jcall2('add', index, value)
        def extend(self, values):
            if isinstance(values, Collection): self._jcall1('addAll', values)
            else:
                for value in values: self._jcall1('add', value)
        def __iadd__(self, values):
            if isinstance(values, Collection): self._jcall1('addAll', values)
            else:
                for value in values: self._jcall1('add', value)
        def remove(self, value): self._jcall1obj('remove', value)
        def pop(self, Py_ssize_t i):
            if i < 0: i += self._jcall0('size')
            return self._jcall1prim('remove', i)
        def count(self, value):
            cdef JEnv env = jenv()
            cdef jvalue val[2]
            val[0].l = get_object(self)
            val[1].l = py2object(env, value, JClass.named(env, 'java.lang.Object'))
            try: return env.CallStaticIntMethod(Collections, CollectionsDef.frequency, val, self._jcall0('size') <= 100)
            finally:
                if val[1].l is not NULL: env.DeleteLocalRef(val[1].l)
        def reverse(self):
            cdef jvalue val
            val.l = get_object(self)
            jenv().CallStaticVoidMethod(Collections, CollectionsDef.reverse, &val, self._jcall0('size') <= 100)
        def sort(self, c=None):
            cdef JEnv env = jenv()
            cdef jvalue val[2]
            val[0].l = get_object(self)
            if c is None:
                env.CallStaticVoidMethod(Collections, CollectionsDef.sort, val, self._jcall0('size') <= 50)
            else:
                val[1].l = py2object(env, c, JClass.named(env, 'java.util.Comparator'))
                try: env.CallStaticVoidMethod(Collections, CollectionsDef.sort_c, val, self._jcall0('size') <= 50)
                finally: env.DeleteLocalRef(val[1].l)
        def binarySearch(self, key, c=None):
            if c is None:
                return get_java_class('java.util.Collections').binarySearch(self, key)
            return get_java_class('java.util.Collections').binarySearch(self, key, c)
        def __reversed__(self):
            it = self._jcall1('listIterator', self._jcall0('size'))
            while it._jcall0('hasPrevious'): yield it._jcall0('previous')

    _no_arg = object()
    class Map(object): # implements collections.MutableMap
        __metaclass__ = JavaClass
        __java_class_name__ = 'java.util.Map'
        def __contains__(self, key): return self._jcall1('containsKey', key)
        def __len__(self): return self._jcall0('size')
        def __getitem__(self, key):
            val = self._jcall1('get', key)
            if val is None and not self._jcall1('containsKey', key): raise KeyError(key)
            return val
        def get(self, key, default=None):
            val = self._jcall1('get', key)
            if val is None and not self._jcall1('containsKey', key): return default
            return val
        def __setitem__(self, key, value): self._jcall2('put', key, value)
        def setdefault(self, key, default=None):
            val = self._jcall1('get', key)
            if val is None and not self._jcall1('containsKey', key):
                self._jcall2('put', key, default)
                return default
            return val
        def clear(self): self._jcall0('clear')
        def __delitem__(self, key):
            if not self._jcall1('containsKey', key): raise KeyError(key)
            self._jcall1('remove', key)
        def pop(self, key, default=_no_arg):
            if not self._jcall1('containsKey', key):
                if default is _no_arg: return default
                raise KeyError(key)
            return self._jcall1('remove', key)
        def popitem(self):
            it = self._jcall0('entrySet')._jcall0('iterator')
            if not it._jcall0('hasNext'): raise KeyError()
            entry = it._jcall0('next')
            it._jcall0('remove')
            return entry
        def __iter__(self): return self._jcall0('keySet')._jcall0('iterator')
        def update(self, other=_no_arg, **kwargs):
            if other is not _no_arg:
                if isinstance(other, Map): self._jcall1('putAll', other)
                elif isinstance(other, collections.Mapping):
                    for k,v in other.items(): self._jcall2('put', k, v) # TODO
                else:
                    for k,v in other: self._jcall2('put', k, v)
            for k,v in kwargs.items(): self._jcall2('put', k, v) # TODO
        def keys(self):   return self._jcall0('keySet')
        def values(self): return self._jcall0('values')
        def items(self):  return self._jcall0('entrySet')
        IF PY_VERSION < PY_VERSION_3:
            viewkeys = keys
            viewvalues = values
            viewitems = items
            iterkeys = keys
            itervalues = values
            iteritems = items

    class MapEntry(object):
        # Made to act like a tuple of (key, value)
        __metaclass__ = JavaClass
        __java_class_name__ = 'java.util.Map$Entry'
        def __getitem__(self, i):
            if isinstance(i, slice):
                start,stop,step = i.indices(2)
                if start == 0 and stop == 2 and step == 1:
                    return (self._jcall0('getKey'), self._jcall0('getValue'))
                elif start == 1 and stop == -1 and step == -1:
                    return (self._jcall0('getValue'), self._jcall0('getKey'))
                elif step > 0 and stop > start or step < 0 and stop < start:
                    return (self._jcall0('getKey') if start == 0 else self._jcall0('getValue'),)
                else: return ()
            i = int(i)
            if i < 0: i += 2
            if i == 0: return self._jcall0('getKey')
            if i == 1: return self._jcall0('getvalue')
            raise IndexError()
        def __len__(self): return 2
        def __iter__(self):
            yield self._jcall0('getKey')
            yield self._jcall0('getValue')
        def __reversed__(self):
            yield self._jcall0('getValue')
            yield self._jcall0('getKey')
        def __contains__(self, value):
            return value == self._jcall0('getKey') or value == self._jcall0('getValue')
        def count(self, value):
            return (value == self._jcall0('getKey')) + (value == self._jcall0('getValue'))
        def index(self, value, start=None, stop=None):
            if start is None and stop is None:
                if value == self._jcall0('getKey'): return 0
                if value == self._jcall0('getValue'): return 1
                raise ValueError()
            start, stop, _ = slice(start, stop, 1).indices(2)
            if start == 0 and stop > 0 and value == self._jcall0('getKey'): return 0
            if start <= 1 and stop == 2 and value == self._jcall0('getValue'): return 1
            raise ValueError()
    
    # Register ABCs
    import collections
    collections.MutableSet.register(Set)
    collections.MutableSequence.register(List)
    collections.MutableMapping.register(Map)
    collections.Sequence.register(MapEntry)
    
cdef int dealloc_collections(JEnv env) except -1:
    global Collections
    if Collections is not NULL: env.DeleteGlobalRef(Collections)
    Collections = NULL
JVM.add_init_hook(init_collections)
JVM.add_dealloc_hook(dealloc_collections)
