const std = @import("std");

pub const PutResult = enum {
    inserted,
    replaced,
};

pub const Engine = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) Engine {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Engine) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }

        self.map.deinit();
    }

    pub fn put(self: *Engine, key: []const u8, value: []const u8) !PutResult {
        const result = try self.map.getOrPut(key);

        const val_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(val_copy);
        if (result.found_existing) {
            self.allocator.free(result.value_ptr.*);
            result.value_ptr.* = val_copy;
            return .replaced;
        }

        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);

        result.key_ptr.* = key_copy;
        result.value_ptr.* = val_copy;

        return .inserted;
    }

    pub fn get(self: *const Engine, key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }

    pub fn delete(self: *Engine, key: []const u8) bool {
        if (self.map.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
            return true;
        }

        return false;
    }

    pub fn count(self: *const Engine) u32 {
        return self.map.count();
    }
};

test "engine puts and gets values" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();

    try std.testing.expectEqual(PutResult.inserted, try engine.put("name", "ashish"));
    try std.testing.expectEqualStrings("ashish", engine.get("name").?);
    try std.testing.expectEqual(@as(u32, 1), engine.count());
}

test "engine replaces existing values" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();

    try std.testing.expectEqual(PutResult.inserted, try engine.put("name", "ashish"));
    try std.testing.expectEqual(PutResult.replaced, try engine.put("name", "zkv"));

    try std.testing.expectEqualStrings("zkv", engine.get("name").?);
    try std.testing.expectEqual(@as(u32, 1), engine.count());
}

test "engine deletes values" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();

    _ = try engine.put("name", "ashish");

    try std.testing.expect(engine.delete("name"));
    try std.testing.expect(engine.get("name") == null);
    try std.testing.expectEqual(@as(u32, 0), engine.count());
    try std.testing.expect(!engine.delete("name"));
}

test "engine stores owned copies" {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();

    var key_buf = [_]u8{ 'n', 'a', 'm', 'e' };
    var value_buf = [_]u8{ 'a', 's', 'h', 'i', 's', 'h' };

    _ = try engine.put(key_buf[0..], value_buf[0..]);

    @memcpy(key_buf[0..], "city");
    @memcpy(value_buf[0..], "toront");

    try std.testing.expectEqualStrings("ashish", engine.get("name").?);
    try std.testing.expect(engine.get("city") == null);
}
