const std = @import("std");
const builtin = @import("builtin");
const log = @import("log.zig");
const gl = @import("bindings/gl.zig");
const math = @import("math.zig");
const assets = @import("assets.zig");

const Font = @import("font.zig");
const Level = @import("level.zig");
const Camera = @import("camera.zig");

const FileMem = @import("memory.zig").FileMem;
const Mesh = @import("mesh.zig");

pub const Environment = struct {
    lights_position: [MeshShader.NUM_LIGHTS]math.Vec3,
    lights_color: [MeshShader.NUM_LIGHTS]math.Color3,
    direct_light_direction: math.Vec3,
    direct_light_color: math.Color3,
};

pub const Renderer = struct {
    mesh_shader: MeshShader,
    mesh_infos: std.BoundedArray(RenderMeshInfo, 128) = .{},

    text_shader: TextShader = undefined,
    char_infos: std.BoundedArray(RenderCharInfo, 128) = .{},

    // debug things
    show_debug_grid: bool = true,
    debug_grid_scale: f32 = 10.0,
    debug_grid_shader: DebugGridShader = undefined,
    debug_grid: DebugGrid = undefined,

    const RenderMeshInfo = struct {
        mesh: *const GpuMesh,
        model: math.Mat4,
        material: assets.Material,
    };

    const RenderCharInfo = struct {
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

    pub fn init() Self {
        return .{
            .mesh_shader = .init(),
            .text_shader = .init(),
            .debug_grid_shader = .init(),
            .debug_grid = .init(),
        };
    }

    pub fn reset(self: *Self) void {
        self.mesh_infos.clear();
        self.char_infos.clear();

        gl.glClearDepth(0.0);
        gl.glClearColor(0.0, 0.0, 0.0, 1.0);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT | gl.GL_DEPTH_BUFFER_BIT);
    }

    pub fn add_mesh_draw(
        self: *Self,
        mesh: *const GpuMesh,
        model: math.Mat4,
        material: assets.Material,
    ) void {
        const mesh_info = RenderMeshInfo{
            .mesh = mesh,
            .model = model,
            .material = material,
        };
        self.mesh_infos.append(mesh_info) catch {
            log.warn(@src(), "Cannot add more meshes to draw queue", .{});
        };
    }

    pub fn add_text_draw(
        self: *Self,
        text: []const u8,
        position: math.Vec3,
        size: f32,
        color: math.Color3,
    ) void {
        const font = assets.fonts.getPtrConst(.Default);
        const scale = size / font.size;
        const font_scale = scale * font.scale();
        var offset: math.Vec3 = .{};

        for (text, 0..) |char, i| {
            const char_info = if (font.chars.len <= char) blk: {
                log.warn(@src(), "Trying to render unknown character: {d}", .{char});
                break :blk &Font.Char{};
            } else &font.chars[char];
            const char_kern =
                if (0 < i) blk: {
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
                .position = char_position,
                .color = color,
                .width = char_info.width * scale,
                .height = char_info.height * scale,
                .texture_scale_x = char_info.width,
                .texture_scale_y = char_info.height,
                .texture_offset_x = char_info.texture_offset_x,
                .texture_offset_y = char_info.texture_offset_y,
            };

            self.char_infos.append(render_char_info) catch {
                log.warn(@src(), "Cannot add more chars to draw queue", .{});
                return;
            };

            offset.x += char_info.x_advance * scale;
        }
    }

    pub fn render(
        self: *const Self,
        camera: *const Camera,
        environment: *const Environment,
    ) void {
        self.mesh_shader.use();
        self.mesh_shader.set_scene_params(
            &camera.view,
            &camera.position,
            &camera.projection,
            &environment.lights_position,
            &environment.lights_color,
            &environment.direct_light_direction,
            &environment.direct_light_color,
        );
        for (self.mesh_infos.slice()) |*mi| {
            self.mesh_shader.set_mesh_params(&mi.model, &mi.material);
            mi.mesh.draw();
        }

        if (self.show_debug_grid) {
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

        self.text_shader.use();
        self.text_shader.set_font(assets.gpu_fonts.getPtrConst(.Default));
        for (self.char_infos.slice()) |*ci| {
            self.text_shader.set_char_info(camera, ci);
            self.text_shader.draw();
        }
    }
};

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

    const Self = @This();

    pub fn init() Self {
        const shader = if (builtin.target.os.tag == .emscripten)
            Shader.init("resources/shaders/mesh_web.vert", "resources/shaders/mesh_web.frag")
        else
            Shader.init("resources/shaders/mesh.vert", "resources/shaders/mesh.frag");

        const view_loc = shader.get_uniform_location("view");
        const projection_loc = shader.get_uniform_location("projection");
        const model_loc = shader.get_uniform_location("model");
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

    pub fn set_scene_params(
        self: *const Self,
        camera_view: *const math.Mat4,
        camera_position: *const math.Vec3,
        camera_projection: *const math.Mat4,
        lights_position: *const [NUM_LIGHTS]math.Vec3,
        lights_color: *const [NUM_LIGHTS]math.Color3,
        direct_light_direction: *const math.Vec3,
        direct_light_color: *const math.Color3,
    ) void {
        gl.glUniformMatrix4fv(self.view_loc, 1, gl.GL_FALSE, @ptrCast(camera_view));
        gl.glUniformMatrix4fv(self.projection_loc, 1, gl.GL_FALSE, @ptrCast(camera_projection));
        gl.glUniform3f(self.camera_pos_loc, camera_position.x, camera_position.y, camera_position.z);
        gl.glUniform3fv(self.lights_pos_loc, NUM_LIGHTS, @ptrCast(lights_position));
        gl.glUniform3fv(self.lights_color_loc, NUM_LIGHTS, @ptrCast(lights_color));
        gl.glUniform3f(
            self.direct_light_direction,
            direct_light_direction.x,
            direct_light_direction.y,
            direct_light_direction.z,
        );
        gl.glUniform3f(
            self.direct_light_color,
            direct_light_color.r,
            direct_light_color.g,
            direct_light_color.b,
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

    pub fn setup(
        self: *const Self,
        camera_position: *const math.Vec3,
        camera_view: *const math.Mat4,
        camera_projection: *const math.Mat4,
        model: *const math.Mat4,
        lights_position: *const [NUM_LIGHTS]math.Vec3,
        lights_color: *const [NUM_LIGHTS]math.Color3,
        direct_light_direction: *const math.Vec3,
        direct_light_color: *const math.Color3,
        albedo: *const math.Color4,
        metallic: f32,
        roughness: f32,
        ao: f32,
    ) void {
        self.shader.use();
        gl.glUniformMatrix4fv(self.view_loc, 1, gl.GL_FALSE, @ptrCast(camera_view));
        gl.glUniformMatrix4fv(self.projection_loc, 1, gl.GL_FALSE, @ptrCast(camera_projection));
        gl.glUniformMatrix4fv(self.model_loc, 1, gl.GL_FALSE, @ptrCast(model));
        gl.glUniform3f(self.camera_pos_loc, camera_position.x, camera_position.y, camera_position.z);
        gl.glUniform3fv(self.lights_pos_loc, NUM_LIGHTS, @ptrCast(lights_position));
        gl.glUniform3fv(self.lights_color_loc, NUM_LIGHTS, @ptrCast(lights_color));
        gl.glUniform3f(
            self.direct_light_direction,
            direct_light_direction.x,
            direct_light_direction.y,
            direct_light_direction.z,
        );
        gl.glUniform3f(
            self.direct_light_color,
            direct_light_color.r,
            direct_light_color.g,
            direct_light_color.b,
        );
        gl.glUniform3f(self.albedo_loc, albedo.r, albedo.g, albedo.b);
        gl.glUniform1f(self.metallic_loc, metallic);
        gl.glUniform1f(self.roughness_loc, roughness);
        gl.glUniform1f(self.ao_loc, ao);
    }
};

pub const GpuMesh = struct {
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
        VERTEX_TYPE.set_attributes();

        return .{
            .vertex_buffer = vertex_buffer,
            .index_buffer = index_buffer,
            .n_indices = n_indices,
            .vertex_array = vertex_array,
        };
    }

    pub fn from_mesh(mesh: *const Mesh) Self {
        return Self.init(Mesh.Vertex, mesh.vertices, mesh.indices);
    }

    pub fn draw(self: *const Self) void {
        gl.glBindVertexArray(self.vertex_array);
        gl.glBindBuffer(gl.GL_ELEMENT_ARRAY_BUFFER, self.index_buffer);
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
    limits_loc: i32,
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
        const limits_loc = shader.get_uniform_location("limits");
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
            .limits_loc = limits_loc,
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
};

pub const GpuFont = struct {
    texture: u32,

    const Self = @This();

    pub fn from_font(font: *const Font) Self {
        var texture: u32 = undefined;
        gl.glGenTextures(1, &texture);
        gl.glBindTexture(gl.GL_TEXTURE_2D, texture);

        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_REPEAT);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_REPEAT);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR_MIPMAP_LINEAR);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);

        gl.glTexImage2D(
            gl.GL_TEXTURE_2D,
            0,
            gl.GL_ALPHA,
            Font.FONT_BITMAP_SIZE,
            Font.FONT_BITMAP_SIZE,
            0,
            gl.GL_ALPHA,
            gl.GL_UNSIGNED_BYTE,
            @ptrCast(font.bitmap.ptr),
        );
        gl.glGenerateMipmap(gl.GL_TEXTURE_2D);
        log.info(@src(), "gpu font texture: {d}", .{texture});
        return .{
            .texture = texture,
        };
    }
};

pub const TextShader = struct {
    shader: Shader,

    view: i32,
    projection: i32,
    model: i32,
    color: i32,
    uv_scale: i32,
    uv_offset: i32,

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
        const color = shader.get_uniform_location("color");
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
            return .{
                .shader = shader,
                .view = view,
                .projection = projection,
                .model = model,
                .color = color,
                .uv_scale = uv_scale,
                .uv_offset = uv_offset,
                .buffer = buffer,
                .vertex_array = vertex_array,
            };
        } else {
            return .{
                .shader = shader,
                .view = view,
                .projection = projection,
                .model = model,
                .color = color,
                .uv_scale = uv_scale,
                .uv_offset = uv_offset,
                .buffer = {},
                .vertex_array = {},
            };
        }
    }

    pub fn use(self: *const Self) void {
        self.shader.use();
    }

    pub fn set_font(self: *const Self, font: *const GpuFont) void {
        _ = self;
        gl.glActiveTexture(gl.GL_TEXTURE0);
        gl.glBindTexture(gl.GL_TEXTURE_2D, font.texture);
    }

    pub fn set_char_info(
        self: *const Self,
        camera: *const Camera,
        char_info: *const Renderer.RenderCharInfo,
    ) void {
        const transform = math.Mat4.IDENDITY
            .translate(char_info.position)
            .scale(.{ .x = char_info.width, .y = char_info.height });
        gl.glUniformMatrix4fv(self.view, 1, gl.GL_FALSE, @ptrCast(&camera.view));
        gl.glUniformMatrix4fv(self.projection, 1, gl.GL_FALSE, @ptrCast(&camera.projection));
        gl.glUniformMatrix4fv(self.model, 1, gl.GL_FALSE, @ptrCast(&transform));
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
