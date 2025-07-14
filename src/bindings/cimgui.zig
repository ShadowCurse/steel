const std = @import("std");
const log = @import("../log.zig");
const math = @import("../math.zig");

const XY = @import("../level.zig").XY;
const Assets = @import("../assets.zig");

const cimgui = @cImport({
    @cDefine("CIMGUI_DEFINE_ENUMS_AND_STRUCTS", "");
    @cDefine("CIMGUI_USE_OPENGL3", "");
    @cDefine("CIMGUI_USE_SDL3", "");
    @cInclude("cimgui.h");
    @cInclude("cimgui_impl.h");
});
pub usingnamespace cimgui;

pub fn format(name: ?[*c]const u8, v: anytype) void {
    const t = @TypeOf(v);
    const type_info = @typeInfo(t);
    switch (type_info) {
        .pointer => |pointer| {
            const type_name: [*c]const u8 = if (name) |n| n else @typeName(t);
            if (!fmt_simple_type(type_name, v)) {
                const child_type_info = @typeInfo(pointer.child);
                switch (child_type_info) {
                    .@"struct" => |s| {
                        _ = cimgui.igSeparatorText(type_name);
                        const type_fields = s.fields;
                        inline for (type_fields) |field| {
                            if (!fmt_simple_type(field.name, &@field(v, field.name)))
                                format(field.name, &@field(v, field.name));
                        }
                    },
                    .@"enum" => |e| {
                        const size: cimgui.ImVec2 = .{
                            .x = 0,
                            .y = e.fields.len * cimgui.igGetTextLineHeightWithSpacing() +
                                0.25 * cimgui.igGetTextLineHeightWithSpacing(),
                        };
                        // This will return false if the list cannot be seen.
                        if (cimgui.igBeginListBox(type_name, size)) {
                            inline for (e.fields) |f| {
                                if (cimgui.igSelectable_Bool(
                                    f.name,
                                    @intFromEnum(v.*) == f.value,
                                    0,
                                    .{},
                                ))
                                    v.* = @enumFromInt(f.value);
                            }
                            _ = cimgui.igEndListBox();
                        }
                    },
                    .array => |a| {
                        // var cimgui_id: i32 = 2048;

                        if (cimgui.igTreeNode_Str(type_name)) {
                            defer cimgui.igTreePop();

                            inline for (0..a.len) |i| {
                                const n = std.fmt.comptimePrint("{d}", .{i});
                                format(n, &v[i]);
                            }
                        }
                    },
                    .optional => {},
                    else => log.err(
                        @src(),
                        "Cannot format pointer child type: {any}",
                        .{pointer.child},
                    ),
                }
            }
        },
        else => log.comptime_err(@src(), "Cannot format non pointer type: {any}", .{t}),
    }
}

fn fmt_simple_type(name: [*c]const u8, v: anytype) bool {
    switch (@TypeOf(v)) {
        *bool => fmt_bool(name, v),
        *u8, *u16, *u32, *u64, *usize => fmt_unsigned(name, v),
        *i8, *i16, *i32, *i64, *isize => fmt_signed(name, v),
        *f32, *f64 => fmt_float(name, v),
        *math.Vec2,
        *math.Vec3,
        *math.Vec4,
        *math.Color3,
        *math.Color4,
        *math.Mat4,
        => fmt_math(name, v),
        *XY, *?[]XY => fmt_xy(name, v),
        *Assets.Materials => fmt_enum_array(name, v),
        else => return false,
    }
    return true;
}

fn fmt_bool(name: [*c]const u8, v: *bool) void {
    _ = cimgui.igCheckbox(name, v);
}

fn fmt_unsigned(name: [*c]const u8, v: anytype) void {
    const t_flag = switch (@TypeOf(v)) {
        *u8 => cimgui.ImGuiDataType_U8,
        *u16 => cimgui.ImGuiDataType_U16,
        *u32 => cimgui.ImGuiDataType_U32,
        *u64, usize => cimgui.ImGuiDataType_U64,
        else => log.comptime_err(@src(), "fmt_unsigned cannot format: {any} type", .{@TypeOf(v)}),
    };
    var step: u64 = 1;
    var step_fast: u64 = 2;
    _ = cimgui.igInputScalar(name, t_flag, @ptrCast(v), &step, &step_fast, null, 0);
}

fn fmt_signed(name: [*c]const u8, v: anytype) void {
    const t_flag = switch (@TypeOf(v)) {
        *i8 => cimgui.ImGuiDataType_S8,
        *i16 => cimgui.ImGuiDataType_S16,
        *i32 => cimgui.ImGuiDataType_S32,
        *i64, usize => cimgui.ImGuiDataType_S64,
        else => log.comptime_err(@src(), "fmt_signed cannot format: {any} type", .{@TypeOf(v)}),
    };
    var step: i64 = 1;
    var step_fast: i64 = 2;
    _ = cimgui.igInputScalar(name, t_flag, @ptrCast(v), &step, &step_fast, null, 0);
}

fn fmt_float(name: [*c]const u8, v: anytype) void {
    switch (@TypeOf(v)) {
        *f32 => _ = cimgui.igInputFloat(name, @ptrCast(v), 0.01, 0.1, null, 0),
        *f64 => _ = cimgui.igInputDouble(name, @ptrCast(v), 0.01, 0.1, null, 0),
        else => log.comptime_err(@src(), "fmt_float cannot format: {any} type", .{@TypeOf(v)}),
    }
}

fn fmt_math(name: [*c]const u8, v: anytype) void {
    switch (@TypeOf(v)) {
        *math.Vec2 => _ = cimgui.igDragFloat2(name, @ptrCast(v), 0.01, -100.0, 100.0, null, 0),
        *math.Vec3 => _ = cimgui.igDragFloat3(name, @ptrCast(v), 0.01, -100.0, 100.0, null, 0),
        *math.Vec4 => _ = cimgui.igDragFloat4(name, @ptrCast(v), 0.01, -100.0, 100.0, null, 0),
        *math.Color3 => _ = cimgui.igColorEdit3(name, @ptrCast(v), 0),
        *math.Color4 => _ = cimgui.igColorEdit4(name, @ptrCast(v), 0),
        *math.Mat4 => {
            if (cimgui.igTreeNode_Str(name)) {
                defer cimgui.igTreePop();

                _ = cimgui.igInputFloat4("i", @ptrCast(&v.i), null, 0);
                _ = cimgui.igInputFloat4("j", @ptrCast(&v.j), null, 0);
                _ = cimgui.igInputFloat4("k", @ptrCast(&v.k), null, 0);
                _ = cimgui.igInputFloat4("t", @ptrCast(&v.t), null, 0);
            }
        },
        else => log.comptime_err(@src(), "fmt_math cannot format: {any} type", .{@TypeOf(v)}),
    }
}

fn fmt_xy(name: [*c]const u8, v: anytype) void {
    switch (@TypeOf(v)) {
        *XY => {
            var step: u8 = 1;
            var step_fast: u8 = 2;
            const val: *[2]u8 = @ptrCast(v);
            _ = cimgui.igInputScalarN(name, cimgui.ImGuiDataType_U8, val, 2, &step, &step_fast, null, 0);
        },
        *?[]XY => {
            if (cimgui.igTreeNode_Str(name)) {
                defer cimgui.igTreePop();

                if (v.*) |path| {
                    _ = cimgui.igBeginChild_Str(
                        "",
                        .{},
                        cimgui.ImGuiChildFlags_Borders | cimgui.ImGuiChildFlags_ResizeY,
                        0,
                    );
                    defer cimgui.igEndChild();

                    var step: u8 = 1;
                    var step_fast: u8 = 2;
                    for (path, 0..) |*xy, i| {
                        cimgui.igPushID_Int(@intCast(i));
                        defer cimgui.igPopID();
                        _ = cimgui.igInputScalarN(
                            "xy",
                            cimgui.ImGuiDataType_U8,
                            @ptrCast(xy),
                            2,
                            &step,
                            &step_fast,
                            null,
                            0,
                        );
                    }
                }
            }
        },
        else => log.comptime_err(@src(), "fmt_xy cannot format: {any} type", .{@TypeOf(v)}),
    }
}

fn fmt_enum_array(name: [*c]const u8, v: anytype) void {
    _ = name;
    const enum_array_type = @typeInfo(@TypeOf(v)).pointer.child;
    var cimgui_id: i32 = 4096;
    inline for (&v.values, 0..) |*m, i| {
        cimgui.igPushID_Int(cimgui_id);
        cimgui_id += 1;
        defer cimgui.igPopID();
        const mat_name = std.fmt.comptimePrint(
            "{any}",
            .{@as(enum_array_type.Key, @enumFromInt(i))},
        );
        format(mat_name, m);
    }
}
