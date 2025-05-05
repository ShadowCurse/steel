const std = @import("std");

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
