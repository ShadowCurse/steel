const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const log = @import("log.zig");

pub const PAGE_SIZE = std.heap.page_size_min;
pub const FileMem = struct {
    mem: []align(PAGE_SIZE) u8,

    const Self = @This();

    pub fn init(path: []const u8) !Self {
        const fd = try std.posix.open(path, .{ .ACCMODE = .RDONLY }, 0);
        defer std.posix.close(fd);

        const stat = try std.posix.fstat(fd);
        const mem = try std.posix.mmap(
            null,
            @intCast(stat.size),
            std.posix.PROT.READ,
            .{ .TYPE = .PRIVATE },
            fd,
            0,
        );
        return .{
            .mem = mem,
        };
    }

    pub fn deinit(self: Self) void {
        std.posix.munmap(self.mem);
    }
};

pub fn align_up(addr: u64, alignment: u64) u64 {
    log.assert(@src(), alignment != 0, "Alignment is zero", .{});
    return (addr + alignment - 1) & ~(alignment - 1);
}

pub fn align_down(addr: u64, alignment: u64) u64 {
    log.assert(@src(), alignment != 0, "Alignment is zero", .{});
    return addr & ~(alignment - 1);
}

pub const FixedArena = struct {
    mem: []u8 = &.{},
    used: u64 = 0,

    const Self = @This();

    pub fn init(mem: []u8) Self {
        return .{
            .mem = mem,
        };
    }

    pub fn reset(self: *Self) void {
        self.used = 0;
    }

    pub fn allocator(self: *Self) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *Self = @ptrCast(@alignCast(ctx));

        const remaining = self.mem.len - self.used;
        if (remaining < len) return null;

        const mem_start: u64 = @intFromPtr(self.mem.ptr);
        const end_addr: u64 = mem_start + self.used;
        const byte_align = alignment.toByteUnits();
        const aligned_start = align_up(end_addr, byte_align);
        const aligned_end = aligned_start + len;
        if (mem_start + self.mem.len < aligned_end) return null;

        self.used = aligned_end - mem_start;
        return @ptrFromInt(aligned_start);
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ctx;
        _ = alignment;
        _ = ret_addr;

        if (buf.len < new_len) {
            return false;
        } else {
            return true;
        }
    }

    fn remap(ctx: *anyopaque, buf: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = ctx;
        _ = buf;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        return null;
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: Alignment, ret_addr: usize) void {
        _ = ctx;
        _ = buf;
        _ = alignment;
        _ = ret_addr;
    }
};

pub const RoundArena = struct {
    mem: []u8 = &.{},
    used: u64 = 0,

    const Self = @This();

    pub fn init(mem: []u8) Self {
        return .{
            .mem = mem,
        };
    }

    pub fn allocator(self: *Self) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *Self = @ptrCast(@alignCast(ctx));

        if (self.mem.len < len) return null;

        const mem_start: u64 = @intFromPtr(self.mem.ptr);
        const end_addr: u64 = mem_start + self.used;
        const byte_align = alignment.toByteUnits();
        var aligned_start = align_up(end_addr, byte_align);
        var aligned_end = aligned_start + len;
        if (mem_start + self.mem.len < aligned_end) {
            aligned_start = align_up(mem_start, byte_align);
            aligned_end = aligned_start + len;
        }
        self.used = aligned_end - mem_start;
        return @ptrFromInt(aligned_start);
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ctx;
        _ = alignment;
        _ = ret_addr;

        if (buf.len < new_len) {
            return false;
        } else {
            return true;
        }
    }

    fn remap(ctx: *anyopaque, buf: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = ctx;
        _ = buf;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        return null;
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: Alignment, ret_addr: usize) void {
        _ = ctx;
        _ = buf;
        _ = alignment;
        _ = ret_addr;
    }
};
