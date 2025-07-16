const std = @import("std");
const builtin = @import("builtin");
const gl = @import("bindings/gl.zig");
const log = @import("log.zig");
const math = @import("math.zig");
const assets = @import("assets.zig");
const gpu = @import("gpu.zig");

const Camera = @import("camera.zig");
const Platform = @import("platform.zig");
const Renderer = @import("renderer.zig");
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

    pub fn get_uniform_location(self: *const Shader, name: [*c]const u8) i32 {
        return gl.glGetUniformLocation(self.shader, name);
    }

    pub fn use(self: *const Shader) void {
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
    shadow_map_view_loc: i32,
    shadow_map_projection_loc: i32,

    camera_pos_loc: i32,
    lights_pos_loc: i32,
    lights_color_loc: i32,
    direct_light_direction: i32,
    direct_light_color: i32,
    albedo_loc: i32,
    metallic_loc: i32,
    roughness_loc: i32,
    ao_loc: i32,

    pub const NUM_LIGHTS = 4;

    pub const Environment = struct {
        lights_position: [MeshShader.NUM_LIGHTS]math.Vec3,
        lights_color: [MeshShader.NUM_LIGHTS]math.Color3,
        direct_light_direction: math.Vec3,
        direct_light_color: math.Color3,
        shadow_map_width: f32 = 10.0,
        shadow_map_height: f32 = 10.0,
        shadow_map_depth: f32 = 50.0,

        pub fn shadow_map_view(e: *const Environment) math.Mat4 {
            const ORIENTATION = math.Quat.from_rotation_axis(.X, .NEG_Z, .Y);
            return math.Mat4.look_at(
                .{},
                e.direct_light_direction,
                math.Vec3.Z,
            )
                .mul(ORIENTATION.to_mat4())
                .translate(e.direct_light_direction.normalize().mul_f32(-10.0))
                .inverse();
        }

        pub fn shadow_map_projection(e: *const Environment) math.Mat4 {
            var projection = math.Mat4.orthogonal(
                e.shadow_map_width,
                e.shadow_map_height,
                e.shadow_map_depth,
            );
            projection.j.y *= -1.0;
            return projection;
        }
    };

    const Self = @This();

    pub fn init() Self {
        const shader = if (builtin.target.os.tag == .emscripten)
            Shader.init("resources/shaders/mesh_web.vert", "resources/shaders/mesh_web.frag")
        else
            Shader.init("resources/shaders/mesh.vert", "resources/shaders/mesh.frag");

        const view_loc = shader.get_uniform_location("view");
        const projection_loc = shader.get_uniform_location("projection");
        const model_loc = shader.get_uniform_location("model");

        const shadow_map_view_loc = shader.get_uniform_location("shadow_map_view");
        const shadow_map_projection_loc = shader.get_uniform_location("shadow_map_projection");

        const camera_pos_loc = shader.get_uniform_location("camera_position");
        const lights_pos_loc = shader.get_uniform_location("light_positions");
        const lights_color_loc = shader.get_uniform_location("light_colors");
        const direct_light_direction = shader.get_uniform_location("direct_light_direction");
        const direct_light_color = shader.get_uniform_location("direct_light_color");
        const albedo_loc = shader.get_uniform_location("albedo");
        const metallic_loc = shader.get_uniform_location("metallic");
        const roughness_loc = shader.get_uniform_location("roughness");
        const ao_loc = shader.get_uniform_location("ao");

        return .{
            .shader = shader,
            .view_loc = view_loc,
            .projection_loc = projection_loc,
            .model_loc = model_loc,
            .shadow_map_view_loc = shadow_map_view_loc,
            .shadow_map_projection_loc = shadow_map_projection_loc,
            .camera_pos_loc = camera_pos_loc,
            .lights_pos_loc = lights_pos_loc,
            .lights_color_loc = lights_color_loc,
            .direct_light_direction = direct_light_direction,
            .direct_light_color = direct_light_color,
            .albedo_loc = albedo_loc,
            .metallic_loc = metallic_loc,
            .roughness_loc = roughness_loc,
            .ao_loc = ao_loc,
        };
    }

    pub fn use(self: *const Self) void {
        self.shader.use();
    }

    pub fn set_shadow_map_texture(shadow_map: *const gpu.ShadowMap) void {
        gl.glActiveTexture(gl.GL_TEXTURE0);
        gl.glBindTexture(gl.GL_TEXTURE_2D, shadow_map.depth_texture);
    }

    pub fn set_scene_params(
        self: *const Self,
        camera_view: *const math.Mat4,
        camera_position: *const math.Vec3,
        camera_projection: *const math.Mat4,
        environment: *const Self.Environment,
    ) void {
        gl.glUniformMatrix4fv(self.view_loc, 1, gl.GL_FALSE, @ptrCast(camera_view));
        gl.glUniformMatrix4fv(self.projection_loc, 1, gl.GL_FALSE, @ptrCast(camera_projection));

        const shadow_map_view = environment.shadow_map_view();
        const shadow_map_projection = environment.shadow_map_projection();
        gl.glUniformMatrix4fv(
            self.shadow_map_view_loc,
            1,
            gl.GL_FALSE,
            @ptrCast(&shadow_map_view),
        );
        gl.glUniformMatrix4fv(
            self.shadow_map_projection_loc,
            1,
            gl.GL_FALSE,
            @ptrCast(&shadow_map_projection),
        );

        gl.glUniform3f(self.camera_pos_loc, camera_position.x, camera_position.y, camera_position.z);
        gl.glUniform3fv(self.lights_pos_loc, NUM_LIGHTS, @ptrCast(&environment.lights_position));
        gl.glUniform3fv(self.lights_color_loc, NUM_LIGHTS, @ptrCast(&environment.lights_color));
        gl.glUniform3f(
            self.direct_light_direction,
            environment.direct_light_direction.x,
            environment.direct_light_direction.y,
            environment.direct_light_direction.z,
        );
        gl.glUniform3f(
            self.direct_light_color,
            environment.direct_light_color.r,
            environment.direct_light_color.g,
            environment.direct_light_color.b,
        );
    }

    pub fn set_mesh_params(
        self: *const Self,
        model: *const math.Mat4,
        material: *const assets.Material,
    ) void {
        gl.glUniformMatrix4fv(self.model_loc, 1, gl.GL_FALSE, @ptrCast(model));
        gl.glUniform3f(self.albedo_loc, material.albedo.r, material.albedo.g, material.albedo.b);
        gl.glUniform1f(self.metallic_loc, material.metallic);
        gl.glUniform1f(self.roughness_loc, material.roughness);
        gl.glUniform1f(self.ao_loc, 0.03);
    }
};

pub const DebugGridShader = struct {
    shader: Shader,

    view_loc: i32,
    projection_loc: i32,
    limits_loc: i32,
    scale_loc: i32,
    inverse_view_loc: if (builtin.target.os.tag == .emscripten) i32 else void,
    inverse_projection_loc: if (builtin.target.os.tag == .emscripten) i32 else void,

    buffer: if (builtin.target.os.tag == .emscripten) u32 else void,
    vertex_array: if (builtin.target.os.tag == .emscripten) u32 else void,

    const Self = @This();

    pub fn init() Self {
        const shader = if (builtin.target.os.tag == .emscripten)
            Shader.init("resources/shaders/grid_web.vert", "resources/shaders/grid_web.frag")
        else
            Shader.init("resources/shaders/grid.vert", "resources/shaders/grid.frag");

        const view_loc = shader.get_uniform_location("view");
        const projection_loc = shader.get_uniform_location("projection");
        const limits_loc = shader.get_uniform_location("limits");
        const scale_loc = shader.get_uniform_location("scale");

        const inverse_view_loc = if (builtin.target.os.tag == .emscripten)
            shader.get_uniform_location("inverse_view")
        else {};

        const inverse_projection_loc = if (builtin.target.os.tag == .emscripten)
            shader.get_uniform_location("inverse_projection")
        else {};

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
            return .{
                .shader = shader,
                .view_loc = view_loc,
                .projection_loc = projection_loc,
                .limits_loc = limits_loc,
                .scale_loc = scale_loc,
                .inverse_view_loc = inverse_view_loc,
                .inverse_projection_loc = inverse_projection_loc,
                .buffer = buffer,
                .vertex_array = vertex_array,
            };
        } else {
            return .{
                .shader = shader,
                .view_loc = view_loc,
                .projection_loc = projection_loc,
                .limits_loc = limits_loc,
                .scale_loc = scale_loc,
                .inverse_view_loc = inverse_view_loc,
                .inverse_projection_loc = inverse_projection_loc,
                .buffer = {},
                .vertex_array = {},
            };
        }
    }

    pub fn setup(
        self: *const Self,
        camera_view: *const math.Mat4,
        camera_projection: *const math.Mat4,
        camera_inverse_view: *const math.Mat4,
        camera_inverse_projection: *const math.Mat4,
        scale: f32,
        limits: *const math.Vec4,
    ) void {
        self.shader.use();
        gl.glUniformMatrix4fv(self.view_loc, 1, gl.GL_FALSE, @ptrCast(camera_view));
        gl.glUniformMatrix4fv(self.projection_loc, 1, gl.GL_FALSE, @ptrCast(camera_projection));
        gl.glUniform4f(self.limits_loc, limits.x, limits.y, limits.z, limits.w);
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

    pub fn draw(self: *const Self) void {
        if (builtin.target.os.tag == .emscripten) {
            gl.glBindVertexArray(self.vertex_array);
        }
        gl.glDrawArrays(gl.GL_TRIANGLES, 0, 6);
    }
};

pub const TextShader = struct {
    shader: Shader,

    view: i32,
    projection: i32,
    model: i32,

    window_size: i32,
    position: i32,
    size: i32,

    color: i32,
    mode: i32,

    uv_scale: i32,
    uv_offset: i32,

    texture_size: if (builtin.target.os.tag == .emscripten) i32 else void,
    buffer: if (builtin.target.os.tag == .emscripten) u32 else void,
    vertex_array: if (builtin.target.os.tag == .emscripten) u32 else void,

    const Self = @This();

    pub fn init() Self {
        const shader = if (builtin.target.os.tag == .emscripten)
            Shader.init("resources/shaders/text_web.vert", "resources/shaders/text_web.frag")
        else
            Shader.init("resources/shaders/text.vert", "resources/shaders/text.frag");

        const view = shader.get_uniform_location("view");
        const projection = shader.get_uniform_location("projection");
        const model = shader.get_uniform_location("model");

        const window_size = shader.get_uniform_location("window_size");
        const position = shader.get_uniform_location("position");
        const size = shader.get_uniform_location("size");

        const color = shader.get_uniform_location("color");
        const mode = shader.get_uniform_location("mode");

        const uv_scale = shader.get_uniform_location("uv_scale");
        const uv_offset = shader.get_uniform_location("uv_offset");

        if (builtin.target.os.tag == .emscripten) {
            const PUV = extern struct {
                position: math.Vec3,
                uv: math.Vec2,
            };
            const vertices = [_]PUV{
                .{ .position = .{ .x = 0.5, .y = 0.5, .z = 0.0 }, .uv = .{ .x = 1.0, .y = 0.0 } },
                .{ .position = .{ .x = -0.5, .y = 0.5, .z = 0.0 }, .uv = .{ .x = 0.0, .y = 0.0 } },
                .{ .position = .{ .x = -0.5, .y = -0.5, .z = 0.0 }, .uv = .{ .x = 0.0, .y = 1.0 } },
                .{ .position = .{ .x = -0.5, .y = -0.5, .z = 0.0 }, .uv = .{ .x = 0.0, .y = 1.0 } },
                .{ .position = .{ .x = 0.5, .y = -0.5, .z = 0.0 }, .uv = .{ .x = 1.0, .y = 1.0 } },
                .{ .position = .{ .x = 0.5, .y = 0.5, .z = 0.0 }, .uv = .{ .x = 1.0, .y = 0.0 } },
            };
            var buffer: u32 = undefined;
            gl.glGenBuffers(1, &buffer);
            gl.glBindBuffer(gl.GL_ARRAY_BUFFER, buffer);
            gl.glBufferData(
                gl.GL_ARRAY_BUFFER,
                @sizeOf(@TypeOf(vertices)),
                &vertices,
                gl.GL_STATIC_DRAW,
            );

            var vertex_array: u32 = undefined;
            gl.glGenVertexArrays(1, &vertex_array);
            gl.glBindVertexArray(vertex_array);
            gl.glBindBuffer(gl.GL_ARRAY_BUFFER, buffer);
            gl.glVertexAttribPointer(0, 3, gl.GL_FLOAT, gl.GL_FALSE, @sizeOf(PUV), @ptrFromInt(0));
            gl.glVertexAttribPointer(1, 2, gl.GL_FLOAT, gl.GL_FALSE, @sizeOf(PUV), @ptrFromInt(3 * @sizeOf(f32)));
            gl.glEnableVertexAttribArray(0);
            gl.glEnableVertexAttribArray(1);

            const texture_size = shader.get_uniform_location("texture_size");

            return .{
                .shader = shader,
                .view = view,
                .projection = projection,
                .model = model,

                .window_size = window_size,
                .position = position,
                .size = size,

                .color = color,
                .mode = mode,

                .uv_scale = uv_scale,
                .uv_offset = uv_offset,

                .texture_size = texture_size,
                .buffer = buffer,
                .vertex_array = vertex_array,
            };
        } else {
            return .{
                .shader = shader,
                .view = view,
                .projection = projection,
                .model = model,

                .window_size = window_size,
                .position = position,
                .size = size,

                .color = color,
                .mode = mode,

                .uv_scale = uv_scale,
                .uv_offset = uv_offset,

                .texture_size = {},
                .buffer = {},
                .vertex_array = {},
            };
        }
    }

    pub fn use(self: *const Self) void {
        self.shader.use();
    }

    pub fn set_font(self: *const Self, font: *const gpu.Font) void {
        gl.glActiveTexture(gl.GL_TEXTURE0);
        gl.glBindTexture(gl.GL_TEXTURE_2D, font.texture);

        if (builtin.target.os.tag == .emscripten) {
            gl.glUniform2f(self.texture_size, font.texture_size.x, font.texture_size.y);
        }
    }

    pub fn set_char_info(
        self: *const Self,
        camera: *const Camera,
        char_info: *const Renderer.RenderCharInfo,
    ) void {
        switch (char_info.mode) {
            .World => {
                gl.glUniform1i(self.mode, 0);
                const transform = math.Mat4.IDENDITY
                    .translate(char_info.position)
                    .scale(.{ .x = char_info.width, .y = char_info.height });
                gl.glUniformMatrix4fv(self.view, 1, gl.GL_FALSE, @ptrCast(&camera.view));
                gl.glUniformMatrix4fv(self.projection, 1, gl.GL_FALSE, @ptrCast(&camera.projection));
                gl.glUniformMatrix4fv(self.model, 1, gl.GL_FALSE, @ptrCast(&transform));
            },
            .Screen => {
                gl.glUniform1i(self.mode, 1);
                gl.glUniform2f(self.window_size, Platform.WINDOW_WIDTH, Platform.WINDOW_HEIGHT);
                gl.glUniform2f(self.position, char_info.position.x, char_info.position.y);
                gl.glUniform2f(self.size, char_info.width, char_info.height);
            },
        }
        gl.glUniform3f(self.color, char_info.color.r, char_info.color.g, char_info.color.b);
        gl.glUniform2f(self.uv_scale, char_info.texture_scale_x, char_info.texture_scale_y);
        gl.glUniform2f(self.uv_offset, char_info.texture_offset_x, char_info.texture_offset_y);
    }

    pub fn draw(self: *const Self) void {
        if (builtin.target.os.tag == .emscripten) {
            gl.glBindVertexArray(self.vertex_array);
        }
        gl.glDrawArrays(gl.GL_TRIANGLES, 0, 6);
    }
};

pub const ShadowMapShader = struct {
    shader: Shader,

    view_loc: i32,
    projection_loc: i32,
    model_loc: i32,

    const Self = @This();

    pub fn init() Self {
        const shader = if (builtin.target.os.tag == .emscripten)
            Shader.init("resources/shaders/mesh_web.vert", "resources/shaders/mesh_web.frag")
        else
            Shader.init("resources/shaders/shadow_map.vert", "resources/shaders/shadow_map.frag");

        const view_loc = shader.get_uniform_location("view");
        const projection_loc = shader.get_uniform_location("projection");
        const model_loc = shader.get_uniform_location("model");

        return .{
            .shader = shader,
            .view_loc = view_loc,
            .projection_loc = projection_loc,
            .model_loc = model_loc,
        };
    }

    pub fn use(self: *const Self) void {
        self.shader.use();
    }

    pub fn set_params(
        self: *const Self,
        environment: *const MeshShader.Environment,
    ) void {
        const view = environment.shadow_map_view();
        const projection = environment.shadow_map_projection();

        gl.glUniformMatrix4fv(self.view_loc, 1, gl.GL_FALSE, @ptrCast(&view));
        gl.glUniformMatrix4fv(self.projection_loc, 1, gl.GL_FALSE, @ptrCast(&projection));
    }

    pub fn set_mesh_params(
        self: *const Self,
        model: *const math.Mat4,
    ) void {
        gl.glUniformMatrix4fv(self.model_loc, 1, gl.GL_FALSE, @ptrCast(model));
    }
};
