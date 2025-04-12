// filesys.d
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

// File systems return an object of a class derived from FileDesc type to
// represent an open file
class FileDesc {
public:
    abstract void seek(ulong offset);
    abstract ulong tell();
    abstract ubyte[] read(ubyte[] buf);
    abstract void close();
};

// A file system implements this interface
interface FileSystem {
    FileDesc open(string path);
};
