const std = @import("std");

const Engine = @import("engine.zig").Engine;
const parser = @import("parser.zig");
const Log = @import("log.zig").Log;

pub fn run(engine: *Engine, log: ?*Log, io: std.Io) !void {
    var stdin_buf: [4096]u8 = undefined;
    var stdout_buf: [4096]u8 = undefined;

    var stdin = std.Io.File.stdin().readerStreaming(io, &stdin_buf);
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buf);

    try runWithIo(engine, log, &stdin.interface, &stdout.interface);
    try stdout.interface.flush();
}

fn runWithIo(engine: *Engine, log: ?*Log, input: *std.Io.Reader, output: *std.Io.Writer) !void {
    while (true) {
        try output.writeAll("zkv> ");
        try output.flush();

        const line = input.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };

        input.toss(@min(1, input.bufferedLen()));

        const command = parser.parse(line) catch |err| {
            try writeParseError(output, err);
            try output.flush();
            continue;
        } orelse continue;

        if (try execute(engine, log, command, output)) break;
        try output.flush();
    }
}

fn execute(engine: *Engine, log: ?*Log, command: parser.Command, output: *std.Io.Writer) !bool {
    switch (command) {
        .put => |put| {
            const result = try engine.put(put.key, put.value);
            if (log) |l| try l.appendPut(put.key, put.value);
            switch (result) {
                .inserted => try output.writeAll("inserted\n"),
                .replaced => try output.writeAll("replaced\n"),
            }
        },
        .get => |key| {
            if (engine.get(key)) |value| {
                try output.print("{s}\n", .{value});
            } else {
                try output.writeAll("not found\n");
            }
        },
        .delete => |key| {
            if (engine.delete(key)) {
                if (log) |l| try l.appendDelete(key);
                try output.writeAll("deleted\n");
            } else {
                try output.writeAll("not found\n");
            }
        },
        .count => try output.print("{d}\n", .{engine.count()}),
        .keys => {
            var it = engine.iterator();
            while (it.next()) |entry| {
                try output.print("{s}\n", .{entry.key_ptr.*});
            }
        },
        .dump => {
            var it = engine.iterator();
            while (it.next()) |entry| {
                try output.print("{s}: {s}\n", .{
                    entry.key_ptr.*,
                    entry.value_ptr.*,
                });
            }
        },
        .clear => {
            engine.clear();
            if (log) |l| try l.appendClear();
            try output.writeAll("cleared\n");
        },
        .compact => {
            if (log) |l| {
                try l.compact(engine);
                try output.writeAll("compacted\n");
            } else {
                try output.writeAll("log disabled\n");
            }
        },
        .exists => |key| {
            if (engine.exists(key)) {
                try output.writeAll("true\n");
            } else {
                try output.writeAll("false\n");
            }
        },
        .help => try writeHelp(output),
        .exit => return true,
    }

    return false;
}

fn writeParseError(output: *std.Io.Writer, err: parser.ParseError) !void {
    switch (err) {
        error.UnknownCommand => try output.writeAll("error: unknown command\n"),
        error.MissingKey => try output.writeAll("error: missing key\n"),
        error.MissingValue => try output.writeAll("error: missing value\n"),
        error.TooManyArguments => try output.writeAll("error: too many arguments\n"),
    }
}

fn writeHelp(output: *std.Io.Writer) !void {
    try output.writeAll(
        \\Commands:
        \\  put <key> <value>  store value under key
        \\  get <key>          print value for key
        \\  del <key>          delete key
        \\  exists <key>       print whether key exists
        \\  count              print number of keys
        \\  keys               print all keys
        \\  dump               print all key-value pairs
        \\  clear              delete all keys
        \\  compact            rewrite log to current engine state
        \\  help               show this help
        \\  exit               quit
        \\
    );
}

fn expectReplOutput(input_text: []const u8, expected_output: []const u8) !void {
    var engine = Engine.init(std.testing.allocator);
    defer engine.deinit();

    var input: std.Io.Reader = .fixed(input_text);
    var output_buf: [4096]u8 = undefined;
    var output: std.Io.Writer = .fixed(&output_buf);

    try runWithIo(&engine, null, &input, &output);
    try std.testing.expectEqualStrings(expected_output, output.buffered());
}

test "repl exits" {
    try expectReplOutput(
        "exit\n",
        "zkv> ",
    );
}

test "repl executes kv commands" {
    try expectReplOutput(
        \\put name ashish
        \\get name
        \\put name zkv
        \\get name
        \\count
        \\del name
        \\get name
        \\count
        \\exit
        \\
    ,
        \\zkv> inserted
        \\zkv> ashish
        \\zkv> replaced
        \\zkv> zkv
        \\zkv> 1
        \\zkv> deleted
        \\zkv> not found
        \\zkv> 0
        \\zkv>
    );
}

test "repl reports parse errors and continues" {
    try expectReplOutput(
        \\wat
        \\get
        \\put name
        \\count extra
        \\exit
        \\
    ,
        \\zkv> error: unknown command
        \\zkv> error: missing key
        \\zkv> error: missing value
        \\zkv> error: too many arguments
        \\zkv>
    );
}

test "repl ignores blank lines" {
    try expectReplOutput(
        \\
        \\
        \\exit
        \\
    ,
        \\zkv> zkv> zkv>
    );
}

test "repl stops on eof without exit" {
    try expectReplOutput(
        \\put name ashish
        \\get name
    ,
        \\zkv> inserted
        \\zkv> ashish
        \\zkv>
    );
}

test "repl handles final line without trailing newline" {
    try expectReplOutput("count",
        \\zkv> 0
        \\zkv>
    );
}

test "repl prints keys" {
    try expectReplOutput(
        \\put name ashish
        \\keys
        \\exit
        \\
    ,
        \\zkv> inserted
        \\zkv> name
        \\zkv>
    );
}

test "repl dumps key values" {
    try expectReplOutput(
        \\put name ashish
        \\dump
        \\exit
        \\
    ,
        \\zkv> inserted
        \\zkv> name: ashish
        \\zkv>
    );
}

test "repl checks whether keys exist" {
    try expectReplOutput(
        \\exists name
        \\put name ashish
        \\exists name
        \\exit
        \\
    ,
        \\zkv> false
        \\zkv> inserted
        \\zkv> true
        \\zkv>
    );
}

test "repl clears values" {
    try expectReplOutput(
        \\put name ashish
        \\clear
        \\count
        \\exists name
        \\exit
        \\
    ,
        \\zkv> inserted
        \\zkv> cleared
        \\zkv> 0
        \\zkv> false
        \\zkv>
    );
}

test "repl reports compact unavailable without log" {
    try expectReplOutput(
        \\compact
        \\exit
        \\
    ,
        \\zkv> log disabled
        \\zkv>
    );
}
