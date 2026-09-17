#!/usr/bin/env bash
set -euo pipefail
trap 'rm -f apply.o apply.out' EXIT
${CC:-cc} -O2 -I "$(lean --print-prefix)/include" -c apply.c -o apply.o
leanc -o apply.out apply.o
./apply.out
