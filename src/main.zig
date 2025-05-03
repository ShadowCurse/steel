const std = @import("std");
const log = @import("log.zig");
const sdl = @import("bindings/sdl.zig");
const gl = @import("bindings/gl.zig");

const WINDOW_WIDTH = 1280;
const WINDOW_HEIGHT = 720;

pub fn main() !void {
    if (!sdl.SDL_Init(sdl.SDL_INIT_AUDIO)) {
        log.err(@src(), "Cannot init SDL: {s}", .{sdl.SDL_GetError()});
        return error.SDLInit;
    }
    const window = sdl.SDL_CreateWindow(
        "stygian",
        WINDOW_WIDTH,
        WINDOW_HEIGHT,
        sdl.SDL_INIT_VIDEO | sdl.SDL_WINDOW_OPENGL,
    ) orelse {
        log.err(@src(), "Cannot create a window: {s}", .{sdl.SDL_GetError()});
        return error.SDLCreateWindow;
    };

    const context = sdl.SDL_GL_CreateContext(window);
    _ = sdl.SDL_GL_MakeCurrent(window, context);

    if (!sdl.SDL_ShowWindow(window)) {
        log.err(@src(), "Cannot show a window: {s}", .{sdl.SDL_GetError()});
        return error.SDLShowWindow;
    }

    var stop: bool = false;
    while (!stop) {
        var sdl_event: sdl.SDL_Event = undefined;
        while (sdl.SDL_PollEvent(&sdl_event)) {
            switch (sdl_event.type) {
                sdl.SDL_EVENT_QUIT => {
                    stop = true;
                },
                else => {},
            }
        }

        gl.glClearColor(1.0, 0.0, 0.0, 1.0);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);
        _ = sdl.SDL_GL_SwapWindow(window);
    }
}
