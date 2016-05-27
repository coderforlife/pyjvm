"""
JVM module. See README.md for more information. This docstring is replace by it at runtime.

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

# Update the doc-string
import os.path
d = os.path.dirname(__file__)
for d in (d, os.path.dirname(d)):
    fn = os.path.join(d, 'README.md')
    if os.path.isfile(fn):
        with open(fn, 'r') as f: __doc__ = f.read()
        del f
        break
del os, d, fn
    
from ._jvm import *
