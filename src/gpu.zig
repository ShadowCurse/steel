const builtin = @import("builtin");
const gl = @import("bindings/gl.zig");
const math = @import("math.zig");

const Platform = @import("platform.zig");

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
        VERTEX_TYPE.set_attributes();

        return .{
            .vertex_buffer = vertex_buffer,
            .index_buffer = index_buffer,
            .n_indices = n_indices,
            .vertex_array = vertex_array,
        };
    }

    const M = @import("mesh.zig");
    pub fn from_mesh(mesh: *const M) Self {
        return Self.init(M.Vertex, mesh.vertices, mesh.indices);
    }

    pub fn draw(self: *const Self) void {
        gl.glBindVertexArray(self.vertex_array);
        gl.glBindBuffer(gl.GL_ELEMENT_ARRAY_BUFFER, self.index_buffer);
        gl.glDrawElements(gl.GL_TRIANGLES, self.n_indices, gl.GL_UNSIGNED_INT, null);
    }
};

pub const Font = struct {
    texture: u32,
    texture_size: if (builtin.target.os.tag == .emscripten) math.Vec2 else void,

    const Self = @This();

    const F = @import("font.zig");
    pub fn from_font(font: *const F) Self {
        var texture: u32 = undefined;
        gl.glGenTextures(1, &texture);
        gl.glBindTexture(gl.GL_TEXTURE_2D, texture);

        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);

        gl.glTexImage2D(
            gl.GL_TEXTURE_2D,
            0,
            gl.GL_ALPHA,
            F.BITMAP_WIDTH,
            @intCast(font.bitmap_height),
            0,
            gl.GL_ALPHA,
            gl.GL_UNSIGNED_BYTE,
            @ptrCast(font.bitmap.ptr),
        );

        if (builtin.target.os.tag == .emscripten) {
            return .{
                .texture = texture,
                .texture_size = math.vec2(F.BITMAP_WIDTH, @floatFromInt(font.bitmap_height)),
            };
        } else {
            return .{
                .texture = texture,
                .texture_size = {},
            };
        }
    }
};

pub const ShadowMap = struct {
    framebuffer: u32,
    depth_texture: u32,

    // const SHADOW_WIDTH = 1024;
    // const SHADOW_HEIGHT = 1024;
    const SHADOW_WIDTH = Platform.WINDOW_WIDTH;
    const SHADOW_HEIGHT = Platform.WINDOW_HEIGHT;
    const Self = ShadowMap;

    pub fn init() ShadowMap {
        var framebuffer: u32 = undefined;
        gl.glGenFramebuffers(1, &framebuffer);

        var depth_texture: u32 = undefined;
        gl.glGenTextures(1, &depth_texture);
        gl.glBindTexture(gl.GL_TEXTURE_2D, depth_texture);
        gl.glTexImage2D(
            gl.GL_TEXTURE_2D,
            0,
            gl.GL_DEPTH_COMPONENT,
            SHADOW_WIDTH,
            SHADOW_HEIGHT,
            0,
            gl.GL_DEPTH_COMPONENT,
            gl.GL_FLOAT,
            null,
        );
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_NEAREST);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_NEAREST);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_BORDER);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_BORDER);
        const border_color: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 };
        gl.glTexParameterfv(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_BORDER_COLOR, &border_color);

        gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, framebuffer);
        gl.glFramebufferTexture2D(
            gl.GL_FRAMEBUFFER,
            gl.GL_DEPTH_ATTACHMENT,
            gl.GL_TEXTURE_2D,
            depth_texture,
            0,
        );
        gl.glDrawBuffer(gl.GL_NONE);
        gl.glReadBuffer(gl.GL_NONE);
        gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, 0);

        return .{
            .framebuffer = framebuffer,
            .depth_texture = depth_texture,
        };
    }

    pub fn use(self: *const Self) void {
        // gl.glViewport(0, 0, SHADOW_WIDTH, SHADOW_HEIGHT);
        gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, self.framebuffer);

        gl.glClearDepth(1.0);
        gl.glClear(gl.GL_DEPTH_BUFFER_BIT);
        gl.glDepthFunc(gl.GL_LEQUAL);
    }
};
