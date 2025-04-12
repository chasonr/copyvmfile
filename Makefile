# Makefile for copyvmfile
#
# Copyright © 2025 Ray Chason.
# 
# This file is part of copyvmfile.
# 
# copyvmfile is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the
# Free Software Foundation, in version 3 of the License.
# 
# copyvmfile is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
# more details.
# 
# You should have received a copy of the GNU General Public License
# along with copyvmfile; see the file LICENSE.  If not see
# <http://www.gnu.org/licenses/>.

OFILES = blockdevice.o fatfs.o filesys.o partition.o runtimeexc.o unicode.o \
         unpack.o vdidevice.o vmread.o 

EXE = copyvmfile

DC = gdc
DFLAGS = -Wall -O2

$(EXE) : $(OFILES)
	$(DC) -o $(EXE) $(OFILES)

blockdevice.o : blockdevice.d
	$(DC) $(DFLAGS) -c $< -o $@

fatfs.o : fatfs.d blockdevice.d filesys.d partition.d runtimeexc.d unicode.d unpack.d
	$(DC) $(DFLAGS) -c $< -o $@

filesys.o : filesys.d
	$(DC) $(DFLAGS) -c $< -o $@

partition.o : partition.d blockdevice.d unpack.d
	$(DC) $(DFLAGS) -c $< -o $@

runtimeexc.o : runtimeexc.d
	$(DC) $(DFLAGS) -c $< -o $@

unicode.o : unicode.d
	$(DC) $(DFLAGS) -c $< -o $@

unpack.o : unpack.d
	$(DC) $(DFLAGS) -c $< -o $@

vdidevice.o : vdidevice.d blockdevice.d runtimeexc.d unpack.d
	$(DC) $(DFLAGS) -c $< -o $@

vmread.o : vmread.d fatfs.d partition.d runtimeexc.d vdidevice.d
	$(DC) $(DFLAGS) -c $< -o $@
