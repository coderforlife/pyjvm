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

The core of the JVM/JNI interaction code. This is broken down into 3 seperate sections:
  * jvm - for interacting with the Java VM directly and handling its threading
  * jenv - a wrapper for the JEnv object
  * jref - for dealing with low-level reflection operations of JNI
See each of those pxd.pxi and pyx.pxi files for more information.
  
These all have significant amount of code but require a lot of interaction between them so they are
split into seperate files but must be compiled by Cython as a single unit.
"""

from __future__ import absolute_import

include "jvm.pyx.pxi"
include "jenv.pyx.pxi"
include "jref.pyx.pxi"
