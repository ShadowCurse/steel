const std = @import("std");
const builtin = @import("builtin");
const log = @import("log.zig");
const sdl = @import("bindings/sdl.zig");
const gl = @import("bindings/gl.zig");
const cimgui = @import("bindings/cimgui.zig");

const math = @import("math.zig");
const Mesh = @import("mesh.zig");
const events = @import("events.zig");

const rendering = @import("rendering.zig");
const MeshShader = rendering.MeshShader;
const DebugGridShader = rendering.DebugGridShader;
const GpuMesh = rendering.Mesh;
const DebugGrid = rendering.DebugGrid;

const Allocator = std.mem.Allocator;
const DebugAllocator = std.heap.DebugAllocator(.{});

const memory = @import("memory.zig");
const FixedArena = memory.FixedArena;
const RoundArena = memory.RoundArena;

const assets = @import("assets.zig");

const WINDOW_WIDTH = 1280;
const WINDOW_HEIGHT = 720;

pub const log_options = log.Options{
    .level = .Info,
    .colors = builtin.target.os.tag != .emscripten,
};

pub const os = if (builtin.os.tag != .emscripten) std.os else struct {
    pub const heap = struct {
        pub const page_allocator = std.heap.c_allocator;
    };
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
    const gpa_alloc = gpa.allocator();

    var frame_allocator = FixedArena.init(try gpa_alloc.alloc(u8, 4096));
    const frame_alloc = frame_allocator.allocator();

    var scratch_allocator = RoundArena.init(try gpa_alloc.alloc(u8, 4096));
    const scratch_alloc = scratch_allocator.allocator();

    var app = App.init(gpa_alloc, frame_alloc, scratch_alloc);
    var stop: bool = false;

    var app_events: [events.MAX_EVENTS]events.Event = undefined;
    var sdl_events: [events.MAX_EVENTS]sdl.SDL_Event = undefined;

    var t = std.time.nanoTimestamp();
    while (!stop) {
        frame_allocator.reset();

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
                        switch (button.key) {
                            .WHEEL => self.active = button.type == .Pressed,
                            else => {},
                        }
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

pub const XY = packed struct(u16) { x: u8 = 0, y: u8 = 0 };
pub const Grid = struct {
    cells: [Self.WIDTH][Self.HEIGHT]Cell = .{.{Cell{}} ** Self.HEIGHT} ** Self.WIDTH,
    has_throne: bool = false,
    throne_xy: XY = .{},
    has_spawn: bool = false,
    spawn_xy: XY = .{},

    pub const WIDTH = 32;
    pub const HEIGHT = 32;
    pub const RIGHT = Self.WIDTH / 2;
    pub const LEFT = -Self.WIDTH / 2;
    pub const TOP = Self.HEIGHT / 2;
    pub const BOT = -Self.HEIGHT / 2;
    pub const LIMITS: math.Vec4 = .{
        .x = RIGHT,
        .y = LEFT,
        .z = TOP,
        .w = BOT,
    };

    const Cell = struct {
        type: CellType = .None,
    };

    const CellType = enum {
        None,
        Floor,
        Wall,
        Spawn,
        Throne,
    };

    const CellInfo = struct {
        color: math.Vec3 = .{},
    };
    const CellTypeInfo = std.EnumArray(CellType, CellInfo).init(
        .{
            .None = .{},
            .Floor = .{
                .color = .ONE,
            },
            .Wall = .{
                .color = .{ .x = 0.5, .y = 0.5, .z = 0.5 },
            },
            .Spawn = .{
                .color = .{ .x = 1.0, .y = 0.0, .z = 0.0 },
            },
            .Throne = .{
                .color = .{ .x = 0.9, .y = 0.8, .z = 0.01 },
            },
        },
    );

    const Self = @This();

    inline fn in_range(x: i32, y: i32) ?XY {
        if (x < Self.LEFT or Self.RIGHT < x or y < Self.BOT or Self.TOP <= y)
            return null
        else
            return .{ .x = @intCast(x + RIGHT), .y = @intCast(y + TOP) };
    }

    pub fn set(self: *Self, x: i32, y: i32, @"type": CellType) void {
        const xy = Self.in_range(x, y) orelse return;
        const cell = &self.cells[xy.x][xy.y];

        if (@"type" == .Throne)
            if (!self.has_throne) {
                self.has_throne = true;
                self.throne_xy = xy;
            } else return;
        if (cell.type == .Throne)
            self.has_throne = false;

        if (@"type" == .Spawn)
            if (!self.has_spawn) {
                self.has_spawn = true;
                self.spawn_xy = xy;
            } else return;

        if (cell.type == .Spawn)
            self.has_spawn = false;

        cell.type = @"type";
    }

    pub fn unset(self: *Self, x: i32, y: i32) void {
        const xy = Self.in_range(x, y) orelse return;
        const cell = &self.cells[xy.x][xy.y];
        if (cell.type == .Throne)
            self.has_throne = false;
        if (cell.type == .Spawn)
            self.has_spawn = false;
        cell.type = .None;
    }

    fn distance_to_throne(self: *const Self, xy: XY) u8 {
        const dx =
            if (self.throne_xy.x < xy.x) xy.x - self.throne_xy.x else self.throne_xy.x - xy.x;
        const dy =
            if (self.throne_xy.y < xy.y) xy.y - self.throne_xy.y else self.throne_xy.y - xy.y;
        return dx + dy;
    }

    const Item = packed struct(u32) {
        xy: XY,
        p: u16,

        fn cmp(_: void, a: Item, b: Item) std.math.Order {
            return std.math.order(a.p, b.p);
        }
    };
    pub fn find_path(self: *Self, allocator: Allocator) !?[]XY {
        if (!self.has_throne or !self.has_spawn)
            return null;

        var to_explore: std.PriorityQueue(Item, void, Item.cmp) = .init(allocator, void{});
        defer to_explore.deinit();

        var came_from: [Self.WIDTH][Self.HEIGHT]XY =
            .{.{XY{ .x = 0, .y = 0 }} ** Self.HEIGHT} ** Self.WIDTH;
        var g_score: [Self.WIDTH][Self.HEIGHT]u16 =
            .{.{std.math.maxInt(u16)} ** Self.HEIGHT} ** Self.WIDTH;
        var f_score: [Self.WIDTH][Self.HEIGHT]u16 =
            .{.{std.math.maxInt(u16)} ** Self.HEIGHT} ** Self.WIDTH;

        try to_explore.add(.{ .xy = self.spawn_xy, .p = 0 });
        g_score[self.spawn_xy.x][self.spawn_xy.y] = 0;
        f_score[self.spawn_xy.x][self.spawn_xy.y] = self.distance_to_throne(self.spawn_xy);

        while (to_explore.removeOrNull()) |current| {
            if (current.xy == self.throne_xy) {
                var path: std.ArrayListUnmanaged(XY) = .{};

                var i: u32 = 0;
                var c = current.xy;
                while (c != self.spawn_xy) : (i += 1) {
                    c = came_from[c.x][c.y];
                    try path.append(allocator, c);

                    log.assert(
                        @src(),
                        i < Self.WIDTH * Self.HEIGHT,
                        "Path is longer than number of cells on the grid",
                        .{},
                    );
                }
                return try path.toOwnedSlice(allocator);
            }

            const left: ?XY =
                if (0 < current.xy.x) .{ .x = current.xy.x - 1, .y = current.xy.y } else null;
            const right: ?XY =
                if (current.xy.x < Self.WIDTH - 1)
                    .{ .x = current.xy.x + 1, .y = current.xy.y }
                else
                    null;
            const bot: ?XY =
                if (0 < current.xy.y) .{ .x = current.xy.x, .y = current.xy.y - 1 } else null;
            const top: ?XY =
                if (current.xy.y < Self.HEIGHT - 1)
                    .{ .x = current.xy.x, .y = current.xy.y + 1 }
                else
                    null;

            const neightbors: [4]?XY = .{
                if (left) |n|
                    if (self.cells[n.x][n.y].type == .Floor or
                        self.cells[n.x][n.y].type == .Throne) left else null
                else
                    null,
                if (right) |n|
                    if (self.cells[n.x][n.y].type == .Floor or
                        self.cells[n.x][n.y].type == .Throne) right else null
                else
                    null,
                if (bot) |n|
                    if (self.cells[n.x][n.y].type == .Floor or
                        self.cells[n.x][n.y].type == .Throne) bot else null
                else
                    null,
                if (top) |n|
                    if (self.cells[n.x][n.y].type == .Floor or
                        self.cells[n.x][n.y].type == .Throne) top else null
                else
                    null,
            };
            for (neightbors) |n| {
                if (n == null)
                    continue;

                const nn = n.?;
                const new_g_score = g_score[current.xy.x][current.xy.y] + 1;
                const old_g_score = g_score[nn.x][nn.y];
                if (new_g_score < old_g_score) {
                    came_from[nn.x][nn.y] = current.xy;
                    g_score[nn.x][nn.y] = new_g_score;
                    const new_f_score = new_g_score + self.distance_to_throne(nn);
                    f_score[nn.x][nn.y] = new_f_score;

                    var found: bool = false;
                    for (to_explore.items) |te| {
                        if (te.xy == nn) {
                            found = true;
                            break;
                        }
                    }
                    if (!found)
                        try to_explore.add(.{ .xy = nn, .p = new_f_score });
                }
            }
        }
        log.info(@src(), "There is no path", .{});
        return null;
    }

    const SaveState = struct {
        cells: []const SavedCell,
        has_throne: bool = false,
        throne_xy: XY = .{},
        has_spawn: bool = false,
        spawn_xy: XY = .{},

        const SavedCell = struct {
            xy: XY,
            cell: Cell,
        };
    };
    pub fn save(self: *const Self, scratch_alloc: Allocator, path: []const u8) !void {
        var file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        const options = std.json.StringifyOptions{
            .whitespace = .indent_4,
        };
        var cells: std.ArrayListUnmanaged(SaveState.SavedCell) = .{};
        for (0..Grid.WIDTH) |x| {
            for (0..Grid.HEIGHT) |y| {
                const cell = &self.cells[x][y];
                if (cell.type == .None)
                    continue;
                try cells.append(scratch_alloc, .{
                    .xy = .{ .x = @intCast(x), .y = @intCast(y) },
                    .cell = cell.*,
                });
            }
        }
        const save_state = SaveState{
            .cells = cells.items,
            .has_throne = self.has_throne,
            .throne_xy = self.throne_xy,
            .has_spawn = self.has_spawn,
            .spawn_xy = self.spawn_xy,
        };
        try std.json.stringify(save_state, options, file.writer());
    }

    pub fn load(self: *Self, scratch_alloc: Allocator, path: []const u8) !void {
        const file_mem = try memory.FileMem.init(path);
        defer file_mem.deinit();

        const ss = try std.json.parseFromSlice(
            SaveState,
            scratch_alloc,
            file_mem.mem,
            .{},
        );

        const save_state = &ss.value;

        for (0..Grid.WIDTH) |x| {
            for (0..Grid.HEIGHT) |y| {
                const cell = &self.cells[x][y];
                for (save_state.cells) |s_cell| {
                    if (s_cell.xy == XY{ .x = @intCast(x), .y = @intCast(y) }) {
                        cell.* = s_cell.cell;
                        break;
                    } else cell.* = .{};
                }
            }
        }
        self.has_throne = save_state.has_throne;
        self.throne_xy = save_state.throne_xy;
        self.has_spawn = save_state.has_spawn;
        self.spawn_xy = save_state.spawn_xy;
    }
};

pub const App = struct {
    gpa_alloc: Allocator,
    frame_alloc: Allocator,
    scratch_alloc: Allocator,

    mesh_shader: MeshShader,
    cube: GpuMesh,
    floor: GpuMesh,
    wall: GpuMesh,
    spawn: GpuMesh,
    throne: GpuMesh,
    debug_grid_shader: DebugGridShader,
    debug_grid: DebugGrid,
    debug_grid_scale: f32 = 10.0,

    floating_camera: Camera,
    topdown_camera: Camera,
    use_topdown_camera: bool = false,

    level_path: [256]u8 = .{0} ** 256,
    grid: Grid,
    current_cell_type: Grid.CellType = .Floor,
    current_path: []XY = &.{},

    const Self = @This();

    pub fn init(
        gpa_alloc: Allocator,
        frame_alloc: Allocator,
        scratch_alloc: Allocator,
    ) Self {
        const mesh_shader = MeshShader.init();
        const debug_grid_shader = DebugGridShader.init();

        const meshes_mem = gpa_alloc.alloc(u8, 4096 * 4) catch unreachable;
        defer gpa_alloc.free(meshes_mem);
        var meshes_allocator = FixedArena.init(meshes_mem);
        const meshes_alloc = meshes_allocator.allocator();

        const mem = memory.FileMem.init(assets.DEFAULT_PACKED_ASSETS_PATH) catch unreachable;
        defer mem.deinit();
        const meshes = assets.unpack(meshes_alloc, mem.mem) catch unreachable;

        const cube = GpuMesh.init(Mesh.Vertex, Mesh.Cube.vertices, Mesh.Cube.indices);
        const spawn = GpuMesh.init(Mesh.Vertex, meshes[0].vertices, meshes[0].indices);
        const wall = GpuMesh.init(Mesh.Vertex, meshes[1].vertices, meshes[1].indices);
        const floor = GpuMesh.init(Mesh.Vertex, meshes[2].vertices, meshes[2].indices);
        const throne = GpuMesh.init(Mesh.Vertex, meshes[3].vertices, meshes[3].indices);

        const debug_grid = DebugGrid.init();

        const floating_camera: Camera = .{ .position = .{ .y = -10.0 } };
        const topdown_camera: Camera = .{
            .position = .{ .z = 10.0 },
            .pitch = -std.math.pi / 2.0,
            .top_down = true,
        };

        const grid: Grid = .{};

        var self = Self{
            .gpa_alloc = gpa_alloc,
            .frame_alloc = frame_alloc,
            .scratch_alloc = scratch_alloc,
            .mesh_shader = mesh_shader,
            .cube = cube,
            .floor = floor,
            .wall = wall,
            .spawn = spawn,
            .throne = throne,
            .debug_grid_shader = debug_grid_shader,
            .debug_grid = debug_grid,
            .floating_camera = floating_camera,
            .topdown_camera = topdown_camera,
            .grid = grid,
        };
        const default_path = "resources/level.json";
        @memcpy(self.level_path[0..default_path.len], default_path);
        return self;
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
            self.grid.set(
                @intFromFloat(@floor(mouse_xy.x)),
                @intFromFloat(@floor(mouse_xy.y)),
                self.current_cell_type,
            );
        if (rmb_pressed)
            self.grid.unset(
                @intFromFloat(@floor(mouse_xy.x)),
                @intFromFloat(@floor(mouse_xy.y)),
            );

        {
            var open: bool = true;

            cimgui.ImGui_ImplOpenGL3_NewFrame();
            cimgui.ImGui_ImplSDL3_NewFrame();
            cimgui.igNewFrame();
            defer cimgui.igRender();

            _ = cimgui.igBegin("options", &open, 0);
            defer cimgui.igEnd();

            if (cimgui.igCollapsingHeader_BoolPtr("Mouse info", &open, 0)) {
                _ = cimgui.igSeparatorText("Mouse");
                _ = cimgui.igValue_Uint("x", mouse_pos.x);
                _ = cimgui.igValue_Uint("y", mouse_pos.y);
                _ = cimgui.igSeparatorText("Mouse XY");
                _ = cimgui.igValue_Float("x", mouse_xy.x, null);
                _ = cimgui.igValue_Float("y", mouse_xy.y, null);
                _ = cimgui.igSeparatorText("Mouse Grid XY");
                _ = cimgui.igValue_Float("x", grid_xy.x, null);
                _ = cimgui.igValue_Float("y", grid_xy.y, null);
            }

            if (cimgui.igCollapsingHeader_BoolPtr("Camera", &open, 0)) {
                _ = cimgui.igSeparatorText("Camera");
                _ = cimgui.igCheckbox("Use top down camera", &self.use_topdown_camera);
                _ = cimgui.igSeparatorText(
                    if (!self.use_topdown_camera) "Floating camera +" else "Floating camera",
                );
                {
                    cimgui.igPushID_Int(0);
                    defer cimgui.igPopID();
                    self.floating_camera.imgui_options();
                }
                _ = cimgui.igSeparatorText(
                    if (self.use_topdown_camera) "Topdown camera +" else "Topdown camera",
                );
                {
                    cimgui.igPushID_Int(1);
                    defer cimgui.igPopID();
                    self.topdown_camera.imgui_options();
                }
            }

            _ = cimgui.igSeparatorText("Debug grid scale");
            _ = cimgui.igDragFloat("scale", &self.debug_grid_scale, 0.1, 1.0, 100.0, null, 0);
            if (cimgui.igCollapsingHeader_BoolPtr(
                "Level",
                &open,
                cimgui.ImGuiTreeNodeFlags_DefaultOpen,
            )) {
                _ = cimgui.igSeparatorText("Cell type");
                if (cimgui.igSelectable_Bool("Floor", self.current_cell_type == .Floor, 0, .{}))
                    self.current_cell_type = .Floor;
                if (cimgui.igSelectable_Bool("Wall", self.current_cell_type == .Wall, 0, .{}))
                    self.current_cell_type = .Wall;
                if (cimgui.igSelectable_Bool("Spawn", self.current_cell_type == .Spawn, 0, .{}))
                    self.current_cell_type = .Spawn;
                if (cimgui.igSelectable_Bool("Throne", self.current_cell_type == .Throne, 0, .{}))
                    self.current_cell_type = .Throne;

                _ = cimgui.igSeparatorText("Spawn XY");
                _ = cimgui.igValue_Uint("x", self.grid.spawn_xy.x);
                _ = cimgui.igValue_Uint("y", self.grid.spawn_xy.y);

                _ = cimgui.igSeparatorText("Throne XY");
                _ = cimgui.igValue_Uint("x", self.grid.throne_xy.x);
                _ = cimgui.igValue_Uint("y", self.grid.throne_xy.y);

                if (cimgui.igButton("Find path", .{})) {
                    if (try self.grid.find_path(self.scratch_alloc)) |new_path| {
                        self.gpa_alloc.free(self.current_path);
                        self.current_path = try self.gpa_alloc.alloc(XY, new_path.len);
                        @memcpy(self.current_path, new_path);
                    }
                }

                _ = cimgui.igSeparatorText("Level Save/Load");
                _ = cimgui.igInputText(
                    "File path",
                    &self.level_path,
                    self.level_path.len,
                    0,
                    null,
                    null,
                );
                const path = std.mem.sliceTo(&self.level_path, 0);
                if (cimgui.igButton("Save level", .{})) {
                    self.grid.save(self.scratch_alloc, path) catch
                        log.err(@src(), "Cannot save level to {s}", .{path});
                }
                if (cimgui.igButton("Load level", .{})) {
                    self.grid.load(self.scratch_alloc, path) catch
                        log.err(@src(), "Cannot load level from {s}", .{path});
                }
            }
        }

        gl.glClearDepth(0.0);
        gl.glClearColor(0.0, 0.0, 0.0, 1.0);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT | gl.GL_DEPTH_BUFFER_BIT);

        for (0..Grid.WIDTH) |x| {
            for (0..Grid.HEIGHT) |y| {
                const cell = &self.grid.cells[x][y];
                if (cell.type == .None)
                    continue;
                const tile_info = Grid.CellTypeInfo.get(cell.type);
                const model = math.Mat4.IDENDITY
                    .translate(.{
                    .x = @as(f32, @floatFromInt(x)) + 0.5 - Grid.RIGHT,
                    .y = @as(f32, @floatFromInt(y)) + 0.5 - Grid.TOP,
                    .z = 0.0,
                });

                self.mesh_shader.setup(
                    &camera.position,
                    &camera.view,
                    &camera.projection,
                    &model,
                    &tile_info.color,
                    &.{ .x = 2.0, .y = 0.0, .z = 4.0 },
                );
                switch (cell.type) {
                    .None => {},
                    .Floor => self.floor.draw(),
                    .Wall => self.wall.draw(),
                    .Spawn => self.spawn.draw(),
                    .Throne => self.throne.draw(),
                }
            }
        }
        for (self.current_path) |c| {
            const model = math.Mat4.IDENDITY
                .translate(.{
                    .x = @as(f32, @floatFromInt(c.x)) + 0.5 - Grid.RIGHT,
                    .y = @as(f32, @floatFromInt(c.y)) + 0.5 - Grid.TOP,
                    .z = 0.0,
                }).scale(.{ .x = 0.5, .y = 0.5, .z = 1.5 });

            self.mesh_shader.setup(
                &camera.position,
                &camera.view,
                &camera.projection,
                &model,
                &.{ .x = 0.0, .y = 0.0, .z = 1.0 },
                &.{ .x = 2.0, .y = 0.0, .z = 4.0 },
            );
            self.cube.draw();
        }
        {
            const cell_info = Grid.CellTypeInfo.get(self.current_cell_type);
            const model = math.Mat4.IDENDITY.translate(grid_xy);

            self.mesh_shader.setup(
                &camera.position,
                &camera.view,
                &camera.projection,
                &model,
                &cell_info.color,
                &.{ .x = 2.0, .y = 0.0, .z = 4.0 },
            );
            switch (self.current_cell_type) {
                .None => {},
                .Floor => self.floor.draw(),
                .Wall => self.wall.draw(),
                .Spawn => self.spawn.draw(),
                .Throne => self.throne.draw(),
            }
        }

        {
            self.debug_grid_shader.setup(
                &camera.view,
                &camera.projection,
                &camera.inverse_view,
                &camera.inverse_projection,
                self.debug_grid_scale,
                &Grid.LIMITS,
            );
            self.debug_grid.draw();
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
