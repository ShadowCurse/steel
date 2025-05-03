const std = @import("std");
const builtin = @import("builtin");
const log = @import("log.zig");
const sdl = @import("bindings/sdl.zig");
const gl = @import("bindings/gl.zig");
const cimgui = @import("bindings/cimgui.zig");

const WINDOW_WIDTH = 1280;
const WINDOW_HEIGHT = 720;
const OPENGL_VERSION = if (builtin.target.os.tag == .emscripten)
    "#version 100"
else
    "#version 450";

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
    _ = sdl.SDL_SetWindowResizable(window, false);

    const context = sdl.SDL_GL_CreateContext(window);
    _ = sdl.SDL_GL_MakeCurrent(window, context);

    if (!sdl.SDL_ShowWindow(window)) {
        log.err(@src(), "Cannot show a window: {s}", .{sdl.SDL_GetError()});
        return error.SDLShowWindow;
    }

    _ = cimgui.igCreateContext(null);
    _ = cimgui.ImGui_ImplSDL3_InitForOpenGL(@ptrCast(window), context);
    _ = cimgui.ImGui_ImplOpenGL3_Init(OPENGL_VERSION);

    gl.glViewport(0, 0, WINDOW_WIDTH, WINDOW_HEIGHT);

    const app = App.init();

    var stop: bool = false;
    while (!stop) {
        var sdl_event: sdl.SDL_Event = undefined;
        while (sdl.SDL_PollEvent(&sdl_event)) {
            _ = cimgui.ImGui_ImplSDL3_ProcessEvent(@ptrCast(&sdl_event));
            switch (sdl_event.type) {
                sdl.SDL_EVENT_QUIT => {
                    stop = true;
                },
                else => {},
            }
        }
        app.update();
        _ = sdl.SDL_GL_SwapWindow(window);
    }
}

const vertices = [_]f32{
    0.5,
    0.5,
    0.0,
    0.5,
    -0.5,
    0.0,
    -0.5,
    -0.5,
    0.0,
    -0.5,
    0.5,
    0.0,
};
const indices = [_]u32{
    0,
    1,
    3,
    1,
    2,
    3,
};

const vertex_shader_src: [*c]const u8 = if (builtin.target.os.tag == .emscripten)
    \\#version 100
    \\precision mediump float;
    \\
    \\attribute vec3 in_position;
    \\
    \\void main() {
    \\    gl_Position = vec4(in_position, 1.0);
    \\}
else
    \\#version 450
    \\
    \\layout (location = 0) in vec3 in_position;
    \\
    \\void main() {
    \\    gl_Position = vec4(in_position, 1.0);
    \\}
;

const fragment_shader_src: [*c]const u8 = if (builtin.target.os.tag == .emscripten)
    \\#version 100
    \\precision mediump float;
    \\
    \\void main() {
    \\    gl_FragColor = vec4(0.0, 1.0, 0.5, 1.0);
    \\}
else
    \\#version 450
    \\
    \\layout (location = 0) out vec4 out_color;
    \\
    \\void main() {
    \\    out_color = vec4(0.0, 1.0, 0.5, 1.0);
    \\}
;

pub fn check_shader_result(
    comptime src: std.builtin.SourceLocation,
    shader: u32,
    tag: u32,
) void {
    var success: i32 = undefined;
    gl.glGetShaderiv(shader, tag, &success);
    if (success != gl.GL_TRUE) {
        var buff: [1024]u8 = undefined;
        var s: i32 = undefined;
        gl.glGetShaderInfoLog(shader, 1024, &s, &buff);
        log.err(
            src,
            "error in shader: {s}({d})",
            .{ buff[0..@intCast(s)], s },
        );
    }
}

pub fn check_program_result(
    comptime src: std.builtin.SourceLocation,
    shader: u32,
    tag: u32,
) void {
    var success: i32 = undefined;
    gl.glGetProgramiv(shader, tag, &success);
    if (success != gl.GL_TRUE) {
        var buff: [1024]u8 = undefined;
        var s: i32 = undefined;
        gl.glGetProgramInfoLog(shader, 1024, &s, &buff);
        log.err(
            src,
            "error in shader: {s}({d})",
            .{ buff[0..@intCast(s)], s },
        );
    }
}

pub const App = struct {
    vertex_buffer: u32,
    index_buffer: u32,
    vertex_shader: u32,
    fragment_shader: u32,
    shader: u32,
    vertex_array: u32,

    const Self = @This();

    pub fn init() Self {
        const vertex_shader = gl.glCreateShader(gl.GL_VERTEX_SHADER);
        gl.glShaderSource(vertex_shader, 1, &vertex_shader_src, null);
        gl.glCompileShader(vertex_shader);
        check_shader_result(@src(), vertex_shader, gl.GL_COMPILE_STATUS);

        const fragment_shader = gl.glCreateShader(gl.GL_FRAGMENT_SHADER);
        gl.glShaderSource(fragment_shader, 1, &fragment_shader_src, null);
        gl.glCompileShader(fragment_shader);
        check_shader_result(@src(), fragment_shader, gl.GL_COMPILE_STATUS);

        const shader = gl.glCreateProgram();
        gl.glAttachShader(shader, vertex_shader);
        gl.glAttachShader(shader, fragment_shader);
        // gl.glBindAttribLocation(shader, 0, "in_position");
        gl.glLinkProgram(shader);
        check_program_result(@src(), shader, gl.GL_LINK_STATUS);

        var vertex_buffer: u32 = undefined;
        gl.glGenBuffers(1, &vertex_buffer);
        gl.glBindBuffer(gl.GL_ARRAY_BUFFER, vertex_buffer);
        gl.glBufferData(
            gl.GL_ARRAY_BUFFER,
            @sizeOf(@TypeOf(vertices)),
            &vertices,
            gl.GL_STATIC_DRAW,
        );

        var index_buffer: u32 = undefined;
        gl.glGenBuffers(1, &index_buffer);
        gl.glBindBuffer(gl.GL_ELEMENT_ARRAY_BUFFER, index_buffer);
        gl.glBufferData(
            gl.GL_ELEMENT_ARRAY_BUFFER,
            @sizeOf(@TypeOf(indices)),
            &indices,
            gl.GL_STATIC_DRAW,
        );

        var vertex_array: u32 = undefined;
        gl.glGenVertexArrays(1, &vertex_array);
        gl.glBindVertexArray(vertex_array);
        gl.glBindBuffer(gl.GL_ARRAY_BUFFER, vertex_buffer);
        gl.glBindBuffer(gl.GL_ELEMENT_ARRAY_BUFFER, index_buffer);
        gl.glVertexAttribPointer(
            0,
            3,
            gl.GL_FLOAT,
            gl.GL_FALSE,
            3 * @sizeOf(f32),
            @ptrFromInt(0),
        );
        gl.glEnableVertexAttribArray(0);

        return .{
            .vertex_buffer = vertex_buffer,
            .index_buffer = index_buffer,
            .vertex_shader = vertex_shader,
            .fragment_shader = fragment_shader,
            .shader = shader,
            .vertex_array = vertex_array,
        };
    }

    pub fn update(self: *const Self) void {
        cimgui.ImGui_ImplOpenGL3_NewFrame();
        cimgui.ImGui_ImplSDL3_NewFrame();
        cimgui.igNewFrame();
        var open: bool = true;
        cimgui.igShowDemoWindow(&open);
        cimgui.igRender();

        gl.glClearColor(1.0, 0.0, 0.0, 1.0);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);

        gl.glUseProgram(self.shader);
        gl.glBindVertexArray(self.vertex_array);
        gl.glDrawElements(gl.GL_TRIANGLES, indices.len, gl.GL_UNSIGNED_INT, null);

        const imgui_data = cimgui.igGetDrawData();
        cimgui.ImGui_ImplOpenGL3_RenderDrawData(imgui_data);
    }
};
