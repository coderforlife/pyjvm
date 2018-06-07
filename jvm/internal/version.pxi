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

Version Information Defines
"""

DEF JNI_VERSION_1_1=0x00010001
DEF JNI_VERSION_1_2=0x00010002
DEF JNI_VERSION_1_4=0x00010004
DEF JNI_VERSION_1_6=0x00010006

DEF PY_VERSION_2=0x02000000
#DEF PY_VERSION_2_7=0x02070000
DEF PY_VERSION_3=0x03000000
DEF PY_VERSION_3_2=0x03020000
DEF PY_VERSION_3_3=0x03030000
DEF PY_VERSION_3_5=0x03050000

# Target Java SE 6 - pretty old already and it does help
# The code requires at least JNI_VERSION_1_2. If lowered to JNI_VERSION_1_4 a fallback for deleting
# references is provided, although it might be slower. If lowered to JNI_VERSION_1_2 native
# ByteBuffers can no longer be used.
DEF JNI_VERSION=JNI_VERSION_1_6

include "config.pxi" # the current version information
