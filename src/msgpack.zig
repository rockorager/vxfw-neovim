const std = @import("std");

const assert = std.debug.assert;
const maxInt = std.math.maxInt;
const minInt = std.math.minInt;

/// A msgpack value
pub const Value = union(enum) {
    i64: i64,
    u64: u64,
    f64: f64,
    nil: void,
    bool: bool,
    str: []const u8,
    bin: []const u8,
    array: []Value,
    map: std.StringHashMap(Value),
    ext: struct {
        id: i8,
        data: []const u8,
    },

    /// Free resources associated with the value
    pub fn deinit(self: Value, allocator: std.mem.Allocator) void {
        switch (self) {
            .i64, .u64, .f64, .nil, .bool => return,
            .str => allocator.free(self.str),
            .bin => allocator.free(self.str),
            .array => {
                for (self.array) |value| {
                    value.deinit(allocator);
                }
                allocator.free(self.array);
            },
            .map => |*map| {
                var iter = map.iterator();
                while (iter.next()) |kv| {
                    allocator.free(kv.key_ptr.*);
                    kv.value_ptr.deinit(allocator);
                }
                const map_ptr = @constCast(map);
                map_ptr.deinit();
            },
            .ext => allocator.free(self.ext.data),
        }
    }

    pub fn format(
        value: Value,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        switch (value) {
            .i64 => try writer.print("{d}", .{value.i64}),
            .u64 => try writer.print("{d}", .{value.u64}),
            .f64 => try writer.print("{d}", .{value.f64}),
            .nil => try writer.writeAll("null"),
            .bool => try writer.print("{}", .{value.bool}),
            .str => try writer.print("\"{s}\"", .{value.str}),
            .bin => try writer.print("{any}", .{value.bin}),
            .array => {
                try writer.writeAll("[");
                for (value.array, 0..) |v, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try v.format(fmt, options, writer);
                }
                try writer.writeAll("]");
            },
            .map => {
                var iter = value.map.iterator();
                try writer.writeAll("\n{");
                while (iter.next()) |kv| {
                    try writer.print("{s}: {}, ", .{ kv.key_ptr.*, kv.value_ptr.* });
                }
                try writer.writeAll("}");
            },
            .ext => |ext| try writer.print("{}", .{ext}),
        }
    }
};

pub const PackOptions = struct {};

/// Encode a type as a msgpack message
pub fn pack(writer: std.io.AnyWriter, value: anytype, opts: PackOptions) anyerror!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .int, .comptime_int => {
            if (value > maxInt(u64) or value < minInt(i64)) return error.Overflow;
            // We use an i65 so we can get all of u64
            const int: i65 = value;
            switch (int) {
                minInt(i65)...minInt(i64) - 1 => unreachable,
                minInt(i64)...minInt(i32) - 1 => return packInt64(writer, @intCast(int)),
                minInt(i32)...minInt(i16) - 1 => return packInt32(writer, @intCast(int)),
                minInt(i16)...minInt(i8) - 1 => return packInt16(writer, @intCast(int)),
                minInt(i8)...-33 => return packInt8(writer, @intCast(int)),
                -32...-1 => return packNegativeFixInt(writer, @intCast(int)),
                0...maxInt(u7) => return packPositiveFixInt(writer, @intCast(int)),
                maxInt(u7) + 1...maxInt(u8) => return packUInt8(writer, @intCast(int)),
                maxInt(u8) + 1...maxInt(u16) => return packUint16(writer, @intCast(int)),
                maxInt(u16) + 1...maxInt(u32) => return packUint32(writer, @intCast(int)),
                maxInt(u32) + 1...maxInt(u64) => return packUint64(writer, @intCast(int)),
            }
        },
        .float, .comptime_float => {
            if (@as(f32, @floatCast(value)) == value) {
                const val: f32 = @floatCast(value);
                return packFloat32(writer, @bitCast(val));
            } else {
                const val: f64 = @floatCast(value);
                return packFloat64(writer, @bitCast(val));
            }
        },
        .bool => return packBool(writer, value),
        .null => return packNil(writer),
        .optional => {
            if (value) |val|
                return pack(writer, val, opts)
            else
                return packNil(writer);
        },
        .@"enum", .enum_literal => {
            if (std.meta.hasFn(T, "msgpackPack")) {
                return value.msgpackPack(writer);
            }
            return packString(writer, @tagName(value));
        },
        .@"union" => {
            if (std.meta.hasFn(T, "msgpackPack")) {
                return value.msgpackPack(writer);
            }
            const info = @typeInfo(T).@"union";
            const UnionTagType = info.tag_type orelse @compileError("Unable to pack untagged union '" ++ @typeName(T) ++ "'");
            inline for (info.fields) |u_field| {
                if (value == @field(UnionTagType, u_field.name)) {
                    // If our field a void field, we handle it differently since the default
                    // struct packing doesn't write void fields
                    if (u_field.type == void) {
                        // Map of length 1
                        try writer.writeByte(0b1000_0001);
                        // One key of field name
                        try packString(writer, u_field.name);
                        // Type is nil
                        try packNil(writer);
                        return;
                    }
                    // Create a struct with one field which is the name of the union field
                    const Struct = @Type(.{ .@"struct" = .{
                        .layout = .auto,
                        .fields = &[_]std.builtin.Type.StructField{
                            .{
                                .name = u_field.name,
                                .type = u_field.type,
                                .is_comptime = false,
                                .alignment = @alignOf(u_field.type),
                                .default_value = null,
                            },
                        },
                        .decls = &[_]std.builtin.Type.Declaration{},
                        .is_tuple = false,
                    } });
                    var val: Struct = undefined;
                    // Set the field of our val to this value
                    @field(val, u_field.name) = @field(value, u_field.name);
                    return pack(writer, val, opts);
                }
            }
        },
        .@"struct" => |S| {
            if (std.meta.hasFn(T, "msgpackPack")) {
                return value.msgpackPack(writer);
            }
            // count the non-void fields
            const n = blk: {
                var n: usize = 0;
                inline for (S.fields) |Field| {
                    // don't include void fields
                    if (Field.type == void) continue;
                    n += 1;
                }
                break :blk n;
            };
            switch (n) {
                0...maxInt(u4) => {
                    const prefix: u8 = if (S.is_tuple) 0b1001_0000 else 0b1000_0000;
                    const b: u8 = prefix | @as(u8, @intCast(n));
                    try writer.writeByte(b);
                },
                maxInt(u4) + 1...maxInt(u16) => {
                    try writer.writeByte(if (S.is_tuple) 0xdc else 0xde);
                    var buf: [2]u8 = undefined;
                    std.mem.writeInt(u16, &buf, @intCast(n), .big);
                    try writer.writeAll(&buf);
                },
                maxInt(u16) + 1...maxInt(u32) => {
                    try writer.writeByte(if (S.is_tuple) 0xdd else 0xdf);
                    var buf: [4]u8 = undefined;
                    std.mem.writeInt(u32, &buf, @intCast(n), .big);
                    try writer.writeAll(&buf);
                },
                else => return error.Overflow,
            }
            inline for (S.fields) |Field| {
                // don't include void fields
                if (Field.type == void) continue;

                if (!S.is_tuple) {
                    try packString(writer, Field.name);
                }
                try pack(writer, @field(value, Field.name), opts);
            }
        },
        .pointer => |ptr_info| switch (ptr_info.size) {
            .One => switch (@typeInfo(ptr_info.child)) {
                .array => {
                    // Coerce `*[N]T` to `[]const T`.
                    const Slice = []const std.meta.Elem(ptr_info.child);
                    return pack(writer, @as(Slice, value), opts);
                },
                else => {
                    return pack(writer, value.*, opts);
                },
            },
            .Many, .Slice => {
                if (ptr_info.size == .Many and ptr_info.sentinel == null)
                    @compileError("unable to pack type '" ++ @typeName(T) ++ "' without sentinel");
                const slice = if (ptr_info.size == .Many) std.mem.span(value) else value;

                if (ptr_info.child == u8) {
                    // This is a []const u8, or some similar Zig string.
                    return packString(writer, slice);
                }

                switch (slice.len) {
                    0...maxInt(u4) => {
                        const b: u8 = 0b1001_0000 | @as(u8, @intCast(slice.len));
                        try writer.writeByte(b);
                    },
                    maxInt(u4) + 1...maxInt(u16) => {
                        try writer.writeByte(0xdc);
                        var buf: [2]u8 = undefined;
                        std.mem.writeInt(u16, &buf, @intCast(slice.len), .big);
                        try writer.writeAll(&buf);
                    },
                    maxInt(u16) + 1...maxInt(u32) => {
                        try writer.writeByte(0xdd);
                        var buf: [4]u8 = undefined;
                        std.mem.writeInt(u32, &buf, @intCast(slice.len), .big);
                        try writer.writeAll(&buf);
                    },
                    else => return error.Overflow,
                }
                for (slice) |x| {
                    try pack(writer, x, opts);
                }
                return;
            },
            else => @compileError("Unable to pack type '" ++ @typeName(T) ++ "'"),
        },
        .array => {
            // Coerce `[N]T` to `*const [N]T` (and then to `[]const T`).
            return pack(writer, &value, opts);
        },
        .vector => |info| {
            const array: [info.len]info.child = value;
            return pack(writer, &array, opts);
        },
        else => @compileError("Unable to pack type '" ++ @typeName(T) ++ "'"),
    }
}

inline fn packNil(writer: std.io.AnyWriter) anyerror!void {
    return writer.writeByte(0xc0);
}

inline fn packBool(writer: std.io.AnyWriter, value: bool) anyerror!void {
    const b: u8 = if (value) 0xc3 else 0xc2;
    return writer.writeByte(b);
}

inline fn packPositiveFixInt(writer: std.io.AnyWriter, value: u7) anyerror!void {
    return writer.writeByte(value);
}

inline fn packNegativeFixInt(writer: std.io.AnyWriter, value: i8) anyerror!void {
    assert(value >= -32);
    assert(value < 0);
    return writer.writeByte(@bitCast(value));
}

inline fn packInt8(writer: std.io.AnyWriter, value: i8) anyerror!void {
    return writer.writeAll(&.{ 0xd0, @bitCast(value) });
}

inline fn packInt16(writer: std.io.AnyWriter, value: i16) anyerror!void {
    var buf: [3]u8 = undefined;
    buf[0] = 0xd1;
    std.mem.writeInt(i16, buf[1..], value, .big);
    return writer.writeAll(&buf);
}

inline fn packInt32(writer: std.io.AnyWriter, value: i32) anyerror!void {
    var buf: [5]u8 = undefined;
    buf[0] = 0xd2;
    std.mem.writeInt(i32, buf[1..], value, .big);
    return writer.writeAll(&buf);
}

inline fn packInt64(writer: std.io.AnyWriter, value: i64) anyerror!void {
    var buf: [9]u8 = undefined;
    buf[0] = 0xd3;
    std.mem.writeInt(i64, buf[1..], value, .big);
    return writer.writeAll(&buf);
}

inline fn packUInt8(writer: std.io.AnyWriter, value: u8) anyerror!void {
    return writer.writeAll(&.{ 0xcc, value });
}

inline fn packUint16(writer: std.io.AnyWriter, value: u16) anyerror!void {
    var buf: [3]u8 = undefined;
    buf[0] = 0xcd;
    std.mem.writeInt(u16, buf[1..], value, .big);
    return writer.writeAll(&buf);
}

inline fn packUint32(writer: std.io.AnyWriter, value: u32) anyerror!void {
    var buf: [5]u8 = undefined;
    buf[0] = 0xce;
    std.mem.writeInt(u32, buf[1..], value, .big);
    return writer.writeAll(&buf);
}

inline fn packUint64(writer: std.io.AnyWriter, value: u64) anyerror!void {
    var buf: [9]u8 = undefined;
    buf[0] = 0xcf;
    std.mem.writeInt(u64, buf[1..], value, .big);
    return writer.writeAll(&buf);
}

inline fn packFloat32(writer: std.io.AnyWriter, value: u32) anyerror!void {
    var buf: [5]u8 = undefined;
    buf[0] = 0xca;
    std.mem.writeInt(u32, buf[1..], value, .big);
    return writer.writeAll(&buf);
}

inline fn packFloat64(writer: std.io.AnyWriter, value: u64) anyerror!void {
    var buf: [9]u8 = undefined;
    buf[0] = 0xcb;
    std.mem.writeInt(u64, buf[1..], value, .big);
    return writer.writeAll(&buf);
}

fn packString(writer: std.io.AnyWriter, value: []const u8) anyerror!void {
    switch (value.len) {
        0...31 => {
            const prefix: u8 = 0b1010_0000 | @as(u8, @intCast(value.len));
            try writer.writeByte(prefix);
        },
        32...maxInt(u8) => {
            try writer.writeByte(0xd9);
            try writer.writeByte(@intCast(value.len));
        },
        maxInt(u8) + 1...maxInt(u16) => {
            try writer.writeByte(0xda);
            var buf: [2]u8 = undefined;
            std.mem.writeInt(u16, &buf, @intCast(value.len), .big);
            try writer.writeAll(&buf);
        },
        maxInt(u16) + 1...maxInt(u32) => {
            try writer.writeByte(0xda);
            var buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &buf, @intCast(value.len), .big);
            try writer.writeAll(&buf);
        },
        else => return error.Overflow,
    }
    return writer.writeAll(value);
}

pub fn unpack(comptime T: type, allocator: std.mem.Allocator, reader: std.io.AnyReader) anyerror!T {
    if (std.meta.hasFn(T, "msgpackUnpack")) {
        return T.msgpackUnpack(reader);
    }
    switch (@typeInfo(@TypeOf(T))) {
        .Bool, .Int, .Float, .Null, .Optional => {
            const value = try unpackValue(allocator, reader);
            return unpackFromValue(T, value);
        },
        .Enum, .EnumLiteral => {
            if (std.meta.hasFn(T, "msgpackUnpack")) {
                return T.msgpackUnpack(reader);
            }
            const value = try unpackValue(allocator, reader);
            return unpackFromValue(T, value);
        },
        .Union => {
            if (std.meta.hasFn(T, "msgpackUnpack")) {
                return T.msgpackUnpack(reader);
            }
            const value = try unpackValue(allocator, reader);
            return unpackFromValue(T, value);
        },
        .Struct => {
            if (std.meta.hasFn(T, "msgpackUnpack")) {
                return T.msgpackUnpack(reader);
            }
            const value = try unpackValue(allocator, reader);
            return unpackFromValue(T, value);
        },
        .Pointer => |ptr_info| switch (ptr_info.size) {
            .One => switch (@typeInfo(ptr_info.child)) {
                .Array => {
                    // Coerce `*[N]T` to `[]const T`.
                    const Slice = []const std.meta.Elem(ptr_info.child);
                    return unpack(Slice, allocator, reader);
                },
                else => {
                    @compileError("Unable to unpack type '" ++ @typeName(T) ++ "'");
                },
            },
            .Many, .Slice => @compileError("Unable to unpack type '" ++ @typeName(T) ++ "'"),
            else => @compileError("Unable to unpack type '" ++ @typeName(T) ++ "'"),
        },
        .Array => @compileError("Unable to unpack type '" ++ @typeName(T) ++ "'"),
        .Vector => @compileError("Unable to unpack type '" ++ @typeName(T) ++ "'"),
        else => @compileError("Unable to unpack type '" ++ @typeName(T) ++ "'"),
    }
}

pub fn unpackFromValue(comptime T: type, value: Value) anyerror!T {
    switch (@typeInfo(T)) {
        .bool => {
            switch (value) {
                .bool => return value.bool,
                else => return error.UnexpectedToken,
            }
        },
        .int => |Int| {
            switch (value) {
                .i64 => |val| {
                    if (val < 0 and Int.signedness == .unsigned) {
                        return error.Overflow;
                    }
                    if (val < minInt(T) or val > maxInt(T)) {
                        return error.Overflow;
                    }
                    return @intCast(val);
                },
                .u64 => |val| {
                    if (val > maxInt(T)) {
                        return error.Overflow;
                    }
                    return @intCast(val);
                },
                else => return error.UnexpectedToken,
            }
        },
        .float => {
            switch (value) {
                .f64 => |val| return @floatCast(val),
                else => return error.UnexpectedToken,
            }
        },
        .null => {
            switch (value) {
                .nil => return null,
                else => return error.UnexpectedToken,
            }
        },
        .optional => |Optional| {
            switch (value) {
                .nil => return null,
                else => return unpackFromValue(Optional.child, value),
            }
        },
        .@"enum", .enum_literal => {
            if (std.meta.hasFn(T, "msgpackUnpackFromValue")) {
                return T.msgpackUnpackFromValue(value);
            }
            @compileError("Unable to unpack type '" ++ @typeName(T) ++ "'");
        },
        .@"union" => {
            if (std.meta.hasFn(T, "msgpackUnpackFromValue")) {
                return T.msgpackUnpackFromValue(value);
            }
            @compileError("Unable to unpack type '" ++ @typeName(T) ++ "'");
        },
        .type => {
            if (std.meta.hasFn(T, "msgpackUnpackFromValue")) {
                return T.msgpackUnpackFromValue(value);
            }
            @compileError("Unable to unpack type '" ++ @typeName(T) ++ "'");
        },
        .@"struct" => {
            if (std.meta.hasFn(T, "msgpackUnpackFromValue")) {
                return T.msgpackUnpackFromValue(value);
            }
            @compileError("Unable to unpack type '" ++ @typeName(T) ++ "'");
        },
        .pointer => |ptr_info| switch (ptr_info.size) {
            .One => switch (@typeInfo(ptr_info.child)) {
                .Array => {
                    // Coerce `*[N]T` to `[]const T`.
                    // const Slice = []const std.meta.Elem(ptr_info.child);
                    // return unpack(Slice, allocator, reader);
                },
                else => {
                    @compileError("Unable to unpack type '" ++ @typeName(T) ++ "'");
                },
            },
            .Many, .Slice => @compileError("Unable to unpack type '" ++ @typeName(T) ++ "'"),
            else => @compileError("Unable to unpack type '" ++ @typeName(T) ++ "'"),
        },
        .array => @compileError("Unable to unpack type '" ++ @typeName(T) ++ "'"),
        .vector => @compileError("Unable to unpack type '" ++ @typeName(T) ++ "'"),
        else => @compileError("Unable to unpack type '" ++ @typeName(T) ++ "'"),
    }
}

pub fn unpackValue(allocator: std.mem.Allocator, reader: std.io.AnyReader) anyerror!Value {
    const b = try reader.readByte();
    switch (b) {
        0x00...0x7F => return .{ .u64 = b }, // positive fixint
        0x80...0x8F => { // fixmap
            const n: u8 = b & 0b0000_1111;
            var map = std.StringHashMap(Value).init(allocator);
            try map.ensureTotalCapacity(n);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                // Read a key, then a value. We require our keys to be strings
                const k = try unpackValue(allocator, reader);
                if (k != .str) return error.InvalidKey;
                const v = try unpackValue(allocator, reader);
                map.put(k.str, v) catch unreachable;
            }
            return .{ .map = map };
        },
        0x90...0x9F => { // fixarray
            const n: u8 = b & 0b0000_1111;
            const values = try allocator.alloc(Value, n);
            for (values) |*value| {
                value.* = try unpackValue(allocator, reader);
            }
            return .{ .array = values };
        },
        0xA0...0xBF => { // fixstr
            const len: usize = b & 0b0001_1111;
            return .{ .str = try unpackBytes(allocator, reader, len) };
        },
        0xC0 => return .nil, // nil
        0xC1 => unreachable, // unused
        0xC2 => return .{ .bool = false }, // false
        0xC3 => return .{ .bool = true }, // true
        0xC4 => { // bin8
            const len = try reader.readByte();
            return .{ .bin = try unpackBytes(allocator, reader, len) };
        },
        0xC5 => { // bin16
            const len = try unpackInt(u16, reader);
            return .{ .bin = try unpackBytes(allocator, reader, len) };
        },
        0xC6 => { // bin32
            const len = try unpackInt(u32, reader);
            return .{ .bin = try unpackBytes(allocator, reader, len) };
        },
        0xC7 => { // ext8
            const len = try unpackInt(u8, reader);
            const _type = try unpackInt(i8, reader);
            return .{ .ext = .{
                .id = _type,
                .data = try unpackBytes(allocator, reader, len),
            } };
        },
        0xC8 => { // ext16
            const len = try unpackInt(u16, reader);
            const _type = try unpackInt(i8, reader);
            return .{ .ext = .{
                .id = _type,
                .data = try unpackBytes(allocator, reader, len),
            } };
        },
        0xC9 => { // ext32
            const len = try unpackInt(u32, reader);
            const _type = try unpackInt(i8, reader);
            return .{ .ext = .{
                .id = _type,
                .data = try unpackBytes(allocator, reader, len),
            } };
        },
        0xCA => { // float32
            const uint = try unpackInt(u32, reader);
            const val: f32 = @bitCast(uint);
            return .{ .f64 = @floatCast(val) };
        },
        0xCB => { // float64
            const uint = try unpackInt(u64, reader);
            const val: f64 = @bitCast(uint);
            return .{ .f64 = val };
        }, // float64
        0xCC => { // u8
            return .{ .u64 = try reader.readByte() };
        },
        0xCD => { // u16
            return .{ .u64 = try unpackInt(u16, reader) };
        },
        0xCE => { // u32
            return .{ .u64 = try unpackInt(u32, reader) };
        },
        0xCF => { // u64
            return .{ .u64 = try unpackInt(u64, reader) };
        },
        0xD0 => { // i8
            return .{ .i64 = try unpackInt(i8, reader) };
        },
        0xD1 => { // i16
            return .{ .i64 = try unpackInt(i16, reader) };
        },
        0xD2 => { // i32
            return .{ .i64 = try unpackInt(i32, reader) };
        },
        0xD3 => { // i64
            return .{ .i64 = try unpackInt(i64, reader) };
        },
        0xD4 => { // fixext1
            return .{ .ext = .{
                .id = try unpackInt(i8, reader),
                .data = try unpackBytes(allocator, reader, 1),
            } };
        },
        0xD5 => { // fixext2
            return .{ .ext = .{
                .id = try unpackInt(i8, reader),
                .data = try unpackBytes(allocator, reader, 2),
            } };
        },
        0xD6 => { // fixext4
            return .{ .ext = .{
                .id = try unpackInt(i8, reader),
                .data = try unpackBytes(allocator, reader, 4),
            } };
        },
        0xD7 => { // fixext8
            return .{ .ext = .{
                .id = try unpackInt(i8, reader),
                .data = try unpackBytes(allocator, reader, 8),
            } };
        },
        0xD8 => { // fixext16
            return .{ .ext = .{
                .id = try unpackInt(i8, reader),
                .data = try unpackBytes(allocator, reader, 16),
            } };
        },
        0xD9 => { // str8
            const len = try reader.readByte();
            return .{ .str = try unpackBytes(allocator, reader, len) };
        },
        0xDA => { // str16
            const len = try unpackInt(u16, reader);
            return .{ .str = try unpackBytes(allocator, reader, len) };
        },
        0xDB => { // str32
            const len = try unpackInt(u32, reader);
            return .{ .str = try unpackBytes(allocator, reader, len) };
        },
        0xDC => { // array16
            const n = try unpackInt(u16, reader);
            const values = try allocator.alloc(Value, n);
            for (values) |*value| {
                value.* = try unpackValue(allocator, reader);
            }
            return .{ .array = values };
        },
        0xDD => { // array32
            const n = try unpackInt(u32, reader);
            const values = try allocator.alloc(Value, n);
            for (values) |*value| {
                value.* = try unpackValue(allocator, reader);
            }
            return .{ .array = values };
        },
        0xDE => { // map16
            const n = try unpackInt(u16, reader);
            var map = std.StringHashMap(Value).init(allocator);
            try map.ensureTotalCapacity(n);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                // Read a key, then a value. We require our keys to be strings
                const k = try unpackValue(allocator, reader);
                if (k != .str) return error.InvalidKey;
                const v = try unpackValue(allocator, reader);
                map.put(k.str, v) catch unreachable;
            }
            return .{ .map = map };
        },
        0xDF => { // map32
            const n = try unpackInt(u32, reader);
            var map = std.StringHashMap(Value).init(allocator);
            try map.ensureTotalCapacity(n);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                // Read a key, then a value. We require our keys to be strings
                const k = try unpackValue(allocator, reader);
                if (k != .str) return error.InvalidKey;
                const v = try unpackValue(allocator, reader);
                map.put(k.str, v) catch unreachable;
            }
            return .{ .map = map };
        },
        0xE0...0xFF => { // negative fixint
            const int: i8 = @bitCast(b);
            return .{ .i64 = int };
        },
    }
}

fn unpackInt(comptime T: type, reader: std.io.AnyReader) anyerror!T {
    const len = @divExact(@typeInfo(T).int.bits, 8);
    var buf: [len]u8 = undefined;
    const n = try reader.readAtLeast(&buf, len);
    if (n != len) return error.LengthMismatch;
    return std.mem.readInt(T, &buf, .big);
}

fn unpackBytes(allocator: std.mem.Allocator, reader: std.io.AnyReader, len: usize) anyerror![]const u8 {
    const slice = try allocator.alloc(u8, len);
    const n = try reader.readAtLeast(slice, len);
    if (n != len) return error.LengthMismatch;
    return slice;
}

test "pack and unpack negative integers" {
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();

    {
        defer list.clearRetainingCapacity();
        const value: i8 = -1;
        try pack(list.writer().any(), value, .{});
        try std.testing.expectEqualSlices(u8, &.{@bitCast(value)}, list.items);

        var fbs = std.io.fixedBufferStream(list.items);
        const rt_val = try unpackValue(std.testing.allocator, fbs.reader().any());
        try std.testing.expect(rt_val == .i64);
        try std.testing.expectEqual(value, rt_val.i64);
    }
    {
        defer list.clearRetainingCapacity();
        const value: i8 = -32;
        try pack(list.writer().any(), value, .{});
        try std.testing.expectEqualSlices(u8, &.{@bitCast(value)}, list.items);

        var fbs = std.io.fixedBufferStream(list.items);
        const rt_val = try unpackValue(std.testing.allocator, fbs.reader().any());
        try std.testing.expect(rt_val == .i64);
        try std.testing.expectEqual(value, rt_val.i64);
    }
    {
        defer list.clearRetainingCapacity();
        try pack(list.writer().any(), -33, .{});
        var expected: [2]u8 = undefined;
        expected[0] = 0xd0;
        std.mem.writeInt(i8, expected[1..], -33, .big);
        try std.testing.expectEqualSlices(u8, &expected, list.items);

        var fbs = std.io.fixedBufferStream(list.items);
        const rt_val = try unpackValue(std.testing.allocator, fbs.reader().any());
        try std.testing.expect(rt_val == .i64);
        try std.testing.expectEqual(-33, rt_val.i64);
    }
    {
        defer list.clearRetainingCapacity();
        const value = -128;
        try pack(list.writer().any(), value, .{});
        var expected: [2]u8 = undefined;
        expected[0] = 0xd0;
        std.mem.writeInt(i8, expected[1..], value, .big);
        try std.testing.expectEqualSlices(u8, &expected, list.items);

        var fbs = std.io.fixedBufferStream(list.items);
        const rt_val = try unpackValue(std.testing.allocator, fbs.reader().any());
        try std.testing.expect(rt_val == .i64);
        try std.testing.expectEqual(value, rt_val.i64);
    }
    {
        defer list.clearRetainingCapacity();
        const value = -129;
        try pack(list.writer().any(), value, .{});
        var expected: [3]u8 = undefined;
        expected[0] = 0xd1;
        std.mem.writeInt(i16, expected[1..], value, .big);
        try std.testing.expectEqualSlices(u8, &expected, list.items);

        var fbs = std.io.fixedBufferStream(list.items);
        const rt_val = try unpackValue(std.testing.allocator, fbs.reader().any());
        try std.testing.expect(rt_val == .i64);
        try std.testing.expectEqual(value, rt_val.i64);
    }
    {
        defer list.clearRetainingCapacity();
        const value = -32768;
        try pack(list.writer().any(), value, .{});
        var expected: [3]u8 = undefined;
        expected[0] = 0xd1;
        std.mem.writeInt(i16, expected[1..], value, .big);
        try std.testing.expectEqualSlices(u8, &expected, list.items);

        var fbs = std.io.fixedBufferStream(list.items);
        const rt_val = try unpackValue(std.testing.allocator, fbs.reader().any());
        try std.testing.expect(rt_val == .i64);
        try std.testing.expectEqual(value, rt_val.i64);
    }
    {
        defer list.clearRetainingCapacity();
        const value = -32769;
        try pack(list.writer().any(), value, .{});
        var expected: [5]u8 = undefined;
        expected[0] = 0xd2;
        std.mem.writeInt(i32, expected[1..], value, .big);
        try std.testing.expectEqualSlices(u8, &expected, list.items);

        var fbs = std.io.fixedBufferStream(list.items);
        const rt_val = try unpackValue(std.testing.allocator, fbs.reader().any());
        try std.testing.expect(rt_val == .i64);
        try std.testing.expectEqual(value, rt_val.i64);
    }
    {
        defer list.clearRetainingCapacity();
        const value = -0x80000000;
        try pack(list.writer().any(), value, .{});
        var expected: [5]u8 = undefined;
        expected[0] = 0xd2;
        std.mem.writeInt(i32, expected[1..], value, .big);
        try std.testing.expectEqualSlices(u8, &expected, list.items);

        var fbs = std.io.fixedBufferStream(list.items);
        const rt_val = try unpackValue(std.testing.allocator, fbs.reader().any());
        try std.testing.expect(rt_val == .i64);
        try std.testing.expectEqual(value, rt_val.i64);
    }
    {
        defer list.clearRetainingCapacity();
        const value = -0x80000001;
        try pack(list.writer().any(), value, .{});
        var expected: [9]u8 = undefined;
        expected[0] = 0xd3;
        std.mem.writeInt(i64, expected[1..], value, .big);
        try std.testing.expectEqualSlices(u8, &expected, list.items);

        var fbs = std.io.fixedBufferStream(list.items);
        const rt_val = try unpackValue(std.testing.allocator, fbs.reader().any());
        try std.testing.expect(rt_val == .i64);
        try std.testing.expectEqual(value, rt_val.i64);
    }
}

test "pack and unpack positive integers" {
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();

    {
        defer list.clearRetainingCapacity();
        try pack(list.writer().any(), 0, .{});
        try std.testing.expectEqualSlices(u8, &.{0x00}, list.items);

        var fbs = std.io.fixedBufferStream(list.items);
        const rt_val = try unpackValue(std.testing.allocator, fbs.reader().any());
        try std.testing.expect(rt_val == .u64);
        try std.testing.expectEqual(0, rt_val.u64);
    }
    {
        defer list.clearRetainingCapacity();
        try pack(list.writer().any(), 0x7F, .{});
        try std.testing.expectEqualSlices(u8, &.{0x7F}, list.items);

        var fbs = std.io.fixedBufferStream(list.items);
        const rt_val = try unpackValue(std.testing.allocator, fbs.reader().any());
        try std.testing.expect(rt_val == .u64);
        try std.testing.expectEqual(0x7F, rt_val.u64);
    }
    {
        defer list.clearRetainingCapacity();
        const value = 0x80;
        try pack(list.writer().any(), value, .{});
        var expected: [2]u8 = undefined;
        expected[0] = 0xcc;
        std.mem.writeInt(u8, expected[1..], value, .big);
        try std.testing.expectEqualSlices(u8, &expected, list.items);

        var fbs = std.io.fixedBufferStream(list.items);
        const rt_val = try unpackValue(std.testing.allocator, fbs.reader().any());
        try std.testing.expect(rt_val == .u64);
        try std.testing.expectEqual(value, rt_val.u64);
    }
    {
        defer list.clearRetainingCapacity();
        const value = 0xFF;
        try pack(list.writer().any(), value, .{});
        var expected: [2]u8 = undefined;
        expected[0] = 0xcc;
        std.mem.writeInt(u8, expected[1..], value, .big);
        try std.testing.expectEqualSlices(u8, &expected, list.items);

        var fbs = std.io.fixedBufferStream(list.items);
        const rt_val = try unpackValue(std.testing.allocator, fbs.reader().any());
        try std.testing.expect(rt_val == .u64);
        try std.testing.expectEqual(value, rt_val.u64);
    }
    {
        defer list.clearRetainingCapacity();
        const value = 0x100;
        try pack(list.writer().any(), value, .{});
        var expected: [3]u8 = undefined;
        expected[0] = 0xcd;
        std.mem.writeInt(u16, expected[1..], value, .big);
        try std.testing.expectEqualSlices(u8, &expected, list.items);

        var fbs = std.io.fixedBufferStream(list.items);
        const rt_val = try unpackValue(std.testing.allocator, fbs.reader().any());
        try std.testing.expect(rt_val == .u64);
        try std.testing.expectEqual(value, rt_val.u64);
    }
    {
        defer list.clearRetainingCapacity();
        const value = 0xFFFF;
        try pack(list.writer().any(), value, .{});
        var expected: [3]u8 = undefined;
        expected[0] = 0xcd;
        std.mem.writeInt(u16, expected[1..], value, .big);
        try std.testing.expectEqualSlices(u8, &expected, list.items);

        var fbs = std.io.fixedBufferStream(list.items);
        const rt_val = try unpackValue(std.testing.allocator, fbs.reader().any());
        try std.testing.expect(rt_val == .u64);
        try std.testing.expectEqual(value, rt_val.u64);
    }
    {
        defer list.clearRetainingCapacity();
        const value = 0x10000;
        try pack(list.writer().any(), value, .{});
        var expected: [5]u8 = undefined;
        expected[0] = 0xce;
        std.mem.writeInt(i32, expected[1..], value, .big);
        try std.testing.expectEqualSlices(u8, &expected, list.items);

        var fbs = std.io.fixedBufferStream(list.items);
        const rt_val = try unpackValue(std.testing.allocator, fbs.reader().any());
        try std.testing.expect(rt_val == .u64);
        try std.testing.expectEqual(value, rt_val.u64);
    }
    {
        defer list.clearRetainingCapacity();
        const value = 0xFFFFFFFF;
        try pack(list.writer().any(), value, .{});
        var expected: [5]u8 = undefined;
        expected[0] = 0xce;
        std.mem.writeInt(u32, expected[1..], value, .big);
        try std.testing.expectEqualSlices(u8, &expected, list.items);

        var fbs = std.io.fixedBufferStream(list.items);
        const rt_val = try unpackValue(std.testing.allocator, fbs.reader().any());
        try std.testing.expect(rt_val == .u64);
        try std.testing.expectEqual(value, rt_val.u64);
    }
    {
        defer list.clearRetainingCapacity();
        const value = 0x100000000;
        try pack(list.writer().any(), value, .{});
        var expected: [9]u8 = undefined;
        expected[0] = 0xcf;
        std.mem.writeInt(i64, expected[1..], value, .big);
        try std.testing.expectEqualSlices(u8, &expected, list.items);

        var fbs = std.io.fixedBufferStream(list.items);
        const rt_val = try unpackValue(std.testing.allocator, fbs.reader().any());
        try std.testing.expect(rt_val == .u64);
        try std.testing.expectEqual(value, rt_val.u64);
    }
}

test "pack and unpack floats" {
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();

    {
        defer list.clearRetainingCapacity();
        const value: f32 = 0.1;
        try pack(list.writer().any(), value, .{});
        var expected: [5]u8 = undefined;
        expected[0] = 0xca;
        std.mem.writeInt(u32, expected[1..], @bitCast(@as(f32, @floatCast(value))), .big);
        try std.testing.expectEqualSlices(u8, &expected, list.items);

        var fbs = std.io.fixedBufferStream(list.items);
        const rt_val = try unpackValue(std.testing.allocator, fbs.reader().any());
        try std.testing.expect(rt_val == .f64);
        try std.testing.expectEqual(value, rt_val.f64);
    }
    {
        defer list.clearRetainingCapacity();
        const value: f64 = 0.1;
        try pack(list.writer().any(), value, .{});
        var expected: [9]u8 = undefined;
        expected[0] = 0xcb;
        std.mem.writeInt(u64, expected[1..], @bitCast(value), .big);
        try std.testing.expectEqualSlices(u8, &expected, list.items);

        var fbs = std.io.fixedBufferStream(list.items);
        const rt_val = try unpackValue(std.testing.allocator, fbs.reader().any());
        try std.testing.expect(rt_val == .f64);
        try std.testing.expectEqual(value, rt_val.f64);
    }
}

test "pack enum" {
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    {
        defer list.clearRetainingCapacity();
        const value = .value;
        try pack(list.writer().any(), value, .{});
        var expected: [6]u8 = undefined;
        expected[0] = 0b1010_0000 | 5;
        @memcpy(expected[1..], @tagName(value));
        try std.testing.expectEqualSlices(u8, &expected, list.items);
    }
}

test "pack struct" {
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    {
        const Struct = struct {
            field_one: u8,
            field_two: []const u8,
        };
        const value: Struct = .{
            .field_one = 1,
            .field_two = "two",
        };
        defer list.clearRetainingCapacity();
        try pack(list.writer().any(), value, .{});
        var expected: [26]u8 = undefined;
        expected[0] = 0b1000_0000 | 2;
        expected[1] = 0b1010_0000 | 9;
        @memcpy(expected[2..11], "field_one");
        expected[11] = 0x01;
        expected[12] = 0b1010_0000 | 9;
        @memcpy(expected[13..22], "field_two");
        expected[22] = 0b1010_0000 | 3;
        @memcpy(expected[23..26], "two");

        try std.testing.expectEqualSlices(u8, &expected, list.items);

        var fbs = std.io.fixedBufferStream(list.items);
        const rt_val = try unpackValue(std.testing.allocator, fbs.reader().any());
        defer rt_val.deinit(std.testing.allocator);
        try std.testing.expect(rt_val == .map);
        const field_one = rt_val.map.get("field_one");
        try std.testing.expect(field_one != null);
        try std.testing.expect(field_one.? == .u64);
        try std.testing.expectEqual(1, field_one.?.u64);
        const field_two = rt_val.map.get("field_two");
        try std.testing.expect(field_two != null);
        try std.testing.expect(field_two.? == .str);
        try std.testing.expectEqualStrings("two", field_two.?.str);
    }
}

test "pack and unpack array" {
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();

    const values = [_]u32{ 1, 2, 3 };
    try pack(list.writer().any(), values, .{});
    var expected: [4]u8 = undefined;
    expected[0] = 0b1001_0000 | 3;
    expected[1] = 0x01;
    expected[2] = 0x02;
    expected[3] = 0x03;
    try std.testing.expectEqualSlices(u8, &expected, list.items);

    var fbs = std.io.fixedBufferStream(list.items);
    const rt_val = try unpackValue(std.testing.allocator, fbs.reader().any());
    defer rt_val.deinit(std.testing.allocator);
    try std.testing.expect(rt_val == .array);
    for (rt_val.array, 0..) |value, i| {
        try std.testing.expect(value == .u64);
        try std.testing.expectEqual(values[i], value.u64);
    }
}

test "pack and unpack union" {
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    const Union = union(enum) {
        field_one,
        field_two: u32,
    };
    {
        const value: Union = .field_one;
        defer list.clearRetainingCapacity();
        try pack(list.writer().any(), value, .{});
        var expected: [12]u8 = undefined;
        expected[0] = 0b1000_0000 | 1;
        expected[1] = 0b1010_0000 | 9;
        @memcpy(expected[2..11], "field_one");
        expected[11] = 0xc0;

        try std.testing.expectEqualSlices(u8, &expected, list.items);

        var fbs = std.io.fixedBufferStream(list.items);
        const rt_val = try unpackValue(std.testing.allocator, fbs.reader().any());
        defer rt_val.deinit(std.testing.allocator);
        try std.testing.expect(rt_val == .map);
        const field_one = rt_val.map.get("field_one");
        try std.testing.expect(field_one != null);
        try std.testing.expect(field_one.? == .nil);
    }
    {
        const value: Union = .{ .field_two = 1 };
        defer list.clearRetainingCapacity();
        try pack(list.writer().any(), value, .{});
        var expected: [12]u8 = undefined;
        expected[0] = 0b1000_0000 | 1;
        expected[1] = 0b1010_0000 | 9;
        @memcpy(expected[2..11], "field_two");
        expected[11] = 0x01;

        try std.testing.expectEqualSlices(u8, &expected, list.items);

        var fbs = std.io.fixedBufferStream(list.items);
        const rt_val = try unpackValue(std.testing.allocator, fbs.reader().any());
        defer rt_val.deinit(std.testing.allocator);
        try std.testing.expect(rt_val == .map);
        const field_two = rt_val.map.get("field_two");
        try std.testing.expect(field_two != null);
        try std.testing.expect(field_two.? == .u64);
        try std.testing.expectEqual(1, field_two.?.u64);
    }
}
