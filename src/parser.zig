const std = @import("std");

pub const Command = union(enum) {
    put: struct {
        key: []const u8,
        value: []const u8,
    },
    get: []const u8,
    delete: []const u8,
    count,
    help,
    exit,
};

pub const ParseError = error{
    UnknownCommand,
    MissingKey,
    MissingValue,
    TooManyArguments,
};

pub fn parse(line: []const u8) ParseError!?Command {
    var scanner = Scanner{
        .rest = std.mem.trim(u8, line, " \t\r\n"),
    };

    const cmd = scanner.next() orelse return null;
    const kind = try CommandType.fromString(cmd);

    return switch (kind) {
        .put => {
            const kv = try scanner.keyValue();
            return Command{
                .put = .{
                    .key = kv.key,
                    .value = kv.value,
                },
            };
        },
        .get => return Command{ .get = try scanner.keyOnly() },
        .delete => return Command{ .delete = try scanner.keyOnly() },
        .count => {
            try scanner.noArgs();
            return Command.count;
        },
        .help => {
            try scanner.noArgs();
            return Command.help;
        },
        .exit => {
            try scanner.noArgs();
            return Command.exit;
        },
    };
}

const CommandType = enum {
    put,
    get,
    delete,
    count,
    help,
    exit,

    fn fromString(value: []const u8) ParseError!CommandType {
        if (std.mem.eql(u8, value, "put")) return .put;
        if (std.mem.eql(u8, value, "get")) return .get;
        if (std.mem.eql(u8, value, "del")) return .delete;
        if (std.mem.eql(u8, value, "count")) return .count;
        if (std.mem.eql(u8, value, "help")) return .help;
        if (std.mem.eql(u8, value, "exit")) return .exit;

        return error.UnknownCommand;
    }
};

const Scanner = struct {
    rest: []const u8,

    fn next(self: *Scanner) ?[]const u8 {
        self.rest = std.mem.trimStart(u8, self.rest, " \t");

        const end = std.mem.indexOfAny(u8, self.rest, " \t") orelse {
            if (self.rest.len == 0) return null;

            const token = self.rest;
            self.rest = "";
            return token;
        };

        const token = self.rest[0..end];
        self.rest = self.rest[end..];
        return token;
    }

    fn remaining(self: *Scanner) []const u8 {
        return std.mem.trimStart(u8, self.rest, " \t");
    }

    fn noArgs(self: *Scanner) ParseError!void {
        if (self.next() != null) return error.TooManyArguments;
    }

    fn keyOnly(self: *Scanner) ParseError![]const u8 {
        const key = self.next() orelse return error.MissingKey;
        try self.noArgs();
        return key;
    }

    fn keyValue(self: *Scanner) ParseError!struct {
        key: []const u8,
        value: []const u8,
    } {
        const key = self.next() orelse return error.MissingKey;
        const value = self.remaining();
        if (value.len == 0) return error.MissingValue;

        return .{
            .key = key,
            .value = value,
        };
    }
};

test "parse ignores empty lines" {
    try std.testing.expect((try parse("")) == null);
    try std.testing.expect((try parse("   \t\r\n")) == null);
}

test "parse put command" {
    const command = (try parse("put name ashish")).?;

    switch (command) {
        .put => |put| {
            try std.testing.expectEqualStrings("name", put.key);
            try std.testing.expectEqualStrings("ashish", put.value);
        },
        else => try std.testing.expect(false),
    }
}

test "parse put command keeps rest of line as value" {
    const command = (try parse("put greeting hello world")).?;

    switch (command) {
        .put => |put| {
            try std.testing.expectEqualStrings("greeting", put.key);
            try std.testing.expectEqualStrings("hello world", put.value);
        },
        else => try std.testing.expect(false),
    }
}

test "parse get command" {
    const command = (try parse("get name")).?;

    switch (command) {
        .get => |key| try std.testing.expectEqualStrings("name", key),
        else => try std.testing.expect(false),
    }
}

test "parse del command" {
    const command = (try parse("del name")).?;

    switch (command) {
        .delete => |key| try std.testing.expectEqualStrings("name", key),
        else => try std.testing.expect(false),
    }
}

test "parse commands with no args" {
    try std.testing.expectEqual(Command.count, (try parse("count")).?);
    try std.testing.expectEqual(Command.help, (try parse("help")).?);
    try std.testing.expectEqual(Command.exit, (try parse("exit")).?);
    try std.testing.expectEqual(Command.exit, (try parse("quit")).?);
}

test "parse errors" {
    try std.testing.expectError(error.UnknownCommand, parse("unknown"));
    try std.testing.expectError(error.UnknownCommand, parse("delete name"));
    try std.testing.expectError(error.MissingKey, parse("get"));
    try std.testing.expectError(error.MissingKey, parse("del"));
    try std.testing.expectError(error.MissingKey, parse("put"));
    try std.testing.expectError(error.MissingValue, parse("put name"));
    try std.testing.expectError(error.TooManyArguments, parse("get name extra"));
    try std.testing.expectError(error.TooManyArguments, parse("del name extra"));
    try std.testing.expectError(error.TooManyArguments, parse("count extra"));
}
