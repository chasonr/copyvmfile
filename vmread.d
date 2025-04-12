// vmread.d
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

import std.conv;
import std.format;
import std.path;
import std.regex;
import std.stdio;
import std.traits;
import core.stdc.stdlib;

import fatfs;
import partition;
import runtimeexc;
import vdidevice;

struct FSOptions {
    string volume;
    uint partitionNum;
    bool listPartitions;
    bool verbose;
};

// Print an error message and exit
void
error(string msg)
{
    stderr.writeln(msg);
    exit(EXIT_FAILURE);
}

// Convert option to numeric type with meaningful error message
void
convertNumeric(numtype)(string option, string value, ref numtype arg)
if (isUnsigned!numtype)
{
    try {
        auto match = matchFirst(value, r"^[0-9]+$");
        if (match.empty) {
            error(format("Option --%s requires a numeric value (not \"%s\")\n",
                    option, value));
        }
        arg = to!numtype(value);
    }
    catch (ConvException exc) {
        error(format("Option --%s: %s overflows", option, value));
    }
}

FSOptions
getOptions(ref string[] args)
{
    import std.getopt;

    FSOptions options;

    try {
        auto helpInfo = getopt(
            args,
            "volume", "Set the name of the volume", &options.volume,
            "partition", "Set the number of the partition",
                    delegate void(string option, string value) {
                        convertNumeric(option, value, options.partitionNum);
                    },
            "list-partitions", "List the partitions on the volume",
                    &options.listPartitions,
            "v|verbose", "Enable extra output", &options.verbose);
        if (helpInfo.helpWanted) {
            writef("Usage: %s [options] <pathname> ...\n\n", args[0]);
            defaultGetoptPrinter("Options for this program follow.\n",
                    helpInfo.options);
            exit(EXIT_FAILURE);
        }
    }
    catch (ConvException exc) {
        error(exc.msg);
    }
    catch (GetOptException exc) {
        error(exc.msg);
    }

    // Validate the given options:

    if (options.volume == "") {
        error("Must specify --volume");
    }

    if (options.listPartitions) {
        if (args.length != 1) {
            error("Cannot specify files with --list-partitions");
        }
    } else {
        if (args.length == 1) {
            error("Must specify at least one file on the volume");
        }
    }

    return options;
}

int main(string[] args)
{
    try {
        FSOptions options = getOptions(args);

        auto vfile = new File(options.volume, "rb");
        auto volume = new VDIDevice(vfile);
        auto table = readPartitionTable(volume);

        if (options.listPartitions) {
            foreach (partNum; 0 .. table.length) {
                auto part = table[partNum];
                string typeStr;
                switch (part.tblType) {
                case TableType.mbr:
                    typeStr = format("Type: %02X  Boot flag: %02X",
                            part.mbrType, part.mbrBootFlag);
                    break;

                case TableType.gpt:
                    typeStr = format("Type: %s Name: %s", part.gptType, part.gptName);
                    break;

                default:
                    assert(0);
                }
                writef("Partition %u: start=%u size=%u %s\n",
                        partNum + 1, part.start, part.size, typeStr);
            }
        } else {
            if (options.partitionNum == 0) {
                options.partitionNum = 1;
            }
            if (options.partitionNum > table.length) {
                error(format("Volume has only %u partition%s", table.length,
                            table.length == 1 ? "" : "s"));
            }
            auto fs = new FATFileSystem(volume, table[options.partitionNum-1]);
            foreach (arg; args[1 .. $]) {
                auto outname = baseName(arg);
                if (options.verbose) {
                    writef("%s => %s\n", arg, outname);
                }
                auto inpfile = fs.open(arg);
                auto outfile = new File(outname, "wb");
                while (true) {
                    ubyte[4096] buf;
                    auto r = inpfile.read(buf);
                    if (r.length == 0) {
                        break;
                    }
                    outfile.rawWrite(r);
                }
                inpfile.close();
            }
        }
    }
    catch (RuntimeException exc) {
        error(exc.message.idup);
    }

    return 0;
}
