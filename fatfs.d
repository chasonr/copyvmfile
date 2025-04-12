// fatfs.d
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

import std.array;
import std.format;
import std.path;
import std.utf;

import blockdevice;
import filesys;
import partition;
import runtimeexc;
import unicode;
import unpack;

class FATFileSystem : FileSystem {
public:

    this(BlockDevice dev_, Partition part_)
    {
        dev = dev_;
        part = part_;

        ubyte[512] bootrec;

        dev.read(part.start, bootrec);

        checkBPB(bootrec);

        // DOS 2.0 BPB
        sectorSize = unpackNum(bootrec[11 .. 13]);
        sectorsPerCluster = bootrec[13];
        reservedSectors = unpackNum(bootrec[14 .. 16]);
        numFATs = bootrec[16];
        rootDirSize = unpackNum(bootrec[17 .. 19]);
        numSectors = unpackNum(bootrec[19 .. 21]);
        sectorsPerFAT = unpackNum(bootrec[22 .. 24]);

        if (numSectors == 0) {
            numSectors = unpackNum(bootrec[32 .. 36]);
        }
        if (sectorsPerFAT == 0) {
            // This is only valid for FAT32
            sectorsPerFAT = unpackNum(bootrec[36 .. 40]);
        }
        if (rootDirSize == 0) {
            // This is only valid for FAT32
            rootDirCluster = unpackNum(bootrec[44 .. 48]);
        }

        fatOffset = reservedSectors;
        rootDirOffset = fatOffset + numFATs * sectorsPerFAT;
        auto rootDirSectors = (rootDirSize * 32 + sectorSize - 1) / sectorSize;
        dataOffset = rootDirOffset + rootDirSectors;
        numClusters = (numSectors - (reservedSectors + numFATs*sectorsPerFAT + rootDirSectors)) / sectorsPerCluster;
        if (numClusters <= 0xFF4) {
            fatSize = 12;
        } else if (numClusters <= 0xFFF4) {
            fatSize = 16;
        } else {
            fatSize = 32;
        }

        fatOffset = fatOffset*sectorSize + part.start;
        rootDirOffset = rootDirOffset*sectorSize + part.start;
        dataOffset = dataOffset*sectorSize + part.start;
        clusterSize = sectorSize * sectorsPerCluster;
        bytesPerFAT = sectorSize * sectorsPerFAT;
    }

    FileDesc open(string path)
    {
        // Normalize the path
        auto normPath = new string[0];
        foreach (string p; pathSplitter(path)) {
            switch (p) {
            case "":
            case ".":
            case "/":
                break;

            case "..":
                if (normPath.length != 0) {
                    --normPath.length;
                }
                break;

            default:
                normPath ~= p;
            }
        }

        if (normPath.length == 0) {
            throw new RuntimeException(format("\"%s\" is the root directory", path));
        }

        // Traverse the directory tree
        auto cluster = rootDirCluster; // 0 if root directory on FAT12/16
        DirEntry entry = null;
        foreach (i; 0 .. normPath.length) {
            auto p = normPath[i];
            entry = searchDir(cluster, p);
            if (entry is null) {
                throw new RuntimeException(format("\"%s\" not found", path));
            }
            if (i < normPath.length - 1) {
                // Must be a directory
                if ((entry.attr & Attrs.directory) == 0) {
                    throw new RuntimeException(format("\"%s\" is not a directory", p));
                }
            } else {
                // Must not be a directory
                if ((entry.attr & Attrs.directory) != 0) {
                    throw new RuntimeException(format("\"%s\" is a directory", path));
                }
            }
            cluster = entry.cluster;
        }

        auto file = new FATFileDesc(this, entry);
        return file;
    }

private:

    class DirEntry {
        uint attr;
        uint cluster;
        uint size;
    };

    enum Attrs {
        readOnly  = 0x01,
        hidden    = 0x02,
        system    = 0x04,
        label     = 0x08,
        directory = 0x10,
        archive   = 0x20,

        // If attrs is equal to this, the entry is a Long File Name record
        lfn       = 0x0F
    };

    BlockDevice dev;
    Partition part;

    uint reservedSectors;
    uint numSectors;
    uint sectorSize;
    uint sectorsPerCluster;
    uint numFATs;
    uint rootDirCluster;
    uint rootDirSize;
    ulong fatOffset;
    uint sectorsPerFAT;
    uint bytesPerFAT;
    ulong rootDirOffset;
    ulong dataOffset;
    uint clusterSize;
    uint numClusters;
    uint fatSize;

    static void checkBPB(ubyte[512] bootrec)
    {
        if (bootrec[510] == 0x55 && bootrec[511] == 0xAA
        && (bootrec[0] == 0xEB || bootrec[0] == 0xE9)) {
            return;
        }

        throw new RuntimeException("FAT file system not found on partition");
    }

    DirEntry searchDir(uint cluster, string name)
    {
        auto dir = new ubyte[0];
        auto longName = new wstring[0];
        uint lfnRecNum = 0;
        uint csum = 0;
        while (true) {
            if (cluster == 0) {
                // Root directory on FAT12 or FAT16
                dir.length = rootDirSize * 32;
                dev.read(rootDirOffset, dir);
            } else {
                // Normal cluster chain
                dir.length = clusterSize;
                readCluster(cluster, dir);
            }
            // Search the area read
            ulong p = 0;
            while (p < dir.length) {
                ubyte[32] ent = dir[p .. (p+32)];
                p += 32;

                if (ent[0] == 0) {
                    // End of directory
                    return null;
                } else if (ent[0] == 0xE5) {
                    // Deleted directory entry
                    longName.length = 0;
                    lfnRecNum = 0;
                    csum = 0;
                } else if (ent[11] == Attrs.lfn) {
                    // Long file name record
                    if (0x41 <= ent[0] && ent[0] <= 0x7F) {
                        // First record for some file
                        lfnRecNum = (ent[0] & 0x3F) - 1;
                        csum = ent[13];
                        longName.length = lfnRecNum + 1;
                        longName[lfnRecNum] = longNameSegment(ent, true);
                    } else if (ent[0] == lfnRecNum && ent[13] == csum) {
                        // Next record
                        --lfnRecNum;
                        longName[lfnRecNum] = longNameSegment(ent, false);
                    } else {
                        // Mismatched record
                        longName.length = 0;
                        lfnRecNum = 0;
                        csum = 0;
                    }
                } else if ((ent[11] & Attrs.label) != 0) {
                    // Volume label
                    longName.length = 0;
                    lfnRecNum = 0;
                    csum = 0;
                } else {
                    // Short name file record
                    if (csum != shortNameChecksum(ent)) {
                        // Record does not match preceding long name records
                        longName.length = 0;
                    }
                    if (longName.length != 0) {
                        string lname = buildLongName(longName);
                        if (caseMatch(lname, name)) {
                            return makeEntry(ent);
                        }
                    }
                    string sname = buildShortName(ent);
                    if (caseMatch(sname, name)) {
                        return makeEntry(ent);
                    }
                }
            }
            // Try the next cluster
            if (cluster == 0) {
                // Root directory on FAT12/FAT16
                return null;
            }
            cluster = nextCluster(cluster);
            if (cluster == 0xFFFFFFFF) {
                return null;
            }
        }
    }

    // Return a 13-character segment of a long file name
    static wstring longNameSegment(ubyte[32] ent, bool atEnd)
    {
        static const ubyte[13] charPos = [
             1,  3,  5,  7,  9,
            14, 16, 18, 20, 22, 24,
            28, 30
        ];
        wchar[13] seg;
        foreach (i; 0 .. 13) {
            auto pos = charPos[i];
            seg[i] = unpackNum(ent[pos .. $][0 .. 2]);
        }
        uint len = 13;
        if (atEnd) {
            for (len = 0; len < 13 && seg[len] != 0; ++len) {}
        }
        return seg[0 .. len].idup;
    }

    // Checksum used in long file name records to determine whether the short
    // name still matches
    static ubyte shortNameChecksum(ubyte[32] ent)
    {
        // Wikipedia, at
        // https://en.wikipedia.org/w/index.php?title=Design_of_the_FAT_file_system&oldid=1278385983

        ubyte sum = 0;

        foreach (ref ubyte b; ent[0 .. 11]) {
            sum = cast(ubyte)(((sum & 1) << 7) + (sum >> 1) + b);
        }

        return sum;
    }

    // Build the long name from the array of segments
    static string buildLongName(wstring[] lname)
    {
        return lname.join().toUTF8();
    }

    // Build a DirEntry structure from a directory record
    DirEntry makeEntry(ubyte[32] ent)
    {
        auto dent = new DirEntry;

        dent.attr = ent[11];
        dent.cluster = unpackNum([ ent[26], ent[27], ent[20], ent[21] ]);
        dent.size = unpackNum(ent[28 .. 32]);

        return dent;
    }

    static string buildShortName(ubyte[32] ent)
    {
        // TODO: make the code page configurable
        static const wchar[256] cp850 = [
            0x0000, 0x0001, 0x0002, 0x0003, 0x0004, 0x0005, 0x0006, 0x0007,
            0x0008, 0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x000E, 0x000F,
            0x0010, 0x0011, 0x0012, 0x0013, 0x0014, 0x0015, 0x0016, 0x0017,
            0x0018, 0x0019, 0x001A, 0x001B, 0x001C, 0x001D, 0x001E, 0x001F,
            0x0020, 0x0021, 0x0022, 0x0023, 0x0024, 0x0025, 0x0026, 0x0027,
            0x0028, 0x0029, 0x002A, 0x002B, 0x002C, 0x002D, 0x002E, 0x002F,
            0x0030, 0x0031, 0x0032, 0x0033, 0x0034, 0x0035, 0x0036, 0x0037,
            0x0038, 0x0039, 0x003A, 0x003B, 0x003C, 0x003D, 0x003E, 0x003F,
            0x0040, 0x0041, 0x0042, 0x0043, 0x0044, 0x0045, 0x0046, 0x0047,
            0x0048, 0x0049, 0x004A, 0x004B, 0x004C, 0x004D, 0x004E, 0x004F,
            0x0050, 0x0051, 0x0052, 0x0053, 0x0054, 0x0055, 0x0056, 0x0057,
            0x0058, 0x0059, 0x005A, 0x005B, 0x005C, 0x005D, 0x005E, 0x005F,
            0x0060, 0x0061, 0x0062, 0x0063, 0x0064, 0x0065, 0x0066, 0x0067,
            0x0068, 0x0069, 0x006A, 0x006B, 0x006C, 0x006D, 0x006E, 0x006F,
            0x0070, 0x0071, 0x0072, 0x0073, 0x0074, 0x0075, 0x0076, 0x0077,
            0x0078, 0x0079, 0x007A, 0x007B, 0x007C, 0x007D, 0x007E, 0x2302,
            0x00C7, 0x00FC, 0x00E9, 0x00E2, 0x00E4, 0x00E0, 0x00E5, 0x00E7,
            0x00EA, 0x00EB, 0x00E8, 0x00EF, 0x00EE, 0x00EC, 0x00C4, 0x00C5,
            0x00C9, 0x00E6, 0x00C6, 0x00F4, 0x00F6, 0x00F2, 0x00FB, 0x00F9,
            0x00FF, 0x00D6, 0x00DC, 0x00F8, 0x00A3, 0x00D8, 0x00D7, 0x0192,
            0x00E1, 0x00ED, 0x00F3, 0x00FA, 0x00F1, 0x00D1, 0x00AA, 0x00BA,
            0x00BF, 0x00AE, 0x00AC, 0x00BD, 0x00BC, 0x00A1, 0x00AB, 0x00BB,
            0x2591, 0x2592, 0x2593, 0x2502, 0x2524, 0x00C1, 0x00C2, 0x00C0,
            0x00A9, 0x2563, 0x2551, 0x2557, 0x255D, 0x00A2, 0x00A5, 0x2510,
            0x2514, 0x2534, 0x252C, 0x251C, 0x2500, 0x253C, 0x00E3, 0x00C3,
            0x255A, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550, 0x256C, 0x00A4,
            0x00F0, 0x00D0, 0x00CA, 0x00CB, 0x00C8, 0x0131, 0x00CD, 0x00CE,
            0x00CF, 0x2518, 0x250C, 0x2588, 0x2584, 0x00A6, 0x00CC, 0x2580,
            0x00D3, 0x00DF, 0x00D4, 0x00D2, 0x00F5, 0x00D5, 0x00B5, 0x00FE,
            0x00DE, 0x00DA, 0x00DB, 0x00D9, 0x00FD, 0x00DD, 0x00AF, 0x00B4,
            0x00AD, 0x00B1, 0x2017, 0x00BE, 0x00B6, 0x00A7, 0x00F7, 0x00B8,
            0x00B0, 0x00A8, 0x00B7, 0x00B9, 0x00B3, 0x00B2, 0x25A0, 0x00A0
        ];

        ubyte[8] name = ent[0 .. 8];
        ubyte[3] ext = ent[8 .. 11];
        if (name[0] == 0x05) {
            name[0] = 0xE5;
        }
        uint nameLen = 8;
        while (nameLen != 0 && name[nameLen-1] == 0x20) {
            --nameLen;
        }
        uint extLen = 3;
        while (extLen != 0 && ext[extLen-1] == 0x20) {
            --extLen;
        }
        wchar[12] sname;
        uint snameLen = 0;
        foreach (ch; name[0 .. nameLen]) {
            sname[snameLen++] = cp850[ch];
        }
        if (extLen != 0) {
            sname[snameLen++] = '.';
            foreach (ch; ext[0 .. extLen]) {
                sname[snameLen++] = cp850[ch];
            }
        }
        return (sname[0 .. snameLen]).toUTF8();
    }

    // Read the selected cluster
    void readCluster(uint cluster, ubyte[] bytes, uint start = 0)
    {
        assert(bytes.length + start <= clusterSize);
        ulong offset = cast(ulong)(cluster-2)*clusterSize + dataOffset + start;
        dev.read(offset, bytes);
    }

    uint nextCluster(uint cluster)
    {
        uint newCluster;

        switch (fatSize) {
        case 12:
            {
                uint offset = (cluster/2) * 3;
                ubyte[4] bytes;
                dev.read(fatOffset + offset, bytes[0 .. 3]);
                newCluster = unpackNum(bytes);
                if (cluster & 1) {
                    newCluster >>= 12;
                } else {
                    newCluster &= 0xFFF;
                }
                if (newCluster >= 0xFF8) {
                    newCluster = 0xFFFFFFFF;
                }
            }
            break;

        case 16:
            {
                uint offset = cluster * 2;
                ubyte[2] bytes;
                dev.read(fatOffset + offset, bytes);
                newCluster = unpackNum(bytes);
                if (newCluster >= 0xFFF8) {
                    newCluster = 0xFFFFFFFF;
                }
            }
            break;

        case 32:
            {
                uint offset = cluster * 4;
                ubyte[4] bytes;
                dev.read(fatOffset + offset, bytes);
                newCluster = unpackNum(bytes) & 0x0FFFFFFF;
                if (newCluster >= 0xFFFFFF8) {
                    newCluster = 0xFFFFFFFF;
                }
            }
            break;

        default:
            assert(0);
        }

        return newCluster;
    }

    uint getClusterSize()
    {
        return clusterSize;
    }

    class FATFileDesc : FileDesc {
    public:
        this(FATFileSystem fs_, DirEntry entry)
        {
            fs = fs_;
            offset = 0;
            size = entry.size;
            cluster = entry.cluster;
            firstCluster = entry.cluster;
        }

        override void seek(ulong offset)
        {
            auto oldCluster = this.offset / fs.getClusterSize();
            auto newCluster = offset / fs.getClusterSize();
            if (newCluster < oldCluster) {
                this.cluster = this.firstCluster;
                oldCluster = 0;
            }
            while (this.cluster != 0xFFFFFFFF && oldCluster < newCluster) {
                this.cluster = fs.nextCluster(this.cluster);
                ++oldCluster;
            }
            this.offset = offset;
        }

        override ulong tell()
        {
            return offset;
        }

        override ubyte[] read(ubyte[] buf)
        {
            auto readLen = buf.length;
            if (this.size <= this.offset) {
                readLen = 0;
            } else if (this.offset + readLen > this.size) {
                readLen = this.size - this.offset;
            }

            if (readLen == 0) {
                return buf[0 .. 0];
            }

            auto sCluster = this.offset / fs.getClusterSize();
            auto sOffset = cast(uint)(this.offset % fs.getClusterSize());
            auto endOffset = this.offset + readLen;
            auto eCluster = endOffset / fs.getClusterSize();
            if (sCluster == eCluster) {
                // Read area lies within the current cluster
                fs.readCluster(this.cluster, buf[0 .. readLen], sOffset);
            } else {
                // Read area spans a cluster boundary
                // Read the start portion
                uint partLen = fs.getClusterSize() - sOffset;
                fs.readCluster(this.cluster, buf[0 .. partLen], sOffset);
                auto newCluster = fs.nextCluster(this.cluster);
                this.cluster = newCluster;
                ++sCluster;
                auto readStart = partLen;
                // Read any complete clusters
                while (sCluster < eCluster) {
                    fs.readCluster(this.cluster,
                                buf[readStart .. readStart+fs.getClusterSize()],
                                0);
                    this.cluster = fs.nextCluster(this.cluster);
                    ++sCluster;
                    readStart += fs.getClusterSize();
                }
                // Read the end portion
                partLen = cast(uint)(buf.length - readStart);
                fs.readCluster(this.cluster, buf[readStart .. $], 0);
            }

            this.offset = endOffset;
            return buf[0 .. readLen];
        }

        override void close()
        {
        }

    private:
        FATFileSystem fs;

        ulong offset;
        uint size;
        uint firstCluster;
        uint cluster;
    };
};
