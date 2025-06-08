const log = @import("log.zig");

size: f32,
ascent: i32 = 0,
decent: i32 = 0,
line_gap: i32 = 0,
chars: []const Char = &.{},
kerning_table: []const Kerning = &.{},
bitmap: []const u8,

pub const FIRST_CHAR = ' ';
pub const ALL_CHARS =
    " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";
pub const FONT_BITMAP_SIZE = 512;

pub const Kerning = struct {
    char_1: u8 = 0,
    char_2: u8 = 0,
    kerning: i32 = 0,
};

pub const Char = struct {
    texture_offset_x: f32 = 0.0,
    texture_offset_y: f32 = 0.0,
    width: f32 = 0.0,
    height: f32 = 0.0,
    x_offset: f32 = 0.0,
    y_offset: f32 = 0.0,
    x_advance: f32 = 0.0,
};

const Self = @This();

pub fn scale(self: *const Self) f32 {
    return self.size / @as(f32, @floatFromInt(self.ascent));
}

pub fn get_kerning(self: *const Self, char_1: u8, char_2: u8) f32 {
    const index = char_1 - FIRST_CHAR;
    const offset = char_2 - FIRST_CHAR;
    const info = self.kerning_table[index * ALL_CHARS.len + offset];
    log.assert(
        @src(),
        info.char_1 == char_1 and info.char_2 == char_2,
        "Tryingt to get a kerninig info for pair {c}/{c} but got one for pair {c}/{c}",
        .{ char_1, char_2, info.char_1, info.char_2 },
    );
    return @floatFromInt(info.kerning);
}
