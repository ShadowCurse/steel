const log = @import("../log.zig");
const math = @import("../math.zig");
const XY = @import("../level.zig").XY;

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
            const child_type_info = @typeInfo(pointer.child);
            switch (child_type_info) {
                .@"struct" => |s| {
                    if (name) |n|
                        _ = cimgui.igSeparatorText(n);
                    const type_fields = s.fields;
                    inline for (type_fields) |field| {
                        switch (field.type) {
                            bool => {
                                _ = cimgui.igCheckbox(field.name, &@field(v, field.name));
                            },
                            u8, u16, u32, u64, usize => {
                                const t_flag = switch (field.type) {
                                    u8 => cimgui.ImGuiDataType_U8,
                                    u16 => cimgui.ImGuiDataType_U16,
                                    u32 => cimgui.ImGuiDataType_U32,
                                    u64, usize => cimgui.ImGuiDataType_U64,
                                    else => unreachable,
                                };
                                var step: u64 = 1;
                                var step_fast: u64 = 2;
                                _ = cimgui.igInputScalar(field.name, t_flag, @ptrCast(&@field(v, field.name)), &step, &step_fast, null, 0);
                            },
                            i8, i16, i32, i64, isize => {
                                const t_flag = switch (field.type) {
                                    i8 => cimgui.ImGuiDataType_S8,
                                    i16 => cimgui.ImGuiDataType_S16,
                                    i32 => cimgui.ImGuiDataType_S32,
                                    i64, usize => cimgui.ImGuiDataType_S64,
                                    else => unreachable,
                                };
                                var step: i64 = 1;
                                var step_fast: i64 = 2;
                                _ = cimgui.igInputScalar(field.name, t_flag, @ptrCast(&@field(v, field.name)), &step, &step_fast, null, 0);
                            },
                            f32 => {
                                _ = cimgui.igInputFloat(field.name, &@field(v, field.name), 0.01, 0.1, null, 0);
                            },
                            f64 => {
                                _ = cimgui.igInputDouble(field.name, &@field(v, field.name), 0.01, 0.1, null, 0);
                            },
                            math.Vec2 => {
                                _ = cimgui.igDragFloat2(field.name, @ptrCast(&@field(v, field.name)), 0.01, -100.0, 100.0, null, 0);
                            },
                            math.Vec3 => {
                                _ = cimgui.igDragFloat3(field.name, @ptrCast(&@field(v, field.name)), 0.01, -100.0, 100.0, null, 0);
                            },
                            math.Vec4 => {
                                _ = cimgui.igDragFloat4(field.name, @ptrCast(&@field(v, field.name)), 0.01, -100.0, 100.0, null, 0);
                            },
                            math.Mat4 => {
                                if (cimgui.igTreeNode_Str(field.name)) {
                                    defer cimgui.igTreePop();

                                    _ = cimgui.igInputFloat4("i", @ptrCast(&@field(v, field.name).i), null, 0);
                                    _ = cimgui.igInputFloat4("j", @ptrCast(&@field(v, field.name).j), null, 0);
                                    _ = cimgui.igInputFloat4("k", @ptrCast(&@field(v, field.name).k), null, 0);
                                    _ = cimgui.igInputFloat4("t", @ptrCast(&@field(v, field.name).t), null, 0);
                                }
                            },
                            math.Color3 => {
                                _ = cimgui.igColorEdit3(field.name, @ptrCast(&@field(v, field.name)), 0);
                            },
                            math.Color4 => {
                                _ = cimgui.igColorEdit4(field.name, @ptrCast(&@field(v, field.name)), 0);
                            },
                            XY => {
                                var step: u8 = 1;
                                var step_fast: u8 = 2;
                                const val: *[2]u8 = @ptrCast(&@field(v, field.name));
                                _ = cimgui.igInputScalarN(field.name, cimgui.ImGuiDataType_U8, val, 2, &step, &step_fast, null, 0);
                            },
                            ?[]XY => {
                                if (cimgui.igTreeNode_Str(field.name)) {
                                    defer cimgui.igTreePop();

                                    if (@field(v, field.name)) |path| {
                                        _ = cimgui.igBeginChild_Str("", .{}, cimgui.ImGuiChildFlags_Borders | cimgui.ImGuiChildFlags_ResizeY, 0);
                                        defer cimgui.igEndChild();

                                        var step: u8 = 1;
                                        var step_fast: u8 = 2;
                                        for (path, 0..) |*xy, i| {
                                            cimgui.igPushID_Int(@intCast(i));
                                            defer cimgui.igPopID();
                                            _ = cimgui.igInputScalarN("xy", cimgui.ImGuiDataType_U8, @ptrCast(xy), 2, &step, &step_fast, null, 0);
                                        }
                                    }
                                }
                            },
                            else => format(field.name, &@field(v, field.name)),
                        }
                    }
                },
                .@"enum" => |e| {
                    const size: cimgui.ImVec2 = .{
                        .x = 0,
                        .y = e.fields.len * cimgui.igGetTextLineHeightWithSpacing() +
                            0.25 * cimgui.igGetTextLineHeightWithSpacing(),
                    };
                    const list_name: [*c]const u8 = if (name) |n|
                        n
                    else
                        @typeName(t);
                    // This will return false if the list cannot be seen.
                    if (cimgui.igBeginListBox(list_name, size)) {
                        inline for (e.fields) |f| {
                            if (cimgui.igSelectable_Bool(f.name, @intFromEnum(v.*) == f.value, 0, .{}))
                                v.* = @enumFromInt(f.value);
                        }
                        _ = cimgui.igEndListBox();
                    }
                },
                else => log.comptime_err(
                    @src(),
                    "Cannot format pointer child type: {any} for cimgui",
                    .{pointer.child},
                ),
            }
        },
        else => log.comptime_err(@src(), "Cannot format non pointer type: {any} for cimgui", .{t}),
    }
}
