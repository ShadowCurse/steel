const std = @import("std");
const gl = @import("bindings/gl.zig");
const log = @import("log.zig");
const math = @import("math.zig");
const assets = @import("assets.zig");
const gpu = @import("gpu.zig");
const shaders = @import("shaders.zig");

const Level = @import("level.zig");
const Camera = @import("camera.zig");

pub var mesh_shader: shaders.MeshShader = undefined;
pub var mesh_infos: std.BoundedArray(RenderMeshInfo, 128) = .{};

pub var text_shader: shaders.TextShader = undefined;
pub var char_infos: std.BoundedArray(RenderCharInfo, 128) = .{};

// debug things
pub var show_debug_grid: bool = true;
pub var debug_grid_scale: f32 = 10.0;
pub var debug_grid_shader: shaders.DebugGridShader = undefined;

const RenderMeshInfo = struct {
    mesh: *const gpu.Mesh,
    model: math.Mat4,
    material: assets.Material,
};

pub const RenderCharMode = enum {
    World,
    Screen,
};
pub const RenderCharInfo = struct {
    mode: RenderCharMode,
    position: math.Vec3,
    color: math.Color3,
    width: f32,
    height: f32,
    texture_scale_x: f32 = 0.0,
    texture_scale_y: f32 = 0.0,
    texture_offset_x: f32 = 0.0,
    texture_offset_y: f32 = 0.0,
};

const Self = @This();

pub fn init() void {
    Self.mesh_shader = .init();
    Self.text_shader = .init();
    Self.debug_grid_shader = .init();
}

pub fn reset() void {
    Self.mesh_infos.clear();
    Self.char_infos.clear();

    gl.glClearDepth(0.0);
    gl.glClearColor(0.0, 0.0, 0.0, 1.0);
    gl.glClear(gl.GL_COLOR_BUFFER_BIT | gl.GL_DEPTH_BUFFER_BIT);
}

pub fn draw_mesh(
    mesh: *const gpu.Mesh,
    model: math.Mat4,
    material: assets.Material,
) void {
    const mesh_info = RenderMeshInfo{
        .mesh = mesh,
        .model = model,
        .material = material,
    };
    Self.mesh_infos.append(mesh_info) catch {
        log.warn(@src(), "Cannot add more meshes to draw queue", .{});
    };
}

pub fn draw_text(
    text: []const u8,
    position: math.Vec3,
    size: f32,
    color: math.Color3,
    mode: RenderCharMode,
) void {
    const font = assets.fonts.getPtrConst(.Default);
    const scale = size / font.size;
    const font_scale = scale * font.scale();
    var offset: math.Vec3 = .{};

    for (text, 0..) |c, i| {
        var char = c;
        const char_info = if (font.get_char_info(char)) |ci| blk: {
            break :blk ci;
        } else blk: {
            log.warn(@src(), "Trying to get info about unknown character: {d}", .{char});
            char = '?';
            break :blk font.get_char_info(char).?;
        };
        const char_kern = if (0 < i) blk: {
            const prev_char = text[i - 1];
            break :blk font.get_kerning(prev_char, char);
        } else blk: {
            break :blk 0.0;
        };

        offset.x += char_kern * font_scale;
        const char_origin = position.add(offset);
        const char_offset = math.Vec3{
            .x = char_info.x_offset + char_info.width * 0.5,
            .y = -char_info.y_offset - char_info.height * 0.5,
        };
        const char_position = char_origin.add(char_offset.mul_f32(scale));

        const render_char_info = RenderCharInfo{
            .mode = mode,
            .position = char_position,
            .color = color,
            .width = char_info.width * scale,
            .height = char_info.height * scale,
            .texture_scale_x = char_info.width,
            .texture_scale_y = char_info.height,
            .texture_offset_x = char_info.texture_offset_x,
            .texture_offset_y = char_info.texture_offset_y,
        };

        Self.char_infos.append(render_char_info) catch {
            log.warn(@src(), "Cannot add more chars to draw queue", .{});
            return;
        };

        offset.x += char_info.x_advance * scale;
    }
}

pub fn render(
    camera: *const Camera,
    environment: *const shaders.MeshShader.Environment,
) void {
    Self.mesh_shader.use();
    Self.mesh_shader.set_scene_params(
        &camera.view,
        &camera.position,
        &camera.projection,
        environment,
    );
    for (Self.mesh_infos.slice()) |*mi| {
        Self.mesh_shader.set_mesh_params(&mi.model, &mi.material);
        mi.mesh.draw();
    }

    if (Self.show_debug_grid) {
        Self.debug_grid_shader.setup(
            &camera.view,
            &camera.projection,
            &camera.inverse_view,
            &camera.inverse_projection,
            Self.debug_grid_scale,
            &Level.LIMITS,
        );
        Self.debug_grid_shader.draw();
    }

    Self.text_shader.use();
    Self.text_shader.set_font(assets.gpu_fonts.getPtrConst(.Default));
    for (Self.char_infos.slice()) |*ci| {
        Self.text_shader.set_char_info(camera, ci);
        Self.text_shader.draw();
    }
}
