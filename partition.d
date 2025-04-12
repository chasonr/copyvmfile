// partition.d
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

import std.uuid;

import blockdevice;
import unpack;

enum TableType { mbr, gpt };

struct Partition {
    ulong start;        // Offset to start of partition
    ulong size;         // Size of partition
    TableType tblType;  // Type of table
    UUID gptType;       // For GPT partition tables: UUID of partition type
    string gptName;     // For GPT partition tables: Name of partition
    ubyte mbrType;      // For MBR partition tables: Type of partition
    ubyte mbrBootFlag;  // For MBR partition tables: Boot flag
};

// Return an array of partitions on the device.
// MBR and GPT partition tables are supported.
// Array is empty if no partition table found.
Partition[]
readPartitionTable(BlockDevice dev)
{
    // Read MBR-type partition table
    auto table = readMBRPartitionTable(dev);

    if (table.length == 1 && table[0].mbrType == 0xEE) {
        // Read GPT-type partition table
        table = readGPTPartitionTable(dev);
    }

    return table;
}

// Read an MBR-type partition table
static Partition[]
readMBRPartitionTable(BlockDevice dev)
{
    auto table = new Partition[0];
    ulong offset = 0;

    while (true) {
        // Read a single MBR-type partition table
        auto length = table.length;
        ubyte[512] block;
        auto read = dev.read(offset, block);
        if (read.length < 512 || read[510] != 0x55 || read[511] != 0xAA) {
            break;
        }

        // Read the partitions from that table
        foreach (i; 0 .. 4) {
            auto where = 0x1BE + i*16;
            // One partition table entry
            auto bytes = block[where .. where+16];
            // Unpack it
            auto bootflag = bytes[0];
            auto chsStart = bytes[1 .. 4];
            auto type = bytes[4];
            auto chsEnd = bytes[5 .. 8];
            auto lbaStart = unpackNum(bytes[8 .. 12]);
            auto lbaCount = unpackNum(bytes[12 .. 16]);
            // TODO: decode chsStart and chsEnd if lbaStart and lbaCount are 0
            if (lbaCount == 0) {
                break;
            }
            table.length += 1;
            table[$-1].start = offset + lbaStart * 512UL;
            table[$-1].size = lbaCount * 512UL;
            table[$-1].tblType = TableType.mbr;
            table[$-1].mbrType = type;
            table[$-1].mbrBootFlag = bootflag;
        }
        // If an extended partition is present, parse it; otherwise, stop
        if (table.length > length) {
            auto type = table[$-1].mbrType;
            if (type == 0x05 || type == 0x0F) {
                offset = table[$-1].start;
                continue;
            }
        }
        break;
    }

    return table;
}

// Read a GPT-type partition table
static Partition[]
readGPTPartitionTable(BlockDevice dev)
{
    auto table = new Partition[0];

    import std.stdio;
    ubyte[512] blk;
    dev.read(512, blk);
    if (unpackString(blk[0 .. 8]) != "EFI PART") {
        return table;
    }

    auto revision = unpackNum(blk[8 .. 12]);
    auto headerSize = unpackNum(blk[12 .. 16]);
    auto headerCRC32 = unpackNum(blk[16 .. 20]);
    auto currentLBA = unpackNum(blk[24 .. 32]);
    auto backupLBA = unpackNum(blk[32 .. 40]);
    auto firstLBA = unpackNum(blk[40 .. 48]);
    auto lastLBA = unpackNum(blk[48 .. 56]);
    auto diskGUID = blk[56 .. 72];
    auto tableLBA = unpackNum(blk[72 .. 80]);
    auto numPartitions = unpackNum(blk[80 .. 84]);
    auto partEntrySize = unpackNum(blk[84 .. 88]);
    auto tableCRC32 = unpackNum(blk[88 .. 92]);

    if (partEntrySize < 128) {
        return table;
    }

    auto tablePtr = tableLBA * 512;
    auto partEntry = new ubyte[partEntrySize];
    foreach (i; 0 .. numPartitions) {
        partEntry[0 .. $] = 0;
        dev.read(tablePtr, partEntry);
        auto typeGUID = UUID(
                partEntry[ 3], partEntry[ 2], partEntry[ 1], partEntry[ 0],
                partEntry[ 5], partEntry[ 4],
                partEntry[ 7], partEntry[ 6],
                partEntry[ 8], partEntry[ 9],
                partEntry[10], partEntry[11], partEntry[12], partEntry[13], partEntry[14], partEntry[15]);
        auto partGUID = partEntry[16 .. 32];
        auto partStartLBA = unpackNum(partEntry[32 .. 40]);
        auto partEndLBA = unpackNum(partEntry[40 .. 48]);
        auto attributes = unpackNum(partEntry[48 .. 56]);
        auto partName = unpackUTF16(partEntry[56 .. 128]);
        tablePtr += partEntrySize;
        if (partStartLBA == 0) {
            continue;
        }

        table.length += 1;

        table[$-1].start = partStartLBA * 512;
        table[$-1].size = (partEndLBA - partStartLBA + 1) * 512;
            table[$-1].tblType = TableType.gpt;
        table[$-1].gptType = typeGUID;
        table[$-1].gptName = partName;
    }

    return table;
}
