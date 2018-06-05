#!/usr/bin/env python
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

from __future__ import division
#from __future__ import unicode_literals
from __future__ import print_function
from __future__ import absolute_import

def check_java_version():
    from jvm._util import java_home, run
    from os.path import join, exists
    import re
    jre = java_home()
    out = run(join(jre,'bin','java'), '-version')[0]
    vers = [int(x) for x in re.search(r'\d+[.]\d+[.]\d+', out).group().split('.')]
    if vers[0] < 1 or vers[1] < 6:
        sys.stderr.write('Requires at least Java SE 6\n')
        exit(1)

def get_ext(name, debug):
    from jvm._util import jdk_home, is_win, is_mac, is_nix, is_x64
    from os.path import join, exists, sep
    from glob import iglob
    def F(f): return join('jvm', f)
    jdk = jdk_home()
    pyx = F(name.replace('.', sep) + '.pyx')
    ext = {
        'name':      'jvm.' + name,
        'sources':   [pyx],
        'libraries': ['jvm'],
        }
    
    if not debug: ext['define_macros'] = [('PYREX_WITHOUT_ASSERTIONS',None)]
    if is_win:
        platform = 'win32'
        # Use the MSVC lib in the JDK
        ext['extra_link_args'] = ['/MANIFEST']
        ext['library_dirs'] = [join(jdk, 'lib')]
        # Disable warnings about unreferenced local variable / label and formal param different from decl
        ext['extra_compile_args'] = ['/wd4101','/wd4102', '/wd4028']
    else:
        if is_mac:
            platform = 'darwin'
            ext['library_dirs'] = [join(jdk,'jre','lib',cs) for cs in ('server','client')]
        elif is_nix:
            platform = 'linux'
            ext['library_dirs'] = [join(jdk,'jre','lib',('amd64' if is_x64 else 'i386'), cs) for cs in ('server','client')]
        ext['extra_compile_args'] = ['-Wno-unused-variable','-Wno-unused-label']
    inc = join(jdk, 'include')
    ext['include_dirs'] = [inc, join(inc, platform)]
    return Extension(**ext)

try:
    from Cython.Build import cythonize
except ImportError:
    # Don't have Cython? That may be okay, just compile the sources.
    def cythonize(exts):
        from os.path import isfile
        for ext in exts: ext.sources = [s[:-4]+'.c' for s in ext.sources] # replace .pyx with .c
        if any((any(not isfile(s) for s in ext.sources)) for ext in exts):
            raise FileNotFoundError('No Cython and no source files - cannot compile')

if __name__ == '__main__':
    from setuptools import setup, Extension
    from os.path import join, dirname, basename, isfile
    import sys

    # Check the Python and Java versions
    if sys.hexversion < 0x02070000:
        sys.stderr.write('Requires at least Python v2.7\n')
        exit(1)
    check_java_version()

    # Write the Python version to the config file but only if it changed
    # Otherwise it has to re-cythonize for no reason
    config = 'DEF PY_VERSION=0x%08x\n'%sys.hexversion
    config += 'DEF PY_UNICODE_WIDE=%s\n'%(sys.hexversion<0x03030000 and sys.maxunicode>65535)
    config_file = join(dirname(__file__), 'jvm', 'internal', 'config.pxi')
    same = False
    if isfile(config_file):
        with open(config_file, 'r') as f: same = f.read() == config
    if not same:
        with open(config_file, 'w') as f: f.write(config)

    # Check if we want to build with assertion info
    debug = ('-g' in sys.argv) or ('--debug' in sys.argv)
    
    # Run the setup
    setup(name='pyjvm',
          version='0.1', # TODO
          description='Seamless access of the Java VM from within Python',
          long_description="""
This uses JNI to give access to all of Java from Python. On top of that it uses Java reflection to
be able to automatically discover Java classes, their methods and their fields. The classes are
wrapped in Python objects and using them becomes seamless from within Python. PyJVM tries to make
the integration as seamless as possible, for example making Java objects that implement
java.util.Iterable are iterable in Python as well.

To get started, simply `import jvm`. After that you just need start importing the classes you want
to use from the `J` module. The `J` module is the 'master' module and has the entire Java namespace
is available under it. For example:

    from J.java.lang import System
    System.out.println('Hello World!')

Additionally, the `java` and `javax` namespaces are also directly importable:

    from java.lang import System
    System.out.println('Hello World!')

For the most part, the objects should behave as you might expect.

For more information, see the included README.md file or using `help(jvm)`.
""",
          author='Jeffrey Bush',
          author_email='jeff@coderforlife.com',
          url='https://github.com/coderforlife/pyjvm',
          packages=['jvm','jvm.internal'],
          classifiers=['Development Status :: 3 - Alpha',
                       'License :: OSI Approved :: GNU General Public License v3 or later (GPLv3+)',
                       'Programming Language :: Java',
                       'Programming Language :: Python :: 2.7',
                       'Programming Language :: Python :: 3'
                       ],
          keywords=['java','integration','jvm','jar'],
          license='GPLv3+',
          data_files=[('jvm',['README.md','LICENSE.md'])],
          ext_modules=cythonize([
              get_ext('internal.utils', debug),
              get_ext('internal.unicode', debug),
              get_ext('internal.core', debug),
              get_ext('internal.objects', debug),
              get_ext('internal.convert', debug),
              get_ext('internal.arrays', debug),
              get_ext('internal.packages', debug),
              get_ext('internal.numbers', debug),
              get_ext('internal.collections', debug),
              get_ext('internal.synth', debug),
          ]))
