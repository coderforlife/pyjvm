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
from __future__ import unicode_literals

# Simply import all of the Python functions from the Cython modules
from .unicode import *
from .core import *
from .objects import *
from .convert import *
from .arrays import *
from .packages import *
from .numbers import *
from .collections import *
from .synth import *

# The set of functions that should be publicly accessible
publicfuncs = {
    'get_java_class':get_java_class,'template':template,
    'synchronized':synchronized,'unbox':unbox,'register_converter':register_converter,
    'JavaClass':JavaClass,'JavaMethods':JavaMethods,'JavaMethod':JavaMethod,'JavaConstructor':JavaConstructor,
    'boolean_array':boolean_array,'char_array':char_array,'object_array':object_array,
    'byte_array':byte_array,'short_array':short_array,'int_array':int_array,'long_array':long_array,
    'float_array':float_array,'double_array':double_array,
}
