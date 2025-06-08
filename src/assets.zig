const std = @import("std");
const log = @import("log.zig");
const math = @import("math.zig");
const memory = @import("memory.zig");
const cgltf = @import("bindings/cgltf.zig");
const stb = @import("bindings/stb.zig");

const Allocator = std.mem.Allocator;
const FixedArena = memory.FixedArena;
const Mesh = @import("mesh.zig");
const Color4 = math.Color4;
const Vec4 = math.Vec4;
const Vec3 = math.Vec3;
const Vec2 = math.Vec2;

const rendering = @import("rendering.zig");
const GpuMesh = rendering.GpuMesh;

const Font = @import("font.zig");
const ALL_CHARS = Font.ALL_CHARS;
const FONT_BITMAP_SIZE = Font.FONT_BITMAP_SIZE;
const Kerning = Font.Kerning;
const Char = Font.Char;

pub const DEFAULT_FONTS_DIR_PATH = "resources/fonts";
pub const DEFAULT_MESHES_DIR_PATH = "resources/models";
pub const DEFAULT_PACKED_ASSETS_PATH = "resources/packed.p";

// In memory this will be
// (
//   Materials[
//     {albedo, ...}
//     ...
//   ]
//   (align MeshInfo)
//   MeshInfos[
//     {mesh_1 number of indexes, mesh_1 number of vertices}
//     ...
//   ]
//   (align 4)
//   [all indices]
//   (align 32)
//   [all vertices]
//   (align FontInfo)
//   FontInfos[]
//   (align CharInfo)
//   [CharInfo[512], FontInfos.len]
//   (align KerningInfo)
//   [KerningInfo[512 * 512], FontInfos.len]
//   (align 1)
//   [u8[512 * 512], FontInfos.len]
// )

pub const GpuMeshes = std.EnumArray(ModelType, GpuMesh);
pub const Materials = std.EnumArray(ModelType, Material);
pub const Meshes = std.EnumArray(ModelType, Mesh);
pub const Fonts = std.EnumArray(FontType, Font);

pub var gpu_meshes: GpuMeshes = undefined;
pub var materials: Materials = undefined;
pub var meshes: Meshes = undefined;
pub var fonts: Fonts = undefined;

const Self = @This();

pub fn init(mem: []align(4096) const u8) !void {
    const unpack_result = try unpack(mem);
    gpu_meshes_from_meshes(&unpack_result.meshes);
    materials = unpack_result.mats;
    meshes = unpack_result.meshes;
    fonts = unpack_result.fonts;
}

fn gpu_meshes_from_meshes(m: *const Meshes) void {
    for (std.enums.values(ModelType)) |v| {
        gpu_meshes.getPtr(v).* = GpuMesh.from_mesh(m.getPtrConst(v));
    }
}

pub const ModelType = enum {
    Floor,
    FloorTrap,
    Wall,
    Spawn,
    Throne,
    Enemy,
    PathMarker,
    Crystal,
};

pub const Material = struct {
    albedo: Color4,
    metallic: f32,
    roughness: f32,
};

pub const MeshInfo = extern struct {
    n_indices: u32 = 0,
    n_vertices: u32 = 0,
};

pub const FontType = enum {
    Default,
};

pub const FontInfo = struct {
    size: f32,
    ascent: i32 = 0,
    decent: i32 = 0,
    line_gap: i32 = 0,
    n_chars: u32 = 0,
};

pub const Packer = struct {
    mats: std.EnumArray(ModelType, Material) = undefined,
    mesh_infos: std.EnumArray(ModelType, MeshInfo) = undefined,
    indices: std.ArrayListUnmanaged(Mesh.Index) = .{},
    vertices: std.ArrayListUnmanaged(Mesh.Vertex) = .{},

    font_infos: std.EnumArray(FontType, FontInfo) = undefined,
    chars: std.ArrayListUnmanaged(Char) = .{},
    kernings: std.ArrayListUnmanaged(Kerning) = .{},
    font_bitmaps: std.ArrayListUnmanaged(u8) = .{},

    const Self = @This();

    pub fn add_model(
        self: *Packer,
        gpa_alloc: Allocator,
        scratch_alloc: Allocator,
        path: [:0]const u8,
        model_type: ModelType,
    ) !void {
        log.info(
            @src(),
            "Loading gltf model of type {any} from path: {s}",
            .{ model_type, path },
        );

        // TODO add allocator params?
        const options = cgltf.cgltf_options{};
        var data: *cgltf.cgltf_data = undefined;
        try cgltf.check_result(cgltf.cgltf_parse_file(&options, path.ptr, @ptrCast(&data)));
        try cgltf.check_result(cgltf.cgltf_load_buffers(&options, data, path.ptr));
        defer cgltf.cgltf_free(data);

        if (data.meshes_count != 1)
            return error.cgltf_too_many_meshes;

        const mesh = &data.meshes[0];

        if (mesh.primitives_count != 1)
            return error.cgltf_too_many_primitives;

        if (data.materials_count != 1)
            return error.cgltf_too_many_materials;

        const material = &data.materials[0];
        self.mats.getPtr(model_type).* = .{
            .albedo = @bitCast(material.pbr_metallic_roughness.base_color_factor),
            .metallic = material.pbr_metallic_roughness.metallic_factor,
            .roughness = material.pbr_metallic_roughness.roughness_factor,
        };

        const mesh_name = std.mem.span(mesh.name);
        log.info(@src(), "Mesh name: {s}", .{mesh_name});

        const primitive = &mesh.primitives[0];
        const number_of_indices = primitive.indices[0].count;

        const initial_index_num = self.indices.items.len;
        try self.indices.resize(gpa_alloc, initial_index_num + number_of_indices);
        for (self.indices.items[initial_index_num..], 0..) |*i, j| {
            const index = cgltf.cgltf_accessor_read_index(primitive.indices, j);
            i.* = @intCast(index);
        }

        const number_of_vertices = primitive.attributes[0].data[0].count;
        const initial_vertex_num = self.vertices.items.len;
        try self.vertices.resize(gpa_alloc, initial_vertex_num + number_of_vertices);

        self.mesh_infos.getPtr(model_type).* = .{
            .n_indices = @intCast(number_of_indices),
            .n_vertices = @intCast(number_of_vertices),
        };

        log.info(@src(), "Mesh primitive type: {}", .{primitive.type});
        for (primitive.attributes[0..primitive.attributes_count]) |attr| {
            log.info(
                @src(),
                "Mesh primitive attr name: {s}, type: {}, index: {}, data type: {}, data count: {}",
                .{
                    attr.name,
                    attr.type,
                    attr.index,
                    attr.data[0].type,
                    attr.data[0].count,
                },
            );
            const num_floats = cgltf.cgltf_accessor_unpack_floats(attr.data, null, 0);
            const floats = try scratch_alloc.alloc(f32, num_floats);
            _ = cgltf.cgltf_accessor_unpack_floats(attr.data, floats.ptr, num_floats);

            switch (attr.type) {
                cgltf.cgltf_attribute_type_position => {
                    const num_components = cgltf.cgltf_num_components(attr.data[0].type);
                    log.info(@src(), "Position has components: {}", .{num_components});
                    log.assert(
                        @src(),
                        num_components == 3,
                        "Position has {d} components insead of {d}",
                        .{ num_components, @as(u32, 3) },
                    );

                    var positions: []const Vec3 = undefined;
                    positions.ptr = @ptrCast(floats.ptr);
                    positions.len = floats.len / 3;

                    for (self.vertices.items[initial_vertex_num..], positions) |*vertex, position| {
                        vertex.position = position;
                    }
                },
                cgltf.cgltf_attribute_type_normal => {
                    const num_components = cgltf.cgltf_num_components(attr.data[0].type);
                    log.info(@src(), "Normal has components: {}", .{num_components});
                    log.assert(
                        @src(),
                        num_components == 3,
                        "Normal has {d} componenets insead of {d}",
                        .{ num_components, @as(u32, 3) },
                    );

                    var normals: []const Vec3 = undefined;
                    normals.ptr = @ptrCast(floats.ptr);
                    normals.len = floats.len / 3;

                    for (self.vertices.items[initial_vertex_num..], normals) |*vertex, normal| {
                        vertex.normal = normal;
                    }
                },
                cgltf.cgltf_attribute_type_texcoord => {
                    const num_components = cgltf.cgltf_num_components(attr.data[0].type);
                    log.info(@src(), "Texture coord has components: {}", .{num_components});
                    log.assert(
                        @src(),
                        num_components == 2,
                        "Texture coord has {d} components insead of {d}",
                        .{ num_components, @as(u32, 2) },
                    );

                    var uvs: []const Vec2 = undefined;
                    uvs.ptr = @ptrCast(floats.ptr);
                    uvs.len = floats.len / 2;

                    for (self.vertices.items[initial_vertex_num..], uvs) |*vertex, uv| {
                        vertex.uv_x = uv.x;
                        vertex.uv_y = uv.y;
                    }
                },
                else => {
                    log.err(@src(), "Unknown attribute type: {}. Skipping", .{attr.type});
                },
            }

            // For debugging use normals as colors
            for (self.vertices.items) |*v| {
                v.color = v.normal.extend(1.0);
            }
        }
    }

    pub fn add_font(
        self: *Packer,
        gpa_alloc: Allocator,
        scratch_alloc: Allocator,
        path: [:0]const u8,
        font_size: f32,
        font_type: FontType,
    ) !void {
        log.info(
            @src(),
            "Loading font of type {any} from path: {s}",
            .{ font_type, path },
        );

        const file_mem = try memory.FileMem.init(path);
        defer file_mem.deinit();

        var stb_font: stb.stbtt_fontinfo = undefined;
        _ = stb.stbtt_InitFont(
            &stb_font,
            file_mem.mem.ptr,
            stb.stbtt_GetFontOffsetForIndex(file_mem.mem.ptr, 0),
        );

        const char_info =
            try scratch_alloc.alloc(stb.stbtt_bakedchar, @intCast(stb_font.numGlyphs));
        const bitmap =
            try scratch_alloc.alignedAlloc(u8, 4, FONT_BITMAP_SIZE * FONT_BITMAP_SIZE);

        _ = stb.stbtt_BakeFontBitmap(
            file_mem.mem.ptr,
            0,
            font_size,
            bitmap.ptr,
            FONT_BITMAP_SIZE,
            FONT_BITMAP_SIZE,
            0,
            stb_font.numGlyphs,
            char_info.ptr,
        );

        var ascent: i32 = undefined;
        var decent: i32 = undefined;
        var line_gap: i32 = undefined;
        stb.stbtt_GetFontVMetrics(&stb_font, &ascent, &decent, &line_gap);

        const start_chars = self.chars.items.len;
        try self.chars.ensureUnusedCapacity(gpa_alloc, char_info.len);
        for (char_info) |ci| {
            const c = Char{
                .texture_offset_x = @floatFromInt(ci.x0),
                .texture_offset_y = @floatFromInt(ci.y0),
                .width = @floatFromInt(ci.x1 - ci.x0),
                .height = @floatFromInt(ci.y1 - ci.y0),
                .x_offset = ci.xoff,
                .y_offset = ci.yoff,
                .x_advance = ci.xadvance,
            };
            try self.chars.append(gpa_alloc, c);
        }

        try self.kernings.ensureUnusedCapacity(gpa_alloc, ALL_CHARS.len * ALL_CHARS.len);
        for (ALL_CHARS) |c1| {
            for (ALL_CHARS) |c2| {
                const k = stb.stbtt_GetCodepointKernAdvance(&stb_font, c1, c2);
                const kerning = Kerning{
                    .char_1 = c1,
                    .char_2 = c2,
                    .kerning = k,
                };
                try self.kernings.append(gpa_alloc, kerning);
            }
        }

        try self.font_bitmaps.appendSlice(gpa_alloc, bitmap);

        const font_info = FontInfo{
            .size = font_size,
            .ascent = ascent,
            .decent = decent,
            .line_gap = line_gap,
            .n_chars = @intCast(self.chars.items.len - start_chars),
        };
        log.info(@src(), "{d} chars", .{font_info.n_chars});
        self.font_infos.getPtr(font_type).* = font_info;
    }

    pub fn pack_and_write(self: *const Packer, gpa_alloc: Allocator, path: []const u8) !void {
        var total_size: usize = 0;
        total_size = memory.align_up(total_size, @alignOf(Material));
        total_size += Materials.len * @sizeOf(Material);
        total_size = memory.align_up(total_size, @alignOf(MeshInfo));
        total_size += Meshes.len * @sizeOf(MeshInfo);
        total_size = memory.align_up(total_size, @alignOf(Mesh.Index));
        total_size += self.indices.items.len * @sizeOf(Mesh.Index);
        total_size = memory.align_up(total_size, @alignOf(Mesh.Vertex));
        total_size += self.vertices.items.len * @sizeOf(Mesh.Vertex);
        total_size = memory.align_up(total_size, @alignOf(FontInfo));
        total_size += Fonts.len * @sizeOf(FontInfo);
        total_size = memory.align_up(total_size, @alignOf(Char));
        total_size += self.chars.items.len * @sizeOf(Char);
        total_size = memory.align_up(total_size, @alignOf(Kerning));
        total_size += self.kernings.items.len * @sizeOf(Kerning);
        total_size = memory.align_up(total_size, @alignOf(u8));
        total_size += self.font_bitmaps.items.len * @sizeOf(u8);
        log.info(@src(), "Total bytes for packed data: {d}", .{total_size});

        const mem = try gpa_alloc.alignedAlloc(u8, 4096, total_size);
        defer gpa_alloc.free(mem);
        var arena_allocator = FixedArena.init(mem);
        const arena_alloc = arena_allocator.allocator();

        _ = try arena_alloc.dupe(Material, &self.mats.values);
        _ = try arena_alloc.dupe(MeshInfo, &self.mesh_infos.values);
        _ = try arena_alloc.dupe(Mesh.Index, self.indices.items);
        _ = try arena_alloc.dupe(Mesh.Vertex, self.vertices.items);
        _ = try arena_alloc.dupe(FontInfo, &self.font_infos.values);
        _ = try arena_alloc.dupe(Char, self.chars.items);
        _ = try arena_alloc.dupe(Kerning, self.kernings.items);
        _ = try arena_alloc.dupe(u8, self.font_bitmaps.items);

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        _ = try file.write(arena_allocator.slice());
    }
};

pub const UnpackedAssets = struct {
    meshes: Meshes,
    mats: Materials,
    fonts: Fonts,
};
pub fn unpack(mem: []align(4096) const u8) !UnpackedAssets {
    var mem_ptr: usize = @intFromPtr(mem.ptr);

    var mats: []const Material = undefined;
    mats.ptr = @ptrFromInt(mem_ptr);
    mats.len = Materials.len;

    mem_ptr += @sizeOf(Material) * Materials.len;
    mem_ptr = memory.align_up(mem_ptr, @alignOf(MeshInfo));
    var meshes_infos: []const MeshInfo = undefined;
    meshes_infos.ptr = @ptrFromInt(mem_ptr);
    meshes_infos.len = Meshes.len;

    var total_indices_len: u32 = 0;
    var total_vertices_len: u32 = 0;
    for (meshes_infos) |info| {
        total_indices_len += info.n_indices;
        total_vertices_len += info.n_vertices;
    }

    mem_ptr += @sizeOf(MeshInfo) * Meshes.len;
    mem_ptr = memory.align_up(mem_ptr, @alignOf(Mesh.Index));
    var indices: []const Mesh.Index = undefined;
    indices.ptr = @ptrFromInt(mem_ptr);
    indices.len = total_indices_len;

    mem_ptr += @sizeOf(Mesh.Index) * total_indices_len;
    mem_ptr = memory.align_up(mem_ptr, @alignOf(Mesh.Vertex));
    var vertices: []const Mesh.Vertex = undefined;
    vertices.ptr = @ptrFromInt(mem_ptr);
    vertices.len = total_vertices_len;

    mem_ptr += @sizeOf(Mesh.Vertex) * total_vertices_len;
    mem_ptr = memory.align_up(mem_ptr, @alignOf(FontInfo));
    var fonts_infos: []const FontInfo = undefined;
    fonts_infos.ptr = @ptrFromInt(mem_ptr);
    fonts_infos.len = Fonts.len;

    var total_chars_len: u32 = 0;
    for (fonts_infos) |*fi|
        total_chars_len += fi.n_chars;

    mem_ptr += @sizeOf(FontInfo) * Fonts.len;
    mem_ptr = memory.align_up(mem_ptr, @alignOf(Char));
    var chars: []const Char = undefined;
    chars.ptr = @ptrFromInt(mem_ptr);
    chars.len = total_chars_len;

    mem_ptr += @sizeOf(Char) * total_chars_len;
    mem_ptr = memory.align_up(mem_ptr, @alignOf(Kerning));
    var kernings: []const Kerning = undefined;
    kernings.ptr = @ptrFromInt(mem_ptr);
    kernings.len = Fonts.len * ALL_CHARS.len * ALL_CHARS.len;

    mem_ptr += @sizeOf(Kerning) * kernings.len;
    mem_ptr = memory.align_up(mem_ptr, @alignOf(u8));
    var bitmaps: []const u8 = undefined;
    bitmaps.ptr = @ptrFromInt(mem_ptr);
    bitmaps.len = Fonts.len * FONT_BITMAP_SIZE * FONT_BITMAP_SIZE;

    var result: UnpackedAssets = undefined;
    for (mats, 0..) |material, i|
        result.mats.values[i] = material;

    var index_offset: u32 = 0;
    var vertex_offset: u32 = 0;
    for (meshes_infos, 0..) |*info, i| {
        result.meshes.values[i] = .{
            .indices = indices[index_offset..][0..info.n_indices],
            .vertices = vertices[vertex_offset..][0..info.n_vertices],
        };
        index_offset += info.n_indices;
        vertex_offset += info.n_vertices;
    }

    var char_offset: u32 = 0;
    var kerning_offset: u32 = 0;
    var bitmap_offset: u32 = 0;
    for (fonts_infos, 0..) |*font_info, i| {
        result.fonts.values[i] = .{
            .size = font_info.size,
            .ascent = font_info.ascent,
            .decent = font_info.decent,
            .line_gap = font_info.line_gap,
            .chars = chars[char_offset..][0..font_info.n_chars],
            .kerning_table = kernings[kerning_offset..][0 .. ALL_CHARS.len * ALL_CHARS.len],
            .bitmap = bitmaps[bitmap_offset..][0 .. FONT_BITMAP_SIZE * FONT_BITMAP_SIZE],
        };
        char_offset += font_info.n_chars;
        kerning_offset += ALL_CHARS.len * ALL_CHARS.len;
        bitmap_offset += FONT_BITMAP_SIZE * FONT_BITMAP_SIZE;
    }

    return result;
}
