//! Binary WAL record format.
//!
//! Endianness: little-endian for all u32 fields (lengths, CRC).
//!
//! ## Record frame
//!
//!   [u32 payload_len][record body…][u32 crc32]
//!
//! payload_len = byte length of the record body (not including payload_len or crc32).
//! crc32       = CRC-32 (IEEE / zlib) over the entire record body.
//!
//! ## Record body
//!
//!   [u8 record_type][type-specific data…]
//!
//! record_type: 1 = put, 2 = del, 3 = clear
//!
//! Type-specific data uses length-prefixed blobs: [u32 len][bytes…]
//!   put:   [key][value]
//!   del:   [key]
//!   clear: (body is only the type byte)
//!
//! ## Example: put "hello" "world" (27 bytes)
//!
//!   13 00 00 00                   payload_len = 19
//!   01                            put
//!   05 00 00 00 68 65 6C 6C 6F    key "hello"
//!   05 00 00 00 77 6F 72 6C 64    value "world"
//!   18 09 F0 A4                   crc32(body)

const std = @import("std");

pub const wal_magic = "ZKVL";
pub const snap_magic = "ZKVS";
pub const format_version: u8 = 1;

pub const RecordType = enum(u8) {
    put = 1,
    del = 2,
    clear = 3,
};

pub const Record = union(enum) {
    put: struct { key: []const u8, value: []const u8 },
    del: struct { key: []const u8 },
    clear: struct {},
};

pub const WalError = error{
    BufferTooSmall,
    Truncated,
    InvalidCrc,
    UnknownRecordType,
};

// Primitives
fn writeU32Le(buf: []u8, offset: usize, value: u32) WalError!usize {
    if (offset + 4 > buf.len) return error.BufferTooSmall;
    std.mem.writeInt(u32, buf[offset .. offset + 4], value, .little);
    return offset + 4;
}

fn readU32Le(buf: []const u8, offset: usize) WalError!struct { value: u32, offset: usize } {
    if (offset + 4 > buf.len) return error.Truncated;
    const value = std.mem.readInt(u32, buf[offset .. offset + 4], .little);
    return .{ .value = value, .offset = offset + 4 };
}

fn writeBlob(buf: []u8, offset: usize, data: []const u8) WalError!usize {
    offset = try writeU32Le(buf, offset, @intCast(data.len));
    if (offset + data.len > buf.len) return error.BufferTooSmall;
    @memcpy(buf[offset .. offset + data.len], data);
    return offset + data.len;
}

fn readBlob(buf: []const u8, offset: usize) WalError!struct { value: []const u8, offset: usize } {
    const result = try readU32Le(buf, offset);
    const len: usize = @intCast(result.value);
    const start = result.offset;

    if (start + len > buf.len) return error.Truncated;

    return .{
        .value = buf[start .. start + len],
        .offset = start + len,
    };
}

fn crc32(data: []const u8) u32 {
    return std.hash.Crc32.hash(data);
}

fn encodePutRecord(buf: []u8, key: []const u8, value: []const u8) WalError!usize {
    var offset: usize = 0;

    // reserve payload_len slot
    const payload_len_slot = offset;
    offset += 4;

    // write payload
    const payload_start = offset;

    buf[offset] = @intFromEnum(RecordType.put);
    offset += 1;

    offset = try writeBlob(buf, offset, key);
    offset = try writeBlob(buf, offset, value);

    // backfill payload_len
    const payload_len = offset - payload_start;
    _ = try writeU32Le(buf, payload_len_slot, @intCast(payload_len));

    // crc over payload only
    const checksum = crc32(buf[payload_start..offset]);
    offset = try writeU32Le(buf, offset, checksum);

    return offset;
}

fn encodeDelRecord(buf: []u8, key: []const u8) WalError!usize {
    var offset: usize = 0;

    // reserve payload_len slog
    const payload_len_slot = offset;
    offset += 4;

    // write payload
    const payload_start = offset;

    buf[offset] = @intFromEnum(RecordType.del);
    offset += 1;

    offset = try writeBlob(buf, offset, key);

    // backfill payload_len
    const payload_len = offset - payload_start;
    _ = try writeU32Le(buf, payload_len_slot, @intCast(payload_len));

    // crc over payload only
    const checksum = crc32(buf[payload_start..offset]);
    offset = try writeU32Le(buf, offset, checksum);

    return offset;
}

fn encodeClearRecord(buf: []u8) WalError!usize {
    var offset: usize = 0;

    // reserve payload_len slot
    const payload_len_slot = offset;
    offset += 4;

    // write payload
    const payload_start = offset;

    buf[offset] = @intFromEnum(RecordType.clear);
    offset += 1;

    // backfill payload_len
    const payload_len = offset - payload_start; // always 1;
    _ = try writeU32Le(buf, payload_len_slot, @intCast(payload_len));

    // crc over payload only
    const checksum = crc32(buf[payload_start..offset]);
    offset = try writeU32Le(buf, offset, checksum);

    return offset;
}

pub fn encodeRecord(buf: []u8, record: Record) WalError!usize {
    return switch (record) {
        .put => |p| try encodePutRecord(buf, p.key, p.value),
        .del => |d| try encodeDelRecord(buf, d.key),
        .clear => try encodeClearRecord(buf),
    };
}

pub fn decodeRecord(buf: []const u8) WalError!struct { record: Record, consumed: usize } {
    // minimum record size is 9: payload_len (4), type (1), crc (4)
    if (buf.len < 9) return error.Truncated;

    const result = try readU32Le(buf, 0);
    const payload_len: usize = @intCast(result.value);
    const record_end = 4 + payload_len + 4; // payload_len (4 bytes) + payload (n bytes) + crc (4 bytes)

    // check if the record fits in the buffer
    if (record_end > buf.len) return error.Truncated;

    // get the payload
    const payload = buf[4 .. 4 + payload_len];

    // get the stored crc starting after the payload and verify payload using it
    const stored_crc = std.mem.readInt(u32, buf[4 + payload_len .. record_end], .little);
    if (crc32(payload) != stored_crc) return error.InvalidCrc;

    if (payload_len == 0) return error.Truncated;

    // decode the record type stored as the first byte of the payload
    const record_type = std.meta.intToEnum(RecordType, payload[0]) catch return error.UnknownRecordType;

    const record: Record = switch (record_type) {
        .put => put: {
            const key = try readBlob(payload, 1);
            const val = try readBlob(payload, key.offset);

            // the offset should be the end of the payload after
            // reading the key and value
            if (val.offset != payload.len) return error.Truncated;
            break :put .{ .put = .{ .key = key.value, .value = val.value } };
        },
        .del => del: {
            const key = try readBlob(payload, 1);

            // the offset should be at the end of the payload
            // after reading the key
            if (key.offset != payload.len) return error.Truncated;
            break :del .{ .del = .{ .key = key.value } };
        },
        .clear => clear: {
            if (payload.len != 1) return error.Truncated;
            break :clear .{ .clear = .{} };
        },
    };

    return .{
        .record = record,
        .consumed = record_end,
    };
}

test "writeU32Le encodes little-endian and advances offset" {
    var buf: [8]u8 = undefined;
    const end = try writeU32Le(&buf, 2, 0x01020304);
    try std.testing.expectEqual(@as(usize, 6), end);
    try std.testing.expectEqual(@as(u8, 0x04), buf[2]);
    try std.testing.expectEqual(@as(u8, 0x03), buf[3]);
    try std.testing.expectEqual(@as(u8, 0x02), buf[4]);
    try std.testing.expectEqual(@as(u8, 0x01), buf[5]);
}

test "writeU32Le returns BufferTooSmall when slice too short" {
    var buf: [3]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, writeU32Le(&buf, 0, 1));
}

test "readU32Le decodes little-endian and advances offset" {
    const buf = [_]u8{ 0x2a, 0x00, 0x00, 0x00 };
    const result = try readU32Le(&buf, 0);
    try std.testing.expectEqual(@as(u32, 42), result.value);
    try std.testing.expectEqual(@as(usize, 4), result.offset);
}

test "readU32Le returns Truncated when slice too short" {
    const buf = [_]u8{ 0x01, 0x00 };
    try std.testing.expectError(error.Truncated, readU32Le(&buf, 0));
}

test "writeU32Le and readU32Le round trip" {
    var buf: [8]u8 = undefined;
    const end = try writeU32Le(&buf, 1, 256);
    const result = try readU32Le(buf[0..end], 1);
    try std.testing.expectEqual(@as(u32, 256), result.value);
    try std.testing.expectEqual(@as(usize, 5), result.offset);
}

test "writeBlob writes length prefix and bytes" {
    var buf: [16]u8 = undefined;
    const end = try writeBlob(&buf, 0, "hi");
    try std.testing.expectEqual(@as(usize, 6), end);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 2, 0, 0, 0, 'h', 'i' }, buf[0..6]);
}

test "writeBlob returns BufferTooSmall when data does not fit" {
    var buf: [5]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, writeBlob(&buf, 0, "hello"));
}

test "writeBlob and readBlob round trip" {
    var buf: [16]u8 = undefined;
    const end = try writeBlob(&buf, 0, "hi");
    const result = try readBlob(buf[0..end], 0);
    try std.testing.expectEqualStrings("hi", result.value);
    try std.testing.expectEqual(@as(usize, 6), result.offset);
}

test "writeBlob and readBlob round trip at offset" {
    var buf: [16]u8 = undefined;
    buf[0] = 0xff;
    const end = try writeBlob(&buf, 1, "yo");
    const result = try readBlob(buf[0..end], 1);
    try std.testing.expectEqualStrings("yo", result.value);
    try std.testing.expectEqual(end, result.offset);
}

test "readBlob returns Truncated when length exceeds remaining bytes" {
    const buf = [_]u8{ 10, 0, 0, 0, 'x', 'y' };
    try std.testing.expectError(error.Truncated, readBlob(&buf, 0));
}

fn expectValidRecord(record: []const u8) ![]const u8 {
    const len_result = try readU32Le(record, 0);
    const payload_len: usize = @intCast(len_result.value);
    const record_end = 4 + payload_len + 4;
    try std.testing.expectEqual(record_end, record.len);

    const payload = record[4 .. 4 + payload_len];
    const stored_crc = std.mem.readInt(u32, record[4 + payload_len .. record_end], .little);
    try std.testing.expectEqual(crc32(payload), stored_crc);

    return payload;
}

test "encodePutRecord writes framed put with valid crc" {
    var buf: [64]u8 = undefined;
    const written = try encodePutRecord(&buf, "hi", "yo");
    try std.testing.expectEqual(@as(usize, 21), written);

    const payload = try expectValidRecord(buf[0..written]);
    try std.testing.expectEqual(@as(usize, 13), payload.len);
    try std.testing.expectEqual(@as(u8, @intFromEnum(RecordType.put)), payload[0]);

    const key = try readBlob(payload, 1);
    try std.testing.expectEqualStrings("hi", key.value);

    const val = try readBlob(payload, key.offset);
    try std.testing.expectEqualStrings("yo", val.value);
    try std.testing.expectEqual(payload.len, val.offset);
}

test "encodeDelRecord writes framed del with valid crc" {
    var buf: [64]u8 = undefined;
    const written = try encodeDelRecord(&buf, "hi");
    try std.testing.expectEqual(@as(usize, 15), written);

    const payload = try expectValidRecord(buf[0..written]);
    try std.testing.expectEqual(@as(usize, 7), payload.len);
    try std.testing.expectEqual(@as(u8, @intFromEnum(RecordType.del)), payload[0]);

    const key = try readBlob(payload, 1);
    try std.testing.expectEqualStrings("hi", key.value);
    try std.testing.expectEqual(payload.len, key.offset);
}

test "encodeClearRecord writes framed clear with valid crc" {
    var buf: [64]u8 = undefined;
    const written = try encodeClearRecord(&buf);
    try std.testing.expectEqual(@as(usize, 9), written);

    const payload = try expectValidRecord(buf[0..written]);
    try std.testing.expectEqual(@as(usize, 1), payload.len);
    try std.testing.expectEqual(@as(u8, @intFromEnum(RecordType.clear)), payload[0]);
}

test "encodeRecord dispatches put del and clear" {
    var buf: [64]u8 = undefined;

    const put_written = try encodeRecord(&buf, .{ .put = .{ .key = "a", .value = "b" } });
    const put_payload = try expectValidRecord(buf[0..put_written]);
    try std.testing.expectEqual(@as(u8, @intFromEnum(RecordType.put)), put_payload[0]);

    const del_written = try encodeRecord(&buf, .{ .del = .{ .key = "a" } });
    const del_payload = try expectValidRecord(buf[0..del_written]);
    try std.testing.expectEqual(@as(u8, @intFromEnum(RecordType.del)), del_payload[0]);

    const clear_written = try encodeRecord(&buf, .{ .clear = .{} });
    const clear_payload = try expectValidRecord(buf[0..clear_written]);
    try std.testing.expectEqual(@as(u8, @intFromEnum(RecordType.clear)), clear_payload[0]);
}

test "decodeRecord round trips put" {
    var buf: [64]u8 = undefined;
    const written = try encodeRecord(&buf, .{ .put = .{ .key = "hi", .value = "yo" } });

    const decoded = try decodeRecord(buf[0..written]);
    try std.testing.expectEqual(written, decoded.consumed);
    try std.testing.expectEqualStrings("hi", decoded.record.put.key);
    try std.testing.expectEqualStrings("yo", decoded.record.put.value);
}

test "decodeRecord round trips del" {
    var buf: [64]u8 = undefined;
    const written = try encodeRecord(&buf, .{ .del = .{ .key = "hi" } });

    const decoded = try decodeRecord(buf[0..written]);
    try std.testing.expectEqual(written, decoded.consumed);
    try std.testing.expectEqualStrings("hi", decoded.record.del.key);
}

test "decodeRecord round trips clear" {
    var buf: [64]u8 = undefined;
    const written = try encodeRecord(&buf, .{ .clear = .{} });

    const decoded = try decodeRecord(buf[0..written]);
    try std.testing.expectEqual(written, decoded.consumed);
    try std.testing.expect(decoded.record == .clear);
}

test "decodeRecord advances through consecutive records" {
    var buf: [128]u8 = undefined;
    var offset: usize = 0;

    offset += try encodeRecord(buf[offset..], .{ .put = .{ .key = "a", .value = "1" } });
    offset += try encodeRecord(buf[offset..], .{ .del = .{ .key = "a" } });
    offset += try encodeRecord(buf[offset..], .{ .clear = .{} });

    var pos: usize = 0;

    const first = try decodeRecord(buf[pos..offset]);
    pos += first.consumed;
    try std.testing.expectEqualStrings("a", first.record.put.key);
    try std.testing.expectEqualStrings("1", first.record.put.value);

    const second = try decodeRecord(buf[pos..offset]);
    pos += second.consumed;
    try std.testing.expectEqualStrings("a", second.record.del.key);

    const third = try decodeRecord(buf[pos..offset]);
    pos += third.consumed;
    try std.testing.expect(third.record == .clear);
    try std.testing.expectEqual(offset, pos);
}

test "decodeRecord returns Truncated when buffer shorter than minimum record" {
    const buf = [_]u8{ 1, 0, 0, 0, 1, 0, 0, 0 };
    try std.testing.expectError(error.Truncated, decodeRecord(&buf));
}

test "decodeRecord returns Truncated when payload_len exceeds buffer" {
    var buf: [64]u8 = undefined;
    const written = try encodePutRecord(&buf, "hi", "yo");
    buf[0] = 0xff;
    try std.testing.expectError(error.Truncated, decodeRecord(buf[0..written]));
}

test "decodeRecord returns Truncated when record is cut off" {
    var buf: [64]u8 = undefined;
    const written = try encodePutRecord(&buf, "hi", "yo");
    try std.testing.expectError(error.Truncated, decodeRecord(buf[0 .. written - 1]));
}

test "decodeRecord returns InvalidCrc when checksum is wrong" {
    var buf: [64]u8 = undefined;
    const written = try encodePutRecord(&buf, "hi", "yo");
    buf[written - 1] +%= 1;
    try std.testing.expectError(error.InvalidCrc, decodeRecord(buf[0..written]));
}

test "decodeRecord returns UnknownRecordType for invalid type byte" {
    var buf: [64]u8 = undefined;
    const written = try encodeClearRecord(&buf);
    buf[4] = 99;
    _ = try writeU32Le(&buf, 5, crc32(buf[4..5]));
    try std.testing.expectError(error.UnknownRecordType, decodeRecord(buf[0..written]));
}

test "decodeRecord returns Truncated when clear payload has extra bytes" {
    var buf: [64]u8 = undefined;
    const written = try encodeClearRecord(&buf);
    _ = try writeU32Le(&buf, 0, 2);
    _ = try writeU32Le(&buf, 6, crc32(buf[4..6]));
    try std.testing.expectError(error.Truncated, decodeRecord(buf[0..written]));
}
