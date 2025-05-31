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

const Level = @import("level.zig");
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
    selected_cell_xy: ?Level.XY = null,
    selected_cell_time: f32 = 0.0,

    const HILIGHT_COLOR: math.Color4 = .{ .g = 1.0, .b = 1.0 };

    const InputMode = enum {
        Selection,
        Placement,
    };

    const LIGHTS_POSITION: [MeshShader.NUM_LIGHTS]math.Vec3 = .{
        .{ .x = 1.0, .y = 1.0, .z = 1.0 },
        .{ .x = -1.0, .y = 1.0, .z = 1.0 },
        .{ .x = 1.0, .y = -1.0, .z = 1.0 },
        .{ .x = -1.0, .y = -1.0, .z = 1.0 },
    };
    const LIGHTS_COLOR: [MeshShader.NUM_LIGHTS]math.Color3 = .{
        .{ .r = 1.0 },
        .{ .g = 1.0 },
        .{ .b = 1.0 },
        .{ .r = 1.0, .g = 1.0, .b = 1.0 },
    };
    const DIRECT_LIGHT_DIRECTION: math.Vec3 = .{ .x = -0.5, .y = -0.5, .z = -1.0 };
    const DIRECT_LIGHT_COLOR: math.Color3 = .{ .r = 1.0, .g = 1.0, .b = 1.0 };

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
                            &LIGHTS_POSITION,
                            &LIGHTS_COLOR,
                            &DIRECT_LIGHT_DIRECTION,
                            &DIRECT_LIGHT_COLOR,
                            &albedo,
                            m.metallic,
                            m.roughness,
                            0.03,
                        );
                        self.gpu_meshes.getPtr(model_type).draw();
                    },
                }
            }
        }

        var iter = self.level.enemies.iterator();
        while (iter.next()) |enemy| {
            {
                const transform = math.Mat4.IDENDITY.translate(enemy.position);
                const m = self.materials.getPtr(.Enemy);
                self.mesh_shader.setup(
                    &camera.position,
                    &camera.view,
                    &camera.projection,
                    &transform,
                    &LIGHTS_POSITION,
                    &LIGHTS_COLOR,
                    &DIRECT_LIGHT_DIRECTION,
                    &DIRECT_LIGHT_COLOR,
                    &m.albedo,
                    m.metallic,
                    m.roughness,
                    0.03,
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
                            &LIGHTS_POSITION,
                            &LIGHTS_COLOR,
                            &DIRECT_LIGHT_DIRECTION,
                            &DIRECT_LIGHT_COLOR,
                            &m.albedo.lerp(.{ .r = 1.0 }, t),
                            m.metallic,
                            m.roughness,
                            0.03,
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
                    &LIGHTS_POSITION,
                    &LIGHTS_COLOR,
                    &DIRECT_LIGHT_DIRECTION,
                    &DIRECT_LIGHT_COLOR,
                    &.{ .x = 1.0, .y = 0.0, .z = 0.0 },
                    0.0,
                    0.0,
                    0.03,
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
                                const xy: Level.XY = .{ .x = @intCast(x), .y = @intCast(y) };
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
