PyJVM - Java bindings for Python
==============================

PyJVM uses JNI to give access to all of Java from Python. On top of that it uses Java reflection
to be able to automatically discover Java classes, their methods and their fields. The classes are
wrapped in Python objects and using them becomes seamless from within Python. PyJVM tries to make
the integration as seamless as possible, for example making Java objects that implement
`java.util.Iterable` iterable in Python as well.


Installation
----------------
You must have a JDK and JRE installed along with the Cython package. The JDK and JRE should be
automatically found in an OS-depedent manner, but their location can also be specified using the
`JDK_HOME` and `JAVA_HOME` environmental variables during setup and when running. `pip` can be
used to install the package once these requirements are met.

Once installed, only the JRE is needed. Cython and the JDK are not needed after installation.


Getting Started
----------------

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
converted to a byte array instead of a `java.lang.String`. In Python 3 this is easy, `str` is
unicode. In Python 2, it is recommended to use `from __future__ import unicode_literals` which
will help.


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
	
**Note:** technically the JVM can be stopped with `jvm.stop()`, however it is unlikely to be able
to be restarted after that due to limitations of most JVMs, so it is of limited use

Besides using the `classpath` keyword argument of `jvm.start()`, the Java class-path can be
adjusted with `jvm.add_class_path(path)`. If the JVM is not yet started, the path is added to the
startup options whenever the JVM is started (through either `jvm.start()` or automatically via an
import of one of the special modules). On the other hand, if the JVM is already started, the
system class loader is modified, if possible, to include the class path. The system class loader
must be a URLClassLoader, which the HotSpot JVM uses by default.


Java Modules
------------
By default, only the `java` and `javax` namespaces can be imported directly. But any name can be
added to the list of base module names that it forwarded to Java packages. To do so use the following
function:

    jvm.register_module_name(name)

To see the list of registered names, call:

    names = jvm.get_module_names()

Some common base names that might be added would be 'com' or 'org'. These modules try to predict
what classes and packages are nested under the package they represent. However, if the JVM (or the
user) uses a non-`URLClassLoader` or the class loader has URLs that are not local files, those
classes and packages will not be enumerated by `dir` on the module.


Java Classes
------------
Within Python the type of Java objects are subclasses of `J.JavaClass`. Each instance of
`JavaClass` represents a different Java class, and can be used in sine places for an instance of
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

Additionally, the classes are setup so `isinstance` and `issubclass` work. For example:

    issubclass(java.util.HashMap, java.util.Map)  # returns True
    m = java.util.HashMap()
    isinstance(m, java.util.Map)                  # returns True


Java Instances
--------------
Once you get an instance of a Java object, you can start using the resulting object just like you
would in Java, accessing fields and calling methods. Just like with `JavaClass` objects, you can
use `dir` on the instances to get a list of the instance fields, methods, and inner classes.

Inner classes (non-static member classes) remember which object you accessed them from and calling
their constructors will automatically add the appropiate object as the first argument just like in
Java. However, it is possible to get un-bound inner classes (via `J.get_java_class`) in which case
the first argument to the constructor must be an instance of the declaring class.

The `JavaClass` of an object can be obtained using `type` on the instance. Additionally, the Java
instances try to emulate Python classes as best they can. Calling `hash(j)` on a Java instance will
return the value from `j.hashCode()`, using `str(j)` on the instance calls `j.toString()`, and
`j == k` / `j != k` use `j.equals(k)` internally. Other types (such as `java.util.Iterator`) define
more Python mappings. See [Predefined Class Templates](#predefined-class-templates) for more
information.

**Note:** unlike in Java, static methods and fields are inaccessible from instances, in Java this
only produces a warning (and is strongly discouraged), here it is enforced; additionally, static
members are only available on the class that declared them and are not inherited


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
obvious Python types (`object` to `java.lang.Object`, unicode `str` to `java.lang.String`, `bytes` to 
`[B`, `bool` to `Z`, `int` to `I`, `float` to `D`).

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
can also be passed around and is bound to the original object (if it wasn't a static method). It
also can be queried for the bound object and class and name. Additionally, it can be iterated over,
yielding `JavaMethod` objects. Similarily, a `JavaClass` object can be iterated over yeilding the
`JavaConstructor` objects.

**Note:** the brackets on `JavaClass` objects also are important for arrays, see the end of the
[Java Arrays](#java-arrays) section

**Note:** when using the brackets, var-args must be given as an array type, but when called the
array will be created automatically if necessary

Methods and constructors can also take a keyword argument `withgil` that if set to `True` will
cause the GIL to not be released for the duration of the call. There is some slight overhead in
releasing the GIL but releasing it reduces the chance of deadlocks. If you have to call certain
methods quickly and frequently and know that they won't cause Python to cause a deadlock then
don't release it. Example:

    myObject.quick(5, withgil=True) # calls with GIL while passing 5 to the method


Access Modifiers
----------------
You may notice that when performing `dir` on `JavaClass` or `Object` instances that some of the
names have leading `_` and `__` even though they did not in the original Java code. This is because
the access protection is being emulated with Python conventions and makes `protected` fields,
methods, and classes begin with a `_` and `private` and package-private ones begin with a `__`.
They are still accessible, since they can be accessed but the underscores discourage direct access.


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
 * `java.util.List` implements the entirety of `collections.MutableSequence` including support for
   slice operations as long as the step size is exactly 1; also has `sort` and `binarySearch`
   methods from `java.util.Collections`
 * `java.util.Set` implements the entirety of `collections.MutableSet` with the operations that
   create new sets requiring that there is a Java constructor that takes a `java.util.Collection`;
   currently this class only accepts other `java.util.Set` objects using the operations
 * `java.util.Map` implements the entirety of `collections.MutableMap`
 * `java.util.Map.Entry` implements `collections.Sequence`, pretending to be a 2-element `tuple` of
   key and value so that `java.util.Map.popitem()` and `java.util.Map.items()` work like expected
   in Python
 * `java.lang.Boolean` defines `__nonzero__`/`__bool__` as `booleanValue`
 * `java.lang.Number` defines `__nonzero__`/`__bool__`, `__int__`, `__long__` as `longValue` and
   `__float__` as `doubleValue`
 * `java.lang.Byte`, `java.lang.Short`, `java.lang.Integer`, and `java.lang.Long` define `__index__`
   as `longValue`
   * all of those plus `java.lang.Number`, `java.lang.Float` and `java.lang.Double` are registered
     in the `numbers` ABC appropiately
 * `java.math.BigInteger` implements the entirety of `numbers.Integral` and supports interoperability
   with Python `numbers.Integral` values
 * `java.math.BigDecimal` implements the entirety of `numbers.Rational` and supports interoperability
   with `java.math.BigInteger`, `decimal.Decimal`, and Python `numbers.Real` values
 * `java.lang.Throwable` extends from `Exception`, making all Java exceptions raisable in Python;
   additionally `__str__` is defined as `getLocalizedMessage`
   * Other exceptions extend from different Python exceptions as appropiate:
     * `java.lang.OutOfMemoryError` extends from `MemoryError`
     * `java.lang.StackOverflowError` extends from `OverflowError`
     * `java.lang.ArithmeticException` extends from `ArithmeticError`
     * `java.lang.AssertionError` extends from `AssertionError`
     * `java.lang.InterruptedException` extends from `KeyboardInterrupt`
     * `java.lang.LinkageError` extends from `ImportError`
     * `java.lang.VirtualMachineError` extends from `SystemError`
     * Extend from `NameError`:
       * `java.lang.ClassNotFoundException`, `java.lang.TypeNotPresentException`
     * Extend from `AttributeError`:
       * `java.lang.IllegalAccessException`, `java.lang.NoSuchFieldError`, `java.lang.NoSuchMethodError`
     * Extend from `TypeError`:
       * `java.lang.ClassCastException`, `java.lang.ArrayStoreException`, `java.lang.InstantiationException`, `java.lang.IllegalStateException`, `java.lang.UnsupportedOperationException`, `java.lang.reflect.UndeclaredThrowableException`
     * Extend from `ValueError`:
       * `java.lang.IllegalArgumentException`, `java.lang.NullPointerException`, `java.lang.EnumConstantNotPresentException`
     * Extend from `IndexError`:
       * `java.lang.IndexOutOfBoundsException`, `java.lang.NegativeArraySizeException`, `java.util.EmptyStackException`, `java.nio.BufferOverflowException'`, `java.nio.BufferUnderflowException`
     * `java.util.NoSuchElementException` extends from `StopIteration`
     * Extend from `IOError`:
       * `java.io.IOException`, `java.io.IOError`
     * `java.io.EOFException` extends from `EOFError`
     * Extend from `UnicodeError`:
       * `java.nio.charset.CharacterCodingException`, `java.nio.charset.CoderMalfunctionError`, `java.io.UTFDataFormatException`, `java.io.UnsupportedEncodingException`, `java.io.CharConversionException`


Custom Class Templates
----------------------
You can define additional class templates as well. One limitation though is that the class template
must be defined before the Java class is ever used. To create a class template, create a new Python
class that uses the @jvm.template(class_name) decoractor. For example, the class template for
`java.lang.Iterable` could be made as follows:

    @jvm.template('java.lang.Iterable')
    class Iterable: # Python 2: must be a new-style class
        def __iter__(self): return self.iterator()

Internally this is setting the metaclass to `JavaClass` and adding a `__java_class_name__` field
which is an alternative to using the @jvm.template decorator. 

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

**Note:** if the class has already be used before you get a chance to create a template for it,
the custom class template can still be created by monkey-patching the `JavaClass` object for the
class, for example `super(type(java.lang.Iterable), java.lang.Iterable).__setattr__('__iter__',
lambda self : self.iterator()` would accomplish the same thing as above. The convoluted attribute
setting is due to `JavaClass` using `__setattr__` for setting static fields.


Automatic Conversion
--------------------
PyJVM automatically converts arguments when calling Java methods and when setting a Java field
value. If the method argument or field value is a primitive, the conversions follow these
conversions:

 * If the target is `boolean`, uses the result of converting the object to a `bool`, however
   methods will only accept `bool`, `java.lang.Boolean`, and objects that define `__nonzero__` or
   `__bool__` as `boolean` arguments
 * If the target is `byte`, then it will convert a length-1 `bytes` or `bytearray` or the result
   of converting the object to an `int` (excluding strings) if the value is within -128 to 127
 * If the target is `char`, then it will convert a length-1 unicode string or the result of
   converting the object to an `int` (excluding strings) if the value is within 0 to 65535
   (the unicode string is preferred)
 * If the target is a `short`, `int`, or `long`, uses the result of converting the object to an
   `int` (excluding strings) if the value is within the primitive type's range
 * If the target is a `float` or `double`, uses the result of converting the object to a `float`
   (the target being a double is preferred)

Since the class templates for the primitive wrappers (e.g. `java.lang.Byte`) define the necessary
numerical conversion methods, they will automatically be unboxed if necessary.

Non-primitive conversion is a bit more complicated. The best way to ensure that the object is
converted correctly is to make sure that it is a Python-wrapped Java object already. Otherwise,
a list of converters is checked in order, and each one of them rates the quality of conversion
they can perform from the Python object to the target Java class. The converter that reports that
it can give the best quality conversion is used to convert the object.

The built-in object conversions are (in the order they are checked):

 * `None` to `null`
 * A Java-wrapped object, as long as it can be cast to the target
 * `JavaClass` to `java.lang.Class`
 * unicode string to an instance of `java.lang.Enum`
 * unicode string to `java.lang.String`
 * unicode string with a length of 1 to `java.lang.Character`
 * unicode string to `char[]`
 * auto-boxing:
   * `bool` or any Python object that has `__nonzero__` or `__bool__` to `java.lang.Boolean`
   * `numbers.Integral` types (e.g. `int`/`long`) to `java.lang.Byte`, `java.lang.Character`,
     `java.lang.Short`, `java.lang.Integer`, or `java.lang.Long` as long as the value fits in the
     range of the target type; converting to `Character` is less preferable here
   * `numbers.Real` types  (e.g. `float`) to `java.lang.Float` or `java.lang.Double` (prefers doubles)
 * `numbers.Integral` to `java.math.BigInteger`
 * `decimal.Decimal` and `numbers.Real` to `java.math.BigDecimal`
 * `decimal.Context` to `java.math.MathContext`
 * `datetime.date` and `datetime.datetime` to `java.util.Date`
 * `bytes` with a length of 1 to `java.lang.Byte`
 * `bytes` to `[B`
 * `bytes` to `java.lang.String` (only in Python 3, strongly prefer other conversions though)
 * `bytearray` with a length of 1 to `java.lang.Byte`
 * `bytearray` to `[B`
 * `array.array` to a primitive array of the same type as given by the `array`'s `typecode` and `itemsize`
 * buffer-object or `memoryview` to a primitive array of the same type as given by the buffer's `format` and `itemsize`

After the built-in converters are checked, custom converters are checked as well. A custom
converter is added with the function `jvm.register_converter`. This function takes a Python
`type`, a `JavaClass`, and a `callable`. The given `callable` takes the Python object to be
converted and the `JavaClass` we would like to convert to. The Python object to be converted
is guaranteed to be an instance of the Python `type` given to `register_converter` (which
can be `None` to not pre-filter based on the Python object's type) and the `JavaClass` is a
the same as or a subclass of the `JavaClass` given to `register_converter` (which also can
be `None` to not pre-filter based on the target Java class). Given this information, the
`callable` must return a quality and another `callable` for converting the Python object to
the target Java class. The quality is a number from -1 to 100 which is the predicted quality
of the conversion that would take place. A value of -1 means the conversion cannot be done
at all and a value of 100 means a perfect conversion (which should be used sparingly). The
converter `callable` takes a single argument of a Python object and returns a Python-wrapped
Java object of the appropiate class.

When calling a group of Java methods (because there are several overloaded methods have the
same name in a class), the arguments are checked against each method and the overall best
quality matching conversion is used. If two methods tie for the best, an error is raised
stating that it is an ambiguous method call (which can be resolved using the `[]` on the
group of methods). The return type of methods is never taken into account. If a single
value matches the component type of a var-args argument, it is slightly less preferred
to matching the single value to just its component type.

So far this has all been about Python to Java conversions. The opposite direction is also
handled, but in a much simpler way and is not extensible. The following conversions are
done:

 * `boolean` to `bool`
 * `char` to length-1 unicode string
 * `byte`/`short`/`int`/`long` to `int` or `long` based on value
 * `float`/`double` to `float`
 * `null` to `None` (`void` methods return `None` as well)
 * `java.lang.String` to unicode string

All other Java objects are simply wrapped in a Python wrapper, which due to class
templates, can be very Python-like objects.

**Note:** since `java.lang.String` objects are always converted to unicode strings, it is
impossible to ever have a Python-wrapped instance of a Java string


Java Arrays
-----------
Java arrays fall into two different categories: primitive and reference. They support the basic
`length` property and `clone` method available in Java:

 * `arr.length` - the length of the array
 * `x = arr.clone()` - create a shallow copy of the array

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

   Copies data to new unicode string.

 * `arr.copyto(dst, [start], [stop], [dst_off])`
  
    Copies the data from `arr[start:stop]` to `dst[dst_off:dst_off+stop-start]`. `dst` can be a
    Java array of the same type. If `arr` is a primitive array, `dst` can also be `bytearray`,
    `array.array` with an equivilent typecode or 'B', or a writable buffer-object or `memoryview`
    of the same type or bytes. If `dst` uses bytes then the data is copied to
    `dst[dst_off:dst_off+sizeof(primitiveType)*(stop-start)]` (notably the `dst_off` is used as-is).

 * `arr.copyfrom(src, [start], [stop], [src_off])`
  
    Copies the data to `arr[start:stop]` from `src[src_off:src_off+stop-start]`. `src` can be a
    Java array of the same type. If `arr` is a primitive array, `src` can also be `bytearray`,
    `bytes`, `unicode` (if `arr` is a char array), `array.array` with an equivilent typecode or 'B',
    a writable buffer-object or `memoryview` of the same type or bytes, or a sequence-like object.
    If `src` uses bytes then the data is copied from `src[src_off:src_off+sizeof(primitiveType)*(stop-start)]`
    (notably the `src_off` is used as-is).

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

Additionally, primitive arrays support the buffer protocol so Numpy `arrays` and `memoryview`s can
directly read the data. Note however there are some limitations to this due ot how the JVM handles
arrays:

 * The old buffer protocol is supported in Python v2.7 through the `__buffer__` attribute, which
   allows Numpy to use it directly and also with `buffer(arr.__buffer__)`
 * The new buffer protocol is always supported naturally, which Numpy and `buffer` use in Python
   v3 and always by `memoryview`
 * Both of them support writable buffers, however the writes likely won't show up in the Java
   array until the buffer is released

While all of these features help you if you can get an array back from a Java method, but what if
you need to create an array yourself? Well, there is a separate method for each of the primitive
types and the reference, or object, array type in the `J` module.

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

    * integer - creates a length-n array
    * Java array of same primitive type - creates a copy of the array
    * `array.array` of an appropiate typecode of 'B' - creates an array with a copy of data
    * `bytes`/`bytearray` - creates an array with a copy of data
    * unicode string - creates an array with a copy of data (only with `char_array`)
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

The class of the array can be obtained with an empty slice:

    cls = java.lang.Object[:]  # equivilent to the Java code Class<Object[]> cls = Object[].class

**Note:** when using `dir` on Java arrays, only the methods defined in `java.lang.Object` show up,
all of the methods and fields listed above must be used directly without introspection

**Note:** most array methods will automatically release the GIL if the array is large enough but not
for smaller arrays.


Extending Java Classes
----------------------
Besides being able to use Java classes and methods in Python, PyJVM also allows extending Java
classes and implementing Java interfaces with Python classes. This allows having "callbacks" by
implementing abstract methods. Extension classes are defined using a set of decorators on methods
and on the class itself. A basic example would be defining a `Runnable` that executes a Python
method:

    @jvm.extends(java.lang.Runnable)
    class PyRunnable:
        @jvm.override
        def run(self): print('running!')

A more complicated example would be to implement the `List` interface, partially listed here:

    @jvm.extends(java.util.List)
    class PyList:
		lst = None # any Python fields must be specified in the class otherwise they will be un-settable
	
        # All public and protected constructors in the superclass (in this case java.lang.Object
        # which has a single, parameter-less constructor) are implemented and forward to the
        # `__init__` method. This method must be able to accept any possible combination of
        # arguments from those constructors. If not provided, then a default, do-nothing,
        # `__init__` method is provided.
        def __init__(self):
            self.lst = []
        
        @jvm.override
        @jvm.param(object) # all parameters must be listed
        @jvm.return(bool)  # these use the same format that methods/constructor lookups use
        def add(self, e):
            self.lst.append(e)
            return True

        @jvm.override('run') # Java can have multiple methods with the same name but not in Python
        # the above statement will override an `add` method even though it is called `insert`
        @jvm.param(int)      # first argument
        @jvm.param(object)   # second argument
        # could also do both at the same time: @jvm.param(int, object)
        # no @jvm.return(...) means void
        @jvm.throws(java.lang.IndexOutOfBoundsException) # technically unnecessary
        def insert(self, i, e):
            if i < 0 or i >= len(self.lst): raise java.lang.IndexOutOfBoundsException()
            self.lst.insert(i, e)
            
        # The rest of the methods... if any abstract or interface method is left unimplemented,
        # the extension class will be marked "abstract".


Other Methods
-------------
A few other methods and utilities are available in the `J` and `jvm` modules:

 * `jvm.get_java_class(classname)` - Gets the `JavaClass` for a given fully-qualified Java class name
 * `with jvm.synchronized(obj): ...` - Equivilent of the Java `synchronized` block on the object
 * `jvm.unbox(obj)` - unboxes a Java primitive wrapper, or returns the object as-is if it isn't a wrapper


Planned Future Enhancements
---------------------------
 * Add `java.nio.ByteBuffer` and other `java.nio.Buffer` class templates and conversions for `bytes`,
   `bytearray`, `unicode`, `array.array`, buffer-object to them
 * Support buffer protocol for multi-dimensional primitive arrays
 * Support critical buffer access for primitive arrays and either periodically commiting writable
   buffers or adding a method to commit them
 * Support GUI functions on Mac (supposedly needs some extra work)
 * Make `super(...)` work as excepted for Java classes using `CallNonvirtual<Type>Method` and `Get/Set<Type>Field`
   [see https://docs.oracle.com/javase/specs/jls/se8/html/jls-15.html]
 * Method resolution identical to Java
 * Deal with weak references
 * Subclassing Java classes, in particular making wrappers for Python `tuple`/`list`, `set`/`frozenset`, and
   `dict` objects to act as `java.util.List`, `java.util.Set`, and `java.util.Map` objects
 * Re-route `System.out`, `System.err`, and `System.in` to Python `sys.stdout`, `sys.stderr`, and `sys.stdin`
 * Make Java annotations work like Python decorators
 * Pickling of `java.lang.Serializable` objects
 * Generic types
 * Modules for package and class discovery (new Java 9)

Thoughts:
 * Should all JObjects be dealloced before JVM deallocs?
 * Hook JVM exit and abort functions?
 * Automatic property generation from get/set functions?
 * Use `PyBuffer_SizeFromFormat` instead of `struct.calcsize`?
