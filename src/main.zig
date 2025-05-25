const std = @import("std");
const builtin = @import("builtin");
const log = @import("log.zig");
const sdl = @import("bindings/sdl.zig");
const gl = @import("bindings/gl.zig");
const cimgui = @import("bindings/cimgui.zig");

const math = @import("math.zig");
const assets = @import("assets.zig");
const events = @import("events.zig");

const rendering = @import("rendering.zig");
const MeshShader = rendering.MeshShader;
const DebugGridShader = rendering.DebugGridShader;
const GpuMesh = rendering.GpuMesh;
const DebugGrid = rendering.DebugGrid;

const memory = @import("memory.zig");
const FixedArena = memory.FixedArena;
const RoundArena = memory.RoundArena;
const Allocator = memory.Allocator;
const DebugAllocator = memory.DebugAllocator;

const Mesh = @import("mesh.zig");
const Camera = @import("camera.zig");
const Platform = @import("platform.zig");
const BoundedArray = std.BoundedArray;

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

pub const Spawn = struct {
    xy: XY,
    path_idx: u32,
};

pub const Throne = struct {
    xy: XY,
    hp: i32,
};

pub const Enemy = struct {
    position: math.Vec3 = .{},
    path_idx: u32 = 0,
    path_node_idx: u32 = 0,
    path_node_progress: f32 = 0.0,
    hp: i32 = 10,
    damage: i32 = 10,
};

pub const XY = packed struct(u16) { x: u8 = 0, y: u8 = 0 };
pub const Level = struct {
    path: [256]u8 = .{0} ** 256,

    cells: [Self.WIDTH][Self.HEIGHT]Cell = .{.{Cell{ .None = {} }} ** Self.HEIGHT} ** Self.WIDTH,

    spawns: BoundedArray(Spawn, 32) = .{},
    paths: BoundedArray([]XY, 32) = .{},
    enemies: BoundedArray(Enemy, 32) = .{},
    thrones: BoundedArray(Throne, 4) = .{},

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

    const CellType = enum {
        None,
        Floor,
        Wall,
        Spawn,
        Throne,
    };

    const Cell = union(CellType) {
        None: void,
        Floor: void,
        Wall: void,
        Spawn: u32,
        Throne: u32,
    };

    const Self = @This();

    inline fn cell_to_model_type(cell: Cell) assets.ModelType {
        return switch (cell) {
            .None => log.panic(@src(), "Trying to convert cell of None type to model type", .{}),
            .Floor => |_| .Floor,
            .Wall => |_| .Wall,
            .Spawn => |_| .Spawn,
            .Throne => |_| .Throne,
        };
    }

    inline fn in_range(x: i32, y: i32) ?XY {
        if (x < Self.LEFT or Self.RIGHT < x or y < Self.BOT or Self.TOP <= y)
            return null
        else
            return .{ .x = @intCast(x + RIGHT), .y = @intCast(y + TOP) };
    }

    pub fn set(self: *Self, x: i32, y: i32, cell_type: CellType) void {
        switch (cell_type) {
            .Spawn => if (self.spawns.len == self.spawns.capacity()) {
                log.warn(
                    @src(),
                    "Cannot place any more spawners. MAX is {d}",
                    .{self.spawns.capacity()},
                );
                return;
            },
            .Throne => if (self.thrones.len == self.thrones.capacity()) {
                log.warn(
                    @src(),
                    "Cannot place any more thrones. MAX is {d}",
                    .{self.thrones.capacity()},
                );
                return;
            },
            else => {},
        }

        const xy = Self.in_range(x, y) orelse return;
        const cell = &self.cells[xy.x][xy.y];

        if (std.meta.activeTag(cell.*) != .None) {
            switch (cell.*) {
                .Spawn => |idx| {
                    const s = self.spawns.slice();
                    const last_spawn = &s[s.len - 1];
                    const ls_xy = last_spawn.xy;
                    self.cells[ls_xy.x][ls_xy.y] = .{ .Spawn = idx };
                    _ = self.spawns.swapRemove(idx);
                },
                .Throne => |idx| {
                    const s = self.thrones.slice();
                    const last_throne = &s[s.len - 1];
                    const ls_xy = last_throne.xy;
                    self.cells[ls_xy.x][ls_xy.y] = .{ .Throne = idx };
                    _ = self.thrones.swapRemove(idx);
                },
                .None => unreachable,
                else => {},
            }
        }

        switch (cell_type) {
            .None => cell.* = .{ .None = {} },
            .Floor => cell.* = .{ .Floor = {} },
            .Wall => cell.* = .{ .Wall = {} },
            .Spawn => {
                self.spawns.append(.{ .xy = xy, .path_idx = 0 }) catch unreachable;
                cell.* = .{ .Spawn = @intCast(self.spawns.len - 1) };
            },
            .Throne => {
                self.thrones.append(.{ .xy = xy, .hp = 100 }) catch unreachable;
                cell.* = .{ .Throne = @intCast(self.thrones.len - 1) };
            },
        }
    }

    pub fn unset(self: *Self, x: i32, y: i32) void {
        const xy = Self.in_range(x, y) orelse return;
        const cell = &self.cells[xy.x][xy.y];

        if (std.meta.activeTag(cell.*) != .None) {
            switch (cell.*) {
                .Spawn => |idx| {
                    const s = self.spawns.slice();
                    const last_spawn = &s[s.len - 1];
                    const ls_xy = last_spawn.xy;
                    self.cells[ls_xy.x][ls_xy.y] = .{ .Spawn = idx };
                    _ = self.spawns.swapRemove(idx);
                },
                .Throne => |idx| {
                    const s = self.thrones.slice();
                    const last_throne = &s[s.len - 1];
                    const ls_xy = last_throne.xy;
                    self.cells[ls_xy.x][ls_xy.y] = .{ .Throne = idx };
                    _ = self.thrones.swapRemove(idx);
                },
                .None => unreachable,
                else => {},
            }
        }

        cell.* = .{ .None = {} };
    }

    fn distance_to_throne(throne_xy: XY, xy: XY) u8 {
        const dx =
            if (throne_xy.x < xy.x) xy.x - throne_xy.x else throne_xy.x - xy.x;
        const dy =
            if (throne_xy.y < xy.y) xy.y - throne_xy.y else throne_xy.y - xy.y;
        return dx + dy;
    }

    pub fn xy_to_vec3(xy: XY) math.Vec3 {
        return .{
            .x = @as(f32, @floatFromInt(xy.x)) + 0.5 - Level.RIGHT,
            .y = @as(f32, @floatFromInt(xy.y)) + 0.5 - Level.TOP,
            .z = 0.0,
        };
    }

    pub fn move_enemy_along_the_path(self: *Self, dt: f32) void {
        const enemy = &self.enemies.slice()[0];

        const current_path = self.paths.slice()[enemy.path_idx];
        if (current_path.len == 0) {
            return;
        }

        const current_node = current_path[enemy.path_node_idx];
        const next_node = current_path[enemy.path_node_idx + 1];

        const current_node_position = Self.xy_to_vec3(current_node);
        const next_node_position = Self.xy_to_vec3(next_node);

        enemy.position =
            current_node_position.lerp(next_node_position, enemy.path_node_progress);
        enemy.path_node_progress += dt;
        if (1.0 <= enemy.path_node_progress) {
            enemy.path_node_progress = 0.0;

            if (enemy.path_node_idx == current_path.len - 2) {
                enemy.path_node_idx = 0;
            } else {
                enemy.path_node_idx += 1;
            }
        }
    }

    const Item = packed struct(u32) {
        xy: XY,
        p: u16,

        fn cmp(_: void, a: Item, b: Item) std.math.Order {
            return std.math.order(a.p, b.p);
        }
    };
    fn valid_path_cell(self: *const Self, xy: XY) bool {
        const cell_type = std.meta.activeTag(self.cells[xy.x][xy.y]);
        return cell_type == .Floor or cell_type == .Throne;
    }
    pub fn find_path(self: *Self, scratch_alloc: Allocator) ?[]XY {
        if (self.thrones.len == 0 or self.spawns.len == 0)
            return null;

        const spawn = &self.spawns.slice()[0];
        const throne = &self.thrones.slice()[0];

        var to_explore: std.PriorityQueue(Item, void, Item.cmp) = .init(scratch_alloc, void{});
        defer to_explore.deinit();

        var came_from: [Self.WIDTH][Self.HEIGHT]XY =
            .{.{XY{ .x = 0, .y = 0 }} ** Self.HEIGHT} ** Self.WIDTH;
        var g_score: [Self.WIDTH][Self.HEIGHT]u16 =
            .{.{std.math.maxInt(u16)} ** Self.HEIGHT} ** Self.WIDTH;
        var f_score: [Self.WIDTH][Self.HEIGHT]u16 =
            .{.{std.math.maxInt(u16)} ** Self.HEIGHT} ** Self.WIDTH;

        to_explore.add(.{ .xy = spawn.xy, .p = 0 }) catch return null;
        g_score[spawn.xy.x][spawn.xy.y] = 0;
        f_score[spawn.xy.x][spawn.xy.y] = distance_to_throne(throne.xy, spawn.xy);

        while (to_explore.removeOrNull()) |current| {
            if (current.xy == throne.xy) {
                var path: std.ArrayListUnmanaged(XY) = .{};

                var i: u32 = 0;
                var c = current.xy;
                while (c != spawn.xy) : (i += 1) {
                    c = came_from[c.x][c.y];
                    path.append(scratch_alloc, c) catch return null;

                    log.assert(
                        @src(),
                        i < Self.WIDTH * Self.HEIGHT,
                        "Path is longer than number of cells on the grid",
                        .{},
                    );
                }
                const slice = path.toOwnedSlice(scratch_alloc) catch return null;
                // The path originally is from Throne to the Spawner, need to
                // reverse.
                std.mem.reverse(XY, slice);
                return slice;
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
                    if (self.valid_path_cell(n)) left else null
                else
                    null,
                if (right) |n|
                    if (self.valid_path_cell(n)) right else null
                else
                    null,
                if (bot) |n|
                    if (self.valid_path_cell(n)) bot else null
                else
                    null,
                if (top) |n|
                    if (self.valid_path_cell(n)) top else null
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
                    const new_f_score = new_g_score + distance_to_throne(throne.xy, nn);
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
        spawns: []const Spawn,
        thrones: []const Throne,

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
        for (0..Level.WIDTH) |x| {
            for (0..Level.HEIGHT) |y| {
                const cell = self.cells[x][y];
                if (std.meta.activeTag(cell) != .None)
                    try cells.append(scratch_alloc, .{
                        .xy = .{ .x = @intCast(x), .y = @intCast(y) },
                        .cell = cell,
                    });
            }
        }
        const save_state = SaveState{
            .cells = cells.items,
            .spawns = self.spawns.slice(),
            .thrones = self.thrones.slice(),
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

        for (0..Level.WIDTH) |x| {
            for (0..Level.HEIGHT) |y| {
                const cell = &self.cells[x][y];
                for (save_state.cells) |s_cell| {
                    if (s_cell.xy == XY{ .x = @intCast(x), .y = @intCast(y) }) {
                        cell.* = s_cell.cell;
                        break;
                    } else cell.* = .{ .None = {} };
                }
            }
        }
        for (save_state.spawns) |s| {
            self.spawns.append(s) catch unreachable;
        }
        for (save_state.thrones) |t| {
            self.thrones.append(t) catch unreachable;
        }
    }

    pub fn imgui_info(
        self: *Self,
        scratch_alloc: Allocator,
        gpa_alloc: Allocator,
    ) void {
        var cimgui_id: i32 = 512;
        var open: bool = true;

        if (cimgui.igCollapsingHeader_BoolPtr("Level", &open, 0)) {
            if (cimgui.igTreeNode_Str("Spawns")) {
                defer cimgui.igTreePop();

                for (self.spawns.slice(), 0..) |*spawn, i| {
                    cimgui.igPushID_Int(cimgui_id);
                    cimgui_id += 1;
                    defer cimgui.igPopID();

                    const label = std.fmt.allocPrintZ(
                        scratch_alloc,
                        "Spawn: {d}",
                        .{i},
                    ) catch unreachable;
                    _ = cimgui.igSeparatorText(label);
                    _ = cimgui.igValue_Uint("x", spawn.xy.x);
                    _ = cimgui.igValue_Uint("y", spawn.xy.y);
                    _ = cimgui.igValue_Uint("path_idx", spawn.path_idx);
                }
            }

            if (cimgui.igTreeNode_Str("Thrones")) {
                defer cimgui.igTreePop();

                for (self.thrones.slice(), 0..) |*throne, i| {
                    cimgui.igPushID_Int(cimgui_id);
                    cimgui_id += 1;
                    defer cimgui.igPopID();

                    const label = std.fmt.allocPrintZ(
                        scratch_alloc,
                        "Throne: {d}",
                        .{i},
                    ) catch unreachable;
                    _ = cimgui.igSeparatorText(label);
                    _ = cimgui.igValue_Uint("x", throne.xy.x);
                    _ = cimgui.igValue_Uint("y", throne.xy.y);
                    _ = cimgui.igValue_Int("hp", throne.hp);
                }
            }

            if (cimgui.igTreeNode_Str("Paths")) {
                defer cimgui.igTreePop();

                for (self.paths.slice(), 0..) |path, i| {
                    cimgui.igPushID_Int(cimgui_id);
                    cimgui_id += 1;
                    defer cimgui.igPopID();

                    const label = std.fmt.allocPrintZ(
                        scratch_alloc,
                        "Path: {d}",
                        .{i},
                    ) catch unreachable;
                    _ = cimgui.igSeparatorText(label);
                    _ = cimgui.igBeginChild_Str(
                        "",
                        .{},
                        cimgui.ImGuiChildFlags_Borders | cimgui.ImGuiChildFlags_ResizeY,
                        0,
                    );
                    defer cimgui.igEndChild();

                    for (path, 0..) |xy, j| {
                        const point = std.fmt.allocPrintZ(
                            scratch_alloc,
                            "{d}: x: {d} y: {d}",
                            .{ j, xy.x, xy.y },
                        ) catch unreachable;
                        _ = cimgui.igText(point);
                    }
                }
            }

            if (cimgui.igButton("Find path", .{})) {
                if (self.find_path(scratch_alloc)) |new_path| {
                    const current_path = &self.paths.slice()[0];

                    gpa_alloc.free(current_path.*);
                    current_path.* = gpa_alloc.alloc(XY, new_path.len) catch unreachable;
                    @memcpy(current_path.*, new_path);

                    const enemy = &self.enemies.slice()[0];
                    enemy.path_node_idx = 0;
                    enemy.path_node_progress = 0.0;
                }
            }

            _ = cimgui.igSeparatorText("Level Save/Load");
            _ = cimgui.igInputText(
                "File path",
                &self.path,
                self.path.len,
                0,
                null,
                null,
            );
            const path = std.mem.sliceTo(&self.path, 0);
            if (cimgui.igButton("Save level", .{})) {
                self.save(scratch_alloc, path) catch
                    log.err(@src(), "Cannot save level to {s}", .{path});
            }
            if (cimgui.igButton("Load level", .{})) {
                self.load(scratch_alloc, path) catch
                    log.err(@src(), "Cannot load level from {s}", .{path});
            }
        }
    }
};

pub const App = struct {
    gpa_allocator: DebugAllocator = .{},
    frame_allocator: FixedArena = .{},
    scratch_allocator: RoundArena = .{},

    assets_file_mem: memory.FileMem = undefined,

    materials: assets.Materials = undefined,
    meshes: assets.Meshes = undefined,

    mesh_shader: MeshShader = undefined,
    cube: GpuMesh = undefined,
    gpu_meshes: assets.GpuMeshes = undefined,
    debug_grid_shader: DebugGridShader = undefined,
    debug_grid: DebugGrid = undefined,
    debug_grid_scale: f32 = 10.0,

    floating_camera: Camera = .{},
    topdown_camera: Camera = .{},
    use_topdown_camera: bool = false,

    lmb_pressed: bool = false,
    rmb_pressed: bool = false,

    input_mode: InputMode = .Selection,
    show_grid: bool = true,
    level: Level = .{},
    current_cell_type: Level.CellType = .Floor,

    // current_path: []XY = &.{},
    // path_node_index: u32 = 0,
    // path_node_progress: f32 = 0.0,
    // enemy_position: ?math.Vec3 = null,

    mouse_closest_t: ?f32 = null,
    selected_cell_xy: ?XY = null,
    selected_cell_time: f32 = 0.0,

    const HILIGHT_COLOR: math.Vec4 = .{ .y = 1.0, .z = 1.0 };

    const InputMode = enum {
        Selection,
        Placement,
    };

    const Self = @This();

    pub fn init(self: *Self) !void {
        var gpa = DebugAllocator{};
        const gpa_alloc = gpa.allocator();

        const frame_allocator = FixedArena.init(try gpa_alloc.alloc(u8, 4096));
        const scratch_allocator = RoundArena.init(try gpa_alloc.alloc(u8, 4096));

        self.gpa_allocator = gpa;
        self.frame_allocator = frame_allocator;
        self.scratch_allocator = scratch_allocator;

        self.assets_file_mem =
            memory.FileMem.init(assets.DEFAULT_PACKED_ASSETS_PATH) catch unreachable;

        const mesh_shader = MeshShader.init();
        const debug_grid_shader = DebugGridShader.init();

        const unpack_result = assets.unpack(self.assets_file_mem.mem) catch unreachable;

        const cube = GpuMesh.init(Mesh.Vertex, Mesh.Cube.vertices, Mesh.Cube.indices);
        const gpu_meshes = assets.gpu_meshes_from_meshes(&unpack_result.meshes);

        const debug_grid = DebugGrid.init();

        const floating_camera: Camera = .{ .position = .{ .y = -10.0 } };
        const topdown_camera: Camera = .{
            .position = .{ .z = 10.0 },
            .pitch = -std.math.pi / 2.0,
            .top_down = true,
        };

        self.mesh_shader = mesh_shader;
        self.meshes = unpack_result.meshes;
        self.materials = unpack_result.materials;
        self.cube = cube;
        self.gpu_meshes = gpu_meshes;
        self.debug_grid_shader = debug_grid_shader;
        self.debug_grid = debug_grid;
        self.floating_camera = floating_camera;
        self.topdown_camera = topdown_camera;

        self.level = .{};
        const default_path = "resources/level.json";
        @memcpy(self.level.path[0..default_path.len], default_path);
        self.level.enemies.append(.{}) catch unreachable;
        self.level.paths.append(&.{}) catch unreachable;
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

        for (new_events) |event| {
            camera.process_input(event, dt);

            switch (event) {
                .Mouse => |mouse| {
                    switch (mouse) {
                        .Button => |button| {
                            switch (button.key) {
                                .LMB => self.lmb_pressed = button.type == .Pressed,
                                .RMB => self.rmb_pressed = button.type == .Pressed,
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

        const mouse_ray = camera.mouse_to_ray(mouse_clip);
        self.find_closest_mouse_t(&mouse_ray);

        if (self.input_mode == .Placement) {
            if (self.lmb_pressed)
                self.level.set(
                    @intFromFloat(@floor(mouse_xy.x)),
                    @intFromFloat(@floor(mouse_xy.y)),
                    self.current_cell_type,
                );
            if (self.rmb_pressed)
                self.level.unset(
                    @intFromFloat(@floor(mouse_xy.x)),
                    @intFromFloat(@floor(mouse_xy.y)),
                );
        }
        self.level.move_enemy_along_the_path(dt);

        self.draw_imgui();

        gl.glClearDepth(0.0);
        gl.glClearColor(0.0, 0.0, 0.0, 1.0);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT | gl.GL_DEPTH_BUFFER_BIT);

        for (0..Level.WIDTH) |x| {
            for (0..Level.HEIGHT) |y| {
                const cell = self.level.cells[x][y];
                switch (cell) {
                    .None => {},
                    else => {
                        const model_type = Level.cell_to_model_type(cell);
                        const p = Level.xy_to_vec3(.{ .x = @intCast(x), .y = @intCast(y) });
                        const model = math.Mat4.IDENDITY.translate(p);

                        const m = self.materials.getPtr(model_type);
                        var albedo = m.albedo;
                        if (self.selected_cell_xy) |xy| {
                            if (xy.x == x and xy.y == y) {
                                self.selected_cell_time += dt;
                                const t = @abs(@sin(self.selected_cell_time * 2.0));
                                albedo = Self.HILIGHT_COLOR.lerp(albedo, t);
                            }
                        }
                        self.mesh_shader.setup(
                            &camera.position,
                            &camera.view,
                            &camera.projection,
                            &model,
                            &.{ .x = 2.0, .y = 0.0, .z = 4.0 },
                            &albedo,
                            m.metallic,
                            m.roughness,
                            1.0,
                        );
                        self.gpu_meshes.getPtr(model_type).draw();
                    },
                }
            }
        }

        for (self.level.enemies.slice()) |*enemy| {
            const transform = math.Mat4.IDENDITY.translate(enemy.position);
            const m = self.materials.getPtr(.Enemy);
            self.mesh_shader.setup(
                &camera.position,
                &camera.view,
                &camera.projection,
                &transform,
                &.{ .x = 2.0, .y = 0.0, .z = 4.0 },
                &m.albedo,
                m.metallic,
                m.roughness,
                1.0,
            );
            self.gpu_meshes.getPtr(.Enemy).draw();
        }

        for (self.level.paths.slice()) |path| {
            for (path) |xy| {
                const p = Level.xy_to_vec3(xy);
                const model = math.Mat4.IDENDITY.translate(p);

                const m = self.materials.getPtr(.PathMarker);
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
                self.gpu_meshes.getPtr(.PathMarker).draw();
            }
        }

        if (false) {
            if (self.mouse_closest_t) |t| {
                const p = mouse_ray.at_t(t);
                const model = math.Mat4.IDENDITY
                    .translate(p).scale(.{ .x = 0.2, .y = 0.2, .z = 0.2 });

                self.mesh_shader.setup(
                    &camera.position,
                    &camera.view,
                    &camera.projection,
                    &model,
                    &.{ .x = 2.0, .y = 0.0, .z = 4.0 },
                    &.{ .x = 1.0, .y = 0.0, .z = 0.0 },
                    0.0,
                    0.0,
                    1.0,
                );
                self.cube.draw();
            }
        }

        if (self.show_grid) {
            self.debug_grid_shader.setup(
                &camera.view,
                &camera.projection,
                &camera.inverse_view,
                &camera.inverse_projection,
                self.debug_grid_scale,
                &Level.LIMITS,
            );
            self.debug_grid.draw();
        }

        const imgui_data = cimgui.igGetDrawData();
        cimgui.ImGui_ImplOpenGL3_RenderDrawData(imgui_data);
    }

    pub fn find_closest_mouse_t(
        self: *Self,
        mouse_ray: *const math.Ray,
    ) void {
        if (self.input_mode != .Selection)
            return;

        if (!self.lmb_pressed)
            return;

        self.mouse_closest_t = null;
        for (0..Level.WIDTH) |x| {
            for (0..Level.HEIGHT) |y| {
                const cell = self.level.cells[x][y];
                switch (cell) {
                    .None => {},
                    else => {
                        const model_type = Level.cell_to_model_type(cell);
                        const transform = math.Mat4.IDENDITY
                            .translate(.{
                            .x = @as(f32, @floatFromInt(x)) + 0.5 - Level.RIGHT,
                            .y = @as(f32, @floatFromInt(y)) + 0.5 - Level.TOP,
                            .z = 0.0,
                        });

                        const mesh = self.meshes.getPtr(model_type);
                        var ti = mesh.triangle_iterator();
                        while (ti.next()) |t| {
                            const tt = t.translate(&transform);

                            const is_ccw = math.triangle_ccw(mouse_ray.direction, &tt);
                            if (!is_ccw)
                                continue;

                            if (math.triangle_ray_intersect(
                                mouse_ray,
                                &tt,
                            )) |i| {
                                self.selected_cell_time = 0.0;
                                const xy: XY = .{ .x = @intCast(x), .y = @intCast(y) };
                                if (self.mouse_closest_t) |cpt| {
                                    if (i.t < cpt) {
                                        self.mouse_closest_t = i.t;
                                        self.selected_cell_xy = xy;
                                    }
                                } else {
                                    self.mouse_closest_t = i.t;
                                    self.selected_cell_xy = xy;
                                }
                                break;
                            }
                        }
                    },
                }
            }
        }
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
            "Editor",
            &open,
            cimgui.ImGuiTreeNodeFlags_DefaultOpen,
        )) {
            _ = cimgui.igSeparatorText("Input mode");
            if (cimgui.igSelectable_Bool("Selection", self.input_mode == .Selection, 0, .{}))
                self.input_mode = .Selection;
            if (cimgui.igSelectable_Bool("Placement", self.input_mode == .Placement, 0, .{}))
                self.input_mode = .Placement;

            if (self.input_mode == .Placement) {
                _ = cimgui.igSeparatorText("Cell type");
                if (cimgui.igSelectable_Bool("Floor", self.current_cell_type == .Floor, 0, .{}))
                    self.current_cell_type = .Floor;
                if (cimgui.igSelectable_Bool("Wall", self.current_cell_type == .Wall, 0, .{}))
                    self.current_cell_type = .Wall;
                if (cimgui.igSelectable_Bool("Spawn", self.current_cell_type == .Spawn, 0, .{}))
                    self.current_cell_type = .Spawn;
                if (cimgui.igSelectable_Bool("Throne", self.current_cell_type == .Throne, 0, .{}))
                    self.current_cell_type = .Throne;
            }
        }

        self.level.imgui_info(scratch_alloc, gpa_alloc);
    }
};
