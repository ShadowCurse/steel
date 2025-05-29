const std = @import("std");
const log = @import("log.zig");
const cimgui = @import("bindings/cimgui.zig");
const math = @import("math.zig");
const assets = @import("assets.zig");
const memory = @import("memory.zig");
const RoundArena = memory.RoundArena;
const Allocator = memory.Allocator;
const ObjectPool = memory.ObjectPool;

scratch_alloc: Allocator = undefined,
path_allocator: RoundArena = undefined,

path: [256]u8 = .{0} ** 256,

cells: [Self.WIDTH][Self.HEIGHT]Cell = .{.{Cell{ .None = {} }} ** Self.HEIGHT} ** Self.WIDTH,

spawns: ObjectPool(Spawn, SPAWNS) = .{},
thrones: ObjectPool(Throne, THRONES) = .{},
enemies: ObjectPool(Enemy, ENEMIES) = .{},

selected_object: SelectedObject = .None,

const Self = @This();

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

pub const SelectedObject = union(enum) {
    None: void,
    Spawn: *Spawn,
    Throne: *Throne,
    Enemy: *Enemy,
};

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
            .position = xy_to_vec3(path[0]),
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
            const target = xy_to_vec3(target_xy);
            const to_target = target.sub(self.position).normalize();
            self.position = self.position.add(to_target.mul_f32(self.speed * dt));

            if (in_cell(target_xy, self.position)) {
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

pub const CellType = enum {
    None,
    Floor,
    Wall,
    Spawn,
    Throne,
};

pub const Cell = union(CellType) {
    None: void,
    Floor: void,
    Wall: void,
    Spawn: *Spawn,
    Throne: *Throne,
};

pub fn init(self: *Self, scratch_alloc: Allocator, gpa_alloc: Allocator) void {
    self.scratch_alloc = scratch_alloc;
    self.path_allocator = .init(
        gpa_alloc.alignedAlloc(u8, @alignOf(XY), @sizeOf(XY) * PATHS * WIDTH * HEIGHT) catch unreachable,
    );

    const default_path = "resources/level.json";
    @memcpy(self.path[0..default_path.len], default_path);
}

pub fn cell_to_model_type(cell: Cell) assets.ModelType {
    return switch (cell) {
        .None => log.panic(@src(), "Trying to convert cell of None type to model type", .{}),
        .Floor => |_| .Floor,
        .Wall => |_| .Wall,
        .Spawn => |_| .Spawn,
        .Throne => |_| .Throne,
    };
}

pub fn in_cell(xy: XY, position: math.Vec3) bool {
    const cell_position = Self.xy_to_vec3(xy);
    const dx = position.x - cell_position.x;
    const dy = position.y - cell_position.y;
    return @abs(dx) < 0.5 and @abs(dy) < 0.5;
}

pub fn in_range(x: i32, y: i32) ?XY {
    if (x < Self.LEFT or Self.RIGHT < x or y < Self.BOT or Self.TOP <= y)
        return null
    else
        return .{ .x = @intCast(x + RIGHT), .y = @intCast(y + TOP) };
}

fn free_cell(self: *Self, xy: XY) void {
    const cell = &self.cells[xy.x][xy.y];
    if (std.meta.activeTag(cell.*) != .None) {
        switch (cell.*) {
            .Spawn => |spawn| {
                self.spawns.free(spawn);
            },
            .Throne => |throne| {
                self.thrones.free(throne);
            },
            else => {},
        }
    }
}

pub fn set(self: *Self, x: i32, y: i32, cell_type: CellType) void {
    const xy = Self.in_range(x, y) orelse return;
    const cell = &self.cells[xy.x][xy.y];
    switch (cell_type) {
        .None => cell.* = .{ .None = {} },
        .Floor => cell.* = .{ .Floor = {} },
        .Wall => cell.* = .{ .Wall = {} },
        .Spawn => {
            if (self.spawns.alloc()) |new_spawn| {
                new_spawn.* = .{ .xy = xy };
                self.free_cell(xy);
                cell.* = .{ .Spawn = new_spawn };
            } else log.warn(
                @src(),
                "Cannot place any more spawns. MAX is {d}",
                .{@as(u32, SPAWNS)},
            );
        },
        .Throne => {
            if (self.thrones.alloc()) |new_throne| {
                new_throne.* = .{ .xy = xy };
                self.free_cell(xy);
                cell.* = .{ .Throne = new_throne };
            } else log.warn(
                @src(),
                "Cannot place any more thrones. MAX is {d}",
                .{@as(u32, THRONES)},
            );
        },
    }
    self.update_enemies_paths();
}

pub fn unset(self: *Self, x: i32, y: i32) void {
    const xy = Self.in_range(x, y) orelse return;
    const cell = &self.cells[xy.x][xy.y];
    self.free_cell(xy);
    cell.* = .{ .None = {} };
    self.update_enemies_paths();
}

pub fn xy_to_vec3(xy: XY) math.Vec3 {
    return .{
        .x = @as(f32, @floatFromInt(xy.x)) + 0.5 - RIGHT,
        .y = @as(f32, @floatFromInt(xy.y)) + 0.5 - TOP,
        .z = 0.0,
    };
}

pub fn run_spawns(self: *Self, dt: f32) void {
    var iter = self.spawns.iterator();
    while (iter.next()) |spawn| {
        if (!spawn.active) continue;

        spawn.spawn_time_remaining -= dt;
        if (spawn.spawn_time_remaining <= 0.0) {
            spawn.spawn_time_remaining = spawn.spawn_time;
            if (self.find_path(spawn.xy)) |new_path| {
                if (self.enemies.alloc()) |new_enemy|
                    new_enemy.* = .init(new_path)
                else {
                    log.warn(@src(), "Cannot spawn enemies. Capacity is full", .{});
                    return;
                }
            }
        }
    }
}

pub fn update_enemies(self: *Self, dt: f32) void {
    var iter = self.enemies.iterator();
    while (iter.next()) |enemy| {
        enemy.move(dt);
        if (enemy.finished) {
            self.enemies.free(enemy);
        }
    }
}

pub fn update_enemies_paths(self: *Self) void {
    var iter = self.enemies.iterator();
    while (iter.next()) |enemy| {
        const new_path = self.find_path(enemy.current_xy);
        enemy.update_path(new_path);
        log.info(@src(), "Enemy: {} found new path: {}", .{ enemy, new_path != null });
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

pub fn reset(self: *Self) void {
    self.spawns.reset();
    self.thrones.reset();
    self.enemies.reset();
}

const SaveState = struct {
    cells: []const SavedCell,
    const SavedCell = struct {
        xy: XY,
        cell: Cell,
    };
};
pub fn save(self: *const Self, path: []const u8) !void {
    var file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    const options = std.json.StringifyOptions{
        .whitespace = .indent_4,
    };
    var cells: std.ArrayListUnmanaged(SaveState.SavedCell) = .{};
    for (0..WIDTH) |x| {
        for (0..HEIGHT) |y| {
            const cell = self.cells[x][y];
            if (std.meta.activeTag(cell) != .None)
                try cells.append(self.scratch_alloc, .{
                    .xy = .{ .x = @intCast(x), .y = @intCast(y) },
                    .cell = cell,
                });
        }
    }
    const save_state = SaveState{
        .cells = cells.items,
    };
    try std.json.stringify(save_state, options, file.writer());
}

pub fn load(self: *Self, path: []const u8) !void {
    self.reset();

    const file_mem = try memory.FileMem.init(path);
    defer file_mem.deinit();

    const ss = try std.json.parseFromSlice(
        SaveState,
        self.scratch_alloc,
        file_mem.mem,
        .{},
    );

    const save_state = &ss.value;

    for (0..WIDTH) |x| {
        for (0..HEIGHT) |y| {
            const cell = &self.cells[x][y];
            for (save_state.cells) |s_cell| {
                if (s_cell.xy == XY{ .x = @intCast(x), .y = @intCast(y) }) {
                    switch (s_cell.cell) {
                        .Spawn => |spawn| {
                            const new_spawn = self.spawns.alloc().?;
                            new_spawn.* = spawn.*;
                            cell.* = .{ .Spawn = new_spawn };
                        },
                        .Throne => |throne| {
                            const new_throne = self.thrones.alloc().?;
                            new_throne.* = throne.*;
                            cell.* = .{ .Throne = new_throne };
                        },
                        else => cell.* = s_cell.cell,
                    }
                    break;
                } else cell.* = .{ .None = {} };
            }
        }
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

            var iter = self.spawns.iterator();
            var i: u32 = 0;
            while (iter.next()) |spawn| : (i += 1) {
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

            var iter = self.thrones.iterator();
            var i: u32 = 0;
            while (iter.next()) |throne| : (i += 1) {
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

            var iter = self.enemies.iterator();
            var i: u32 = 0;
            while (iter.next()) |enemy| : (i += 1) {
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

        _ = cimgui.igSeparatorText("Save/Load");
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
            self.save(path) catch
                log.err(@src(), "Cannot save level to {s}", .{path});
        }
        if (cimgui.igButton("Load level", .{})) {
            self.load(path) catch
                log.err(@src(), "Cannot load level from {s}", .{path});
        }
    }
}
