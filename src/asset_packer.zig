const std = @import("std");
const log = @import("log.zig");
const assets = @import("assets.zig");
const memory = @import("memory.zig");

const DebugAllocator = std.heap.DebugAllocator(.{});
const RoundArena = memory.RoundArena;

pub fn main() !void {
    var gpa = DebugAllocator{};
    const gpa_alloc = gpa.allocator();

    var scratch_allocator = RoundArena.init(try gpa_alloc.alloc(u8, 4096));
    const scratch_alloc = scratch_allocator.allocator();

    var meshes_dir = try std.fs.cwd().openDir(assets.DEFAULT_MESHES_DIR_PATH, .{ .iterate = true });
    defer meshes_dir.close();

    var packer: assets.Packer = .{};
    var meshes_dir_iter = meshes_dir.iterate();
    while (try meshes_dir_iter.next()) |entry| {
        log.info(@src(), "Found mesh at: {s}", .{entry.name});
        const mesh_path = try std.fmt.allocPrintZ(
            scratch_alloc,
            "{s}/{s}",
            .{ assets.DEFAULT_MESHES_DIR_PATH, entry.name },
        );
        packer.add_mesh(gpa_alloc, scratch_alloc, mesh_path) catch |e| {
            log.err(@src(), "Error loading mesh from path: {s}: {}", .{ mesh_path, e });
        };
    }

    try packer.pack_and_write(gpa_alloc, assets.DEFAULT_PACKED_ASSETS_PATH);
}
