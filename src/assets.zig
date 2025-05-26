const std = @import("std");
const log = @import("log.zig");
const math = @import("math.zig");
const memory = @import("memory.zig");
const cgltf = @import("bindings/cgltf.zig");

const Allocator = std.mem.Allocator;
const FixedArena = memory.FixedArena;
const Mesh = @import("mesh.zig");
const Color4 = math.Color4;
const Vec4 = math.Vec4;
const Vec3 = math.Vec3;
const Vec2 = math.Vec2;

const rendering = @import("rendering.zig");
const GpuMesh = rendering.GpuMesh;

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
// )

pub const Meshes = std.EnumArray(ModelType, Mesh);
pub const Materials = std.EnumArray(ModelType, Material);
pub const GpuMeshes = std.EnumArray(ModelType, GpuMesh);

pub fn gpu_meshes_from_meshes(meshes: *const Meshes) GpuMeshes {
    var gpu_meshes: GpuMeshes = undefined;
    for (std.enums.values(ModelType)) |v| {
        gpu_meshes.getPtr(v).* = GpuMesh.from_mesh(meshes.getPtrConst(v));
    }
    return gpu_meshes;
}

pub const ModelType = enum {
    Floor,
    Wall,
    Spawn,
    Throne,
    Enemy,
    PathMarker,
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

pub const Packer = struct {
    materials: std.EnumArray(ModelType, Material) = undefined,
    mesh_infos: std.EnumArray(ModelType, MeshInfo) = undefined,
    indices: std.ArrayListUnmanaged(Mesh.Index) = .{},
    vertices: std.ArrayListUnmanaged(Mesh.Vertex) = .{},

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
        self.materials.getPtr(model_type).* = .{
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
        log.info(@src(), "Total bytes for packed data: {d}", .{total_size});

        const mem = try gpa_alloc.alignedAlloc(u8, 4096, total_size);
        defer gpa_alloc.free(mem);
        var arena_allocator = FixedArena.init(mem);
        const arena_alloc = arena_allocator.allocator();

        _ = try arena_alloc.dupe(Material, &self.materials.values);
        _ = try arena_alloc.dupe(MeshInfo, &self.mesh_infos.values);
        _ = try arena_alloc.dupe(Mesh.Index, self.indices.items);
        _ = try arena_alloc.dupe(Mesh.Vertex, self.vertices.items);

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        _ = try file.write(arena_allocator.slice());
    }
};

pub const UnpackedAssets = struct {
    meshes: Meshes,
    materials: Materials,
};
pub fn unpack(mem: []align(4096) const u8) !UnpackedAssets {
    var mem_ptr: usize = @intFromPtr(mem.ptr);

    var materials: []const Material = undefined;
    materials.ptr = @ptrFromInt(mem_ptr);
    materials.len = Materials.len;

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

    var result: UnpackedAssets = undefined;
    for (materials, 0..) |material, i|
        result.materials.values[i] = material;

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

    return result;
}
