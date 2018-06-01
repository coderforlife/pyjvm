"""
Utilities - mostly for OS dependent functions like finding the JRE/JDK and loading libraries and
Python 2/3 support functions.

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

import sys, os, ctypes

is_py2  = sys.version_info.major == 2
is_x64  = ctypes.sizeof(ctypes.c_voidp) == 8
is_mac  = sys.platform == 'darwin'
is_nix  = os.name == 'posix'   # sys.platform.startswith('linux') or sys.platform.startswith('freebsd') or sys.platform = 'cygwin'
is_win  = os.name == 'nt'      # sys.platform.startswith('win')
#is_os2  = os.name == 'os2'    # sys.platform.startswith('os2')
#is_ce   = os.name == 'ce'
#is_risc = os.name == 'riscos' # sys.platform.startswith('riscos')
#is_athe = sys.platform.startswith('atheos')
#is_sun  = sys.platform.startswith('sunos')
#TODO: os.name == 'java'

if not is_py2: unicode = str

def run(*cmd):
    from subprocess import check_output, STDOUT
    out = check_output(cmd, stderr=STDOUT).strip()
    return (unicode(out, 'utf-8') if isinstance(out, bytes) else out).split('\n')

def append_to_path(*args):
    path = os.environ['PATH'].split(os.pathsep)
    for a in args:
        if a not in path: path.append(a)
    path = os.pathsep.join(path)
    if is_py2 and isinstance(os.environ['PATH'], bytes) and isinstance(path, unicode):
        path = path.encode('utf-8')
    os.environ['PATH'] = path

def set_java_home(path):
    os.environ['JAVA_HOME'] = path
    append_to_path(path)
    return path

def java_home():
    """
    Looks for 'JAVA_HOME' in the environment. If it isn't there, uses a platform-specific method to
    find the folder containing the JRE.
    """
    if 'JAVA_HOME' in os.environ: return os.environ['JAVA_HOME']
    from os.path import abspath, join, dirname, exists
    if is_mac:
        path = run('/usr/libexec/java_home', '--request', '--arch', 'x86_64' if is_x64 else 'i386')[0]
        libc = ctypes.CDLL('/usr/lib/libc.dylib')
        for p in (join(dirname(path), 'Libraries'), join(path, 'jre', 'lib', 'server')):
            lib = join(p, 'libjvm.dylib')
            # make sure lib exists and can be loaded
            if exists(lib) and libc.dlopen_preflight(lib) != 0:
                return set_java_home(path)
    elif is_nix:
        # TODO: this is not architecture-specific and may find a bad version
        try:
            path = run('/usr/bin/which', 'java')[0]
            path = run('readlink', '-f', path)[0]
            path = dirname(dirname(path))
            return set_java_home(path)
        except Exception: pass
    elif is_win:
        if is_py2: import _winreg as winreg
        else:      import winreg
        for k in (winreg.HKEY_CURRENT_USER, winreg.HKEY_LOCAL_MACHINE):
            try:
                k = winreg.OpenKey(k, 'SOFTWARE\\JavaSoft\\Java Runtime Environment')
                cv = unicode(winreg.QueryValueEx(k, 'CurrentVersion')[0])
                path = unicode(winreg.QueryValueEx(winreg.OpenKey(k, cv), 'JavaHome')[0])
                return set_java_home(path)
            except Exception: pass
    raise RuntimeError('Cannot find a compatible Java Runtime Environment, install the JRE/JDK or set the environmental variable JAVA_HOME to its location')

def jdk_home():
    """
    Looks for 'JDK_HOME' in the environment. If it isn't there, uses a platform-specific method to
    find the folder containing the JDK. On Windows the JDK and JRE are separate, but on other
    systems they are co-located so we just return java_home()
    """
    if 'JDK_HOME' in os.environ: return os.environ['JDK_HOME']
    if is_win:
        if is_py2: import _winreg as winreg
        else:        import winreg
        for k in (winreg.HKEY_CURRENT_USER, winreg.HKEY_LOCAL_MACHINE):
            try:
                k = winreg.OpenKey(k, 'SOFTWARE\\JavaSoft\\Java Development Kit')
                cv = unicode(winreg.QueryValueEx(k, 'CurrentVersion')[0])
                return unicode(winreg.QueryValueEx(winreg.OpenKey(k, cv), 'JavaHome')[0])
            except Exception: pass
    else:
        jdk = java_home()
        if os.path.basename(jdk) == 'jre': jdk = os.path.dirname(jdk)
        return jdk
    raise RuntimeError('Cannot find a compatible Java, install the JDK or set the environmental variable JDK_HOME to its location')

def find_libjvms(java_home, name):
    """
    Runs `find` on `java_home` for files named `name`. Looks at the list of resulting paths and
    looks at the paths for containing 'server' and 'client'. Returns a server and client path, or
    None for ones not found.
    """
    paths = run('find', java_home, '-name', name)
    client = None
    server = None
    for path in paths:
        if   'server' in path: server = path
        elif 'client' in path: client = path
        else:
            import warnings
            w = 'libjvm path "%s" could not be identified as server or client'%path
            if server is None:
                warnings.warn('%s, assuming server'%w)
                server = path
            elif client is None:
                warnings.warn('%s, assuming server'%w)
                client = path
            else:
                warnings.warn('%s, not using'%w)
    return client, server
                
def jvm_find(prefer=None):
    """
    Finds the jvm dynamic library (jvm.dll, libjvm.dylib, or libjvm.so depending on the OS). There
    are possibly two different versions: server and client. The `prefer` argument biases which is
    returned, although not gauranteed. The default is None which just picks one. The found JVM
    library path along with 'client' or 'server' is returned.
    """
    jre = java_home()
    client,server = None,None
    from os.path import join, isfile
    if is_mac:   client,server = find_libjvms(jre, 'libjvm.dylib')
    elif is_nix: client,server = find_libjvms(jre, 'libjvm.so')
    elif is_win:
        for jre in (jre, join(jre, 'jre')):
            jre = join(jre, 'bin')
            jvm = join(jre, 'client', 'jvm.dll')
            if isfile(jvm): client = jvm
            jvm = join(jre, 'server', 'jvm.dll')
            if isfile(jvm): server = jvm
    if server is None and client is None: raise RuntimeError('Cannot find a compatible JVM')
    if prefer is 'client':
        if client is not None: return client, 'client'
        import warnings
        warnings.warn('Preferred JVM "client" not found, using "server"')
    elif prefer is 'server':
        if server is not None: return server, 'server'
        import warnings
        warnings.warn('Preferred JVM "server" not found, using "client"')
    elif prefer is not None: raise ValueError('prefer must be "client", "server", or None')
    return (client, 'client') if server is None else (server, 'server')

libjvm_type = None
libjvm = None
def jvm_load(prefer=None):
    """
    Loads the JVM dynamic library. The `prefer` argument works like for `jvm_find`. If the library
    is already loaded, this produces a warning if `prefer` doesn't match the loaded library,
    otherwise it does nothing.
    """
    global libjvm, libjvm_type
    if libjvm is not None:
        if prefer is not None and prefer != libjvm_type:
            import warnings
            warnings.warn('Already loaded JVM "%s", so preferred JVM "%s" is unloadable'%(libjvm_type,prefer))
        return
    jvm,libjvm_type = jvm_find(prefer)
    libjvm = (ctypes.windll if is_win else ctypes.cdll).LoadLibrary(jvm)
