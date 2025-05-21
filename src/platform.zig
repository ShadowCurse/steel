const std = @import("std");
const builtin = @import("builtin");
const log = @import("log.zig");
const sdl = @import("bindings/sdl.zig");
const gl = @import("bindings/gl.zig");
const cimgui = @import("bindings/cimgui.zig");
const events = @import("events.zig");

pub const WINDOW_WIDTH = 1280;
pub const WINDOW_HEIGHT = 720;

pub var window: *sdl.SDL_Window = undefined;
pub var imgui_io: *cimgui.ImGuiIO = undefined;

pub var app_events: [events.MAX_EVENTS]events.Event = undefined;
pub var sdl_events: [events.MAX_EVENTS]sdl.SDL_Event = undefined;

pub var mouse_position: events.MousePosition = .{};
pub var input_events: []events.Event = &.{};
pub var stop: bool = false;

pub fn init() void {
    sdl.assert(@src(), sdl.SDL_Init(sdl.SDL_INIT_AUDIO | sdl.SDL_INIT_VIDEO));

    // for 24bit depth
    sdl.assert(@src(), sdl.SDL_GL_SetAttribute(sdl.SDL_GL_DEPTH_SIZE, 24));

    window = sdl.SDL_CreateWindow(
        "steel",
        WINDOW_WIDTH,
        WINDOW_HEIGHT,
        sdl.SDL_WINDOW_OPENGL,
    ) orelse {
        log.assert(@src(), false, "Cannot create a window: {s}", .{sdl.SDL_GetError()});
        unreachable;
    };

    sdl.assert(@src(), sdl.SDL_SetWindowResizable(window, false));

    const context = sdl.SDL_GL_CreateContext(window);
    sdl.assert(@src(), sdl.SDL_GL_MakeCurrent(window, context));

    log.info(@src(), "Vendor graphic card: {s}", .{gl.glGetString(gl.GL_VENDOR)});
    log.info(@src(), "Renderer: {s}", .{gl.glGetString(gl.GL_RENDERER)});
    log.info(@src(), "Version GL: {s}", .{gl.glGetString(gl.GL_VERSION)});
    log.info(@src(), "Version GLSL: {s}", .{gl.glGetString(gl.GL_SHADING_LANGUAGE_VERSION)});

    sdl.assert(@src(), sdl.SDL_ShowWindow(window));

    _ = cimgui.igCreateContext(null);
    _ = cimgui.ImGui_ImplSDL3_InitForOpenGL(@ptrCast(window), context);
    const cimgli_opengl_version = if (builtin.target.os.tag == .emscripten)
        "#version 100"
    else
        "#version 450";
    _ = cimgui.ImGui_ImplOpenGL3_Init(cimgli_opengl_version);
    imgui_io = @ptrCast(cimgui.igGetIO_Nil());

    gl.glViewport(0, 0, WINDOW_WIDTH, WINDOW_HEIGHT);

    if (builtin.target.os.tag != .emscripten)
        gl.glClipControl(gl.GL_LOWER_LEFT, gl.GL_ZERO_TO_ONE);

    gl.glEnable(gl.GL_DEPTH_TEST);
    gl.glEnable(gl.GL_BLEND);
    gl.glEnable(gl.GL_CULL_FACE);
    gl.glDepthFunc(gl.GL_GEQUAL);
    gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);
}

pub fn process_events() void {
    const new_sdl_events = events.get_sdl_events(&sdl_events);
    for (new_sdl_events) |*sdl_event| {
        _ = cimgui.ImGui_ImplSDL3_ProcessEvent(@ptrCast(sdl_event));
        switch (sdl_event.type) {
            sdl.SDL_EVENT_QUIT => {
                stop = true;
            },
            else => {},
        }
    }
    mouse_position = events.get_mouse_pos();
    input_events = events.parse_sdl_events(new_sdl_events, &app_events);
}

pub fn imgui_wants_to_handle_events() bool {
    return imgui_io.WantCaptureMouse or
        imgui_io.WantCaptureKeyboard or
        imgui_io.WantTextInput;
}

pub fn present() void {
    sdl.assert(@src(), sdl.SDL_GL_SwapWindow(window));
}
