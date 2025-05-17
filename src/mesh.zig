const gl = @import("bindings/gl.zig");
const _math = @import("math.zig");
const Vec3 = _math.Vec3;
const Vec4 = _math.Vec4;

indices: []const u32,
vertices: []const Vertex,

const Self = @This();

pub const Vertex = extern struct {
    position: Vec3 = .{},
    uv_x: f32 = 0.0,
    normal: Vec3 = .{},
    uv_y: f32 = 0.0,
    color: Vec4 = .{},

    pub fn set_attributes() void {
        gl.glVertexAttribPointer(0, 3, gl.GL_FLOAT, gl.GL_FALSE, @sizeOf(Vertex), @ptrFromInt(0));
        gl.glVertexAttribPointer(1, 1, gl.GL_FLOAT, gl.GL_FALSE, @sizeOf(Vertex), @ptrFromInt(3 * @sizeOf(f32)));
        gl.glVertexAttribPointer(2, 3, gl.GL_FLOAT, gl.GL_FALSE, @sizeOf(Vertex), @ptrFromInt(4 * @sizeOf(f32)));
        gl.glVertexAttribPointer(3, 1, gl.GL_FLOAT, gl.GL_FALSE, @sizeOf(Vertex), @ptrFromInt(7 * @sizeOf(f32)));
        gl.glVertexAttribPointer(4, 4, gl.GL_FLOAT, gl.GL_FALSE, @sizeOf(Vertex), @ptrFromInt(8 * @sizeOf(f32)));
        gl.glEnableVertexAttribArray(0);
        gl.glEnableVertexAttribArray(1);
        gl.glEnableVertexAttribArray(2);
        gl.glEnableVertexAttribArray(3);
        gl.glEnableVertexAttribArray(4);
    }
};

pub const Cube = Self{
    .indices = &.{
        1,
        14,
        20,
        1,
        20,
        7,
        10,
        6,
        19,
        10,
        19,
        23,
        21,
        18,
        12,
        21,
        12,
        15,
        16,
        3,
        9,
        16,
        9,
        22,
        5,
        2,
        8,
        5,
        8,
        11,
        17,
        13,
        0,
        17,
        0,
        4,
    },
    .vertices = &.{
        .{
            .position = Vec3{ .x = 0.5, .y = 0.5, .z = -0.5 },
            .normal = Vec3{ .x = 0.0, .y = 0.0, .z = -1.0 },
            .uv_x = 6.25e-1,
            .uv_y = 5e-1,
            .color = Vec4{ .x = 0.0, .y = 0.0, .z = -1.0, .w = 1.0 },
        },
        .{
            .position = Vec3{ .x = 0.5, .y = 0.5, .z = -0.5 },
            .normal = Vec3{ .x = 0.0, .y = 1.0, .z = 0.0 },
            .uv_x = 6.25e-1,
            .uv_y = 5e-1,
            .color = Vec4{ .x = 0.0, .y = 1.0, .z = 0.0, .w = 1.0 },
        },
        .{
            .position = Vec3{ .x = 0.5, .y = 0.5, .z = -0.5 },
            .normal = Vec3{ .x = 1.0, .y = 0.0, .z = 0.0 },
            .uv_x = 6.25e-1,
            .uv_y = 5e-1,
            .color = Vec4{ .x = 1.0, .y = 0.0, .z = 0.0, .w = 1.0 },
        },
        .{
            .position = Vec3{ .x = 0.5, .y = -0.5, .z = -0.5 },
            .normal = Vec3{ .x = 0.0, .y = -1.0, .z = 0.0 },
            .uv_x = 3.75e-1,
            .uv_y = 5e-1,
            .color = Vec4{ .x = 0.0, .y = -1.0, .z = 0.0, .w = 1.0 },
        },
        .{
            .position = Vec3{ .x = 0.5, .y = -0.5, .z = -0.5 },
            .normal = Vec3{ .x = 0.0, .y = 0.0, .z = -1.0 },
            .uv_x = 3.75e-1,
            .uv_y = 5e-1,
            .color = Vec4{ .x = 0.0, .y = 0.0, .z = -1.0, .w = 1.0 },
        },
        .{
            .position = Vec3{ .x = 0.5, .y = -0.5, .z = -0.5 },
            .normal = Vec3{ .x = 1.0, .y = 0.0, .z = 0.0 },
            .uv_x = 3.75e-1,
            .uv_y = 5e-1,
            .color = Vec4{ .x = 1.0, .y = 0.0, .z = 0.0, .w = 1.0 },
        },
        .{
            .position = Vec3{ .x = 0.5, .y = 0.5, .z = 0.5 },
            .normal = Vec3{ .x = 0.0, .y = 0.0, .z = 1.0 },
            .uv_x = 6.25e-1,
            .uv_y = 2.5e-1,
            .color = Vec4{ .x = 0.0, .y = 0.0, .z = 1.0, .w = 1.0 },
        },
        .{
            .position = Vec3{ .x = 0.5, .y = 0.5, .z = 0.5 },
            .normal = Vec3{ .x = 0.0, .y = 1.0, .z = 0.0 },
            .uv_x = 6.25e-1,
            .uv_y = 2.5e-1,
            .color = Vec4{ .x = 0.0, .y = 1.0, .z = 0.0, .w = 1.0 },
        },
        .{
            .position = Vec3{ .x = 0.5, .y = 0.5, .z = 0.5 },
            .normal = Vec3{ .x = 1.0, .y = 0.0, .z = 0.0 },
            .uv_x = 6.25e-1,
            .uv_y = 2.5e-1,
            .color = Vec4{ .x = 1.0, .y = 0.0, .z = 0.0, .w = 1.0 },
        },
        .{
            .position = Vec3{ .x = 0.5, .y = -0.5, .z = 0.5 },
            .normal = Vec3{ .x = 0.0, .y = -1.0, .z = 0.0 },
            .uv_x = 3.75e-1,
            .uv_y = 2.5e-1,
            .color = Vec4{ .x = 0.0, .y = -1.0, .z = 0.0, .w = 1.0 },
        },
        .{
            .position = Vec3{ .x = 0.5, .y = -0.5, .z = 0.5 },
            .normal = Vec3{ .x = 0.0, .y = 0.0, .z = 1.0 },
            .uv_x = 3.75e-1,
            .uv_y = 2.5e-1,
            .color = Vec4{ .x = 0.0, .y = 0.0, .z = 1.0, .w = 1.0 },
        },
        .{
            .position = Vec3{ .x = 0.5, .y = -0.5, .z = 0.5 },
            .normal = Vec3{ .x = 1.0, .y = 0.0, .z = 0.0 },
            .uv_x = 3.75e-1,
            .uv_y = 2.5e-1,
            .color = Vec4{ .x = 1.0, .y = 0.0, .z = 0.0, .w = 1.0 },
        },
        .{
            .position = Vec3{ .x = -0.5, .y = 0.5, .z = -0.5 },
            .normal = Vec3{ .x = -1.0, .y = 0.0, .z = 0.0 },
            .uv_x = 6.25e-1,
            .uv_y = 7.5e-1,
            .color = Vec4{ .x = -1.0, .y = 0.0, .z = 0.0, .w = 1.0 },
        },
        .{
            .position = Vec3{ .x = -0.5, .y = 0.5, .z = -0.5 },
            .normal = Vec3{ .x = 0.0, .y = 0.0, .z = -1.0 },
            .uv_x = 6.25e-1,
            .uv_y = 7.5e-1,
            .color = Vec4{ .x = 0.0, .y = 0.0, .z = -1.0, .w = 1.0 },
        },
        .{
            .position = Vec3{ .x = -0.5, .y = 0.5, .z = -0.5 },
            .normal = Vec3{ .x = 0.0, .y = 1.0, .z = 0.0 },
            .uv_x = 8.75e-1,
            .uv_y = 5e-1,
            .color = Vec4{ .x = 0.0, .y = 1.0, .z = 0.0, .w = 1.0 },
        },
        .{
            .position = Vec3{ .x = -0.5, .y = -0.5, .z = -0.5 },
            .normal = Vec3{ .x = -1.0, .y = 0.0, .z = 0.0 },
            .uv_x = 3.75e-1,
            .uv_y = 7.5e-1,
            .color = Vec4{ .x = -1.0, .y = 0.0, .z = 0.0, .w = 1.0 },
        },
        .{
            .position = Vec3{ .x = -0.5, .y = -0.5, .z = -0.5 },
            .normal = Vec3{ .x = 0.0, .y = -1.0, .z = 0.0 },
            .uv_x = 1.25e-1,
            .uv_y = 5e-1,
            .color = Vec4{ .x = 0.0, .y = -1.0, .z = 0.0, .w = 1.0 },
        },
        .{
            .position = Vec3{ .x = -0.5, .y = -0.5, .z = -0.5 },
            .normal = Vec3{ .x = 0.0, .y = 0.0, .z = -1.0 },
            .uv_x = 3.75e-1,
            .uv_y = 7.5e-1,
            .color = Vec4{ .x = 0.0, .y = 0.0, .z = -1.0, .w = 1.0 },
        },
        .{
            .position = Vec3{ .x = -0.5, .y = 0.5, .z = 0.5 },
            .normal = Vec3{ .x = -1.0, .y = 0.0, .z = 0.0 },
            .uv_x = 6.25e-1,
            .uv_y = 0.5,
            .color = Vec4{ .x = -1.0, .y = 0.0, .z = 0.0, .w = 1.0 },
        },
        .{
            .position = Vec3{ .x = -0.5, .y = 0.5, .z = 0.5 },
            .normal = Vec3{ .x = 0.0, .y = 0.0, .z = 1.0 },
            .uv_x = 6.25e-1,
            .uv_y = 0.0,
            .color = Vec4{ .x = 0.0, .y = 0.0, .z = 1.0, .w = 1.0 },
        },
        .{
            .position = Vec3{ .x = -0.5, .y = 0.5, .z = 0.5 },
            .normal = Vec3{ .x = 0.0, .y = 1.0, .z = 0.0 },
            .uv_x = 8.75e-1,
            .uv_y = 2.5e-1,
            .color = Vec4{ .x = 0.0, .y = 1.0, .z = 0.0, .w = 1.0 },
        },
        .{
            .position = Vec3{ .x = -0.5, .y = -0.5, .z = 0.5 },
            .normal = Vec3{ .x = -1.0, .y = 0.0, .z = 0.0 },
            .uv_x = 3.75e-1,
            .uv_y = 0.5,
            .color = Vec4{ .x = -1.0, .y = 0.0, .z = 0.0, .w = 1.0 },
        },
        .{
            .position = Vec3{ .x = -0.5, .y = -0.5, .z = 0.5 },
            .normal = Vec3{ .x = 0.0, .y = -1.0, .z = 0.0 },
            .uv_x = 1.25e-1,
            .uv_y = 2.5e-1,
            .color = Vec4{ .x = 0.0, .y = -1.0, .z = 0.0, .w = 1.0 },
        },
        .{
            .position = Vec3{ .x = -0.5, .y = -0.5, .z = 0.5 },
            .normal = Vec3{ .x = 0.0, .y = 0.0, .z = 1.0 },
            .uv_x = 3.75e-1,
            .uv_y = 0.0,
            .color = Vec4{ .x = 0.0, .y = 0.0, .z = 1.0, .w = 1.0 },
        },
    },
};
