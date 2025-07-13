const std = @import("std");
const builtin = @import("builtin");
const log = @import("log.zig");
const sdl = @import("bindings/sdl.zig");
const gl = @import("bindings/gl.zig");
const cimgui = @import("bindings/cimgui.zig");

const math = @import("math.zig");
const events = @import("events.zig");
const shaders = @import("shaders.zig");

const memory = @import("memory.zig");
const FixedArena = memory.FixedArena;
const RoundArena = memory.RoundArena;
const Allocator = memory.Allocator;
const DebugAllocator = memory.DebugAllocator;

const types = @import("types.zig");

const Level = @import("level.zig");
const Mesh = @import("mesh.zig");
const Camera = @import("camera.zig");
const Platform = @import("platform.zig");
const Audio = @import("audio.zig");
const Renderer = @import("renderer.zig");
const Assets = @import("assets.zig");
const BoundedArray = std.BoundedArray;

const Input = @import("input.zig");

pub const log_options = log.Options{
    .level = .Info,
    .colors = builtin.target.os.tag != .emscripten,
};

pub const os = if (builtin.os.tag != .emscripten) std.os else struct {
    pub const heap = struct {
        pub const page_allocator = std.heap.c_allocator;
    };
};

/// For some reason emsdk does not have it, so raw dog it.
export fn _emscripten_memcpy_js(dest: [*]u8, src: [*]u8, len: usize) void {
    var d: []u8 = undefined;
    d.ptr = dest;
    d.len = len;
    var s: []u8 = undefined;
    s.ptr = src;
    s.len = len;
    @memcpy(d, s);
}

pub fn main() !void {
    Platform.init();
    Renderer.init();
    try Audio.init();

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

pub const App = struct {
    gpa_allocator: DebugAllocator = .{},
    frame_allocator: FixedArena = .{},
    scratch_allocator: RoundArena = .{},

    assets_file_mem: memory.FileMem = undefined,

    topdown_camera: Camera = .{},
    free_camera: Camera = .{},
    game_camera: Camera = .{},
    camera_type: Camera.Type = .Game,

    level: Level = .{},
    current_crystals: u32 = 0,
    lost: bool = false,

    game_mode: GameMode = .Paused,
    input_mode: InputMode = .Selection,
    show_grid: bool = true,
    current_cell_type: Level.CellType = .Floor,

    selected_item: ?Level.XY = null,
    selected_item_time: f32 = 0.0,

    const HILIGHT_COLOR: math.Color4 = .{ .g = 1.0, .b = 1.0 };

    const GameMode = enum {
        Paused,
        Running,
    };

    const InputMode = enum {
        Game,
        Selection,
        Placement,
    };

    const ENVIRONMENT: shaders.MeshShader.Environment = .{
        .lights_position = .{
            .{ .x = 1.0, .y = 1.0, .z = 1.0 },
            .{ .x = -1.0, .y = 1.0, .z = 1.0 },
            .{ .x = 1.0, .y = -1.0, .z = 1.0 },
            .{ .x = -1.0, .y = -1.0, .z = 1.0 },
        },
        .lights_color = .{
            .{ .r = 1.0 },
            .{ .g = 1.0 },
            .{ .b = 1.0 },
            .{ .r = 1.0, .g = 1.0, .b = 1.0 },
        },
        .direct_light_direction = .{ .x = -0.5, .y = -0.5, .z = -1.0 },
        .direct_light_color = .{ .r = 1.0, .g = 1.0, .b = 1.0 },
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
            memory.FileMem.init(Assets.DEFAULT_PACKED_ASSETS_PATH) catch unreachable;
        Assets.init(self.assets_file_mem.mem) catch unreachable;

        const topdown_camera: Camera = .{
            .position = .{ .z = 10.0 },
            .pitch = -std.math.pi / 2.0,
            .type = .TopDown,
        };
        const free_camera: Camera = .{ .position = .{ .y = -5.0, .z = 5.0 }, .pitch = -1.1 };
        const game_camera: Camera = .{
            .position = .{ .y = -5.0, .z = 5.0 },
            .pitch = -1.0,
            .yaw = -0.5,
            .type = .Game,
        };

        self.free_camera = free_camera;
        self.topdown_camera = topdown_camera;
        self.game_camera = game_camera;

        self.level.init(self.scratch_allocator.allocator(), self.gpa_allocator.allocator());

        Audio.play(.Background, 0.5, 0.5);
    }

    pub fn update(
        self: *Self,
        dt: f32,
    ) !void {
        self.frame_allocator.reset();

        const imgui_wants_to_handle_events = Platform.imgui_wants_to_handle_events();
        var new_events = Platform.input_events;

        const camera = switch (self.camera_type) {
            .TopDown => &self.topdown_camera,
            .Free => &self.free_camera,
            .Game => &self.game_camera,
        };

        if (imgui_wants_to_handle_events) {
            new_events = &.{};
            camera.velocity = .{};
        }

        Input.update(new_events);

        for (new_events) |event| {
            camera.process_input(event, dt);
        }
        camera.move(dt);

        const mouse_clip = Platform.mouse_clip();
        const mouse_xy = camera.mouse_to_xy(mouse_clip);

        const mouse_ray = camera.mouse_to_ray(mouse_clip);
        self.select_cell(&mouse_ray);

        if (self.input_mode == .Placement) {
            if (Input.lmb_now_pressed)
                self.level.set(
                    @intFromFloat(@floor(mouse_xy.x)),
                    @intFromFloat(@floor(mouse_xy.y)),
                    self.current_cell_type,
                );
            if (Input.rmb_now_pressed)
                self.level.unset(
                    @intFromFloat(@floor(mouse_xy.x)),
                    @intFromFloat(@floor(mouse_xy.y)),
                );
        }

        if (self.game_mode == .Running) {
            self.damage_clicked_enemy(&mouse_ray);
            self.collect_crystals();
            self.check_thrones();
            self.level.progress_traps(dt);
            self.level.spawn_enemies(dt);
            self.level.update_enemies(dt);
        }

        self.prepare_imgui_frame();
        {
            Renderer.reset();
            defer Renderer.render(camera, &Self.ENVIRONMENT);

            self.draw_level(dt);
            self.draw_ui();
        }

        const imgui_data = cimgui.igGetDrawData();
        cimgui.ImGui_ImplOpenGL3_RenderDrawData(imgui_data);
    }

    pub fn select_cell(
        self: *Self,
        mouse_ray: *const math.Ray,
    ) void {
        if (!Input.lmb_was_pressed)
            return;

        self.selected_item = self.level.hovered_cell(mouse_ray);
    }

    pub fn damage_clicked_enemy(
        self: *Self,
        mouse_ray: *const math.Ray,
    ) void {
        if (!Input.lmb_was_pressed)
            return;

        if (self.level.hovered_enemy(mouse_ray)) |enemy|
            enemy.hp -= Level.CLICK_DAMAGE;
    }

    pub fn collect_crystals(self: *Self) void {
        if (!Input.lmb_was_pressed)
            return;

        if (self.selected_item) |si| {
            const cell = self.level.get_cell(si);
            switch (cell.*) {
                .Crystal => |_| {
                    self.current_crystals += 1;
                },
                else => {},
            }
        }
    }

    pub fn check_thrones(self: *Self) void {
        self.lost = self.level.thrones.empty();
    }

    pub fn draw_level(self: *Self, dt: f32) void {
        for (0..Level.WIDTH) |x| {
            for (0..Level.HEIGHT) |y| {
                const cell = self.level.cells[x][y];
                switch (cell) {
                    .None => {},
                    else => {
                        const model_type = Level.cell_to_model_type(cell);
                        const p = Level.xy_to_vec3(.{ .x = @intCast(x), .y = @intCast(y) });
                        const transform = math.Mat4.IDENDITY.translate(p);

                        var material = Assets.materials.get(model_type);

                        // quick hack to change color
                        switch (cell) {
                            .FloorTrap => |ft| {
                                if (!ft.active)
                                    material.albedo = material.albedo.lerp(
                                        .{ .r = 0.9, .g = 0.45, .b = 0.05, .a = 1.0 },
                                        1.0 - ft.activate_time_remaining / ft.activate_time,
                                    )
                                else
                                    material.albedo = material.albedo.lerp(
                                        .{ .r = 1.0, .a = 1.0 },
                                        1.0 - ft.active_time_remaining / ft.active_time,
                                    );
                            },
                            else => {},
                        }

                        if (self.input_mode != .Game) {
                            if (self.selected_item) |xy| {
                                if (xy.x == x and xy.y == y) {
                                    self.selected_item_time += dt;
                                    const t = @abs(@sin(self.selected_item_time * 2.0));
                                    material.albedo = Self.HILIGHT_COLOR.lerp(material.albedo, t);
                                }
                            }
                        }
                        Renderer.draw_mesh(
                            Assets.gpu_meshes.getPtrConst(model_type),
                            transform,
                            material,
                        );
                    },
                }
            }
        }

        var iter = self.level.enemies.iterator();
        while (iter.next()) |enemy| {
            {
                const transform = math.Mat4.IDENDITY.translate(enemy.position);
                var material = Assets.materials.get(.Enemy);

                const t =
                    @as(f32, @floatFromInt(enemy.hp)) /
                    @as(f32, @floatFromInt(enemy.max_hp));
                material.albedo = Level.Enemy.NO_HP_COLOR.lerp(material.albedo, t);

                Renderer.draw_mesh(
                    Assets.gpu_meshes.getPtrConst(.Enemy),
                    transform,
                    material,
                );
            }

            if (enemy.show_path) {
                if (enemy.path) |path| {
                    for (path, 0..) |xy, i| {
                        const p = Level.xy_to_vec3(xy);
                        const transform = math.Mat4.IDENDITY.translate(p);

                        var material = Assets.materials.get(.PathMarker);
                        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(path.len));
                        material.albedo = material.albedo.lerp(.{ .r = 1.0 }, t);

                        Renderer.draw_mesh(
                            Assets.gpu_meshes.getPtrConst(.Enemy),
                            transform,
                            material,
                        );
                    }
                }
            }
        }
    }

    pub fn draw_ui(self: *Self) void {
        Renderer.draw_text(
            "TEST",
            .{ .x = 0.0, .y = -4.0, .z = 2.0 },
            1.0,
            .GREEN,
            .World,
        );

        const c = std.fmt.allocPrint(
            self.scratch_allocator.allocator(),
            "Crystals: {d}",
            .{self.current_crystals},
        ) catch unreachable;
        Renderer.draw_text(
            c,
            .{ .x = 0.0, .y = 650.0 },
            64.0,
            .WHITE,
            .Screen,
        );

        if (self.lost)
            Renderer.draw_text(
                "LOST",
                .{ .x = 0.0, .y = 2.0, .z = 2.0 },
                1.0,
                .RED,
                .World,
            );

        var it = self.level.thrones.const_iterator();
        while (it.next()) |throne| {
            var position = Level.xy_to_vec3(throne.xy);
            position.z = 1.5;
            const hp = std.fmt.allocPrint(
                self.scratch_allocator.allocator(),
                "HP: {d}",
                .{throne.hp},
            ) catch unreachable;
            Renderer.draw_text(
                hp,
                position,
                0.5,
                .WHITE,
                .World,
            );
        }
    }

    pub fn prepare_imgui_frame(self: *Self) void {
        var open: bool = true;

        cimgui.ImGui_ImplOpenGL3_NewFrame();
        cimgui.ImGui_ImplSDL3_NewFrame();
        cimgui.igNewFrame();
        defer cimgui.igRender();

        var cimgui_id: i32 = 0;
        _ = cimgui.igBegin("options", &open, 0);
        defer cimgui.igEnd();

        if (cimgui.igCollapsingHeader_BoolPtr("Mouse info", &open, 0)) {
            _ = cimgui.igSeparatorText("Mouse");
            _ = cimgui.igValue_Uint("x", Platform.mouse_position.x);
            _ = cimgui.igValue_Uint("y", Platform.mouse_position.y);

            Input.imgui_info();
        }

        if (cimgui.igCollapsingHeader_BoolPtr("Camera", &open, 0)) {
            cimgui.format("Camera type", &self.camera_type);

            {
                cimgui.igPushID_Int(cimgui_id);
                cimgui_id += 1;
                defer cimgui.igPopID();

                cimgui.format("Topdown camera", &self.topdown_camera);
            }
            {
                cimgui.igPushID_Int(cimgui_id);
                cimgui_id += 1;
                defer cimgui.igPopID();

                cimgui.format("Floating camera", &self.free_camera);
            }
            {
                cimgui.igPushID_Int(cimgui_id);
                cimgui_id += 1;
                defer cimgui.igPopID();

                cimgui.format("Game camera", &self.game_camera);
            }
        }

        if (cimgui.igCollapsingHeader_BoolPtr("Debug grid", &open, 0)) {
            _ = cimgui.igCheckbox("Enabled", &Renderer.show_debug_grid);
            _ = cimgui.igDragFloat(
                "scale",
                &Renderer.debug_grid_scale,
                0.1,
                1.0,
                100.0,
                null,
                0,
            );
        }

        if (cimgui.igCollapsingHeader_BoolPtr("Materials", &open, 0)) {
            var iter = Assets.materials.iterator();
            while (iter.next()) |m| {
                cimgui.igPushID_Int(cimgui_id);
                cimgui_id += 1;
                defer cimgui.igPopID();

                cimgui.format(null, m.value);
            }
        }

        if (cimgui.igCollapsingHeader_BoolPtr(
            "Editor",
            &open,
            cimgui.ImGuiTreeNodeFlags_DefaultOpen,
        )) {
            cimgui.format("Game mode", &self.game_mode);
            cimgui.format("Input mode", &self.input_mode);
            if (self.input_mode == .Placement) {
                cimgui.format("Cell type", &self.current_cell_type);
            }
        }

        self.level.imgui_info();
        Audio.imgui_info();
    }
};
