const std = @import("std");
const builtin = @import("builtin");
const log = @import("log.zig");
const sdl = @import("bindings/sdl.zig");
const gl = @import("bindings/gl.zig");
const cimgui = @import("bindings/cimgui.zig");

const math = @import("math.zig");
const mesh = @import("mesh.zig");
const events = @import("events.zig");

const WINDOW_WIDTH = 1280;
const WINDOW_HEIGHT = 720;

pub const log_options = log.Options{
    .level = .Info,
    .colors = builtin.target.os.tag != .emscripten,
};

pub fn main() !void {
    sdl.assert(@src(), sdl.SDL_Init(sdl.SDL_INIT_AUDIO | sdl.SDL_INIT_VIDEO));

    // for 24bit depth
    sdl.assert(@src(), sdl.SDL_GL_SetAttribute(sdl.SDL_GL_DEPTH_SIZE, 24));

    const window = sdl.SDL_CreateWindow(
        "steel",
        WINDOW_WIDTH,
        WINDOW_HEIGHT,
        sdl.SDL_WINDOW_OPENGL,
    ) orelse {
        log.err(@src(), "Cannot create a window: {s}", .{sdl.SDL_GetError()});
        return error.SDLCreateWindow;
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

    gl.glViewport(0, 0, WINDOW_WIDTH, WINDOW_HEIGHT);

    var app = App.init();
    var stop: bool = false;

    var app_events: [events.MAX_EVENTS]events.Event = undefined;
    var sdl_events: [events.MAX_EVENTS]sdl.SDL_Event = undefined;

    var t = std.time.nanoTimestamp();
    while (!stop) {
        const new_t = std.time.nanoTimestamp();
        const dt = @as(f32, @floatFromInt(new_t - t)) / std.time.ns_per_s;
        t = new_t;

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

        const new_events = events.parse_sdl_events(new_sdl_events, &app_events);
        app.update(new_events, dt);

        sdl.assert(@src(), sdl.SDL_GL_SwapWindow(window));
    }
}

pub const Camera = struct {
    position: math.Vec3 = .{},
    pitch: f32 = 0.0,
    yaw: f32 = 0.0,
    fovy: f32 = std.math.pi / 2.0,
    near: f32 = 0.1,
    far: f32 = 10000.0,

    velocity: math.Vec3 = .{},
    speed: f32 = 5.0,
    active: bool = false,

    const ORIENTATION = math.Quat.from_rotation_axis(.X, .NEG_Z, .Y);
    const SENSITIVITY = 0.5;

    const Self = @This();

    pub fn process_input(self: *Self, event: events.Event, dt: f32) void {
        switch (event) {
            .Keyboard => |key| {
                const value: f32 = if (key.type == .Pressed) 1.0 else 0.0;
                switch (key.key) {
                    events.KeybordKeyScancode.W => self.velocity.z = value,
                    events.KeybordKeyScancode.S => self.velocity.z = -value,
                    events.KeybordKeyScancode.A => self.velocity.x = -value,
                    events.KeybordKeyScancode.D => self.velocity.x = value,
                    events.KeybordKeyScancode.SPACE => self.velocity.y = -value,
                    events.KeybordKeyScancode.LCTRL => self.velocity.y = value,
                    else => {},
                }
            },
            .Mouse => |mouse| {
                switch (mouse) {
                    .Button => |button| {
                        self.active = button.type == .Pressed;
                    },
                    .Motion => |motion| {
                        if (self.active) {
                            self.yaw -= motion.x * Self.SENSITIVITY * dt;
                            self.pitch -= motion.y * Self.SENSITIVITY * dt;
                            if (std.math.pi / 2.0 < self.pitch) {
                                self.pitch = std.math.pi / 2.0;
                            }
                            if (self.pitch < -std.math.pi / 2.0) {
                                self.pitch = -std.math.pi / 2.0;
                            }
                        }
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    pub fn move(self: *Self, dt: f32) void {
        const rotation = self.rotation_matrix();
        const velocity = self.velocity.mul_f32(self.speed * dt).extend(1.0);
        const delta = rotation.mul_vec4(velocity);
        self.position = self.position.add(delta.shrink());
    }

    pub fn transform(self: *const Self) math.Mat4 {
        return self.rotation_matrix().translate(self.position);
    }

    pub fn rotation_matrix(self: *const Self) math.Mat4 {
        const r_yaw = math.Quat.from_axis_angle(.Z, self.yaw);
        const r_pitch = math.Quat.from_axis_angle(.X, self.pitch);
        return r_yaw.mul(r_pitch).mul(Self.ORIENTATION).to_mat4();
    }

    pub fn projection(self: *const Self) math.Mat4 {
        var m = math.Mat4.perspective(
            self.fovy,
            @as(f32, @floatFromInt(WINDOW_WIDTH)) / @as(f32, @floatFromInt(WINDOW_HEIGHT)),
            self.near,
            self.far,
        );
        // flip Y for opengl
        m.j.y *= -1.0;
        return m;
    }
};

pub const PAGE_SIZE = std.heap.page_size_min;
pub const FileMem = struct {
    mem: []align(PAGE_SIZE) u8,

    const Self = @This();

    pub fn init(path: []const u8) !Self {
        const fd = try std.posix.open(path, .{ .ACCMODE = .RDONLY }, 0);
        defer std.posix.close(fd);

        const stat = try std.posix.fstat(fd);
        const mem = try std.posix.mmap(
            null,
            @intCast(stat.size),
            std.posix.PROT.READ,
            .{ .TYPE = .PRIVATE },
            fd,
            0,
        );
        return .{
            .mem = mem,
        };
    }

    pub fn deinit(self: Self) void {
        std.posix.munmap(self.mem);
    }
};

pub const Shader = struct {
    vertex_shader: u32,
    fragment_shader: u32,
    shader: u32,

    const Self = @This();

    pub fn init(vertex_shader_path: []const u8, fragment_shader_path: []const u8) Self {
        const vertex_shader_src =
            FileMem.init(vertex_shader_path) catch @panic("cannot read vertex shader");
        defer vertex_shader_src.deinit();

        const fragment_shader_src =
            FileMem.init(fragment_shader_path) catch @panic("cannot read fragment shader");
        defer fragment_shader_src.deinit();

        const vertex_shader = gl.glCreateShader(gl.GL_VERTEX_SHADER);
        const v_ptr = [_]*const u8{@ptrCast(vertex_shader_src.mem.ptr)};
        const v_len: i32 = @intCast(vertex_shader_src.mem.len);
        gl.glShaderSource(
            vertex_shader,
            1,
            @ptrCast(&v_ptr),
            @ptrCast(&v_len),
        );
        gl.glCompileShader(vertex_shader);
        check_shader_result(@src(), vertex_shader, gl.GL_COMPILE_STATUS);

        const fragment_shader = gl.glCreateShader(gl.GL_FRAGMENT_SHADER);
        const f_ptr = [_]*const u8{@ptrCast(fragment_shader_src.mem.ptr)};
        const f_len: i32 = @intCast(fragment_shader_src.mem.len);
        gl.glShaderSource(
            fragment_shader,
            1,
            @ptrCast(&f_ptr),
            @ptrCast(&f_len),
        );
        gl.glCompileShader(fragment_shader);
        check_shader_result(@src(), fragment_shader, gl.GL_COMPILE_STATUS);

        const shader = gl.glCreateProgram();
        gl.glAttachShader(shader, vertex_shader);
        gl.glAttachShader(shader, fragment_shader);
        gl.glLinkProgram(shader);
        check_program_result(@src(), shader, gl.GL_LINK_STATUS);

        return .{
            .vertex_shader = vertex_shader,
            .fragment_shader = fragment_shader,
            .shader = shader,
        };
    }

    pub fn get_uniform_location(self: *const Self, name: [*c]const u8) i32 {
        return gl.glGetUniformLocation(self.shader, name);
    }

    pub fn use(self: *const Self) void {
        gl.glUseProgram(self.shader);
    }

    fn check_shader_result(
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
            log.assert(
                src,
                false,
                "error in shader: {s}({d})",
                .{ buff[0..@intCast(s)], s },
            );
        }
    }

    fn check_program_result(
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
            log.assert(
                src,
                false,
                "error in shader: {s}({d})",
                .{ buff[0..@intCast(s)], s },
            );
        }
    }
};

pub const App = struct {
    vertex_buffer: u32,
    index_buffer: u32,
    mesh_shader: Shader,
    vertex_array: u32,
    grid_buffer: u32,
    grid_vertex_array: u32,
    grid_shader: Shader,

    camera: Camera,

    const Self = @This();

    pub fn init() Self {
        const mesh_shader = if (builtin.target.os.tag == .emscripten)
            Shader.init("resources/shaders/mesh_web.vert", "resources/shaders/mesh_web.frag")
        else
            Shader.init("resources/shaders/mesh.vert", "resources/shaders/mesh.frag");

        const grid_shader = if (builtin.target.os.tag == .emscripten)
            Shader.init("resources/shaders/grid_web.vert", "resources/shaders/grid_web.frag")
        else
            Shader.init("resources/shaders/grid.vert", "resources/shaders/grid.frag");

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

        const grid_planes = [_]math.Vec3{
            math.Vec3{ .x = 1, .y = 1, .z = 0 },
            math.Vec3{ .x = -1, .y = -1, .z = 0 },
            math.Vec3{ .x = -1, .y = 1, .z = 0 },
            math.Vec3{ .x = -1, .y = -1, .z = 0 },
            math.Vec3{ .x = 1, .y = 1, .z = 0 },
            math.Vec3{ .x = 1, .y = -1, .z = 0 },
        };
        var grid_buffer: u32 = undefined;
        gl.glGenBuffers(1, &grid_buffer);
        gl.glBindBuffer(gl.GL_ARRAY_BUFFER, grid_buffer);
        gl.glBufferData(
            gl.GL_ARRAY_BUFFER,
            @sizeOf(@TypeOf(grid_planes)),
            &grid_planes,
            gl.GL_STATIC_DRAW,
        );

        var vertex_array: u32 = undefined;
        gl.glGenVertexArrays(1, &vertex_array);
        gl.glBindVertexArray(vertex_array);
        gl.glBindBuffer(gl.GL_ARRAY_BUFFER, vertex_buffer);
        gl.glBindBuffer(gl.GL_ELEMENT_ARRAY_BUFFER, index_buffer);
        mesh.MeshVertex.set_attributes();

        var grid_vertex_array: u32 = undefined;
        gl.glGenVertexArrays(1, &grid_vertex_array);
        gl.glBindVertexArray(grid_vertex_array);
        gl.glBindBuffer(gl.GL_ARRAY_BUFFER, grid_buffer);
        gl.glVertexAttribPointer(0, 3, gl.GL_FLOAT, gl.GL_FALSE, @sizeOf(math.Vec3), @ptrFromInt(0));
        gl.glEnableVertexAttribArray(0);

        // gl.glClipControl(gl.GL_LOWER_LEFT, gl.GL_ZERO_TO_ONE);
        gl.glEnable(gl.GL_DEPTH_TEST);
        gl.glEnable(gl.GL_BLEND);
        gl.glDepthFunc(gl.GL_GEQUAL);
        gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);

        const camera: Camera = .{ .position = .{ .y = -10.0 } };

        return .{
            .vertex_buffer = vertex_buffer,
            .index_buffer = index_buffer,
            .mesh_shader = mesh_shader,
            .grid_buffer = grid_buffer,
            .grid_vertex_array = grid_vertex_array,
            .grid_shader = grid_shader,
            .vertex_array = vertex_array,
            .camera = camera,
        };
    }

    pub fn update(self: *Self, new_events: []const events.Event, dt: f32) void {
        for (new_events) |event|
            self.camera.process_input(event, dt);
        self.camera.move(dt);

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
        {
            const view_loc = self.mesh_shader.get_uniform_location("view");
            const projection_loc = self.mesh_shader.get_uniform_location("projection");
            const model_loc = self.mesh_shader.get_uniform_location("model");

            self.mesh_shader.use();
            gl.glUniformMatrix4fv(view_loc, 1, gl.GL_FALSE, @ptrCast(&camera_view));
            gl.glUniformMatrix4fv(projection_loc, 1, gl.GL_FALSE, @ptrCast(&camera_projection));
            gl.glUniformMatrix4fv(model_loc, 1, gl.GL_FALSE, @ptrCast(&model));
            gl.glBindVertexArray(self.vertex_array);
            gl.glDrawElements(gl.GL_TRIANGLES, mesh.Cube.INDICES.len, gl.GL_UNSIGNED_INT, null);
        }

        {
            const view_loc = self.grid_shader.get_uniform_location("view");
            const projection_loc = self.grid_shader.get_uniform_location("projection");

            self.grid_shader.use();
            gl.glUniformMatrix4fv(view_loc, 1, gl.GL_FALSE, @ptrCast(&camera_view));
            gl.glUniformMatrix4fv(projection_loc, 1, gl.GL_FALSE, @ptrCast(&camera_projection));

            if (builtin.target.os.tag == .emscripten) {
                const inverse_view_loc = self.grid_shader.get_uniform_location("inverse_view");
                const inverse_projection_loc = self.grid_shader.get_uniform_location("inverse_projection");
                const inverse_camera_view = camera_view.inverse();
                const inverse_camera_projection = camera_projection.inverse();
                gl.glUniformMatrix4fv(inverse_view_loc, 1, gl.GL_FALSE, @ptrCast(&inverse_camera_view));
                gl.glUniformMatrix4fv(inverse_projection_loc, 1, gl.GL_FALSE, @ptrCast(&inverse_camera_projection));
                gl.glBindVertexArray(self.grid_vertex_array);
            }

            gl.glDrawArrays(gl.GL_TRIANGLES, 0, 6);
        }

        const imgui_data = cimgui.igGetDrawData();
        cimgui.ImGui_ImplOpenGL3_RenderDrawData(imgui_data);
    }
};
