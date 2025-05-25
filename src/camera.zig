const std = @import("std");
const cimgui = @import("bindings/cimgui.zig");
const math = @import("math.zig");
const events = @import("events.zig");
const Platform = @import("platform.zig");

position: math.Vec3 = .{},
pitch: f32 = 0.0,
yaw: f32 = 0.0,

fovy: f32 = math.PI / 2.0,
near: f32 = 0.1,
far: f32 = 10000.0,

zoom: f32 = 50.0,

velocity: math.Vec3 = .{},
speed: f32 = 5.0,
active: bool = false,
top_down: bool = false,

view: math.Mat4 = .{},
projection: math.Mat4 = .{},
inverse_view: math.Mat4 = .{},
inverse_projection: math.Mat4 = .{},

const ORIENTATION = math.Quat.from_rotation_axis(.X, .NEG_Z, .Y);
const SENSITIVITY = 0.5;
const ORTHO_DEPTH = 100.0;

const Self = @This();

pub fn process_input(self: *Self, event: events.Event, dt: f32) void {
    switch (event) {
        .Keyboard => |key| {
            const value: f32 = if (key.type == .Pressed) 1.0 else 0.0;
            if (self.top_down) {
                switch (key.key) {
                    events.KeybordKeyScancode.W => self.velocity.y = -value,
                    events.KeybordKeyScancode.S => self.velocity.y = value,
                    events.KeybordKeyScancode.A => self.velocity.x = -value,
                    events.KeybordKeyScancode.D => self.velocity.x = value,
                    else => {},
                }
            } else {
                switch (key.key) {
                    events.KeybordKeyScancode.W => self.velocity.z = value,
                    events.KeybordKeyScancode.S => self.velocity.z = -value,
                    events.KeybordKeyScancode.A => self.velocity.x = -value,
                    events.KeybordKeyScancode.D => self.velocity.x = value,
                    events.KeybordKeyScancode.SPACE => self.velocity.y = -value,
                    events.KeybordKeyScancode.LCTRL => self.velocity.y = value,
                    else => {},
                }
            }
        },
        .Mouse => |mouse| {
            switch (mouse) {
                .Button => |button| {
                    switch (button.key) {
                        .WHEEL => self.active = button.type == .Pressed,
                        else => {},
                    }
                },
                .Motion => |motion| {
                    if (self.active) {
                        if (self.top_down) {
                            self.position.x -= motion.x * Self.SENSITIVITY * dt;
                            self.position.y += motion.y * Self.SENSITIVITY * dt;
                        } else {
                            self.yaw -= motion.x * Self.SENSITIVITY * dt;
                            self.pitch -= motion.y * Self.SENSITIVITY * dt;
                            if (math.PI / 2.0 < self.pitch) {
                                self.pitch = math.PI / 2.0;
                            }
                            if (self.pitch < -math.PI / 2.0) {
                                self.pitch = -math.PI / 2.0;
                            }
                        }
                    }
                },
                .Wheel => |wheel| {
                    if (self.top_down)
                        self.position.z -= wheel.amount * Self.SENSITIVITY * 50.0 * dt;
                },
            }
        },
        else => {},
    }
}

pub fn move(self: *Self, dt: f32) void {
    const rotation = self.rotation_matrix();
    const velocity = self.velocity.mul_f32(self.speed * dt).extend(1.0);
    const delta = rotation.mul_vec4(velocity);
    self.position = self.position.add(delta.shrink());

    self.inverse_view = self.transform();
    self.view = self.inverse_view.inverse();
    if (self.top_down)
        self.projection = self.orthogonal()
    else
        self.projection = self.perspective();
    self.inverse_projection = self.projection.inverse();
}

pub fn transform(self: *const Self) math.Mat4 {
    return self.rotation_matrix().translate(self.position);
}

pub fn rotation_matrix(self: *const Self) math.Mat4 {
    const r_yaw = math.Quat.from_axis_angle(.Z, self.yaw);
    const r_pitch = math.Quat.from_axis_angle(.X, self.pitch);
    return r_yaw.mul(r_pitch).mul(Self.ORIENTATION).to_mat4();
}

pub fn perspective(self: *const Self) math.Mat4 {
    var m = math.Mat4.perspective(
        self.fovy,
        @as(f32, @floatFromInt(Platform.WINDOW_WIDTH)) /
            @as(f32, @floatFromInt(Platform.WINDOW_HEIGHT)),
        self.near,
        self.far,
    );
    // flip Y for opengl
    m.j.y *= -1.0;
    return m;
}

pub fn orthogonal(self: *const Self) math.Mat4 {
    const width: f32 = @as(f32, Platform.WINDOW_WIDTH) / self.zoom;
    const height: f32 = @as(f32, Platform.WINDOW_HEIGHT) / self.zoom;
    var m = math.Mat4.orthogonal(
        width,
        height,
        Self.ORTHO_DEPTH,
    );
    // flip Y for opengl
    m.j.y *= -1.0;
    return m;
}

pub fn mouse_to_ray(self: *const Self, mouse_pos: math.Vec3) math.Ray {
    const world_near_world = if (self.top_down) blk: {
        break :blk self.inverse_view
            .mul(self.inverse_projection)
            .mul_vec4(mouse_pos.extend(1.0))
            .shrink();
    } else blk: {
        const world_near =
            self.inverse_view.mul(self.inverse_projection).mul_vec4(mouse_pos.extend(1.0));
        break :blk world_near.shrink().div_f32(world_near.w);
    };
    const forward = world_near_world.sub(self.position).normalize();
    return .{
        .origin = self.position,
        .direction = forward,
    };
}

pub fn mouse_to_xy(self: *const Self, mouse_pos: math.Vec3) math.Vec3 {
    if (self.top_down) {
        return self.inverse_view
            .mul(self.inverse_projection)
            .mul_vec4(mouse_pos.extend(1.0))
            .shrink();
    } else {
        const world_near =
            self.inverse_view.mul(self.inverse_projection).mul_vec4(mouse_pos.extend(1.0));
        const world_near_world = world_near.shrink().div_f32(world_near.w);
        const forward = world_near_world.sub(self.position).normalize();
        const t = -self.position.z / forward.z;
        const xy = self.position.add(forward.mul_f32(t));
        return xy;
    }
}

pub fn imgui_options(self: *Self) void {
    _ = cimgui.igSliderFloat3("position", @ptrCast(&self.position), -100.0, 100.0, null, 0);
    _ = cimgui.igSliderFloat("pitch", @ptrCast(&self.pitch), -100.0, 100.0, null, 0);
    _ = cimgui.igSliderFloat("yaw", @ptrCast(&self.yaw), -100.0, 100.0, null, 0);
    if (self.top_down) {
        _ = cimgui.igSliderFloat("zoom", @ptrCast(&self.zoom), -100.0, 100.0, null, 0);
    } else {
        _ = cimgui.igSliderFloat("fovy", @ptrCast(&self.fovy), -100.0, 100.0, null, 0);
        _ = cimgui.igSliderFloat("near", @ptrCast(&self.near), -100.0, 100.0, null, 0);
        _ = cimgui.igSliderFloat("far", @ptrCast(&self.far), -100.0, 100.0, null, 0);
    }
}
