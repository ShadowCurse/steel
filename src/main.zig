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
const GpuMesh = rendering.GpuMesh;
const DebugGrid = rendering.DebugGrid;

const Allocator = std.mem.Allocator;
const DebugAllocator = std.heap.DebugAllocator(.{});

const memory = @import("memory.zig");
const FixedArena = memory.FixedArena;
const RoundArena = memory.RoundArena;

const assets = @import("assets.zig");
const Platform = @import("platform.zig");

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
    Platform.init();

    var app: App = .{};
    try app.init();

    var t = std.time.nanoTimestamp();
    while (!Platform.stop) {
        const new_t = std.time.nanoTimestamp();
        const dt = @as(f32, @floatFromInt(new_t - t)) / std.time.ns_per_s;
        t = new_t;

        Platform.process_events();
        try app.update(dt);

        Platform.present();
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
            @as(f32, @floatFromInt(Platform.WINDOW_WIDTH)) /
                @as(f32, @floatFromInt(Platform.WINDOW_HEIGHT)),
            self.near,
            self.far,
        );
        // flip Y for opengl
        m.j.y *= -1.0;
        return m;
    }

    pub fn orthogonal(self: *const Self) math.Mat4 {
        const width: f32 = @as(f32, Platform.WINDOW_WIDTH) / self.zoom;
        const height: f32 = @as(f32, Platform.WINDOW_HEIGHT) / self.zoom;
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
        type: ?assets.ModelType = null,
    };

    const Self = @This();

    inline fn in_range(x: i32, y: i32) ?XY {
        if (x < Self.LEFT or Self.RIGHT < x or y < Self.BOT or Self.TOP <= y)
            return null
        else
            return .{ .x = @intCast(x + RIGHT), .y = @intCast(y + TOP) };
    }

    pub fn set(self: *Self, x: i32, y: i32, @"type": assets.ModelType) void {
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
        cell.type = null;
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
    pub fn find_path(self: *Self, allocator: Allocator) ?[]XY {
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

        to_explore.add(.{ .xy = self.spawn_xy, .p = 0 }) catch return null;
        g_score[self.spawn_xy.x][self.spawn_xy.y] = 0;
        f_score[self.spawn_xy.x][self.spawn_xy.y] = self.distance_to_throne(self.spawn_xy);

        while (to_explore.removeOrNull()) |current| {
            if (current.xy == self.throne_xy) {
                var path: std.ArrayListUnmanaged(XY) = .{};

                var i: u32 = 0;
                var c = current.xy;
                while (c != self.spawn_xy) : (i += 1) {
                    c = came_from[c.x][c.y];
                    path.append(allocator, c) catch return null;

                    log.assert(
                        @src(),
                        i < Self.WIDTH * Self.HEIGHT,
                        "Path is longer than number of cells on the grid",
                        .{},
                    );
                }
                return path.toOwnedSlice(allocator) catch return null;
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
                        to_explore.add(.{ .xy = nn, .p = new_f_score }) catch return null;
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
                if (cell.type) |_|
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
    gpa_allocator: DebugAllocator = .{},
    frame_allocator: FixedArena = .{},
    scratch_allocator: RoundArena = .{},

    mesh_shader: MeshShader = undefined,
    materials: assets.Materials = undefined,
    cube: GpuMesh = undefined,
    gpu_meshes: assets.GpuMeshes = undefined,
    debug_grid_shader: DebugGridShader = undefined,
    debug_grid: DebugGrid = undefined,
    debug_grid_scale: f32 = 10.0,

    floating_camera: Camera = .{},
    topdown_camera: Camera = .{},
    use_topdown_camera: bool = false,

    level_path: [256]u8 = .{0} ** 256,
    show_grid: bool = true,
    grid: Grid = .{},
    current_cell_type: assets.ModelType = .Floor,
    current_path: []XY = &.{},

    const Self = @This();

    pub fn init(self: *Self) !void {
        var gpa = DebugAllocator{};
        const gpa_alloc = gpa.allocator();

        const frame_allocator = FixedArena.init(try gpa_alloc.alloc(u8, 4096));
        const scratch_allocator = RoundArena.init(try gpa_alloc.alloc(u8, 4096));

        self.gpa_allocator = gpa;
        self.frame_allocator = frame_allocator;
        self.scratch_allocator = scratch_allocator;

        const mesh_shader = MeshShader.init();
        const debug_grid_shader = DebugGridShader.init();

        const mem = memory.FileMem.init(assets.DEFAULT_PACKED_ASSETS_PATH) catch unreachable;
        defer mem.deinit();
        const unpack_result = assets.unpack(mem.mem) catch unreachable;

        const cube = GpuMesh.init(Mesh.Vertex, Mesh.Cube.vertices, Mesh.Cube.indices);
        const gpu_meshes = assets.gpu_meshes_from_meshes(&unpack_result.meshes);

        const debug_grid = DebugGrid.init();

        const floating_camera: Camera = .{ .position = .{ .y = -10.0 } };
        const topdown_camera: Camera = .{
            .position = .{ .z = 10.0 },
            .pitch = -std.math.pi / 2.0,
            .top_down = true,
        };

        const grid: Grid = .{};

        self.mesh_shader = mesh_shader;
        self.materials = unpack_result.materials;
        self.cube = cube;
        self.gpu_meshes = gpu_meshes;
        self.debug_grid_shader = debug_grid_shader;
        self.debug_grid = debug_grid;
        self.floating_camera = floating_camera;
        self.topdown_camera = topdown_camera;
        self.grid = grid;

        const default_path = "resources/level.json";
        @memcpy(self.level_path[0..default_path.len], default_path);
    }

    pub fn update(
        self: *Self,
        dt: f32,
    ) !void {
        self.frame_allocator.reset();

        const imgui_wants_to_handle_events = Platform.imgui_wants_to_handle_events();
        var new_events = Platform.input_events;

        const camera = if (self.use_topdown_camera)
            &self.topdown_camera
        else
            &self.floating_camera;

        if (imgui_wants_to_handle_events) {
            new_events = &.{};
            camera.velocity = .{};
        }

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
            .x = (@as(f32, @floatFromInt(Platform.mouse_position.x)) /
                Platform.WINDOW_WIDTH * 2.0) - 1.0,
            .y = -((@as(f32, @floatFromInt(Platform.mouse_position.y)) /
                Platform.WINDOW_HEIGHT * 2.0) - 1.0),
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

        self.draw_imgui();

        gl.glClearDepth(0.0);
        gl.glClearColor(0.0, 0.0, 0.0, 1.0);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT | gl.GL_DEPTH_BUFFER_BIT);

        for (0..Grid.WIDTH) |x| {
            for (0..Grid.HEIGHT) |y| {
                const cell = &self.grid.cells[x][y];
                if (cell.type) |cell_type| {
                    const model = math.Mat4.IDENDITY
                        .translate(.{
                        .x = @as(f32, @floatFromInt(x)) + 0.5 - Grid.RIGHT,
                        .y = @as(f32, @floatFromInt(y)) + 0.5 - Grid.TOP,
                        .z = 0.0,
                    });

                    const m = self.materials.getPtr(cell_type);
                    self.mesh_shader.setup(
                        &camera.position,
                        &camera.view,
                        &camera.projection,
                        &model,
                        &.{ .x = 2.0, .y = 0.0, .z = 4.0 },
                        &m.albedo,
                        m.metallic,
                        m.roughness,
                        1.0,
                    );
                    self.gpu_meshes.getPtr(cell_type).draw();
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
                &.{ .x = 2.0, .y = 0.0, .z = 4.0 },
                &.{ .x = 0.0, .y = 0.0, .z = 1.0 },
                0.0,
                0.0,
                1.0,
            );
            self.cube.draw();
        }
        {
            const model = math.Mat4.IDENDITY.translate(grid_xy);
            const m = self.materials.getPtr(self.current_cell_type);
            self.mesh_shader.setup(
                &camera.position,
                &camera.view,
                &camera.projection,
                &model,
                &.{ .x = 2.0, .y = 0.0, .z = 4.0 },
                &m.albedo,
                m.metallic,
                m.roughness,
                1.0,
            );
            self.gpu_meshes.getPtr(self.current_cell_type).draw();
        }

        if (self.show_grid) {
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

    pub fn draw_imgui(self: *Self) void {
        var open: bool = true;
        const scratch_alloc = self.scratch_allocator.allocator();
        const gpa_alloc = self.gpa_allocator.allocator();

        cimgui.ImGui_ImplOpenGL3_NewFrame();
        cimgui.ImGui_ImplSDL3_NewFrame();
        cimgui.igNewFrame();
        defer cimgui.igRender();

        _ = cimgui.igBegin("options", &open, 0);
        defer cimgui.igEnd();

        var cimgui_id: i32 = 0;

        if (cimgui.igCollapsingHeader_BoolPtr("Mouse info", &open, 0)) {
            _ = cimgui.igSeparatorText("Mouse");
            _ = cimgui.igValue_Uint("x", Platform.mouse_position.x);
            _ = cimgui.igValue_Uint("y", Platform.mouse_position.y);
        }

        if (cimgui.igCollapsingHeader_BoolPtr("Camera", &open, 0)) {
            _ = cimgui.igSeparatorText("Camera");
            _ = cimgui.igCheckbox("Use top down camera", &self.use_topdown_camera);
            _ = cimgui.igSeparatorText(
                if (!self.use_topdown_camera) "Floating camera +" else "Floating camera",
            );
            {
                cimgui.igPushID_Int(cimgui_id);
                cimgui_id += 1;
                defer cimgui.igPopID();
                self.floating_camera.imgui_options();
            }
            _ = cimgui.igSeparatorText(
                if (self.use_topdown_camera) "Topdown camera +" else "Topdown camera",
            );
            {
                cimgui.igPushID_Int(cimgui_id);
                cimgui_id += 1;
                defer cimgui.igPopID();
                self.topdown_camera.imgui_options();
            }
        }

        if (cimgui.igCollapsingHeader_BoolPtr("Debug grid", &open, 0)) {
            _ = cimgui.igCheckbox("Enabled", &self.show_grid);
            _ = cimgui.igDragFloat("scale", &self.debug_grid_scale, 0.1, 1.0, 100.0, null, 0);
        }

        if (cimgui.igCollapsingHeader_BoolPtr("Materials", &open, 0)) {
            var iter = self.materials.iterator();
            while (iter.next()) |m| {
                cimgui.igPushID_Int(cimgui_id);
                cimgui_id += 1;
                defer cimgui.igPopID();

                _ = cimgui.igColorEdit4("albedo", @ptrCast(&m.value.albedo), 0);
                _ = cimgui.igSliderFloat("metallic", &m.value.metallic, 0.0, 1.0, null, 0);
                _ = cimgui.igSliderFloat("roughness", &m.value.roughness, 0.0, 1.0, null, 0);
            }
        }

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
                if (self.grid.find_path(scratch_alloc)) |new_path| {
                    gpa_alloc.free(self.current_path);
                    self.current_path = gpa_alloc.alloc(XY, new_path.len) catch unreachable;
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
                self.grid.save(scratch_alloc, path) catch
                    log.err(@src(), "Cannot save level to {s}", .{path});
            }
            if (cimgui.igButton("Load level", .{})) {
                self.grid.load(scratch_alloc, path) catch
                    log.err(@src(), "Cannot load level from {s}", .{path});
            }
        }
    }
};
