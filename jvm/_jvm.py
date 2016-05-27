"""
JVM internal Python module. While most of the code is in Cython, this module includes functions for
basic control of the JVM and Java pseudo-modules.

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

from __future__ import division
from __future__ import unicode_literals
from __future__ import print_function
from __future__ import absolute_import

__all__ = ['start', 'started', 'stop', 'add_class_path', 'register_module_name', 'module_names']

from ._util import is_py2
if is_py2:
    _keys = lambda d: d.viewkeys()
else:
    unicode = str
    _keys = lambda d: d.keys()

__jvm = None
__class_paths = []
def start(*opts):
    """
    Start the JVM with the given options in a separate thread. The most common options use keyword
    arguments for convience:
        classpath = sequence of paths to add to the class path
        max_heap  = number of kibibytes, forced to at least 2MiB
        headless  = boolean

    Otherwise, options that can be given to the Java command line can be given. Note that if the
    classpath is done manually, the separator between paths must os.pathsep and -cp or -classpath
    cannot be used. Additionally, the -client and -server options may not be honored, especially if
    the JVM was previously started with a different option in the same process.

    Examples:
      Print messages:    -verbose
                         -verbose:class
                         -verbose:jni
                         -verbose:gc
      Disable JIT:       -Djava.compiler=NONE
      Enable assertions: -enableassertions
      Extra JNI checks:  -Xcheck:jni
    """
    
    classpath = None
    max_heap = None
    headless = None
    
    import re, os
    remove = []
    prefer = None
    opts = list(opts)
    hdlss = re.compile('^-Djava.awt.headless=([tT]rue|[fF]alse)')
    xmx = re.compile('^-Xmx(\d+)([kKmM]|)$')
    cp = re.compile('^(-cp|-classpath|-Djava.class.path=)')
    for i,a in enumerate(opts):
        if a in ('-client', '-server'):
            if prefer is not None: raise ValueError('only one of -client and -server can be specified')
            prefer = a[1:]
            remove.append(i) # the JVM techinically ignores this flag, it has to be used ahead of time to select the right JVM
        m = hdlss.match(a)
        if m is not None:
            if headless is not None: raise ValueError('headless option specified more than once')
            headless = bool(a.group(1))
            remove.append(i)
            continue
        m = xmx.match(a)
        if m is not None:
            if max_heap is not None: raise ValueError('max heap size option specified more than once')
            max_heap = int(m.group(1))
            if   m.group(2) in 'kK': pass
            elif m.group(2) in 'mM': max_heap *= 1024
            else:                    max_heap //= 1024
            remove.append(i)
            continue
        m = cp.match(a)
        if m is not None:
            if a.startswith('-c'): raise ValueError('Cannot use the -cp or -classpath options')
            if classpath is not None: raise ValueError('classpath option specified more than once')
            classpath = a[18:],
            remove.append(i)
            continue
        if a == 'vfprinf' or a == 'exit' or a == 'abort':
            raise ValueError('Cannot use the vfprintf, exit, or abort options')
    for i in remove: del opts[i]

    global __class_paths
    if isinstance(classpath, bytes):
        classpath = unicode(classpath)
    elif classpath is None:
        classpath = ''
    elif not isinstance(classpath, unicode):
        classpath = os.pathsep.join(classpath)
    if len(__class_paths) > 0:
        if classpath == '': classpath = os.pathsep.join(__class_paths)
        else: classpath += os.pathsep + os.pathsep.join(__class_paths)
    __class_paths = classpath.split(os.pathsep)
    if classpath != '': opts.append('-Djava.class.path='+classpath)
    if max_heap is not None:
        if max_heap < 2*1024: max_heap = 2*1024 # at least 2 MiB
        opts.append('-Xmx%dk'%max_heap)
    if headless: opts.append('-Djava.awt.headless=true')
    __start_core(prefer, opts)

def __start_core(prefer, opts):
    # Load the JVM dynamic library
    from ._util import jvm_load
    jvm_load(prefer)

    # Start the JVM in its own thread
    import threading, imp
    from ._internal import jvm_create
    jvm = jvm_create() # if the JVM is already created, this will raise an exception
    event = threading.Event()
    locked = imp.lock_held()
    if locked:
        # If we are in the middle of an import (which is definitely possible) we can't start
        # another thread unless we release the import lock. If we do start the thread and then wait
        # for it to start, it will deadlock Python
        imp.release_lock()
    try:
        t = threading.Thread(target=jvm.run, name='JVM-Main', args=(opts,event))
        t.daemon = True
        t.start()
        event.wait() # wait for it to be initialized
    finally:
        if locked: imp.acquire_lock()
    jvm.check_pending_exception()
    global __jvm
    __jvm = jvm

def _start_if_needed():
    """Starts the JVM only if not already started."""
    # The conditional here is just to skip the common case of definitely started. A more robust
    # check for it already being started is through the exception handler.
    if __jvm is None:
        opts = [] if len(__class_paths) == 0 else ['-Djava.class.path='+os.pathsep.join(__class_paths)]
        try: __start_core(None, opts)
        except RuntimeError: pass

def started():
    """Check if the JVM is already started and connected."""
    return __jvm is not None

def stop():
    """
    Stops the JVM if it is started. Terminates the JVM thread and waits for it to finish. Even if
    this raises an exception the JVM will be stopped. After this point no JVM functions can be used
    and it is unlikely that the JVM can be re-started.
    """
    from ._internal import jvm_destroy
    global __jvm
    __jvm = None
    jvm_destroy()
    JavaPackage._globalfuncs = None

def add_class_path(path):
    """
    Add a path to the class path of the JVM. If the JVM has not been started yet, this is added to
    the startup options of the JVM when it is eventually started (either with jvm_start() or
    automatically). Otherwise this is added to the system class loader if it can be.
    """
    from os.path import abspath
    path = abspath(path)
    if isinstance(path, bytes): path = unicode(path)
    __class_paths.append(path)
    if __jvm is not None: 
        from ._internal import add_class_path
        add_class_path(path)

class JavaImporter(object):
    """A Python meta-importer for finding and loading Java packages"""

    _mod_super = 'J'
    """
    The 'super' module that contains the entire Java namespace. Default is 'J', which means you can
    do the following:
        from J.java.util import HashMap
    Since this is a global setting and affects all imports for all of Python, be careful when setting
    this value.
    """

    _mod_prefixes = {'java', 'javax'}
    """
    The module prefixes that can be load Java packages and classes directly. For example, if this
    contains 'java' (which it does by default), the following can be done:
        from java.util import HashMap
    or:
        import java.util
        x = java.util.HashMap(...)
    Since this is a global setting and affects all imports for all of Python, be careful when adding
    entries to this list.
    """

    def find_module(self, name, package_path=None):
        import sys
        if isinstance(name, bytes): name = unicode(name)
        if name in sys.modules: return None
        return self if (self.__is_mod_super(name) or self.__is_mod_prefix(name)) else None
    def load_module(self, name):
        import sys
        if isinstance(name, bytes): name = unicode(name)
        if self.__is_mod_super(name): name = name[len(self._mod_super)+1:]
        elif not self.__is_mod_prefix(name): raise ValueError()
        mod = JavaPackage(name)
        sys.modules[name] = mod
        return mod
    def __is_mod_super(self, name):  return name == self._mod_super
    def __is_mod_prefix(self, name): return name in self._mod_prefixes
__importer = JavaImporter() # singleton instance of class
import sys
sys.meta_path.append(__importer)

def register_module_name(name):
    """
    Add a base module name to the list of modules that load Java packages and classes directly. For
    example, if 'com' is registered then the following can be done:
        from com.google.common.base import Optional
    or:
        import com.google.common.base.Optional
        x = Optional(...)
    Since this is a global setting and affects all imports for all of Python, be careful when adding
    entries. Call `get_module_names()` to see the registered values.
    """
    if '.' in name or '/' in name or '\\' in name: raise ValueError('Module name cannot contain ./\\')
    __importer._mod_prefixes.add(name)

def module_names():
    """
    Gets the list of module names that are automatically imported as Java packages. By default
    this includes only 'java' and 'javax'. Since this is a global setting and affects all imports
    for all of Python, be careful when adding entries. Call `register_module_name(name)` to
    register new values.
    """
    return tuple(__importer._mod_prefixes)
    
import types
class JavaPackage(types.ModuleType):
    """A Python module that represents a Java Package."""
    def __init__(self, name, pkg_desc=None):
        self.__all__ = ()
        self.__name__ = name
        self.__builtins__ = __builtins__
        self.__package__ = None
        self.__jpkg_desc__ = pkg_desc
        _start_if_needed()
        from ._internal import get_pkgs_and_classes
        self.__jpackages__, self.__jclasses__ = get_pkgs_and_classes(name)
    def __getattr__(self, name):
        name_orig = name
        if isinstance(name, bytes): name = unicode(name)
        is_super = self.__name__ == ''
        full = name if is_super else '.'.join((self.__name__, name))
        from ._internal import get_java_class, get_pkg_desc, publicfuncs
        if is_super and name in publicfuncs:
            # A public/global function
            x = publicfuncs[name]
            x.__module__ = JavaImporter._mod_super
        elif name in self.__jclasses__:
            # A known child class
            n = self.__jclasses__[name]
            full = n if is_super else '.'.join((self.__name__, n))
            x = get_java_class(full)
        elif name in self.__jpackages__:
            # A known child package
            x = JavaPackage(full)
        elif '_'+name in self.__jclasses__ or '__'+name in self.__jclasses__:
            # A known protected/private child class
            raise AttributeError(name)
        # Some internal Python and IPython attributes that need to be filtered out to not produce errors
        elif name in ('__loader__', '__path__', '__file__', '__cache__', '__spec__', '__methods__',
                      '_ipython_display_', '_repr_jpeg_', '_repr_html_', '_repr_svg_', '_repr_png_',
                      '_repr_javascript_', '_repr_markdown_', '_repr_latex_', '_repr_json_', '_repr_pdf_',
                      '_getAttributeNames', 'trait_names'):
            raise AttributeError(name)
        else:
            # An unknown
            pkg = get_pkg_desc(full)
            if pkg is not None: x = JavaPackage(full, pkg)
            else:
                try: x = get_java_class(full)
                except Exception: x = JavaPackage(full)
        self.__dict__[name] = x
        if isinstance(name_orig, bytes): self.__dict__[name_orig] = x
        return x
    
    def __dir__(self):
        c = list(self.__jpackages__) + list(_keys(self.__jclasses__))
        if self.__name__ == '':
            from ._internal import publicfuncs
            c.extend(_keys(publicfuncs))
        return c
    @property
    def __doc__(self): return unicode(self)
    def __unicode__(self):
        if self.__jpkg_desc__ is None:
            from ._internal import get_pkg_desc
            try: self.__jpkg_desc__ = get_pkg_desc(self.__name__)
            except Exception as ex: pass
            if self.__jpkg_desc__ is None: self.__jpkg_desc__ = unicode(repr(self))
        return self.__jpkg_desc__
    if is_py2:
        def __str__(self): return unicode(self).encode('utf8')
    else: __str__ = __unicode__
    def __repr__(self):
        if self.__name__ == '': return u'<Java root packag>'
        return u'<Java package %s>'%(self.__name__)
