const std = @import("std");

const Engine = @import("engine.zig").Engine;
const parser = @import("parser.zig");

pub const Log = struct {
    io: std.Io,
    file: std.Io.File,

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
