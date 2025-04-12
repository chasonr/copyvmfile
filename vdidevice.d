// vdidevice.d
// Portions opyright © 2025 Ray Chason.
// Adapted from VirtualBox 7.1.6 source, file src/VBox/Storage/VDICore.h,
// with copyright statement reproduced below:
//
// Copyright (C) 2006-2024 Oracle and/or its affiliates.
//
// This file is part of VirtualBox base platform packages, as
// available from https://www.virtualbox.org.
//
// This program is free software; you can redistribute it and/or
// modify it under the terms of the GNU General Public License
// as published by the Free Software Foundation, in version 3 of the
// License.
//
// This program is distributed in the hope that it will be useful, but
// WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program; if not, see <https://www.gnu.org/licenses>.
//
// SPDX-License-Identifier: GPL-3.0-only

import std.format;
import std.stdio;
import std.uuid;

import blockdevice;
import runtimeexc;
import unpack;


// Harddisk geometry

struct VDIDiskGeometry
{
    static const uint sizeOnDisk = 16;

    uint cCylinders; // Cylinders
    uint cHeads;     // Heads
    uint cSectors;   // Sectors per track
    uint cbSector;   // Sector size

    void unpack(ubyte[sizeOnDisk] bytes)
    {
        cCylinders = unpackNum(bytes[0 .. 4]);
        cHeads     = unpackNum(bytes[4 .. 8]);
        cSectors   = unpackNum(bytes[8 .. 12]);
        cbSector   = unpackNum(bytes[12 .. 16]);
    }
};

// Image signature
const uint VDIImageSignature = 0xBEDA107F;

class VDIDevice : BlockDevice {
    this(File *fp)
    {
        m_fp = fp;

        fp.seek(0);

        // Pre-header
        ubyte[preHeaderSize] preheader;
        fp.rawRead(preheader);
        szFileInfo   = unpackString(preheader[0 .. 64]);
        u32Signature = unpackNum(preheader[64 .. 68]);
        u32Version   = unpackNum(preheader[68 .. 72]);

        if (u32Signature != VDIImageSignature) {
            m_isValid = false;
            return;
        }
        m_isValid = true;

        switch (u32Version >> 16) {
        case 0:
            // Version 0 header
            {
                ubyte[header0Size] header;
                fp.rawRead(header);
                u32Type          = unpackNum(header[0 .. 4]);
                fFlags           = unpackNum(header[4 .. 8]);
                szComment        = unpackString(header[8 .. 264]);
                LegacyGeometry.unpack(header[264 .. 280]);
                cbDisk           = unpackNum(header[280 .. 288]);
                cbBlock          = unpackNum(header[288 .. 292]);
                cBlocks          = unpackNum(header[292 .. 296]);
                cBlocksAllocatedOffset = 296;
                cBlocksAllocated = unpackNum(header[296 .. 300]);
                uuidCreate       = UUID(header[300 .. 316]);
                uuidModify       = UUID(header[316 .. 332]);
                uuidLinkage      = UUID(header[332 .. 348]);

                offBlocks        = preHeaderSize + header0Size;
                offData          = offBlocks + cBlocks*4;
                cbBlockExtra     = 0;
            }
            break;

        case 1:
            // Version 1 header
            {
                ubyte[header1PlusSize] header;
                fp.rawRead(header[0 .. 4]);
                auto headerSize = unpackNum(header[0 .. 4]);

                if (headerSize < header1Size) {
                    throw new RuntimeException(format("Invalid header size of %u bytes",
                            headerSize));
                }
                if (headerSize > header1PlusSize) {
                    headerSize = header1PlusSize;
                }

                fp.rawRead(header[4 .. headerSize]);

                cbHeader         = unpackNum(header[0 .. 4]);
                u32Type          = unpackNum(header[4 .. 8]);
                fFlags           = unpackNum(header[8 .. 12]);
                szComment        = unpackString(header[12 .. 268]);
                offBlocks        = unpackNum(header[268 .. 272]);
                offData          = unpackNum(header[272 .. 276]);
                LegacyGeometry.unpack(header[276 .. 292]);
                cbDisk           = unpackNum(header[296 .. 304]);
                cbBlock          = unpackNum(header[304 .. 308]);
                cbBlockExtra     = unpackNum(header[308 .. 312]);
                cBlocks          = unpackNum(header[312 .. 316]);
                cBlocksAllocatedOffset = 316;
                cBlocksAllocated = unpackNum(header[316 .. 320]);
                uuidCreate       = UUID(header[320 .. 336]);
                uuidModify       = UUID(header[336 .. 352]);
                uuidLinkage      = UUID(header[352 .. 368]);
                uuidParentModify = UUID(header[368 .. 384]);
                if (headerSize >= header1PlusSize) {
                    LCHSGeometry.unpack(header[384 .. 400]);
                }
            }
            break;

        default:
            throw new RuntimeException(format("VDI version %u is not supported",
                        u32Version >> 16));
        }

        // It is not clear what cbBlockExtra actually means -- whether the
        // "additional service information" is stored before or after the
        // block, or somewhere else -- and VirtualBox does not seem to create
        // images with a nonzero value here.
        if (cbBlockExtra != 0) {
            throw new RuntimeException("VDI has unsupported non-zero extra block information");
        }
    }

    bool isValid() { return m_isValid; }

    ubyte[] read(ulong offset, ubyte[] data)
    {
        ulong end_read = offset + data.length;
        auto sblock = offset / cbBlock;
        auto eblock = end_read / cbBlock; 
        uint partBlock = cast(uint)(offset % cbBlock);
        if (sblock >= cBlocks) {
            // read begins beyond end of volume
            return [];
        }
        if (eblock >= cBlocks) {
            // read begins within volume but ends beyond it
            eblock = cBlocks;
            end_read = cast(ulong)(cBlocks) * cbBlock;
        }
        if (sblock == eblock) {
            // Read is within a block
            readBlock(sblock, partBlock, data);
        } else {
            // Read spans two or more blocks
            ulong p = 0;
            uint sz = cbBlock - partBlock;
            readBlock(sblock, partBlock, data[0 .. sz]);
            p += sz;
            foreach (b; (sblock+1)..eblock) {
                readBlock(b, 0, data[p .. (p+cbBlock)]);
                p += cbBlock;
            }
            sz = cast(uint)(end_read % cbBlock);
            readBlock(eblock, 0, data[p .. (p+sz)]);
        }
        return data[0 .. (end_read-offset)];
    }

    // Return the size of the block device
    ulong size()
    {
        return cbDisk;
    }

private:
    void readBlock(ulong block, uint offset, ubyte[] data)
    {
        if (data.length == 0) {
            return;
        }

        // Read pointer to block
        m_fp.seek(offBlocks + block*4);
        ubyte[4] blkb;
        m_fp.rawRead(blkb);
        auto blk = unpackNum(blkb);

        if (blk >= 0xFFFFFFFE) {
            data[0 .. $] = 0;
            return;
        }

        // Find offset in file to block
        ulong loc = cast(ulong)(blk) * cbBlock + offData + offset;
        m_fp.seek(loc);
        m_fp.rawRead(data);
    }

    static const uint preHeaderSize = 72;
    static const uint header0Size = 348;
    static const uint header1Size = 384;
    static const uint header1PlusSize = 400;

    File *m_fp;

    bool m_isValid;

    // Pre-header

    string szFileInfo;   // Just text info about image type, for eyes only
    uint   u32Signature; // The image signature (VDIImageSignature)
    uint   u32Version;   // The image version (0 or 1)

    // Header
    uint            cbHeader;         // Size of this structure in bytes
    uint            u32Type;          // The image type
    uint            fFlags;           // Image flags
    string          szComment;        // Image comment (UTF-8)
    uint            offBlocks;        // Offset of blocks array from the beginning of image file
                                      // Should be sector-aligned for HDD access optimization
    uint            offData;          // Offset of image data from the beginning of image file
                                      // Should be sector-aligned for HDD access optimization
    VDIDiskGeometry LegacyGeometry;   // Legacy image geometry (previous code stored PCHS there)
    ulong           cbDisk;           // Size of disk (in bytes)
    uint            cbBlock;          // Block size; should be a power of 2
    uint            cbBlockExtra;     // Size of additional service information of every data block
                                      // Prepended before block data. May be 0
                                      // Should be a power of 2 and sector-aligned for optimization reasons
    uint            cBlocks;          // Number of blocks
    ulong           cBlocksAllocatedOffset; // Offset to place in header where the allocation count is stored
    uint            cBlocksAllocated; // Number of allocated blocks
    UUID            uuidCreate;       // UUID of image
    UUID            uuidModify;       // UUID of image's last modification
    UUID            uuidLinkage;      // Only for secondary images - UUID of previous image
    UUID            uuidParentModify; // Only for secondary images - UUID of previous image's last modification
    VDIDiskGeometry LCHSGeometry;     // LCHS image geometry (new field in VDI1.2 version
};
