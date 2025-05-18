const std = @import("std");
const log = @import("log.zig");
const math = @import("math.zig");
const memory = @import("memory.zig");
const cgltf = @import("bindings/cgltf.zig");

const Allocator = std.mem.Allocator;
const FixedArena = memory.FixedArena;
const Mesh = @import("mesh.zig");
const Vec3 = math.Vec3;
const Vec2 = math.Vec2;

pub const DEFAULT_MESHES_DIR_PATH = "resources/models";
pub const DEFAULT_PACKED_ASSETS_PATH = "resources/packed.p";

// In memory this will be
// (
//   {number of meshes, number of sounds}
//   [
//     {mesh_1 name len with zero, mesh_1 number of indexes, mesh_1 number of vertices}
//     ...
//   ]
//   [all names]
//   (align 4)
//   [all indices]
//   (align 32)
//   [all vertices]
// )

pub const Header = struct {
    number_of_meshes: u32 = 0,
};

pub const MeshInfo = extern struct {
    name_len: u32 = 0,
    number_of_indices: u32 = 0,
    number_of_vertices: u32 = 0,
};

pub const Packer = struct {
    header: Header = .{},
    meshes_infos: std.ArrayListUnmanaged(MeshInfo) = .{},
    meshes_names: std.ArrayListUnmanaged(u8) = .{},
    meshes_indices: std.ArrayListUnmanaged(Mesh.Index) = .{},
    meshes_vertices: std.ArrayListUnmanaged(Mesh.Vertex) = .{},

    const Self = @This();

    pub fn add_mesh(
        self: *Packer,
        gpa_alloc: Allocator,
        scratch_alloc: Allocator,
        path: [:0]const u8,
    ) !void {
        log.info(@src(), "Loading gltf mesh from path: {s}", .{path});

        // TODO add allocator params?
        const options = cgltf.cgltf_options{};
        var data: *cgltf.cgltf_data = undefined;
        try cgltf.check_result(cgltf.cgltf_parse_file(&options, path.ptr, @ptrCast(&data)));
        try cgltf.check_result(cgltf.cgltf_load_buffers(&options, data, path.ptr));
        defer cgltf.cgltf_free(data);

        if (data.meshes_count != 1)
            return error.cgltf_too_many_meshes;

        const mesh = data.meshes[0];

        if (mesh.primitives_count != 1)
            return error.cgltf_too_many_primitives;

        const mesh_name = std.mem.span(mesh.name);
        try self.meshes_names.appendSlice(gpa_alloc, mesh_name);
        log.info(@src(), "Mesh name: {s}", .{mesh_name});

        const primitive = &mesh.primitives[0];
        const number_of_indices = primitive.indices[0].count;

        const initial_index_num = self.meshes_indices.items.len;
        try self.meshes_indices.resize(gpa_alloc, initial_index_num + number_of_indices);
        for (self.meshes_indices.items[initial_index_num..], 0..) |*i, j| {
            const index = cgltf.cgltf_accessor_read_index(primitive.indices, j);
            i.* = @intCast(index);
        }

        const number_of_vertices = primitive.attributes[0].data[0].count;
        const initial_vertex_num = self.meshes_vertices.items.len;
        try self.meshes_vertices.resize(gpa_alloc, initial_vertex_num + number_of_vertices);

        self.header.number_of_meshes += 1;
        try self.meshes_infos.append(gpa_alloc, .{
            .name_len = @intCast(mesh_name.len),
            .number_of_indices = @intCast(number_of_indices),
            .number_of_vertices = @intCast(number_of_vertices),
        });

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

                    for (self.meshes_vertices.items[initial_vertex_num..], positions) |*vertex, position| {
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

                    for (self.meshes_vertices.items[initial_vertex_num..], normals) |*vertex, normal| {
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

                    for (self.meshes_vertices.items[initial_vertex_num..], uvs) |*vertex, uv| {
                        vertex.uv_x = uv.x;
                        vertex.uv_y = uv.y;
                    }
                },
                else => {
                    log.err(@src(), "Unknown attribute type: {}. Skipping", .{attr.type});
                },
            }

            // For debugging use normals as colors
            for (self.meshes_vertices.items) |*v| {
                v.color = v.normal.extend(1.0);
            }
        }
    }

    pub fn pack_and_write(self: *const Packer, gpa_alloc: Allocator, path: []const u8) !void {
        var total_size: usize = @sizeOf(Header);
        total_size = memory.align_up(total_size, @alignOf(MeshInfo));
        total_size += self.meshes_infos.items.len * @sizeOf(MeshInfo);
        total_size = memory.align_up(total_size, @alignOf(u8));
        total_size += self.meshes_names.items.len * @sizeOf(u8);
        total_size = memory.align_up(total_size, @alignOf(Mesh.Index));
        total_size += self.meshes_indices.items.len * @sizeOf(Mesh.Index);
        total_size = memory.align_up(total_size, @alignOf(Mesh.Vertex));
        total_size += self.meshes_vertices.items.len * @sizeOf(Mesh.Vertex);
        log.info(@src(), "Total bytes for packed data: {d}", .{total_size});

        const mem = try gpa_alloc.alignedAlloc(u8, 4096, total_size);
        defer gpa_alloc.free(mem);
        var arena_allocator = FixedArena.init(mem);
        const arena_alloc = arena_allocator.allocator();

        const header = try arena_alloc.create(Header);
        header.* = self.header;

        const meshes_infos = try arena_alloc.alloc(MeshInfo, self.meshes_infos.items.len);
        @memcpy(meshes_infos, self.meshes_infos.items);

        const meshes_names = try arena_alloc.alloc(u8, self.meshes_names.items.len);
        @memcpy(meshes_names, self.meshes_names.items);

        const meshes_indices =
            try arena_alloc.alloc(Mesh.Index, self.meshes_indices.items.len);
        @memcpy(meshes_indices, self.meshes_indices.items);

        const meshes_vertices =
            try arena_alloc.alloc(Mesh.Vertex, self.meshes_vertices.items.len);
        @memcpy(meshes_vertices, self.meshes_vertices.items);

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        _ = try file.write(arena_allocator.slice());
    }
};

pub fn unpack(alloc: Allocator, mem: []align(4096) const u8) ![]Mesh {
    var mem_ptr: usize = @intFromPtr(mem.ptr);
    const header: *const Header = @ptrFromInt(mem_ptr);
    log.debug(@src(), "Header: {any}", .{header});

    mem_ptr += @sizeOf(Header);
    var meshes_infos: []const MeshInfo = undefined;
    meshes_infos.ptr = @ptrFromInt(mem_ptr);
    meshes_infos.len = header.number_of_meshes;

    var total_names_len: u32 = 0;
    var total_indices_len: u32 = 0;
    var total_vertices_len: u32 = 0;
    for (meshes_infos) |info| {
        total_names_len += info.name_len;
        total_indices_len += info.number_of_indices;
        total_vertices_len += info.number_of_vertices;
    }

    mem_ptr += @sizeOf(MeshInfo) * header.number_of_meshes;
    mem_ptr = memory.align_up(mem_ptr, @alignOf(u8));
    var names: []const u8 = undefined;
    names.ptr = @ptrFromInt(mem_ptr);
    names.len = total_names_len;

    mem_ptr += @sizeOf(u8) * total_names_len;
    mem_ptr = memory.align_up(mem_ptr, @alignOf(Mesh.Index));
    var indices: []const Mesh.Index = undefined;
    indices.ptr = @ptrFromInt(mem_ptr);
    indices.len = total_indices_len;

    mem_ptr += @sizeOf(Mesh.Index) * total_indices_len;
    mem_ptr = memory.align_up(mem_ptr, @alignOf(Mesh.Vertex));
    var vertices: []const Mesh.Vertex = undefined;
    vertices.ptr = @ptrFromInt(mem_ptr);
    vertices.len = total_vertices_len;

    var name_offset: u32 = 0;
    var index_offset: u32 = 0;
    var vertex_offset: u32 = 0;
    const meshes = try alloc.alloc(Mesh, header.number_of_meshes);
    for (meshes, meshes_infos) |*mesh, *info| {
        mesh.name = try alloc.dupe(u8, names[name_offset..][0..info.name_len]);
        name_offset += info.name_len;
        mesh.indices =
            try alloc.dupe(Mesh.Index, indices[index_offset..][0..info.number_of_indices]);
        index_offset += info.number_of_indices;
        mesh.vertices =
            try alloc.dupe(Mesh.Vertex, vertices[vertex_offset..][0..info.number_of_vertices]);
        vertex_offset += info.number_of_vertices;
    }

    return meshes;
}
