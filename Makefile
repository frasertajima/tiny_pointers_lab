# Tiny Pointers GPU benchmark (CUDA Fortran / nvfortran)
# RTX A1000 is compute capability 8.6
NVFORTRAN ?= nvfortran
GPUARCH   ?= cc86
FLAGS     = -cuda -gpu=$(GPUARCH) -O3

all: hashbench tinyfull joindemo kvpage succinctbst stabledict spacedict

hashbench: hashbench.cuf
	$(NVFORTRAN) $(FLAGS) -o $@ $<

tinyfull: tinyfull.cuf
	$(NVFORTRAN) $(FLAGS) -o $@ $<

joindemo: tinymap.cuf joindemo.cuf
	$(NVFORTRAN) $(FLAGS) -o $@ tinymap.cuf joindemo.cuf

kvpage: tinymap.cuf kvpage.cuf
	$(NVFORTRAN) $(FLAGS) -o $@ tinymap.cuf kvpage.cuf

# --- the paper's five applications (succinctbst is self-contained) ---
succinctbst: succinctbst.cuf
	$(NVFORTRAN) $(FLAGS) -o $@ $<

stabledict: tinymap.cuf stabledict.cuf
	$(NVFORTRAN) $(FLAGS) -o $@ tinymap.cuf stabledict.cuf

spacedict: tinymap.cuf spacedict.cuf
	$(NVFORTRAN) $(FLAGS) -o $@ tinymap.cuf spacedict.cuf

run: hashbench
	./hashbench

clean:
	rm -f hashbench tinyfull joindemo kvpage succinctbst stabledict spacedict *.mod

.PHONY: run clean
