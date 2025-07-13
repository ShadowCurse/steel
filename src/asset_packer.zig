const std = @import("std");
const log = @import("log.zig");
const memory = @import("memory.zig");
const Assets = @import("assets.zig");

const DebugAllocator = std.heap.DebugAllocator(.{});
const RoundArena = memory.RoundArena;

const ModelPathsType = std.EnumArray(Assets.ModelType, [:0]const u8);
const MODEL_PATHS = ModelPathsType.init(.{
    .Floor = Assets.DEFAULT_MESHES_DIR_PATH ++ "/floor.glb",
    .FloorTrap = Assets.DEFAULT_MESHES_DIR_PATH ++ "/floor_trap.glb",
    .Wall = Assets.DEFAULT_MESHES_DIR_PATH ++ "/wall.glb",
    .Spawn = Assets.DEFAULT_MESHES_DIR_PATH ++ "/spawn.glb",
    .Throne = Assets.DEFAULT_MESHES_DIR_PATH ++ "/throne.glb",
    .Enemy = Assets.DEFAULT_MESHES_DIR_PATH ++ "/enemy.glb",
    .PathMarker = Assets.DEFAULT_MESHES_DIR_PATH ++ "/path_marker.glb",
    .Crystal = Assets.DEFAULT_MESHES_DIR_PATH ++ "/crystal.glb",
});
const FontPathsType = std.EnumArray(Assets.FontType, struct { [:0]const u8, f32 });
const FONT_PATHS = FontPathsType.init(.{
    .Default = .{ Assets.DEFAULT_FONTS_DIR_PATH ++ "/Roboto-Regular.ttf", 128.0 },
});
const SoundtrackPathsType = std.EnumArray(Assets.SoundtrackType, [:0]const u8);
const SOUNDTRACK_PATHS = SoundtrackPathsType.init(.{
    .Background = Assets.DEFAULT_SOUNDTRACK_DIR_PATH ++ "/background.ogg",
});

pub fn main() !void {
    var gpa = DebugAllocator{};
    const gpa_alloc = gpa.allocator();

    var scratch_allocator = RoundArena.init(try gpa_alloc.alloc(u8, 1 << 30));
    const scratch_alloc = scratch_allocator.allocator();

    var packer: Assets.Packer = .{};
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
    for (0..FontPathsType.len) |i| {
        const font_type = FontPathsType.Indexer.keyForIndex(i);
        const t = FONT_PATHS.values[i];

        packer.add_font(
            gpa_alloc,
            scratch_alloc,
            t[0],
            t[1],
            font_type,
        ) catch |e| {
            log.err(@src(), "Error loading font from path: {s}: {}", .{ t[0], e });
        };
    }
    for (0..SoundtrackPathsType.len) |i| {
        const soundtrack_type = SoundtrackPathsType.Indexer.keyForIndex(i);
        const path = SOUNDTRACK_PATHS.values[i];

        packer.add_soundtrack(
            gpa_alloc,
            scratch_alloc,
            path,
            soundtrack_type,
        ) catch |e| {
            log.err(@src(), "Error loading soundtrack from path: {s}: {}", .{ path, e });
        };
    }

    try packer.pack_and_write(gpa_alloc, Assets.DEFAULT_PACKED_ASSETS_PATH);
}
