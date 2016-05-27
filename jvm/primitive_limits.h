// pyjvm - Java VM access from within Python
// Copyright (C) 2016 Jeffrey Bush <jeff@coderforlife.com>
// 
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
// 
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
// 
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
// 
// ------------------------------------------------------------------------------------------------
// 
// Defines the limits of the Java primitive types. Defined in a C header because if defined in
// Cython it manipulates the values and causes warnings and possibly other issues.

#define JBYTE_MIN  -0x80
#define JBYTE_MAX  +0x7F
#define JSHORT_MIN -0x8000
#define JSHORT_MAX +0x7FFF
#define JINT_MIN   -0x80000000LL
#define JINT_MAX   +0x7FFFFFFFLL
#define JLONG_MIN  -0x8000000000000000LL
#define JLONG_MAX  +0x7FFFFFFFFFFFFFFFLL
#define JCHAR_MAX  0xFFFF
#define JFLOAT_MAX 3.40282347E+38
