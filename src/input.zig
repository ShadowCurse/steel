const events = @import("events.zig");
const cimgui = @import("bindings/cimgui.zig");

pub var lmb_was_pressed: bool = false;
pub var lmb_was_released: bool = false;
pub var lmb_now_pressed: bool = false;
pub var rmb_was_pressed: bool = false;
pub var rmb_was_released: bool = false;
pub var rmb_now_pressed: bool = false;
pub var mmb_was_pressed: bool = false;
pub var mmb_was_released: bool = false;
pub var mmb_now_pressed: bool = false;

const Self = @This();

pub fn reset() void {
    lmb_was_pressed = false;
    lmb_was_released = false;
    lmb_now_pressed = false;
    rmb_was_pressed = false;
    rmb_was_released = false;
    rmb_now_pressed = false;
    mmb_was_pressed = false;
    mmb_was_released = false;
    mmb_now_pressed = false;
}

pub fn update(new_events: []events.Event) void {
    lmb_was_pressed = false;
    lmb_was_released = false;
    rmb_was_pressed = false;
    rmb_was_released = false;
    mmb_was_pressed = false;
    mmb_was_released = false;
    for (new_events) |event| {
        switch (event) {
            .Mouse => |mouse| {
                switch (mouse) {
                    .Button => |button| {
                        switch (button.key) {
                            .LMB => {
                                lmb_was_pressed = button.type == .Pressed;
                                lmb_was_released = button.type == .Released;
                            },
                            .RMB => {
                                rmb_was_pressed = button.type == .Pressed;
                                rmb_was_released = button.type == .Released;
                            },
                            .WHEEL => {
                                mmb_was_pressed = button.type == .Pressed;
                                mmb_was_released = button.type == .Released;
                            },
                            else => {},
                        }
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
    if (lmb_was_pressed)
        lmb_now_pressed = true;
    if (lmb_was_released)
        lmb_now_pressed = false;
    if (rmb_was_pressed)
        rmb_now_pressed = true;
    if (rmb_was_released)
        rmb_now_pressed = false;
    if (mmb_was_pressed)
        mmb_now_pressed = true;
    if (mmb_was_released)
        mmb_now_pressed = false;
}

pub fn imgui_info() void {
    _ = cimgui.igValue_Bool("lmb_was_pressed", lmb_was_pressed);
    _ = cimgui.igValue_Bool("lmb_was_released", lmb_was_released);
    _ = cimgui.igValue_Bool("lmb_now_pressed", lmb_now_pressed);
    _ = cimgui.igValue_Bool("rmb_was_pressed", rmb_was_pressed);
    _ = cimgui.igValue_Bool("rmb_was_released", rmb_was_released);
    _ = cimgui.igValue_Bool("rmb_now_pressed", rmb_now_pressed);
    _ = cimgui.igValue_Bool("mmb_was_pressed", mmb_was_pressed);
    _ = cimgui.igValue_Bool("mmb_was_released", mmb_was_released);
    _ = cimgui.igValue_Bool("mmb_now_pressed", mmb_now_pressed);
}
