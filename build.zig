const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    var env_map = try std.process.getEnvMap(b.allocator);
    defer env_map.deinit();

    const cimgui = build_cimgui(b, target, optimize, &env_map);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "steel",
        .root_module = exe_mod,
    });
    exe.addIncludePath(.{ .cwd_relative = env_map.get("SDL3_INCLUDE_PATH").? });
    exe.addIncludePath(.{ .cwd_relative = env_map.get("LIBGL_INCLUDE_PATH").? });
    exe.addIncludePath(b.path("thirdparty/cimgui"));
    exe.linkLibC();
    exe.linkSystemLibrary("SDL3");
    exe.linkSystemLibrary("GL");
    exe.linkLibrary(cimgui);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
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
