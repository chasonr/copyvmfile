// unpack.d
//
// Copyright © 2025 Ray Chason.
// 
// This file is part of copyvmfile.
// 
// copyvmfile is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the
// Free Software Foundation, in version 3 of the License.
// 
// copyvmfile is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
// more details.
// 
// You should have received a copy of the GNU General Public License
// along with copyvmfile; see the file LICENSE.  If not see
// <http://www.gnu.org/licenses/>.

import std.utf;

ushort
unpackNum(ubyte[2] bytes)
{
    return (cast(ushort)(bytes[0]) << 0)
         | (cast(ushort)(bytes[1]) << 8);
}

uint
unpackNum(ubyte[4] bytes)
{
    return (cast(uint)(bytes[0]) <<  0)
         | (cast(uint)(bytes[1]) <<  8)
         | (cast(uint)(bytes[2]) << 16)
         | (cast(uint)(bytes[3]) << 24);
}

ulong
unpackNum(ubyte[8] bytes)
{
    return (cast(ulong)(bytes[0]) <<  0)
         | (cast(ulong)(bytes[1]) <<  8)
         | (cast(ulong)(bytes[2]) << 16)
         | (cast(ulong)(bytes[3]) << 24)
         | (cast(ulong)(bytes[4]) << 32)
         | (cast(ulong)(bytes[5]) << 40)
         | (cast(ulong)(bytes[6]) << 48)
         | (cast(ulong)(bytes[7]) << 56);
}

string
unpackString(ubyte[] bytes)
{
    ulong len;
    for (len = 0; len < bytes.length && bytes[len] != 0; ++len) {}
    auto str = new char[len];
    foreach (ulong i; 0 .. len) {
        str[i] = cast(ubyte)(bytes[i]);
    }
    return str.idup;
}

string
unpackUTF16(ubyte[] bytes)
{
    assert((bytes.length & 1) == 0);

    auto wstr = new wchar[bytes.length/2];
    foreach (i; 0 .. wstr.length) {
        wstr[i] = (cast(wchar)(bytes[i*2+0] << 0))
                | (cast(wchar)(bytes[i*2+1] << 8));
        if (wstr[i] == 0) {
            wstr.length = i;
            break;
        }
    }
    return wstr.toUTF8;
}
