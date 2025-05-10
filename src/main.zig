const std = @import("std");
const builtin = @import("builtin");
const log = @import("log.zig");
const sdl = @import("bindings/sdl.zig");
const gl = @import("bindings/gl.zig");
const cimgui = @import("bindings/cimgui.zig");

const math = @import("math.zig");
const mesh = @import("mesh.zig");
const events = @import("events.zig");

const rendering = @import("rendering.zig");
const Shader = rendering.Shader;
const Mesh = rendering.Mesh;
const Grid = rendering.Grid;

const Allocator = std.mem.Allocator;
const DebugAllocator = std.heap.DebugAllocator(.{});

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
    const imgui_io = &cimgui.igGetIO_Nil()[0];

    gl.glViewport(0, 0, WINDOW_WIDTH, WINDOW_HEIGHT);

    if (builtin.target.os.tag != .emscripten)
        gl.glClipControl(gl.GL_LOWER_LEFT, gl.GL_ZERO_TO_ONE);

    gl.glEnable(gl.GL_DEPTH_TEST);
    gl.glEnable(gl.GL_BLEND);
    gl.glEnable(gl.GL_CULL_FACE);
    gl.glDepthFunc(gl.GL_GEQUAL);
    gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);

    var gpa = DebugAllocator{};
    const allocator = gpa.allocator();

    var app = App.init(allocator);
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
        const mouse_pos = events.get_mouse_pos();
        const new_events =
            if (imgui_io.WantCaptureMouse or
            imgui_io.WantCaptureKeyboard or
            imgui_io.WantTextInput)
                &.{}
            else
                events.parse_sdl_events(new_sdl_events, &app_events);
        try app.update(new_events, mouse_pos, dt);

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

    zoom: f32 = 50.0,

    velocity: math.Vec3 = .{},
    speed: f32 = 5.0,
    active: bool = false,
    top_down: bool = false,

    view: math.Mat4 = .{},
    projection: math.Mat4 = .{},
    inverse_view: math.Mat4 = .{},
    inverse_projection: math.Mat4 = .{},

    const ORIENTATION = math.Quat.from_rotation_axis(.X, .NEG_Z, .Y);
    const SENSITIVITY = 0.5;
    const ORTHO_DEPTH = 100.0;

    const Self = @This();

    pub fn process_input(self: *Self, event: events.Event, dt: f32) void {
        switch (event) {
            .Keyboard => |key| {
                const value: f32 = if (key.type == .Pressed) 1.0 else 0.0;
                if (self.top_down) {
                    switch (key.key) {
                        events.KeybordKeyScancode.W => self.velocity.y = -value,
                        events.KeybordKeyScancode.S => self.velocity.y = value,
                        events.KeybordKeyScancode.A => self.velocity.x = -value,
                        events.KeybordKeyScancode.D => self.velocity.x = value,
                        else => {},
                    }
                } else {
                    switch (key.key) {
                        events.KeybordKeyScancode.W => self.velocity.z = value,
                        events.KeybordKeyScancode.S => self.velocity.z = -value,
                        events.KeybordKeyScancode.A => self.velocity.x = -value,
                        events.KeybordKeyScancode.D => self.velocity.x = value,
                        events.KeybordKeyScancode.SPACE => self.velocity.y = -value,
                        events.KeybordKeyScancode.LCTRL => self.velocity.y = value,
                        else => {},
                    }
                }
            },
            .Mouse => |mouse| {
                switch (mouse) {
                    .Button => |button| {
                        self.active = button.type == .Pressed;
                    },
                    .Motion => |motion| {
                        if (self.active) {
                            if (self.top_down) {
                                self.position.x -= motion.x * Self.SENSITIVITY * dt;
                                self.position.y += motion.y * Self.SENSITIVITY * dt;
                            } else {
                                self.yaw -= motion.x * Self.SENSITIVITY * dt;
                                self.pitch -= motion.y * Self.SENSITIVITY * dt;
                                if (std.math.pi / 2.0 < self.pitch) {
                                    self.pitch = std.math.pi / 2.0;
                                }
                                if (self.pitch < -std.math.pi / 2.0) {
                                    self.pitch = -std.math.pi / 2.0;
                                }
                            }
                        }
                    },
                    .Wheel => |wheel| {
                        if (self.top_down)
                            self.position.z -= wheel.amount * Self.SENSITIVITY * 50.0 * dt;
                    },
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

        self.inverse_view = self.transform();
        self.view = self.inverse_view.inverse();
        if (self.top_down)
            self.projection = self.orthogonal()
        else
            self.projection = self.perspective();
        self.inverse_projection = self.projection.inverse();
    }

    pub fn transform(self: *const Self) math.Mat4 {
        return self.rotation_matrix().translate(self.position);
    }

    pub fn rotation_matrix(self: *const Self) math.Mat4 {
        const r_yaw = math.Quat.from_axis_angle(.Z, self.yaw);
        const r_pitch = math.Quat.from_axis_angle(.X, self.pitch);
        return r_yaw.mul(r_pitch).mul(Self.ORIENTATION).to_mat4();
    }

    pub fn perspective(self: *const Self) math.Mat4 {
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

    pub fn orthogonal(self: *const Self) math.Mat4 {
        const width: f32 = @as(f32, WINDOW_WIDTH) / self.zoom;
        const height: f32 = @as(f32, WINDOW_HEIGHT) / self.zoom;
        var m = math.Mat4.orthogonal(
            width,
            height,
            Self.ORTHO_DEPTH,
        );
        // flip Y for opengl
        m.j.y *= -1.0;
        return m;
    }

    pub fn mouse_to_xy(self: *const Self, mouse_pos: math.Vec3) math.Vec3 {
        if (self.top_down) {
            return self.inverse_view
                .mul(self.inverse_projection)
                .mul_vec4(mouse_pos.extend(1.0))
                .shrink();
        } else {
            const world_near =
                self.inverse_view.mul(self.inverse_projection).mul_vec4(mouse_pos.extend(1.0));
            const world_near_world = world_near.shrink().div_f32(world_near.w);
            const forward = world_near_world.sub(self.position).normalize();
            const t = -self.position.z / forward.z;
            const xy = self.position.add(forward.mul_f32(t));
            return xy;
        }
    }

    pub fn imgui_options(self: *Self) void {
        _ = cimgui.igSliderFloat3("position", @ptrCast(&self.position), -100.0, 100.0, null, 0);
        _ = cimgui.igSliderFloat("pitch", @ptrCast(&self.pitch), -100.0, 100.0, null, 0);
        _ = cimgui.igSliderFloat("yaw", @ptrCast(&self.yaw), -100.0, 100.0, null, 0);
        if (self.top_down) {
            _ = cimgui.igSliderFloat("zoom", @ptrCast(&self.zoom), -100.0, 100.0, null, 0);
        } else {
            _ = cimgui.igSliderFloat("fovy", @ptrCast(&self.fovy), -100.0, 100.0, null, 0);
            _ = cimgui.igSliderFloat("near", @ptrCast(&self.near), -100.0, 100.0, null, 0);
            _ = cimgui.igSliderFloat("far", @ptrCast(&self.far), -100.0, 100.0, null, 0);
        }
    }
};

pub const App = struct {
    allocator: Allocator,

    mesh_shader: Shader,
    cube: Mesh,
    grid_shader: Shader,
    grid: Grid,
    grid_scale: f32 = 10.0,

    floating_camera: Camera,
    topdown_camera: Camera,
    use_topdown_camera: bool = false,

    level_tiles: std.ArrayListUnmanaged(Self.Tile) = .empty,
    current_tile_type: Self.TileType = .Floor,

    const Tile = struct {
        position: math.Vec2,
        type: TileType,
    };

    const TileType = enum {
        Floor,
        Wall,
    };

    const TileInfo = struct {
        scale: math.Vec3,
        color: math.Vec3,
    };
    const TileTypeInfo = std.EnumArray(TileType, TileInfo).init(
        .{
            .Floor = .{
                .scale = .{ .x = 1.0, .y = 1.0, .z = 0.2 },
                .color = .ONE,
            },
            .Wall = .{
                .scale = .{ .x = 1.0, .y = 1.0, .z = 1.0 },
                .color = .{ .x = 0.5, .y = 0.5, .z = 0.5 },
            },
        },
    );

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        const mesh_shader = if (builtin.target.os.tag == .emscripten)
            Shader.init("resources/shaders/mesh_web.vert", "resources/shaders/mesh_web.frag")
        else
            Shader.init("resources/shaders/mesh.vert", "resources/shaders/mesh.frag");

        const grid_shader = if (builtin.target.os.tag == .emscripten)
            Shader.init("resources/shaders/grid_web.vert", "resources/shaders/grid_web.frag")
        else
            Shader.init("resources/shaders/grid.vert", "resources/shaders/grid.frag");

        const cube = Mesh.init(mesh.MeshVertex, &mesh.Cube.VERTICES, &mesh.Cube.INDICES);
        const grid = Grid.init();

        const floating_camera: Camera = .{ .position = .{ .y = -10.0 } };
        const topdown_camera: Camera = .{
            .position = .{ .z = 10.0 },
            .pitch = -std.math.pi / 2.0,
            .top_down = true,
        };

        return .{
            .allocator = allocator,
            .mesh_shader = mesh_shader,
            .cube = cube,
            .grid_shader = grid_shader,
            .grid = grid,
            .floating_camera = floating_camera,
            .topdown_camera = topdown_camera,
        };
    }

    pub fn update(
        self: *Self,
        new_events: []const events.Event,
        mouse_pos: events.MousePosition,
        dt: f32,
    ) !void {
        const camera = if (self.use_topdown_camera)
            &self.topdown_camera
        else
            &self.floating_camera;

        var lmb_pressed: bool = false;
        var rmb_pressed: bool = false;
        for (new_events) |event| {
            camera.process_input(event, dt);

            switch (event) {
                .Mouse => |mouse| {
                    switch (mouse) {
                        .Button => |button| {
                            switch (button.key) {
                                .LMB => lmb_pressed = button.type == .Pressed,
                                .RMB => rmb_pressed = button.type == .Pressed,
                                else => {},
                            }
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }
        camera.move(dt);

        cimgui.ImGui_ImplOpenGL3_NewFrame();
        cimgui.ImGui_ImplSDL3_NewFrame();
        cimgui.igNewFrame();

        const mouse_clip = math.Vec3{
            .x = (@as(f32, @floatFromInt(mouse_pos.x)) / WINDOW_WIDTH * 2.0) - 1.0,
            .y = -((@as(f32, @floatFromInt(mouse_pos.y)) / WINDOW_HEIGHT * 2.0) - 1.0),
            .z = 1.0,
        };
        const mouse_xy = camera.mouse_to_xy(mouse_clip);
        const grid_xy = math.Vec3{
            .x = @floor(mouse_xy.x) + 0.5,
            .y = @floor(mouse_xy.y) + 0.5,
            .z = 0.0,
        };

        if (lmb_pressed)
            try self.add_cube(.{
                .position = .{
                    .x = grid_xy.x,
                    .y = grid_xy.y,
                },
                .type = self.current_tile_type,
            });
        if (rmb_pressed)
            try self.remove_cube(.{
                .x = grid_xy.x,
                .y = grid_xy.y,
            });

        {
            var open: bool = true;
            _ = cimgui.igBegin("options", &open, 0);
            defer cimgui.igEnd();

            _ = cimgui.igSeparatorText("Mouse");
            _ = cimgui.igValue_Uint("x", mouse_pos.x);
            _ = cimgui.igValue_Uint("y", mouse_pos.y);
            _ = cimgui.igSeparatorText("Mouse XY");
            _ = cimgui.igValue_Float("x", mouse_xy.x, null);
            _ = cimgui.igValue_Float("y", mouse_xy.y, null);
            _ = cimgui.igSeparatorText("Mouse Grid XY");
            _ = cimgui.igValue_Float("x", grid_xy.x, null);
            _ = cimgui.igValue_Float("y", grid_xy.y, null);

            _ = cimgui.igSeparatorText("Camera");
            _ = cimgui.igCheckbox("Use top down camera", &self.use_topdown_camera);
            _ = cimgui.igSeparatorText("Floating camera");
            {
                cimgui.igPushID_Int(0);
                defer cimgui.igPopID();
                self.floating_camera.imgui_options();
            }
            _ = cimgui.igSeparatorText("Topdown camera");
            {
                cimgui.igPushID_Int(1);
                defer cimgui.igPopID();
                self.topdown_camera.imgui_options();
            }

            _ = cimgui.igSeparatorText("Grid scale");
            _ = cimgui.igDragFloat("scale", &self.grid_scale, 0.1, 1.0, 100.0, null, 0);

            _ = cimgui.igSeparatorText("Total cubes");
            _ = cimgui.igValue_Uint("n", @intCast(self.level_tiles.items.len));

            _ = cimgui.igSeparatorText("Tile type");
            if (cimgui.igSelectable_Bool("Floor", self.current_tile_type == .Floor, 0, .{}))
                self.current_tile_type = .Floor;
            if (cimgui.igSelectable_Bool("Wall", self.current_tile_type == .Wall, 0, .{}))
                self.current_tile_type = .Wall;
        }
        cimgui.igRender();

        gl.glClearDepth(0.0);
        gl.glClearColor(0.0, 0.0, 0.0, 1.0);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT | gl.GL_DEPTH_BUFFER_BIT);

        for (self.level_tiles.items) |cube| {
            const tile_info = Self.TileTypeInfo.get(cube.type);
            const model = math.Mat4.IDENDITY
                .translate(cube.position.extend(0.0))
                .scale(tile_info.scale);

            const view_loc = self.mesh_shader.get_uniform_location("view");
            const projection_loc = self.mesh_shader.get_uniform_location("projection");
            const model_loc = self.mesh_shader.get_uniform_location("model");
            const color_loc = self.mesh_shader.get_uniform_location("color");

            self.mesh_shader.use();
            gl.glUniformMatrix4fv(view_loc, 1, gl.GL_FALSE, @ptrCast(&camera.view));
            gl.glUniformMatrix4fv(projection_loc, 1, gl.GL_FALSE, @ptrCast(&camera.projection));
            gl.glUniformMatrix4fv(model_loc, 1, gl.GL_FALSE, @ptrCast(&model));
            gl.glUniform3f(color_loc, tile_info.color.x, tile_info.color.y, tile_info.color.z);
            self.cube.draw();
        }
        {
            const tile_info = Self.TileTypeInfo.get(self.current_tile_type);
            const model = math.Mat4.IDENDITY.translate(grid_xy).scale(tile_info.scale);

            const view_loc = self.mesh_shader.get_uniform_location("view");
            const projection_loc = self.mesh_shader.get_uniform_location("projection");
            const model_loc = self.mesh_shader.get_uniform_location("model");
            const color_loc = self.mesh_shader.get_uniform_location("color");

            self.mesh_shader.use();
            gl.glUniformMatrix4fv(view_loc, 1, gl.GL_FALSE, @ptrCast(&camera.view));
            gl.glUniformMatrix4fv(projection_loc, 1, gl.GL_FALSE, @ptrCast(&camera.projection));
            gl.glUniformMatrix4fv(model_loc, 1, gl.GL_FALSE, @ptrCast(&model));
            gl.glUniform3f(color_loc, tile_info.color.x, tile_info.color.y, tile_info.color.z);
            self.cube.draw();
        }

        {
            const view_loc = self.grid_shader.get_uniform_location("view");
            const projection_loc = self.grid_shader.get_uniform_location("projection");
            const scale_loc = self.grid_shader.get_uniform_location("scale");

            self.grid_shader.use();
            gl.glUniformMatrix4fv(view_loc, 1, gl.GL_FALSE, @ptrCast(&camera.view));
            gl.glUniformMatrix4fv(projection_loc, 1, gl.GL_FALSE, @ptrCast(&camera.projection));
            gl.glUniform1f(scale_loc, self.grid_scale);

            if (builtin.target.os.tag == .emscripten) {
                const inverse_view_loc = self.grid_shader.get_uniform_location("inverse_view");
                const inverse_projection_loc = self.grid_shader.get_uniform_location("inverse_projection");
                gl.glUniformMatrix4fv(
                    inverse_view_loc,
                    1,
                    gl.GL_FALSE,
                    @ptrCast(&camera.inverse_view),
                );
                gl.glUniformMatrix4fv(
                    inverse_projection_loc,
                    1,
                    gl.GL_FALSE,
                    @ptrCast(&camera.inverse_projection),
                );
            }

            self.grid.draw();
        }

        const imgui_data = cimgui.igGetDrawData();
        cimgui.ImGui_ImplOpenGL3_RenderDrawData(imgui_data);
    }

    pub fn add_cube(self: *Self, cube: Self.Tile) !void {
        for (self.level_tiles.items) |c|
            if (c.position.eq(cube.position)) return;
        try self.level_tiles.append(self.allocator, cube);
    }

    pub fn remove_cube(self: *Self, position: math.Vec2) !void {
        for (self.level_tiles.items, 0..) |c, i| {
            if (c.position.eq(position)) _ = self.level_tiles.swapRemove(i);
        }
    }
};
