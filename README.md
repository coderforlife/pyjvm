PyJVM - Java bindings for Python
==============================

This uses JNI to give access to all of Java from Python. On top of that it uses lots of Java
reflection to be able to automatically discover Java classes, their methods and their fields. The
classes are wrapped in Python objects and using them becomes seamless from within Python. PyJVM
tries to make the integration as seamless as possible, for example making Java objects that
implement `java.util.Iterable` iterable in Python as well.

To get started, simply `import jvm`. After that you just need start importing the classes you want
to use from the `J` module. The `J` module is the 'master' module and has the entire Java namespace
is available under it. For example:

    from J.java.lang import System
    System.out.println('Hello World!')

Additionally, the java and javax namespaces are also directly importable:

    from java.lang import System
    System.out.println('Hello World!')

For the most part, the objects should behave as you might expect.

**Note:** strings should always be unicode, and in some cases a byte-string will end up being
converted to a byte array instead of a java.lang.String. In Python 3 this is easy, strings are
normally unicode. In Python 2, it is recommended to use `from __future__ import unicode_literals`.


Starting the JVM
----------------
The JVM starts automatically as soon as it is needed. However, once it is started, several JVM
properties cannot be modified such as the amount of heap space or enabling assertions. These can be
given to the function `jvm.start()`, each complete option as a separate string. This function
accepts most command line options that can be given to the `java` command line program. It also
accepts a few special keyword arguments to make the most common options easier:

    jvm.start(max_heap=16*1024)                # start the JVM with a max heap size of 16 MiB
    jvm.start(classpath=('~/myclasses.jar',))  # start the JVM with the given classpath

If the JVM is already started, this will produce an error (or warning in some rare cases) and the
options will be dropped. The JVM could have been started automatically.

Additionally, you can check if the JVM is already started with:

    jvm.started()
	
**Note:** currently the classpath must be specified before the JVM is started. It is planned to
make it dynamic in the future.

**Note:** technically the JVM can be stopped with `jvm.stop()`, however it is unlikely to be able
to be restarted after that due to limitations of most JVMs, so it is of limited use.


Java Modules
------------
By default, only `java` and `javax` namespaces can be imported directly. But any name can be added
to the list of base module names that it forwarded to Java packages. To do so use the following
function:

    jvm.register_module_name(name)

To see the list of registered names, call:

    names = jvm.get_module_names()

Some common base names that might be added would be 'com' or 'org' if those are common beginnings
of package names. These modules try to predict what classes and packages are nested under the
package they represent. However, if the JVM (or the user) uses a non-`URLClassLoader` or the class
loader has URLs that are not local files, those classes and packages will not be enumerated by
`dir` on the module.


Java Classes
------------
Within Python the type of Java objects are subclasses of `J.JavaClass`. Each instance of
`JavaClass` represents a different Java class, and can be used in many places for an instance of
`java.lang.Class`. When you get a class, like `java.lang.Object`, this is a `JavaClass`. The
`JavaClass` objects also act as the holder for all of the static fields, methods, and nested
classes. For example:

    pi = java.lang.Math.PI                        # get static field
    x = java.lang.Math.atan2(4.5, 6.5)            # call static method
    J.com.example.MyClass.my_static_int_field = 5 # set static field

One can query what static members are available by using `dir`:

    list_of_static_members = dir(cls)

Besides static members, the `JavaClass` objects also work as you would except for constructing new
objects:

    rand = java.util.Random(100)                  # call a constructor

Additionally, the classes are setup so isinstance and issubclass work. For example:

    issubclass(java.util.HashMap, java.util.Map)  # returns True
    m = java.util.HashMap()
    isinstance(m, java.util.Map)                  # returns True


Java Instances
--------------
Once you get an instance of a Java object, you can start using the resulting object just like you
would in Java, accessing fields and calling methods. Just like with `JavaClass` objects, you can
use `dir` on the instances to get a list of the instance fields, methods, and member classes.

**Note:** currently member classes do not remember where they came from, and so their constructor
needs to be passed an additional first argument for the instance they are linked to.

The `JavaClass` of an object can be obtained using `type` on the instance. Additionally, the Java
instances try to emulate Python classes as best they can. Calling `hash(j)` on a Java instance will
return the value from `j.hashCode()`, using `str(j)` on the instance calls `j.toString()`, and
`j == k` / `j != k` use `j.equals(k)` internally. Other types (such as `java.util.Iterator`) define
more Python mappings. See [Predefined Class Templates](#predefined-class-templates) for more
information.

**Note:** unlike in Java, static methods and fields are inaccessible from instances, in Java this only
produces a warning (and is strongly discouraged), here it is enforced.


Java Methods and Constructors
-----------------------------
In Java, there can be more than one constructor for a class or more than one method with a
particular name in a particular class. This is called method overloading. This is a feature that
isn't directly supported in Python, so it is emulated.

Methods and constructors are looked up based on the number of arguments given to them and the
quality of conversions that can be done for the Python objects to the actual parameter types of the
method/constructor. See the [conversion](#automatic-conversion) section for more information on the
available conversions. It is always best to use actual Java objects when possible, as they can be
mapped directly to the parameter types, but this is not always possible, there may be cases when
the proper method is not selected properly, in which case you can use the brackets to select a the
proper one by its signature. Some examples:

    java.util.Date['IIIIII'](y, m, d, h, mn, s)      # selects the constructor that takes 6 ints
    java.util.Random[int](100)                       # selects the constructor that takes 1 int
    java.lang.System.out.println['java.lang.String']('Hi') # selects the method that takes 1 string

These examples are simple, but hopefully you get the idea. You can specify a single string that
gives the parameter type signature or the full method signature (as given by the `javap` program,
with . or / as separators). Or one value can be given for each parameter which is either a string
representing the type (can be with or without the L;), or a `JavaClass` object, or a limited set of
obvious Python types (`object` to `java.lang.Object`, `unicode` to `java.lang.String`, `bytes` to 
`[B`, `bool` to `Z`, `int` to `I`, `long` to `J`, `float` to `D`).

Besides using the `javap` program to find the signatures, the available signatures can be found
using an ellipsis in the brackets:

    sigs = java.util.Data[...]
    sigs = java.lang.System.out.println[...]

When used without the ellipsis, the brackes actually give back a `J.JavaMethod` or `J.JavaConstructor`
object that can be passed around, and when called, calls the method for the original instance of
creates an object. The object can also be queried for its name, signature, paramater types, the
return type/`JavaClass` that will be created, and the object is it bound to (if it isn't a
constructor or static method).

When a method is not called or the brackets are not used on it, it is a `J.JavaMethods` object which
can also be passed around and is bound to the original object (if it wasnt a static method). It also
can be queried for the bound object and class and name. Additionally, it can be iterated over,
yielding `JavaMethod` objects. Similarily, a `JavaClass` object can be iterated over yeilding the
`JavaConstructor` objects.

**Note:** the brackets on `JavaClass` objects also are important for arrays, see the end of the
[Java Arrays](#java-arrays) section.

**Note:** when using the brackets, var-args must be given as an array type, but when called the
array will be created automatically if necessary.


Access Modifiers
----------------
You may notice that when performing `dir` on `JavaClass` or `Object` instances that some of the
names have leading `_` and `__` even though they did not in the original Java code. This is because
the access protection is being emulated with Python conventions and makes `protected` fields,
methods, and nested classes begin with a `_` and `private` and package-private ones begin with a
`__`. They are still accessible, since they can be accessed via reflection, but the underscores
discourage direct access.

**Note:** currently the underscores are not addded to classes at the package level


Predefined Class Templates
--------------------------
This library uses 'templates' of the various Java classes so that various methods and fields can be
mapped to Python features. For example, the template for `java.lang.Object` maps the Python methods
`__hash__`, `__str__`, and `__eq__` to `hashCode`, `toString`, and `equals` so that all Java objects
can be used in dictionaries, displayed, and checked for equality in a natural Pythonic manner.

The other predefined class templates are:

 * `java.lang.AutoCloseable` implements the context manager protocol, defining `__exit__` as `close`
 * `java.lang.Cloneable` defines `__copy__` as `clone`
 * `java.lang.Comparable` defines `__lt__`, `__gt__`, `__le__`, and `__ge__` using `compareTo`
 * `java.lang.Iterable` implements `collections.Iterable` by defining `__iter__` as `iterator`
 * `java.util.Iterator` implements `collections.Iterator` by defining `__next__` using `hasNext` and
   `next`
 * `java.util.Enumeration` implements `collections.Iterator` by defining `__next__` using
   `hasMoreElements` and `nextElement`
 * `java.util.Collection` implements `collections.Sized` and `collections.Container` by defining
   `__len__` as `size` and `__contains__` as `contains`
 * `java.lang.Boolean` defines `__nonzero__` as booleanValue
 * `java.lang.Number` defines `__nonzero__`, `__int__`, `__long__` as `longValue` and `__float__` as
   `doubleValue`
 * `java.lang.Byte`, `java.lang.Short`, `java.lang.Integer`, and `java.lang.Long` define `__index__`
   as `longValue`
   * all of those plus `java.lang.Number`, `java.lang.Float` and `java.lang.Double` are registered
     in the `numbers` ABC appropiately
 * `java.lang.Throwable` extends from StandardError, making all Java exceptions raisable in Python;
   additionally `__str__` is defined as `getLocalizedMessage`
   * Other exceptions extend from different Python exceptions as appropiate
     [TODO: list all mapped exceptions]

**Note:** currently `java.util.Set`, `java.util.List`, and `java.util.Map` do not implement
`collections.MutableSet`, `collections.MutableSequence`, or `collections.MutableMap` as you would
except, but this should be coming soon


Defining Class Templates
------------------------
You can define additional class templates as well. One limitation though is that the class template
must be defined before the Java class is ever used. To create a class template, create a new Python
class that either has some other Java interface or class as a base or has the metaclass `JavaClass`.
In either case, the class definition also requires a field `__java_class_name__` that is a unicode
string with the full name of the class or interface. For example, the class template for
`java.lang.Iterable` coudl be made as follows:

    class Iterable(object):
        __metaclass__ = JavaClass
        __java_class_name__ = 'java.lang.Iterable'
        def __iter__(self): return self.iterator()

The metaclass handles many aspects of the base classes for you. It will automatically add the
superclass and any interfaces as bases if you do not include them. If you include a superclass,
it doesn't even need to be the right one, it just needs to be a superclass (so just putting in
`java.lang.Object` is usually good). The interfaces need to be correct however. If the template is
for an interface, a superclass cannot be given.

The base classes of the template can become tricky if the template class is also extending a Python
class. In this case, the real superclass is added to the list of base classes wherever the
superclass is placed, or at the end of the list of bases if it wasn't included at all. Interfaces
are also placed where they are listed, or at the very end if not listed at all.

**Note:** class templates only effect the classes/objects as they appear in Python and have no
influence on the Java code itself


Automatic Conversion
--------------------
TODO


Java Arrays
-----------
Java arrays fall into two different categories: primitive and reference. They support the basic Java
length property available in Java:

 * `arr.length` - the length of the array

When wrapped in Python they both support the following basic Python sequence methods:

 * `len(arr)` - also the length of the array
 * `x = arr[i]` - get a single item from the list
 * `arr[i] = x` - set a single item in the list
 * `iter(arr)` - iterate over the values of the array
 * `reversed(arr)` - iterate over the values of the array in reverse order
 * `x in arr` - check if a value is in the array
 * `arr.index(x, [start], [stop])` - find the index of a value in the array
 * `arr.count(x)` - get the number of occurences of the value in the array
 * `arr.reverse()` - reverse the values in the array
 * `a = arr[i:j]`

   Creates a copy of a portion of the array, step must be 1. Unlike in Python if `j` is greater than
   the length of the array, the resulting copy is extending and includes extra `0`/`false`/`null`s
   to emulate the behavior of `java.util.Arrays.copyOf`, however negative indices still operate like
   in Python. As an extension of this `a = arr[:]` will make a complete copy of the array.

 * `arr[i:j] = x`

   Set the values from `i` (inclusive) to `j` (exclusive) to the value(s) of `x`. If `x` is a scalar
   (single value) then the values are all filled in with the same value `x`. The length of `x` must
   be appropiate to fill in all of the data. For reference arrays, `x` can be another Java array of
   the same type or a sequence. For primitive array, `x` can also be `bytes`/`bytearray`, an
   `array.array` with an equivilent typecode or 'B', a writable buffer-object or memoryview of the
   same type or bytes, a unciode string (if `arr` is a char array).
 

They also support several methods to convert to Python objects:

 * `arr.tolist([start], [stop], [deep])`

   Copies data to a new list, for reference arrays if `deep` is False, nested arrays will not be
   converted to lists as well.

 * `arr.tobytearray([start], [stop])`    (primitve arrays only)

   Copies data to a new `bytearray`, for primitives that aren't `byte` the native byte are written
   directly, in the native byte order.

 * `arr.tobytes([start], [stop])`    (primitve arrays only)

   Copies data to a new `bytes`, for primitives that aren't `byte` the native byte are written
   directly, in the native byte order.

 * `arr.toarray([start], [stop])`    (primitve arrays only)

   Copies data to a new `array.array` which is given a typecode appropiate for the Java primitive
   type. In cases when there is no appropiate typecode, a 'B' is used.

 * `arr.tounicode([start], [stop])`    (char arrays only)

   Copies data to new `unicode` string.

 * `arr.copyto(dst, [start], [stop], [dst_off])`
  
    Copies the data from `arr[start:stop]` to `dst[dst_off:dst_off+stop-start]`. `dst` can be a
    Java array of the same type. If `arr` is a primitive array, `dst` can also be `bytearray`,
    `array.array` with an equivilent typecode or 'B', or a writable buffer-object or memoryview of
    the same type or bytes. If `dst` uses bytes then the data is copied to
    `dst[dst_off:dst_off+sizeof(primitiveType)*(stop-start)]` (notably the `dst_off` is used as-is).

They also support several methods that utilize or emulate the functions in `java.util.Arrays`:

 * `arr.binarySearch(key, [fromIndex], [toIndex], [c])`

   Calls `java.util.Arrays.binarySearch` on the array. Assumes the array is sorted. The `c`
   parameter is only valid for reference arrays.

 * `arr.sort([fromIndex], [toIndex], [c])`

   Calls `java.util.Arrays.sort` on the array. Sorts the array in-place. The `c` parameter is only
   valid for reference arrays. Note that unlike the standard Python sort function, this does not
   take `key` or `reverse` arguments.
    
 * `hash(arr)`

   Calls `java.util.Arrays.hashCode` for primitive arrays and `java.util.Arrays.deepHashCode` for
   reference arrays.

 * `arr == other` and `arr != other`

   Call `java.util.Arrays.equals` for primitive arrays and `java.util.Arrays.deepEquals` for
   reference arrays.

 * `str(arr)`

   Calls `java.util.Arrays.toString` for primitive arrays and `java.util.Arrays.deepToString` for
   reference arrays.

 * `fill` can be done with `arr[i:j]=x`, `copyOf` and `copyOfRange` can be done with `a=arr[i:j]`
`
They reference arrays have a few other methods from java.util.Arrays to be able to choose between
deep or shallow usage or specify a different type:

 * `arr.hashCode([deep])` - calls `java.util.Arrays.hashCode` or `java.util.Arrays.deepHashCode`
 * `arr.equals(other, [deep])` - calls `java.util.Arrays.equals` or `java.util.Arrays.deepEquals`
 * `arr.toString([deep])` - calls `java.util.Arrays.toString` or `java.util.Arrays.deepToString`
 * `arr.copyOf([from_], [to], [newType])`

   Copies the array, converting the component type of the array to `newType`. If `newType` is not
   given, it is equivilent to `arr[from_:to]`.


While all of these features help you if you can an array back from a Java method, but what if you
need to create an array yourself? Well, there is a separate method for each of the primitive types
and the reference, or object, array type in the `J` module.

 * `J.boolean_array(*args)`
 * `J.byte_array(*args)`
 * `J.char_array(*args)`
 * `J.short_array(*args)`
 * `J.int_array(*args)`
 * `J.long_array(*args)`
 * `J.float_array(*args)`
 * `J.double_array(*args)`

   Primitive arrays can be constructed from several different sources. If the method is not given
   any arguments, then a length-0 array is created. For a single argument, the following values are
   acceptable:

    * integer - creates a length-n array is created
    * Java array of same primitive type - creates a copy of the array
    * `array.array` of an appropiate typecode of 'B' - creates an array with a copy of data
    * `bytes`/`bytearray` - creates an array with a copy of data
    * `unicode` - creates an array with a copy of data (only with `char_array`)
    * buffer-object or `memoryview` of same data type or bytes - creates an array with a copy of data
    * sequence - creates an array containing each element converted

   If more than one argument is given, then it is treated as a sequence and each element is
   converted.

 * `J.object_array(*args, type=None)`

   Reference arrays support a more limited set of sources then primitive arrays. The argument `type`
   must be given as a keyword argument. It specifies the component type of the reference array. If
   not provided, it defaults to java.lang.Object. If there are no arguments besides type then a
   length-0 array is created. For a single argument, the following values are acceptable:

    * integer - creates a length-n array is created
    * Java array of a compatible component type - creates a copy with a possibly new component type
    * sequence - creates an array containing each element converted

   If more than one argument is given, then it is treated as a sequence and each element is
   converted.

Additionally, object arrays can be created using the component type, the following example creates
a 9-element array containing java.lang.Objects:

    arr = java.lang.Object[9]

The class of the array can be obtained with and empty slice:

    cls = java.lang.Object[:]  # equivilent of the Java code Class<Object[]> cls = Object[].class

**Note:** when using `dir` on Java arrays, only the methods defined in `java.lang.Object` show up,
all of the methods and fields listed above must be used directly without introspection.


Other Methods
-------------
A few other methods and utilities are available in `J` module:

 * `J.get_java_class(classname)` - Gets the `JavaClass` for a given fully-qualified Java class name
 * `with J.synchronized(obj): ...` - Equivilent of the Java `synchronized` block on the object
 * `J.unbox(obj)` - unboxes a Java primitive wrapper, or returns the object as-is if it isn't a wrapper
