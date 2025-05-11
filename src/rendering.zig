const std = @import("std");
const builtin = @import("builtin");
const log = @import("log.zig");
const gl = @import("bindings/gl.zig");
const math = @import("math.zig");
const FileMem = @import("memory.zig").FileMem;

pub const Shader = struct {
    vertex_shader: u32,
    fragment_shader: u32,
    shader: u32,

    const Self = @This();

    pub fn init(vertex_shader_path: []const u8, fragment_shader_path: []const u8) Self {
        const vertex_shader_src =
            FileMem.init(vertex_shader_path) catch @panic("cannot read vertex shader");
        defer vertex_shader_src.deinit();

        const fragment_shader_src =
            FileMem.init(fragment_shader_path) catch @panic("cannot read fragment shader");
        defer fragment_shader_src.deinit();

        const vertex_shader = gl.glCreateShader(gl.GL_VERTEX_SHADER);
        const v_ptr = [_]*const u8{@ptrCast(vertex_shader_src.mem.ptr)};
        const v_len: i32 = @intCast(vertex_shader_src.mem.len);
        gl.glShaderSource(
            vertex_shader,
            1,
            @ptrCast(&v_ptr),
            @ptrCast(&v_len),
        );
        gl.glCompileShader(vertex_shader);
        check_shader_result(@src(), vertex_shader, gl.GL_COMPILE_STATUS);

        const fragment_shader = gl.glCreateShader(gl.GL_FRAGMENT_SHADER);
        const f_ptr = [_]*const u8{@ptrCast(fragment_shader_src.mem.ptr)};
        const f_len: i32 = @intCast(fragment_shader_src.mem.len);
        gl.glShaderSource(
            fragment_shader,
            1,
            @ptrCast(&f_ptr),
            @ptrCast(&f_len),
        );
        gl.glCompileShader(fragment_shader);
        check_shader_result(@src(), fragment_shader, gl.GL_COMPILE_STATUS);

        const shader = gl.glCreateProgram();
        gl.glAttachShader(shader, vertex_shader);
        gl.glAttachShader(shader, fragment_shader);
        gl.glLinkProgram(shader);
        check_program_result(@src(), shader, gl.GL_LINK_STATUS);

        return .{
            .vertex_shader = vertex_shader,
            .fragment_shader = fragment_shader,
            .shader = shader,
        };
    }

    pub fn get_uniform_location(self: *const Self, name: [*c]const u8) i32 {
        return gl.glGetUniformLocation(self.shader, name);
    }

    pub fn use(self: *const Self) void {
        gl.glUseProgram(self.shader);
    }

    fn check_shader_result(
        comptime src: std.builtin.SourceLocation,
        shader: u32,
        tag: u32,
    ) void {
        var success: i32 = undefined;
        gl.glGetShaderiv(shader, tag, &success);
        if (success != gl.GL_TRUE) {
            var buff: [1024]u8 = undefined;
            var s: i32 = undefined;
            gl.glGetShaderInfoLog(shader, 1024, &s, &buff);
            log.assert(
                src,
                false,
                "error in shader: {s}({d})",
                .{ buff[0..@intCast(s)], s },
            );
        }
    }

    fn check_program_result(
        comptime src: std.builtin.SourceLocation,
        shader: u32,
        tag: u32,
    ) void {
        var success: i32 = undefined;
        gl.glGetProgramiv(shader, tag, &success);
        if (success != gl.GL_TRUE) {
            var buff: [1024]u8 = undefined;
            var s: i32 = undefined;
            gl.glGetProgramInfoLog(shader, 1024, &s, &buff);
            log.assert(
                src,
                false,
                "error in shader: {s}({d})",
                .{ buff[0..@intCast(s)], s },
            );
        }
    }
};

pub const MeshShader = struct {
    shader: Shader,

    view_loc: i32,
    projection_loc: i32,
    model_loc: i32,
    color_loc: i32,
    camera_pos_loc: i32,
    light_pos_loc: i32,

    const Self = @This();

    pub fn init() Self {
        const shader = if (builtin.target.os.tag == .emscripten)
            Shader.init("resources/shaders/mesh_web.vert", "resources/shaders/mesh_web.frag")
        else
            Shader.init("resources/shaders/mesh.vert", "resources/shaders/mesh.frag");

        const view_loc = shader.get_uniform_location("view");
        const projection_loc = shader.get_uniform_location("projection");
        const model_loc = shader.get_uniform_location("model");
        const color_loc = shader.get_uniform_location("color");
        const camera_pos_loc = shader.get_uniform_location("camera_position");
        const light_pos_loc = shader.get_uniform_location("light_position");

        return .{
            .shader = shader,
            .view_loc = view_loc,
            .projection_loc = projection_loc,
            .model_loc = model_loc,
            .color_loc = color_loc,
            .camera_pos_loc = camera_pos_loc,
            .light_pos_loc = light_pos_loc,
        };
    }

    pub fn setup(
        self: *const Self,
        camera_position: *const math.Vec3,
        camera_view: *const math.Mat4,
        camera_projection: *const math.Mat4,
        model: *const math.Mat4,
        color: *const math.Vec3,
        light_position: *const math.Vec3,
    ) void {
        self.shader.use();
        gl.glUniformMatrix4fv(self.view_loc, 1, gl.GL_FALSE, @ptrCast(camera_view));
        gl.glUniformMatrix4fv(self.projection_loc, 1, gl.GL_FALSE, @ptrCast(camera_projection));
        gl.glUniformMatrix4fv(self.model_loc, 1, gl.GL_FALSE, @ptrCast(model));
        gl.glUniform3f(self.color_loc, color.x, color.y, color.z);
        gl.glUniform3f(self.camera_pos_loc, camera_position.x, camera_position.y, camera_position.z);
        gl.glUniform3f(self.light_pos_loc, light_position.x, light_position.y, light_position.z);
    }
};

pub const Mesh = struct {
    vertex_buffer: u32,
    index_buffer: u32,
    n_indices: i32,
    vertex_array: u32,

    const Self = @This();

    pub fn init(VERTEX_TYPE: type, vertices: []const VERTEX_TYPE, indices: []const u32) Self {
        var vertex_buffer: u32 = undefined;
        gl.glGenBuffers(1, &vertex_buffer);
        gl.glBindBuffer(gl.GL_ARRAY_BUFFER, vertex_buffer);
        gl.glBufferData(
            gl.GL_ARRAY_BUFFER,
            @intCast(@sizeOf(VERTEX_TYPE) * vertices.len),
            vertices.ptr,
            gl.GL_STATIC_DRAW,
        );

        var index_buffer: u32 = undefined;
        gl.glGenBuffers(1, &index_buffer);
        gl.glBindBuffer(gl.GL_ELEMENT_ARRAY_BUFFER, index_buffer);
        gl.glBufferData(
            gl.GL_ELEMENT_ARRAY_BUFFER,
            @intCast(@sizeOf(u32) * indices.len),
            indices.ptr,
            gl.GL_STATIC_DRAW,
        );
        const n_indices: i32 = @intCast(indices.len);

        var vertex_array: u32 = undefined;
        gl.glGenVertexArrays(1, &vertex_array);
        gl.glBindVertexArray(vertex_array);
        gl.glBindBuffer(gl.GL_ARRAY_BUFFER, vertex_buffer);
        gl.glBindBuffer(gl.GL_ELEMENT_ARRAY_BUFFER, index_buffer);
        VERTEX_TYPE.set_attributes();

        return .{
            .vertex_buffer = vertex_buffer,
            .index_buffer = index_buffer,
            .n_indices = n_indices,
            .vertex_array = vertex_array,
        };
    }

    pub fn draw(self: *const Self) void {
        gl.glBindVertexArray(self.vertex_array);
        gl.glDrawElements(gl.GL_TRIANGLES, self.n_indices, gl.GL_UNSIGNED_INT, null);
    }
};

pub const DebugGrid = struct {
    buffer: if (builtin.target.os.tag == .emscripten) u32 else void,
    vertex_array: if (builtin.target.os.tag == .emscripten) u32 else void,

    const Self = @This();

    pub fn init() Self {
        if (builtin.target.os.tag == .emscripten) {
            const planes = [_]math.Vec3{
                math.Vec3{ .x = 1, .y = 1, .z = 0 },
                math.Vec3{ .x = -1, .y = 1, .z = 0 },
                math.Vec3{ .x = -1, .y = -1, .z = 0 },
                math.Vec3{ .x = -1, .y = -1, .z = 0 },
                math.Vec3{ .x = 1, .y = -1, .z = 0 },
                math.Vec3{ .x = 1, .y = 1, .z = 0 },
            };
            var buffer: u32 = undefined;
            gl.glGenBuffers(1, &buffer);
            gl.glBindBuffer(gl.GL_ARRAY_BUFFER, buffer);
            gl.glBufferData(
                gl.GL_ARRAY_BUFFER,
                @sizeOf(@TypeOf(planes)),
                &planes,
                gl.GL_STATIC_DRAW,
            );

            var vertex_array: u32 = undefined;
            gl.glGenVertexArrays(1, &vertex_array);
            gl.glBindVertexArray(vertex_array);
            gl.glBindBuffer(gl.GL_ARRAY_BUFFER, buffer);
            gl.glVertexAttribPointer(
                0,
                3,
                gl.GL_FLOAT,
                gl.GL_FALSE,
                @sizeOf(math.Vec3),
                @ptrFromInt(0),
            );
            gl.glEnableVertexAttribArray(0);
            return .{ .buffer = buffer, .vertex_array = vertex_array };
        } else {
            return .{ .buffer = {}, .vertex_array = {} };
        }
    }

    pub fn draw(self: *const Self) void {
        if (builtin.target.os.tag == .emscripten) {
            gl.glBindVertexArray(self.vertex_array);
        }
        gl.glDrawArrays(gl.GL_TRIANGLES, 0, 6);
    }
};

pub const DebugGridShader = struct {
    shader: Shader,

    view_loc: i32,
    projection_loc: i32,
    scale_loc: i32,
    inverse_view_loc: if (builtin.target.os.tag == .emscripten) i32 else void,
    inverse_projection_loc: if (builtin.target.os.tag == .emscripten) i32 else void,

    const Self = @This();

    pub fn init() Self {
        const shader = if (builtin.target.os.tag == .emscripten)
            Shader.init("resources/shaders/grid_web.vert", "resources/shaders/grid_web.frag")
        else
            Shader.init("resources/shaders/grid.vert", "resources/shaders/grid.frag");

        const view_loc = shader.get_uniform_location("view");
        const projection_loc = shader.get_uniform_location("projection");
        const scale_loc = shader.get_uniform_location("scale");

        const inverse_view_loc = if (builtin.target.os.tag == .emscripten)
            shader.get_uniform_location("inverse_view")
        else {};

        const inverse_projection_loc = if (builtin.target.os.tag == .emscripten)
            shader.get_uniform_location("inverse_projection")
        else {};

        return .{
            .shader = shader,
            .view_loc = view_loc,
            .projection_loc = projection_loc,
            .scale_loc = scale_loc,
            .inverse_view_loc = inverse_view_loc,
            .inverse_projection_loc = inverse_projection_loc,
        };
    }

    pub fn setup(
        self: *const Self,
        camera_view: *const math.Mat4,
        camera_projection: *const math.Mat4,
        camera_inverse_view: *const math.Mat4,
        camera_inverse_projection: *const math.Mat4,
        scale: f32,
    ) void {
        self.shader.use();
        gl.glUniformMatrix4fv(self.view_loc, 1, gl.GL_FALSE, @ptrCast(camera_view));
        gl.glUniformMatrix4fv(self.projection_loc, 1, gl.GL_FALSE, @ptrCast(camera_projection));
        gl.glUniform1f(self.scale_loc, scale);

        if (builtin.target.os.tag == .emscripten) {
            gl.glUniformMatrix4fv(
                self.inverse_view_loc,
                1,
                gl.GL_FALSE,
                @ptrCast(camera_inverse_view),
            );
            gl.glUniformMatrix4fv(
                self.inverse_projection_loc,
                1,
                gl.GL_FALSE,
                @ptrCast(camera_inverse_projection),
            );
        }
    }
};
