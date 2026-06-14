# TINYJOIN -- tiny-pointer hash join demo (IBM COBOL for Linux)
# Run from the cobol/ directory: make run
COBCMD = cob2
COBFLAGS =

# IBM STL plumbing flags (harmless for LINE SEQUENTIAL; kept for parity
# with the rest of the COBOL suite).
COBENV = VFS_IO_AIO=0 VFS_IO_DIO=0 VFS_IO_CACHE=1 VFS_IO_THREAD=0

.PHONY: all run run-join run-dict clean

all: tinyjoin dictenc

tinyjoin: cbl/TINYJOIN.cbl
	$(COBCMD) $(COBFLAGS) -o tinyjoin cbl/TINYJOIN.cbl

dictenc: cbl/DICTENC.cbl
	$(COBCMD) $(COBFLAGS) -o dictenc cbl/DICTENC.cbl

run: run-join run-dict

run-join: tinyjoin
	mkdir -p data
	$(COBENV) ./tinyjoin

run-dict: dictenc
	mkdir -p data
	$(COBENV) ./dictenc

clean:
	rm -f tinyjoin dictenc \
	      data/CUSTOMER.DAT data/ORDERS.DAT data/JOINED.DAT \
	      data/COLUMN.DAT data/ENCODED.DAT
