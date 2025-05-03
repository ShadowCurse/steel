#!/bin/bash

cd wasm

emcc \
  -sFULL-ES3=1 \
  -sASSERTIONS=1 \
  -sMALLOC='dlmalloc' \
  -sFORCE_FILESYSTEM=1 \
  -sUSE_OFFSET_CONVERTER=1 \
  -sGL_ENABLE_GET_PROC_ADDRESS \
  -sEXPORTED_RUNTIME_METHODS=ccall \
  -sEXPORTED_RUNTIME_METHODS=cwrap \
  -sALLOW_MEMORY_GROWTH=1 \
  -sSTACK_SIZE=1mb \
  -sABORTING_MALLOC=0 \
  -sASYNCIFY \
  --emrun \
  ../zig-out/lib/* \
  ../../SDL/build/libSDL3.a \
  -o \
  steel.js

