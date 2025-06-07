const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    var env_map = try std.process.getEnvMap(b.allocator);
    defer env_map.deinit();

    const cimgui = build_cimgui(b, target, optimize, &env_map);

    const artifact = if (target.result.os.tag == .emscripten) blk: {
        const cache_include = std.fs.path.join(
            b.allocator,
            &.{
                b.sysroot.?,
                "cache",
                "sysroot",
                "include",
            },
        ) catch @panic("Out of memory");
        defer b.allocator.free(cache_include);
        const cache_path = std.Build.LazyPath{ .cwd_relative = cache_include };

        cimgui.addIncludePath(cache_path);
        b.installArtifact(cimgui);

        const lib = b.addStaticLibrary(.{
            .name = "wasm",
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });
        lib.addIncludePath(cache_path);
        break :blk lib;
    } else blk: {
        const exe = b.addExecutable(.{
            .name = "steel",
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });
        exe.linkSystemLibrary("SDL3");
        exe.linkSystemLibrary("GL");
        break :blk exe;
    };
    artifact.addIncludePath(.{ .cwd_relative = env_map.get("SDL3_INCLUDE_PATH").? });
    artifact.addIncludePath(.{ .cwd_relative = env_map.get("LIBGL_INCLUDE_PATH").? });
    artifact.addIncludePath(b.path("thirdparty/cimgui"));
    artifact.addIncludePath(b.path("thirdparty/stb/"));
    artifact.linkLibC();
    artifact.linkLibrary(cimgui);
    b.installArtifact(artifact);

    if (target.result.os.tag != .emscripten) {
        const run_cmd = b.addRunArtifact(artifact);
        run_cmd.step.dependOn(b.getInstallStep());

        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);

        const asset_packer = b.addExecutable(.{
            .name = "asset_packer",
            .root_source_file = b.path("src/asset_packer.zig"),
            .target = target,
            .optimize = optimize,
        });
        asset_packer.addIncludePath(b.path("thirdparty/cgltf/"));
        asset_packer.addIncludePath(b.path("thirdparty/stb/"));
        asset_packer.addCSourceFile(.{ .file = b.path("thirdparty/cgltf/cgltf.c") });
        asset_packer.addCSourceFile(.{ .file = b.path("thirdparty/stb/stb.c") });
        asset_packer.linkLibC();

        b.installArtifact(asset_packer);
        const pack_cmd = b.addRunArtifact(asset_packer);
        pack_cmd.step.dependOn(b.getInstallStep());

        const pack_step = b.step("pack", "Pack assets");
        pack_step.dependOn(&pack_cmd.step);
    }
}

fn build_cimgui(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    env_map: *const std.process.EnvMap,
) *std.Build.Step.Compile {
    const cimgui = b.addStaticLibrary(.{
        .name = "cimgui",
        .target = target,
        .optimize = optimize,
    });
    cimgui.addCSourceFiles(.{
        .files = &.{
            "thirdparty/cimgui/cimgui.cpp",
            "thirdparty/cimgui/imgui/imgui.cpp",
            "thirdparty/cimgui/imgui/imgui_demo.cpp",
            "thirdparty/cimgui/imgui/imgui_draw.cpp",
            "thirdparty/cimgui/imgui/imgui_tables.cpp",
            "thirdparty/cimgui/imgui/imgui_widgets.cpp",
            "thirdparty/cimgui/imgui/backends/imgui_impl_sdl3.cpp",
            "thirdparty/cimgui/imgui/backends/imgui_impl_opengl3.cpp",
        },
    });
    cimgui.addIncludePath(b.path("thirdparty/cimgui"));
    cimgui.addIncludePath(b.path("thirdparty/cimgui/imgui"));
    cimgui.addIncludePath(b.path("thirdparty/cimgui/imgui/backends"));
    cimgui.addIncludePath(.{ .cwd_relative = env_map.get("SDL3_INCLUDE_PATH").? });
    cimgui.linkLibCpp();
    return cimgui;
}
