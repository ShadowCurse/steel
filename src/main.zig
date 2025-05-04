const std = @import("std");
const builtin = @import("builtin");
const log = @import("log.zig");
const sdl = @import("bindings/sdl.zig");
const gl = @import("bindings/gl.zig");
const cimgui = @import("bindings/cimgui.zig");

const math = @import("math.zig");
const mesh = @import("mesh.zig");

const WINDOW_WIDTH = 1280;
const WINDOW_HEIGHT = 720;

pub const log_options = log.Options{
    .level = .Info,
    .colors = builtin.target.os.tag != .emscripten,
};

pub fn main() !void {
    if (!sdl.SDL_Init(sdl.SDL_INIT_AUDIO)) {
        log.err(@src(), "Cannot init SDL: {s}", .{sdl.SDL_GetError()});
        return error.SDLInit;
    }

    // for 32bit depth
    _ = sdl.SDL_GL_SetAttribute(sdl.SDL_GL_DEPTH_SIZE, 32);

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

    const cimgli_opengl_version = if (builtin.target.os.tag == .emscripten)
        "#version 100"
    else
        "#version 450";
    _ = cimgui.ImGui_ImplOpenGL3_Init(cimgli_opengl_version);

    gl.glViewport(0, 0, WINDOW_WIDTH, WINDOW_HEIGHT);

    var app = App.init();
    var stop: bool = false;

    var t = std.time.nanoTimestamp();
    while (!stop) {
        const new_t = std.time.nanoTimestamp();
        const dt = @as(f32, @floatFromInt(new_t - t)) / std.time.ns_per_s;
        t = new_t;

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
        app.update(dt);
        _ = sdl.SDL_GL_SwapWindow(window);
    }
}

const vertex_shader_src: [*c]const u8 = if (builtin.target.os.tag == .emscripten)
    \\#version 100
    \\precision mediump float;
    \\
    \\attribute vec3 in_position;
    \\attribute float in_uv_x;
    \\attribute vec3 in_normal;
    \\attribute float in_uv_y;
    \\attribute vec4 in_color;
    \\
    \\varying vec4 frag_color;
    \\varying vec3 normal;
    \\varying vec2 uv;
    \\
    \\uniform mat4 projection;
    \\uniform mat4 view;
    \\uniform mat4 model;
    \\
    \\void main() {
    \\    gl_Position = projection * view * model * vec4(in_position, 1.0);
    \\    frag_color = in_color;
    \\    normal = in_normal;
    \\    uv = vec2(in_uv_x, in_uv_y);
    \\}
else
    \\#version 450
    \\
    \\layout (location = 0) in vec3 in_position;
    \\layout (location = 1) in float in_uv_x;
    \\layout (location = 2) in vec3 in_normal;
    \\layout (location = 3) in float in_uv_y;
    \\layout (location = 4) in vec4 in_color;
    \\
    \\layout (location = 5) out vec4 out_color;
    \\
    \\uniform mat4 projection;
    \\uniform mat4 view;
    \\uniform mat4 model;
    \\
    \\void main() {
    \\    gl_Position = projection * view * model * vec4(in_position, 1.0);
    \\    out_color = in_color;
    \\}
;

const fragment_shader_src: [*c]const u8 = if (builtin.target.os.tag == .emscripten)
    \\#version 100
    \\precision mediump float;
    \\
    \\varying vec4 frag_color;
    \\
    \\void main() {
    \\    gl_FragColor = abs(frag_color);
    \\}
else
    \\#version 450
    \\
    \\layout (location = 5) in vec4 in_color;
    \\
    \\layout (location = 0) out vec4 out_color;
    \\
    \\void main() {
    \\    out_color = abs(in_color);
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

pub const Camera = struct {
    position: math.Vec3 = .{},
    pitch: f32 = 0.0,
    yaw: f32 = 0.0,
    fovy: f32 = std.math.pi / 2.0,
    near: f32 = 0.1,
    far: f32 = 10000.0,

    const ORIENTATION = math.Quat.from_rotation_axis(.X, .NEG_Z, .Y);

    const Self = @This();

    pub fn transform(self: *const Self) math.Mat4 {
        return self.rotation_matrix().translate(self.position);
    }

    pub fn rotation_matrix(self: *const Self) math.Mat4 {
        const r_yaw = math.Quat.from_axis_angle(.Z, self.yaw);
        const r_pitch = math.Quat.from_axis_angle(.X, self.pitch);
        return r_yaw.mul(r_pitch).mul(Self.ORIENTATION).to_mat4();
    }

    pub fn projection(self: *const Self) math.Mat4 {
        return math.Mat4.perspective(
            self.fovy,
            @as(f32, @floatFromInt(WINDOW_WIDTH)) / @as(f32, @floatFromInt(WINDOW_HEIGHT)),
            self.near,
            self.far,
        );
    }
};

pub const App = struct {
    vertex_buffer: u32,
    index_buffer: u32,
    vertex_shader: u32,
    fragment_shader: u32,
    shader: u32,
    vertex_array: u32,
    camera: Camera,

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
        gl.glLinkProgram(shader);
        check_program_result(@src(), shader, gl.GL_LINK_STATUS);

        var vertex_buffer: u32 = undefined;
        gl.glGenBuffers(1, &vertex_buffer);
        gl.glBindBuffer(gl.GL_ARRAY_BUFFER, vertex_buffer);
        gl.glBufferData(
            gl.GL_ARRAY_BUFFER,
            @sizeOf(@TypeOf(mesh.Cube.VERTICES)),
            &mesh.Cube.VERTICES,
            gl.GL_STATIC_DRAW,
        );

        var index_buffer: u32 = undefined;
        gl.glGenBuffers(1, &index_buffer);
        gl.glBindBuffer(gl.GL_ELEMENT_ARRAY_BUFFER, index_buffer);
        gl.glBufferData(
            gl.GL_ELEMENT_ARRAY_BUFFER,
            @sizeOf(@TypeOf(mesh.Cube.INDICES)),
            &mesh.Cube.INDICES,
            gl.GL_STATIC_DRAW,
        );

        var vertex_array: u32 = undefined;
        gl.glGenVertexArrays(1, &vertex_array);
        gl.glBindVertexArray(vertex_array);
        gl.glBindBuffer(gl.GL_ARRAY_BUFFER, vertex_buffer);
        gl.glBindBuffer(gl.GL_ELEMENT_ARRAY_BUFFER, index_buffer);

        gl.glVertexAttribPointer(0, 3, gl.GL_FLOAT, gl.GL_FALSE, @sizeOf(mesh.MeshVertex), @ptrFromInt(0));
        gl.glVertexAttribPointer(1, 1, gl.GL_FLOAT, gl.GL_FALSE, @sizeOf(mesh.MeshVertex), @ptrFromInt(3 * @sizeOf(f32)));
        gl.glVertexAttribPointer(2, 3, gl.GL_FLOAT, gl.GL_FALSE, @sizeOf(mesh.MeshVertex), @ptrFromInt(4 * @sizeOf(f32)));
        gl.glVertexAttribPointer(3, 1, gl.GL_FLOAT, gl.GL_FALSE, @sizeOf(mesh.MeshVertex), @ptrFromInt(7 * @sizeOf(f32)));
        gl.glVertexAttribPointer(4, 4, gl.GL_FLOAT, gl.GL_FALSE, @sizeOf(mesh.MeshVertex), @ptrFromInt(8 * @sizeOf(f32)));
        gl.glEnableVertexAttribArray(0);
        gl.glEnableVertexAttribArray(1);
        gl.glEnableVertexAttribArray(2);
        gl.glEnableVertexAttribArray(3);
        gl.glEnableVertexAttribArray(4);

        // gl.glClipControl(gl.GL_LOWER_LEFT, gl.GL_ZERO_TO_ONE);
        gl.glEnable(gl.GL_DEPTH_TEST);
        gl.glDepthFunc(gl.GL_GEQUAL);

        const camera: Camera = .{ .position = .{ .y = -10.0 } };

        return .{
            .vertex_buffer = vertex_buffer,
            .index_buffer = index_buffer,
            .vertex_shader = vertex_shader,
            .fragment_shader = fragment_shader,
            .shader = shader,
            .vertex_array = vertex_array,
            .camera = camera,
        };
    }

    pub fn update(self: *Self, dt: f32) void {
        cimgui.ImGui_ImplOpenGL3_NewFrame();
        cimgui.ImGui_ImplSDL3_NewFrame();
        cimgui.igNewFrame();

        {
            var open: bool = true;
            _ = cimgui.igBegin("options", &open, 0);
            defer cimgui.igEnd();

            _ = cimgui.igSliderFloat3(
                "camera position",
                @ptrCast(&self.camera.position),
                -100.0,
                100.0,
                null,
                0,
            );
        }
        cimgui.igRender();

        gl.glClearDepth(0.0);
        gl.glClearColor(0.0, 0.0, 0.0, 1.0);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT | gl.GL_DEPTH_BUFFER_BIT);

        const camera_view = self.camera.transform().inverse();
        const camera_projection = self.camera.projection();
        const A = struct {
            var t: f32 = 0.0;
        };
        A.t += 0.5 * dt;
        const model = math.Mat4.rotation_z(A.t);
        const view_loc = gl.glGetUniformLocation(self.shader, "view");
        const projection_loc = gl.glGetUniformLocation(self.shader, "projection");
        const model_loc = gl.glGetUniformLocation(self.shader, "model");

        gl.glUseProgram(self.shader);
        gl.glUniformMatrix4fv(view_loc, 1, gl.GL_FALSE, @ptrCast(&camera_view));
        gl.glUniformMatrix4fv(projection_loc, 1, gl.GL_FALSE, @ptrCast(&camera_projection));
        gl.glUniformMatrix4fv(model_loc, 1, gl.GL_FALSE, @ptrCast(&model));
        gl.glBindVertexArray(self.vertex_array);
        gl.glDrawElements(gl.GL_TRIANGLES, mesh.Cube.INDICES.len, gl.GL_UNSIGNED_INT, null);

        const imgui_data = cimgui.igGetDrawData();
        cimgui.ImGui_ImplOpenGL3_RenderDrawData(imgui_data);
    }
};
