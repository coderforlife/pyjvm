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

Packages and the Class Path
---------------------------
Functions for dealing with the Java package system and looking up classes on the class path.

Public functions:
    add_class_path - adds a path to the class path once the JVM has already started

Internal functions:
    add_class_to_packages - adds a newly loaded class to the database of packages and classes
    get_pkg_desc          - gets the description of a package
    get_pkgs_and_classes  - gets the pcakages and classes that are immediately under a package
    
FUTURE:
    add Java 9 module support which is able to discover available packages and classes cleaner
"""

from __future__ import absolute_import

from .utils cimport ITEMS

from .jni cimport jobject, jvalue, jstring, jobjectArray, jint

from .core cimport jvm_add_init_hook, jvm_add_dealloc_hook
from .core cimport JClass, JEnv, jenv, protection_prefix
from .core cimport ObjectDef, SystemDef, ClassLoaderDef, URLClassLoaderDef, FileDef, URIDef, PackageDef, ThreadDef


def add_class_path(unicode path):
    """Adds a path to the system class loader's class path and update the internal database."""
    cdef JEnv env = jenv()
    cdef jobject scl = env.CallStaticObject(ClassLoaderDef.clazz, ClassLoaderDef.getSystemClassLoader)
    cdef jobject f, uri
    cdef jvalue val
    try:
        if not env.IsInstanceOf(scl, URLClassLoaderDef.clazz): raise RuntimeError(u'System class loader must be a URLClassLoader for add_class_path to work once the JVM has started')
        val.l = env.NewString(path)
        try: f = env.NewObject(FileDef.clazz, FileDef.ctor, &val, True)
        finally: env.DeleteLocalRef(val.l)
        try: uri = env.CallObject(f, FileDef.toURI)
        finally: env.DeleteLocalRef(f)
        try: val.l = env.CallObject(uri, URIDef.toURL)
        finally: env.DeleteLocalRef(uri)
        try: env.CallVoidMethod(scl, URLClassLoaderDef.addURL, &val, True)
        finally: env.DeleteLocalRef(val.l)
    finally: env.DeleteLocalRef(scl)
    
    cdef list classes = []
    process_path_classes(path, classes)
    update_packages(allpackages, classes)

cdef add_class_to_packages(unicode classname):
    """Adds a class to the internal database. If it is already there, does nothing."""
    if len(classname) == 0 or classname[0] == u'[': return
    cdef dict d = allpackages
    parts = classname.split(u'.')
    for p in parts[:-1]: d = d.setdefault(p, {})
    d[parts[-1]] = None
        
def get_pkg_desc(unicode name):
    """Get the decription of a package by name"""
    cdef JEnv env = jenv()
    cdef jvalue val
    val.l = env.NewString(name)
    cdef jobject obj
    try: obj = env.CallStaticObject(PackageDef.clazz, PackageDef.getPackage, &val)
    finally: env.DeleteLocalRef(val.l)
    if obj is NULL: return None
    try: return env.CallString(obj, ObjectDef.toString)
    finally: env.DeleteLocalRef(obj)

def get_pkgs_and_classes(unicode name):
    """
    Gets all of the package names as a set and class names as a dictionary that reside within the
    named package. The classes are given as protection_prefixed-name -> original name
    """
    cdef JEnv env = jenv()
    cdef dict p = allpackages
    if name != u'':
        for pkg_name in name.split(u'.'):
            p = p.setdefault(pkg_name, {})
    packages = set(k for k,v in ITEMS(p) if v is not None)
    classes = {pp:cn for pp,cn in ((get_pp_class_name(env, name, k),k) for k,v in ITEMS(p) if v is None) if pp is not None}
    return packages, classes

cdef unicode get_pp_class_name(JEnv env, unicode pkg, unicode cn):
    cdef JClass clazz = JClass.named(env, cn if len(pkg) == 0 else u'.'.join((pkg, cn)))
    return None if clazz.is_nested() else (protection_prefix(clazz.modifiers) + cn)
    
cdef dict find_all_classnames(JEnv env):
    """
    Finds all classes that we can and return them in a dictionary where each part of the package
    name is a key in the dictionary and the value is the next level. Class names are put in as
    keys and the value is None.

    This can only find classes in JARs/ZIPs and in loose directories. This can only find such
    instances that are on the boot class path (if it can be queried) and from URLClassLoaders that
    can be found.
    """
    from os.path import pathsep
    cdef unicode path = None
    cdef list bootclasspath = []
    cdef list classes = []
    cdef jvalue val
    cdef jobject obj1, obj2
    
    # Get classes from boot class path
    val.l = env.NewString(u'sun.boot.class.path')
    try:
        path = env.pystr(<jstring>env.CallStaticObject(SystemDef.clazz, SystemDef.getProperty, &val))
    except Exception: pass
    finally: env.DeleteLocalRef(val.l)
    if path is not None: bootclasspath = path.split(pathsep)
    for path in bootclasspath: process_path_classes(path, classes)

    # Get classes from regular class path
    cdef set processed = set() # set of hash-codes for processed classloaders
    # Process ClassLoader.getSystemClassLoader()
    obj1 = env.CallStaticObject(ClassLoaderDef.clazz, ClassLoaderDef.getSystemClassLoader)
    process_classloader(env, processed, obj1, classes)
    # Process Thread.currentThread().getContextClassLoader()
    obj1 = env.CallStaticObject(ThreadDef.clazz, ThreadDef.currentThread)
    try: obj2 = env.CallObject(obj1, ThreadDef.getContextClassLoader)
    finally: env.DeleteLocalRef(obj1)
    process_classloader(env, processed, obj2, classes)
    
    # Organize the found classes
    cdef dict organized = {}
    update_packages(organized, classes)
    return organized

cdef update_packages(dict packages, list classes):
    classes.sort() # causes next loop to go much faster due to memory localization
    cdef dict d
    for c in classes:
        parts = c.split(u'.')
        d = packages
        for p in parts[:-1]: d = d.setdefault(p, {})
        d[parts[-1]] = None
    
cdef int process_classloader(JEnv env, set processed, jobject cl, list classes) except -1:
    cdef jint hash
    cdef jobject parent
    try:
        while cl is not NULL:
            hash = env.CallInt(cl, ObjectDef.hashCode)
            if hash in processed: break
            if env.IsInstanceOf(cl, URLClassLoaderDef.clazz):
                process_urlclassloader(env, cl, classes)
            parent = env.CallObject(cl, ClassLoaderDef.getParent)
            env.DeleteLocalRef(cl)
            cl = parent
    finally:
        if cl is not NULL: env.DeleteLocalRef(cl)
    return 0

cdef int process_urlclassloader(JEnv env, jobject cl, list classes) except -1:
    cdef unicode path
    cdef jobject url
    cdef jobjectArray urls = <jobjectArray>env.CallObject(cl, URLClassLoaderDef.getURLs)
    try:
        for i in xrange(env.GetArrayLength(urls)):
            url = env.GetObjectArrayElement(urls, i)
            try: path = env.CallString(url, ObjectDef.toString)
            finally: env.DeleteLocalRef(url)
            if path.startswith(u'file:'): process_path_classes(path[5:], classes)
    finally: env.DeleteLocalRef(urls)
    return 0

cdef int process_path_classes(unicode path, list classes):
    from os.path import isdir, isfile
    if isdir(path): process_dir_classes(path, classes)
    elif isfile(path) and (path.endswith(u'.jar') or path.endswith(u'.zip')):
        process_jar_classes(path, classes)
    return 0

cdef int process_dir_classes(unicode path, list classes) except -1:
    from os import walk
    from os.path import abspath, relpath, join
    for root, dirs, names in walk(abspath(path)):
        classes.extend(relpath(join(root, n), path)[:-6].replace(u'/', u'.').replace(u'\\', u'.')
                       for n in names if n.endswith(u'.class') and u'$' not in n)
    return 0

cdef int process_jar_classes(unicode path, list classes) except -1:
    from zipfile import ZipFile, BadZipfile, LargeZipFile
    try:
        with ZipFile(path, u'r') as zip:
            classes.extend(n[:-6].replace(u'/', u'.')
                           for n in zip.namelist() if n.endswith(u'.class') and u'$' not in n)
    except (BadZipfile, LargeZipFile, IOError): pass
    return 0

allpackages = None
cdef int init_importer(JEnv env) except -1: global allpackages; allpackages = find_all_classnames(env)
cdef int dealloc_importer(JEnv env) except -1: global allpackages; allpackages = None
jvm_add_init_hook(init_importer, -1)
jvm_add_dealloc_hook(dealloc_importer, -1)
