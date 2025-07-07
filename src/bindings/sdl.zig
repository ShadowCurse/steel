const std = @import("std");
const log = @import("../log.zig");

const sdl = @cImport({
    @cInclude("SDL3/SDL.h");
});
pub usingnamespace sdl;

pub fn assert(comptime src: std.builtin.SourceLocation, b: bool) void {
    log.assert(src, b, "SDL error {s}", .{sdl.SDL_GetError()});
}
