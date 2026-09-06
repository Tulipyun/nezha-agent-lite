//! A fixed-capacity queue. Producers never block the HTTP/2 task reader.
const std = @import("std");

pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        items: []T,
        head: usize = 0,
        count: usize = 0,
        high_water: usize = 0,
        closed: bool = false,
        mutex: std.Thread.Mutex = .{},
        available: std.Thread.Condition = .{},

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            if (capacity == 0) return error.InvalidCapacity;
            return .{ .allocator = allocator, .items = try allocator.alloc(T, capacity) };
        }

        /// All users must have stopped before deinit. Items are stored by value.
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.items);
        }

        pub fn tryPush(self: *Self, item: T) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.closed or self.count == self.items.len) return false;
            self.items[(self.head + self.count) % self.items.len] = item;
            self.count += 1;
            self.high_water = @max(self.high_water, self.count);
            self.available.signal();
            return true;
        }

        pub fn pop(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.count == 0 and !self.closed) self.available.wait(&self.mutex);
            if (self.count == 0) return null;
            const item = self.items[self.head];
            self.head = (self.head + 1) % self.items.len;
            self.count -= 1;
            return item;
        }

        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.closed = true;
            self.available.broadcast();
        }

        pub fn snapshot(self: *Self) struct { pending: usize, peak: usize } {
            self.mutex.lock();
            defer self.mutex.unlock();
            return .{ .pending = self.count, .peak = self.high_water };
        }
    };
}

test "bounded queue rejects overflow and preserves order across wraparound" {
    var queue = try Queue(u64).init(std.testing.allocator, 2);
    defer queue.deinit();
    try std.testing.expect(queue.tryPush(10));
    try std.testing.expect(queue.tryPush(20));
    try std.testing.expect(!queue.tryPush(30));
    try std.testing.expectEqual(@as(?u64, 10), queue.pop());
    try std.testing.expect(queue.tryPush(30));
    queue.close();
    try std.testing.expect(!queue.tryPush(40));
    try std.testing.expectEqual(@as(?u64, 20), queue.pop());
    try std.testing.expectEqual(@as(?u64, 30), queue.pop());
    try std.testing.expectEqual(@as(?u64, null), queue.pop());
    try std.testing.expectEqual(@as(usize, 2), queue.snapshot().peak);
}

test "eight consumers process a burst exactly once" {
    const Context = struct {
        queue: *Queue(u64),
        sum: std.atomic.Value(u64) = .init(0),
        count: std.atomic.Value(u64) = .init(0),
        fn consume(ctx: *@This()) void {
            while (ctx.queue.pop()) |value| {
                _ = ctx.sum.fetchAdd(value, .monotonic);
                _ = ctx.count.fetchAdd(1, .monotonic);
            }
        }
    };
    var queue = try Queue(u64).init(std.testing.allocator, 32);
    defer queue.deinit();
    var context = Context{ .queue = &queue };
    for (0..32) |i| try std.testing.expect(queue.tryPush(i + 1));
    var threads: [8]std.Thread = undefined;
    var started: usize = 0;
    defer {
        queue.close();
        for (threads[0..started]) |thread| thread.join();
    }
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Context.consume, .{&context});
        started += 1;
    }
    queue.close();
    for (threads[0..started]) |thread| thread.join();
    started = 0;
    try std.testing.expectEqual(@as(u64, 32), context.count.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 528), context.sum.load(.monotonic));
}
