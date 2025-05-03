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

Build and run
```bash
$ zig build run
```
