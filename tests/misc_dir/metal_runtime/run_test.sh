leanc -O2 -o runtime.out runtime.c
LEAN_METAL=0 ./runtime.out
LEAN_METAL=1 ./runtime.out
