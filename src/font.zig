const log = @import("log.zig");

size: f32 = 0.0,
ascent: i32 = 0,
decent: i32 = 0,
line_gap: i32 = 0,
chars: []const CharInfo = &.{},
kerning_table: []const Kerning = &.{},
bitmap: []const u8 = &.{},
bitmap_height: u32 = 0,

pub const FIRST_CHAR = ' ';
pub const ALL_CHARS =
    " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";
pub const BITMAP_WIDTH = 1024;
pub const BITMAP_HEIGHT = 1024;
pub const BITMAP_SIZE = BITMAP_WIDTH * BITMAP_HEIGHT;

pub const Kerning = struct {
    char_1: u8 = 0,
    char_2: u8 = 0,
    kerning: i32 = 0,
};

pub const CharInfo = struct {
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

pub fn get_char_info(self: *const Self, char: u8) ?CharInfo {
    if (ALL_CHARS[0] <= char and char <= ALL_CHARS[ALL_CHARS.len - 1]) {
        return self.chars[char - FIRST_CHAR];
    } else {
        return null;
    }
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
