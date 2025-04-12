// blockdevice.d
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

// A block device implements this interface
interface BlockDevice {
    // The constructor will set this to return true if the provided volume
    // is of the type that the class works with
    bool isValid();

    // Reads from the volume, starting at the given byte offset and filling
    // data for its given length
    // Returns the slice that was actually read (which may be empty)
    ubyte[] read(ulong offset, ubyte[] data);

    // Return the size of the block device
    ulong size();
};
