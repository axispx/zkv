const std = @import("std");

const Engine = @import("engine.zig").Engine;
const parser = @import("parser.zig");

pub const Log = struct {
    io: std.Io,
    file: std.Io.File,
    path: []const u8,

    pub fn open(io: std.Io, path: []const u8) !Log {
        const cwd = std.Io.Dir.cwd();

        const file = cwd.openFile(io, path, .{
            .mode = .read_write,
            .allow_directory = false,
        }) catch |err| switch (err) {
            error.FileNotFound => try cwd.createFile(io, path, .{
                .read = true,
                .truncate = false,
            }),
            else => return err,
        };

        return .{
            .io = io,
            .file = file,
            .path = path,
        };
    }

    pub fn replay(self: *Log, engine: *Engine) !void {
        var buf: [4096]u8 = undefined;
        var reader = self.file.readerStreaming(self.io, &buf);

        while (true) {
            const line = reader.interface.takeDelimiterExclusive('\n') catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };

            reader.interface.toss(@min(1, reader.interface.bufferedLen()));

            const command = try parser.parse(line) orelse continue;

            switch (command) {
                .put => |put| _ = try engine.put(put.key, put.value),
                .delete => |key| _ = engine.delete(key),
                .clear => engine.clear(),
                else => unreachable,
            }
        }
    }

    pub fn deinit(self: *Log) void {
        self.file.close(self.io);
    }

    pub fn appendPut(self: *Log, key: []const u8, value: []const u8) !void {
        var buf: [4096]u8 = undefined;
        var writer = self.file.writerStreaming(self.io, &buf);

        const stat = try self.file.stat(self.io);
        try writer.seekTo(stat.size);

        try writer.interface.print("put {s} {s}\n", .{ key, value });
        try writer.interface.flush();
    }

    pub fn appendDelete(self: *Log, key: []const u8) !void {
        var buf: [4096]u8 = undefined;
        var writer = self.file.writerStreaming(self.io, &buf);

        const stat = try self.file.stat(self.io);
        try writer.seekTo(stat.size);

        try writer.interface.print("del {s}\n", .{key});
        try writer.interface.flush();
    }

    pub fn appendClear(self: *Log) !void {
        var buf: [4096]u8 = undefined;
        var writer = self.file.writerStreaming(self.io, &buf);

        const stat = try self.file.stat(self.io);
        try writer.seekTo(stat.size);

        try writer.interface.writeAll("clear\n");
        try writer.interface.flush();
    }

    pub fn compact(self: *Log, engine: *const Engine) !void {
        var tmp_path_buf: [std.Io.Dir.max_name_bytes]u8 = undefined;
        const tmp_path = try std.fmt.bufPrint(&tmp_path_buf, "{s}.tmp", .{self.path});

        const cwd = std.Io.Dir.cwd();

        self.deinit();

        {
            var tmp = try Log.open(self.io, tmp_path);
            defer tmp.deinit();

            var it = engine.iterator();
            while (it.next()) |entry| {
                try tmp.appendPut(entry.key_ptr.*, entry.value_ptr.*);
            }
        }

        cwd.deleteFile(self.io, self.path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        try cwd.rename(tmp_path, cwd, self.path, self.io);

        self.* = try Log.open(self.io, self.path);
    }
};

fn tmpLogPath(tmp: *const std.testing.TmpDir, buffer: []u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, ".zig-cache/tmp/{s}/zkv.log", .{&tmp.sub_path});
}

fn readLogFile(path: []const u8, buffer: []u8) ![]const u8 {
    return try std.Io.Dir.cwd().readFile(std.testing.io, path, buffer);
}

test "log appends put and delete commands" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tmpLogPath(&tmp, &path_buf);

    var log = try Log.open(std.testing.io, path);
    try log.appendPut("name", "ashish");
    try log.appendDelete("name");
    log.deinit();

    var read_buf: [1024]u8 = undefined;
    const contents = try readLogFile(path, &read_buf);

    try std.testing.expectEqualStrings(
        \\put name ashish
        \\del name
        \\
    , contents);
}

test "log appends clear command" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tmpLogPath(&tmp, &path_buf);

    var log = try Log.open(std.testing.io, path);
    try log.appendPut("name", "ashish");
    try log.appendClear();
    log.deinit();

    var read_buf: [1024]u8 = undefined;
    const contents = try readLogFile(path, &read_buf);

    try std.testing.expectEqualStrings(
        \\put name ashish
        \\clear
        \\
    , contents);
}

test "log appends to existing file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tmpLogPath(&tmp, &path_buf);

    {
        var log = try Log.open(std.testing.io, path);
        try log.appendPut("name", "ashish");
        log.deinit();
    }

    {
        var log = try Log.open(std.testing.io, path);
        try log.appendPut("city", "toronto");
        log.deinit();
    }

    var read_buf: [1024]u8 = undefined;
    const contents = try readLogFile(path, &read_buf);

    try std.testing.expectEqualStrings(
        \\put name ashish
        \\put city toronto
        \\
    , contents);
}

test "log replay does not compact automatically" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tmpLogPath(&tmp, &path_buf);

    {
        var log = try Log.open(std.testing.io, path);
        try log.appendPut("name", "ashish");
        try log.appendPut("name", "zkv");
        log.deinit();
    }

    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();

    {
        var log = try Log.open(std.testing.io, path);
        try log.replay(&engine);
        log.deinit();
    }

    try std.testing.expectEqualStrings("zkv", engine.get("name").?);

    var read_buf: [1024]u8 = undefined;
    const contents = try readLogFile(path, &read_buf);

    try std.testing.expectEqualStrings(
        \\put name ashish
        \\put name zkv
        \\
    , contents);
}

test "log compacts history to current engine state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tmpLogPath(&tmp, &path_buf);

    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();

    var log = try Log.open(std.testing.io, path);
    defer log.deinit();

    _ = try engine.put("name", "ashish");
    try log.appendPut("name", "ashish");

    _ = try engine.put("name", "zkv");
    try log.appendPut("name", "zkv");

    _ = try engine.put("city", "toronto");
    try log.appendPut("city", "toronto");

    _ = engine.delete("city");
    try log.appendDelete("city");

    try log.compact(&engine);

    var read_buf: [1024]u8 = undefined;
    const contents = try readLogFile(path, &read_buf);

    try std.testing.expectEqualStrings(
        \\put name zkv
        \\
    , contents);
}

test "log appends after compaction" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tmpLogPath(&tmp, &path_buf);

    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();

    var log = try Log.open(std.testing.io, path);
    defer log.deinit();

    _ = try engine.put("name", "ashish");
    try log.appendPut("name", "ashish");

    try log.compact(&engine);

    _ = try engine.put("city", "toronto");
    try log.appendPut("city", "toronto");

    var read_buf: [1024]u8 = undefined;
    const contents = try readLogFile(path, &read_buf);

    try std.testing.expectEqualStrings(
        \\put name ashish
        \\put city toronto
        \\
    , contents);
}
