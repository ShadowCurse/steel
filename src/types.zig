const log = @import("log.zig");

pub fn RingBuffer(comptime T: type, comptime N: u32) type {
    return struct {
        ring: [N]T = .{T{}} ** N,
        start: u32 = 0,
        len: u32 = 0,

        const Self = @This();

        pub fn empty(self: *const Self) bool {
            return self.len == 0;
        }

        pub fn full(self: *const Self) bool {
            return self.len == N;
        }

        pub fn reset(self: *Self) void {
            self.start = 0;
            self.len = 0;
        }

        pub fn end(self: *const Self) u32 {
            return (self.start + self.len) % N;
        }

        pub fn reserve_next(self: *Self) *T {
            log.assert(
                @src(),
                !self.full(),
                "Trying to reserve slot in the ring which is full",
                .{},
            );

            const current_idx = (self.start + self.len) % N;
            self.len += 1;
            return &self.ring[current_idx];
        }

        pub fn append(self: *Self, v: T) void {
            if (self.full()) {
                log.warn(@src(), "Trying to append {any} to the ring which is full", .{v});
                return;
            }

            const current_idx = (self.start + self.len) % N;
            self.ring[current_idx] = v;
            self.len += 1;
        }

        pub fn pop_front(self: *Self) T {
            if (self.empty()) {
                log.warn(@src(), "Trying to pop_from from the ring which is empty", .{});
                return;
            }

            const index = self.start;
            self.start = (self.start + 1) % N;
            return self.ring[index];
        }

        pub const Iterator = struct {
            ring: *Self,
            start: u32,

            pub fn next(self: *Iterator) ?*T {
                if (self.start != self.ring.end()) {
                    const r = &self.ring.ring[self.start];
                    self.start += 1;
                    return r;
                } else return null;
            }
        };

        pub fn iterator(self: *Self) Iterator {
            return .{
                .ring = self,
                .start = self.start,
            };
        }
    };
}
