const std = @import("std");
const log = @import("log.zig");

pub const Allocator = std.mem.Allocator;
pub const Alignment = std.mem.Alignment;
pub const DebugAllocator = std.heap.DebugAllocator(.{});
pub const page_allocator = std.heap.page_allocator;

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

pub fn align_up(addr: usize, alignment: usize) usize {
    log.assert(@src(), alignment != 0, "Alignment is zero", .{});
    return (addr + alignment - 1) & ~(alignment - 1);
}

pub fn align_down(addr: usize, alignment: usize) usize {
    log.assert(@src(), alignment != 0, "Alignment is zero", .{});
    return addr & ~(alignment - 1);
}

pub const FixedArena = struct {
    mem: []u8 = &.{},
    used: usize = 0,

    const Self = @This();

    pub fn init(mem: []u8) Self {
        return .{
            .mem = mem,
        };
    }

    pub fn slice(self: *const Self) []const u8 {
        return self.mem[0..self.used];
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

        const mem_start: usize = @intFromPtr(self.mem.ptr);
        const end_addr: usize = mem_start + self.used;
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
    used: usize = 0,

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

        const mem_start: usize = @intFromPtr(self.mem.ptr);
        const end_addr: usize = mem_start + self.used;
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

pub fn ObjectPool(comptime T: type, comptime N: u32) type {
    return struct {
        array: std.BoundedArray(Node, N) = .{},
        first_node: ?*Node = null,
        last_node: ?*Node = null,
        free_list: ?*Node = null,

        const Self = @This();

        const Node = struct {
            next: ?*Node = null,
            prev: ?*Node = null,
            value: T,
        };

        pub fn reset(self: *Self) void {
            self.* = .{};
        }

        pub fn empty(self: *const Self) bool {
            return self.first_node == null;
        }

        pub fn full(self: *const Self) bool {
            return self.free_list == null and self.array.buffer.len == self.array.capacity();
        }

        pub fn compact(self: *const Self, allocator: Allocator) ![]T {
            const array = try allocator.alloc(T, N);
            var i: u32 = 0;
            var iter = self.const_iterator();
            while (iter.next()) |v| : (i += 1)
                array[i] = v.*;
            return array[0..i];
        }

        pub fn alloc(self: *Self) ?*T {
            const new_node =
                if (self.free_list) |free_node| blk: {
                    self.free_list = free_node.next;
                    break :blk free_node;
                } else blk: {
                    break :blk self.array.addOne() catch return null;
                };

            if (self.last_node) |last_node| {
                last_node.next = new_node;
                new_node.prev = last_node;
            } else {
                new_node.prev = null;
            }
            self.last_node = new_node;

            if (self.first_node == null) {
                self.first_node = new_node;
            }
            new_node.next = null;

            return &new_node.value;
        }

        pub fn free(self: *Self, value: *T) void {
            const old_node: *Node = @alignCast(@fieldParentPtr("value", value));

            if (old_node.prev) |prev|
                prev.next = old_node.next
            else
                self.first_node = old_node.next;

            if (old_node.next) |next|
                next.prev = old_node.prev
            else
                self.last_node = old_node.prev;

            if (self.free_list) |free_node|
                old_node.next = free_node
            else
                old_node.next = null;

            old_node.prev = null;
            self.free_list = old_node;
        }

        pub const Iterator = struct {
            pool: *Self,
            current_node: ?*Node,

            pub fn next(self: *Iterator) ?*T {
                if (self.current_node) |cn| {
                    const result = &cn.value;
                    self.current_node = cn.next;
                    return result;
                } else return null;
            }
        };

        pub fn iterator(self: *Self) Iterator {
            return .{
                .pool = self,
                .current_node = self.first_node,
            };
        }

        pub const ConstIterator = struct {
            pool: *const Self,
            current_node: ?*Node,

            pub fn next(self: *ConstIterator) ?*const T {
                if (self.current_node) |cn| {
                    const result = &cn.value;
                    self.current_node = cn.next;
                    return result;
                } else return null;
            }
        };
        pub fn const_iterator(self: *const Self) ConstIterator {
            return .{
                .pool = self,
                .current_node = self.first_node,
            };
        }
    };
}

test "ObjectPool_simple_iter" {
    var op = ObjectPool(usize, 8){};

    var os: [8]*usize = undefined;
    for (0..8) |i| {
        const o = op.alloc().?;
        o.* = i;
        os[i] = o;
    }

    var iter = op.iterator();
    var i: usize = 0;
    while (iter.next()) |o| : (i += 1) {
        try std.testing.expect(o.* == i);
    }
}

test "ObjectPool_free_alloc_0" {
    var op = ObjectPool(usize, 8){};

    var os: [8]*usize = undefined;
    for (0..8) |i| {
        const o = op.alloc().?;
        o.* = i;
        os[i] = o;
    }
    op.free(os[0]);
    {
        const expected = [_]usize{ 1, 2, 3, 4, 5, 6, 7 };
        var iter = op.iterator();
        var i: usize = 0;
        while (iter.next()) |o| : (i += 1) {
            try std.testing.expect(o.* == expected[i]);
        }
    }
    os[0] = op.alloc().?;
    os[0].* = 0;
    {
        const expected = [_]usize{ 1, 2, 3, 4, 5, 6, 7, 0 };
        var iter = op.iterator();
        var i: usize = 0;
        while (iter.next()) |o| : (i += 1) {
            try std.testing.expect(o.* == expected[i]);
        }
    }
}

test "ObjectPool_free_alloc_5" {
    var op = ObjectPool(usize, 8){};

    var os: [8]*usize = undefined;
    for (0..8) |i| {
        const o = op.alloc().?;
        o.* = i;
        os[i] = o;
    }
    op.free(os[5]);
    {
        const expected = [_]usize{ 0, 1, 2, 3, 4, 6, 7 };
        var iter = op.iterator();
        var i: usize = 0;
        while (iter.next()) |o| : (i += 1) {
            try std.testing.expect(o.* == expected[i]);
        }
    }
    os[5] = op.alloc().?;
    os[5].* = 5;
    {
        const expected = [_]usize{ 0, 1, 2, 3, 4, 6, 7, 5 };
        var iter = op.iterator();
        var i: usize = 0;
        while (iter.next()) |o| : (i += 1) {
            try std.testing.expect(o.* == expected[i]);
        }
    }
}

test "ObjectPool_free_alloc_7" {
    var op = ObjectPool(usize, 8){};

    var os: [8]*usize = undefined;
    for (0..8) |i| {
        const o = op.alloc().?;
        o.* = i;
        os[i] = o;
    }
    op.free(os[7]);
    {
        const expected = [_]usize{ 0, 1, 2, 3, 4, 5, 6 };
        var iter = op.iterator();
        var i: usize = 0;
        while (iter.next()) |o| : (i += 1) {
            try std.testing.expect(o.* == expected[i]);
        }
    }

    os[7] = op.alloc().?;
    os[7].* = 7;
    {
        const expected = [_]usize{ 0, 1, 2, 3, 4, 5, 6, 7 };
        var iter = op.iterator();
        var i: usize = 0;
        while (iter.next()) |o| : (i += 1) {
            try std.testing.expect(o.* == expected[i]);
        }
    }
}

test "ObjectPool_free_in_iter" {
    var op = ObjectPool(usize, 8){};

    var os: [8]*usize = undefined;
    for (0..5) |i| {
        const o = op.alloc().?;
        o.* = i;
        os[i] = o;
    }
    {
        var iter = op.iterator();
        var i: usize = 0;
        while (iter.next()) |o| : (i += 1) {
            if (o.* == 1) op.free(o);
        }
    }
    {
        const expected = [_]usize{ 0, 2, 3, 4 };
        var iter = op.iterator();
        var i: usize = 0;
        while (iter.next()) |o| : (i += 1) {
            try std.testing.expect(o.* == expected[i]);
        }
    }
}

test "ObjectPool_no_inf_chain" {
    var op = ObjectPool(usize, 8){};

    var os: [8]*usize = undefined;
    for (0..5) |i| {
        const o = op.alloc().?;
        o.* = i;
        os[i] = o;
    }
    {
        var iter = op.iterator();
        var i: usize = 0;
        while (iter.next()) |o| : (i += 1) {
            if (o.* == 1 or o.* == 2) op.free(o);
        }
    }
    {
        const expected = [_]usize{ 0, 3, 4 };
        var iter = op.iterator();
        var i: usize = 0;
        while (iter.next()) |o| : (i += 1) {
            try std.testing.expect(o.* == expected[i]);
        }
    }
    op.alloc().?.* = 25;
    {
        const expected = [_]usize{ 0, 3, 4, 25 };
        var iter = op.iterator();
        var i: usize = 0;
        while (iter.next()) |o| : (i += 1) {
            try std.testing.expect(o.* == expected[i]);
        }
    }
}
