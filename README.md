# steel

## Build on linux
Update submodules:
```bash
$ git submodule update --init --recursive
```

Patch cimgui:
```bash
$ cd thirdparty/cimgui/imgui
$ git apply ../../../imgui.diff 
```
This is needed for imgui to export backend functions (SDL3 + OpenGl in this case).

Build and run native
```bash
$ zig build run
```

Build for web. Needs [`emsdk`](https://github.com/emscripten-core/emsdk)
```bash
$ zig build -Dtarget=wasm32-emscripten --sysroot "emsdk/upstream/emscripten" -Doptimize=ReleaseFast
$ bash wasm.sh
```
