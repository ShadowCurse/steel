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

const types = @import("types.zig");

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
    xy: XY = .{},
    spawn_time: f32 = 1.0,
    spawn_time_remaining: f32 = 1.0,

    active: bool = true,
};

pub const Throne = struct {
    xy: XY = .{},
    hp: i32 = 100,
};

pub const Enemy = struct {
    position: math.Vec3 = .{},
    path: ?[]XY = null,
    current_xy: XY = .{},
    finished: bool = false,

    speed: f32 = 1.0,
    hp: i32 = 10,
    damage: i32 = 10,

    show_path: bool = false,

    pub fn init(path: []XY) Enemy {
        return .{
            .position = Level.xy_to_vec3(path[0]),
            .current_xy = path[0],
            .path = path[1..],
        };
    }

    pub fn update_path(self: *Enemy, path: ?[]XY) void {
        if (path) |p| {
            self.current_xy = p[0];
            self.path = p[1..];
        } else self.path = null;
    }

    pub fn move(self: *Enemy, dt: f32) void {
        if (self.path) |path| {
            if (path.len == 0) {
                self.finished = true;
                return;
            }

            const target_xy = path[0];
            const target = Level.xy_to_vec3(target_xy);
            const to_target = target.sub(self.position).normalize();
            self.position = self.position.add(to_target.mul_f32(self.speed * dt));

            if (Level.in_cell(target_xy, self.position)) {
                self.current_xy = path[0];
                self.path = path[1..];
                if (path.len == 0) {
                    self.finished = true;
                }
            }
        }
    }
};

pub const XY = packed struct(u16) { x: u8 = 0, y: u8 = 0 };
pub const Level = struct {
    scratch_alloc: Allocator = undefined,
    path_allocator: RoundArena = undefined,

    path: [256]u8 = .{0} ** 256,

    cells: [Self.WIDTH][Self.HEIGHT]Cell = .{.{Cell{ .None = {} }} ** Self.HEIGHT} ** Self.WIDTH,

    spawns: BoundedArray(Spawn, SPAWNS) = .{},
    enemies: BoundedArray(Enemy, ENEMIES) = .{},
    thrones: BoundedArray(Throne, THRONES) = .{},

    pub const SPAWNS = 4;
    pub const ENEMIES = 32;
    pub const THRONES = 4;
    pub const PATHS = SPAWNS + ENEMIES;

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

    fn init(self: *Self, scratch_alloc: Allocator, gpa_alloc: Allocator) void {
        self.scratch_alloc = scratch_alloc;
        self.path_allocator = .init(
            gpa_alloc.alignedAlloc(u8, @alignOf(XY), @sizeOf(XY) * PATHS * WIDTH * HEIGHT) catch unreachable,
        );

        const default_path = "resources/level.json";
        @memcpy(self.path[0..default_path.len], default_path);
    }

    fn cell_to_model_type(cell: Cell) assets.ModelType {
        return switch (cell) {
            .None => log.panic(@src(), "Trying to convert cell of None type to model type", .{}),
            .Floor => |_| .Floor,
            .Wall => |_| .Wall,
            .Spawn => |_| .Spawn,
            .Throne => |_| .Throne,
        };
    }

    fn in_cell(xy: XY, position: math.Vec3) bool {
        const cell_position = Self.xy_to_vec3(xy);
        const dx = position.x - cell_position.x;
        const dy = position.y - cell_position.y;
        return @abs(dx) < 0.5 and @abs(dy) < 0.5;
    }

    fn in_range(x: i32, y: i32) ?XY {
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
                self.spawns.append(.{ .xy = xy }) catch unreachable;
                cell.* = .{ .Spawn = @intCast(self.spawns.len - 1) };
            },
            .Throne => {
                self.thrones.append(.{ .xy = xy }) catch unreachable;
                cell.* = .{ .Throne = @intCast(self.thrones.len - 1) };
            },
        }

        self.update_enemies_paths();
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

        self.update_enemies_paths();
    }

    pub fn xy_to_vec3(xy: XY) math.Vec3 {
        return .{
            .x = @as(f32, @floatFromInt(xy.x)) + 0.5 - Level.RIGHT,
            .y = @as(f32, @floatFromInt(xy.y)) + 0.5 - Level.TOP,
            .z = 0.0,
        };
    }

    pub fn run_spawns(self: *Self, dt: f32) void {
        for (self.spawns.slice()) |*spawn| {
            if (!spawn.active) continue;

            spawn.spawn_time_remaining -= dt;
            if (spawn.spawn_time_remaining <= 0.0) {
                spawn.spawn_time_remaining = spawn.spawn_time;
                if (self.find_path(spawn.xy)) |new_path| {
                    self.enemies.append(.init(new_path)) catch {
                        log.warn(@src(), "Cannot spawn enemies. Capacity is full", .{});
                        return;
                    };
                }
            }
        }
    }

    pub fn update_enemies(self: *Self, dt: f32) void {
        const enemies = self.enemies.slice();
        for (enemies) |*enemy| {
            enemy.move(dt);
        }
        var i: usize = 0;
        var end = enemies.len;
        while (i < end) : (i += 1) {
            if (enemies[i].finished) {
                _ = self.enemies.swapRemove(i);
                end -= 1;
            }
        }
    }

    pub fn update_enemies_paths(self: *Self) void {
        for (self.enemies.slice(), 0..) |*enemy, i| {
            const new_path = self.find_path(enemy.current_xy);
            enemy.update_path(new_path);
            log.info(@src(), "Enemy: {d} found new path: {}", .{ i, new_path != null });
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
    pub fn find_path(self: *Self, start_xy: XY) ?[]XY {
        var to_explore: std.PriorityQueue(Item, void, Item.cmp) = .init(self.scratch_alloc, void{});

        var came_from: [Self.WIDTH][Self.HEIGHT]XY =
            .{.{XY{ .x = 0, .y = 0 }} ** Self.HEIGHT} ** Self.WIDTH;
        var g_score: [Self.WIDTH][Self.HEIGHT]u16 =
            .{.{std.math.maxInt(u16)} ** Self.HEIGHT} ** Self.WIDTH;
        var f_score: [Self.WIDTH][Self.HEIGHT]u16 =
            .{.{std.math.maxInt(u16)} ** Self.HEIGHT} ** Self.WIDTH;

        to_explore.add(.{ .xy = start_xy, .p = 0 }) catch return null;
        g_score[start_xy.x][start_xy.y] = 0;
        f_score[start_xy.x][start_xy.y] = 0;

        while (to_explore.removeOrNull()) |current| {
            if (std.meta.activeTag(self.cells[current.xy.x][current.xy.y]) == .Throne) {
                var path: std.ArrayListUnmanaged(XY) = .{};
                path.append(self.scratch_alloc, current.xy) catch return null;

                var i: u32 = 0;
                var c = current.xy;
                while (c != start_xy) : (i += 1) {
                    c = came_from[c.x][c.y];
                    path.append(self.scratch_alloc, c) catch return null;

                    log.assert(
                        @src(),
                        i < Self.WIDTH * Self.HEIGHT,
                        "Path is longer than number of cells on the grid",
                        .{},
                    );
                }
                const slice =
                    path.toOwnedSlice(self.path_allocator.allocator()) catch return null;
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
                    const new_f_score = new_g_score;
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
    ) void {
        var cimgui_id: i32 = 512;
        var open: bool = true;

        if (cimgui.igCollapsingHeader_BoolPtr(
            "Level",
            &open,
            cimgui.ImGuiTreeNodeFlags_DefaultOpen,
        )) {
            if (cimgui.igTreeNode_Str("Spawns")) {
                defer cimgui.igTreePop();

                for (self.spawns.slice(), 0..) |*spawn, i| {
                    cimgui.igPushID_Int(cimgui_id);
                    cimgui_id += 1;
                    defer cimgui.igPopID();

                    const label = std.fmt.allocPrintZ(
                        self.scratch_alloc,
                        "Spawn: {d}",
                        .{i},
                    ) catch unreachable;
                    _ = cimgui.igSeparatorText(label);

                    cimgui.format(spawn);
                }
            }

            if (cimgui.igTreeNode_Str("Thrones")) {
                defer cimgui.igTreePop();

                for (self.thrones.slice(), 0..) |*throne, i| {
                    cimgui.igPushID_Int(cimgui_id);
                    cimgui_id += 1;
                    defer cimgui.igPopID();

                    const label = std.fmt.allocPrintZ(
                        self.scratch_alloc,
                        "Throne: {d}",
                        .{i},
                    ) catch unreachable;
                    _ = cimgui.igSeparatorText(label);

                    cimgui.format(throne);
                }
            }

            if (cimgui.igTreeNode_Str("Enemies")) {
                defer cimgui.igTreePop();

                for (self.enemies.slice(), 0..) |*enemy, i| {
                    cimgui.igPushID_Int(cimgui_id);
                    cimgui_id += 1;
                    defer cimgui.igPopID();

                    const label = std.fmt.allocPrintZ(
                        self.scratch_alloc,
                        "Enemy: {d}",
                        .{i},
                    ) catch unreachable;
                    _ = cimgui.igSeparatorText(label);
                    cimgui.format(enemy);
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
                self.save(self.scratch_alloc, path) catch
                    log.err(@src(), "Cannot save level to {s}", .{path});
            }
            if (cimgui.igButton("Load level", .{})) {
                self.load(self.scratch_alloc, path) catch
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

    level: Level = .{},

    input_mode: InputMode = .Selection,
    show_grid: bool = true,
    current_cell_type: Level.CellType = .Floor,

    mouse_closest_t: ?f32 = null,
    selected_cell_xy: ?XY = null,
    selected_cell_time: f32 = 0.0,

    const HILIGHT_COLOR: math.Color4 = .{ .g = 1.0, .b = 1.0 };

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

        const floating_camera: Camera = .{ .position = .{ .y = -5.0, .z = 5.0 }, .pitch = -1.1 };
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

        self.level.init(self.scratch_allocator.allocator(), self.gpa_allocator.allocator());
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
        // self.level.move_enemy_along_the_path(dt);
        self.level.run_spawns(dt);
        self.level.update_enemies(dt);

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
            {
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

            if (enemy.show_path) {
                if (enemy.path) |path| {
                    for (path, 0..) |xy, i| {
                        const p = Level.xy_to_vec3(xy);
                        const model = math.Mat4.IDENDITY.translate(p);

                        const m = self.materials.getPtr(.PathMarker);
                        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(path.len));
                        self.mesh_shader.setup(
                            &camera.position,
                            &camera.view,
                            &camera.projection,
                            &model,
                            &.{ .x = 2.0, .y = 0.0, .z = 4.0 },
                            &m.albedo.lerp(.{ .r = 1.0 }, t),
                            m.metallic,
                            m.roughness,
                            1.0,
                        );
                        self.gpu_meshes.getPtr(.PathMarker).draw();
                    }
                }
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

                cimgui.format(&self.floating_camera);
            }
            _ = cimgui.igSeparatorText(
                if (self.use_topdown_camera) "Topdown camera +" else "Topdown camera",
            );
            {
                cimgui.igPushID_Int(cimgui_id);
                cimgui_id += 1;
                defer cimgui.igPopID();

                cimgui.format(&self.topdown_camera);
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

                cimgui.format(m.value);
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

        self.level.imgui_info();
    }
};
