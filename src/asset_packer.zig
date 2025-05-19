const std = @import("std");
const log = @import("log.zig");
const assets = @import("assets.zig");
const memory = @import("memory.zig");

const DebugAllocator = std.heap.DebugAllocator(.{});
const RoundArena = memory.RoundArena;

const ModelPathsType = std.EnumArray(assets.ModelType, [:0]const u8);
const MODEL_PATHS = ModelPathsType.init(.{
    .Floor = assets.DEFAULT_MESHES_DIR_PATH ++ "/floor.glb",
    .Wall = assets.DEFAULT_MESHES_DIR_PATH ++ "/wall.glb",
    .Spawn = assets.DEFAULT_MESHES_DIR_PATH ++ "/spawn.glb",
    .Throne = assets.DEFAULT_MESHES_DIR_PATH ++ "/throne.glb",
});

pub fn main() !void {
    var gpa = DebugAllocator{};
    const gpa_alloc = gpa.allocator();

    var scratch_allocator = RoundArena.init(try gpa_alloc.alloc(u8, 4096));
    const scratch_alloc = scratch_allocator.allocator();

    var packer: assets.Packer = .{};
    for (0..ModelPathsType.len) |i| {
        const model_type = ModelPathsType.Indexer.keyForIndex(i);
        const path = MODEL_PATHS.values[i];

        packer.add_model(
            gpa_alloc,
            scratch_alloc,
            path,
            model_type,
        ) catch |e| {
            log.err(@src(), "Error loading model from path: {s}: {}", .{ path, e });
        };
    }

    try packer.pack_and_write(gpa_alloc, assets.DEFAULT_PACKED_ASSETS_PATH);
}
