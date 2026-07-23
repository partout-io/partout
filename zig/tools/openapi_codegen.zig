// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const ParseError = error{
    ExpectedComponents,
    ExpectedSchemas,
    InvalidSchema,
    OutOfMemory,
};

const AllocError = std.mem.Allocator.Error;
const WriterError = std.Io.Writer.Error;
const RenderError = AllocError || WriterError || ParseError;
const MainError = RenderError || std.process.Args.Iterator.InitError || std.Io.Dir.ReadFileAllocError || std.Io.Dir.WriteFileError;

const Primitive = enum {
    string,
    integer,
    number,
    boolean,
    object,
};

const TypeSpec = union(enum) {
    none,
    primitive: Primitive,
    ref: []const u8,
    array: *TypeSpec,
    raw_json,
};

const Property = struct {
    name: []const u8,
    spec: TypeSpec = .none,
};

const Variant = struct {
    raw: []const u8,
    schema: []const u8,
};

const Schema = struct {
    name: []const u8,
    typ: ?[]const u8 = null,
    format: ?[]const u8 = null,
    enum_values: std.ArrayList([]const u8) = .empty,
    enum_names: std.ArrayList([]const u8) = .empty,
    required: std.ArrayList([]const u8) = .empty,
    properties: std.ArrayList(Property) = .empty,
    variants: std.ArrayList(Variant) = .empty,
    discriminator_property: ?[]const u8 = null,
};

const Document = struct {
    schemas: std.ArrayList(Schema) = .empty,

    fn schema(self: Document, name: []const u8) ?*const Schema {
        for (self.schemas.items) |*item| {
            if (std.mem.eql(u8, item.name, name)) return item;
        }
        return null;
    }

    fn isDiscriminatorVariant(self: Document, name: []const u8) bool {
        for (self.schemas.items) |schema_item| {
            for (schema_item.variants.items) |variant| {
                if (std.mem.eql(u8, variant.schema, name)) return true;
            }
        }
        return false;
    }
};

const SchemaExclusions = struct {
    names: []const []const u8 = &.{},

    fn contains(self: SchemaExclusions, name: []const u8) bool {
        for (self.names) |item| {
            if (matchesExclusion(item, name)) return true;
            if (matchesExclusion(item, zigTypeName(name))) return true;
        }
        return false;
    }
};

fn matchesExclusion(pattern: []const u8, name: []const u8) bool {
    if (std.mem.endsWith(u8, pattern, "*")) {
        return std.mem.startsWith(u8, name, pattern[0 .. pattern.len - 1]);
    }
    return std.mem.eql(u8, pattern, name);
}

pub fn main(init: std.process.Init) MainError!void {
    const allocator = init.arena.allocator();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const input_path = args.next() orelse {
        try usage();
        return;
    };
    const output_path = args.next() orelse {
        try usage();
        return;
    };

    var exclusions = SchemaExclusions{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--exclude")) {
            exclusions = try parseSchemaExclusions(allocator, args.next() orelse {
                try usage();
                return;
            });
        } else if (std.mem.startsWith(u8, arg, "--exclude=")) {
            exclusions = try parseSchemaExclusions(allocator, arg["--exclude=".len..]);
        } else {
            try usage();
            return;
        }
    }

    const cwd = std.Io.Dir.cwd();
    const input = try readFileAlloc(cwd, init.io, allocator, input_path);
    defer allocator.free(input);

    const doc = try parseDocument(allocator, input);
    const generated = try renderDocument(allocator, doc, exclusions);
    defer allocator.free(generated);

    try cwd.writeFile(init.io, .{ .sub_path = output_path, .data = generated });
}

fn parseSchemaExclusions(allocator: std.mem.Allocator, raw: []const u8) ParseError!SchemaExclusions {
    if (std.mem.trim(u8, raw, " \t").len == 0) return .{};

    var names: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.splitScalar(u8, raw, ',');
    while (parts.next()) |part| {
        const name = std.mem.trim(u8, part, " \t");
        if (name.len == 0) return ParseError.InvalidSchema;
        try names.append(allocator, try allocator.dupe(u8, name));
    }

    return .{ .names = try names.toOwnedSlice(allocator) };
}

fn usage() WriterError!void {
    var stderr = std.debug.lockStderr(&.{});
    defer std.debug.unlockStderr();
    try stderr.file_writer.interface.writeAll(
        \\usage: zig run tools/openapi_codegen.zig -- <openapi.yaml> <generated.zig> [--exclude SchemaA,SchemaB]
        \\
    );
}

fn readFileAlloc(dir: std.Io.Dir, io: std.Io, allocator: std.mem.Allocator, path: []const u8) std.Io.Dir.ReadFileAllocError![]u8 {
    return dir.readFileAlloc(io, path, allocator, .limited(1024 * 1024));
}

fn parseDocument(allocator: std.mem.Allocator, contents: []const u8) ParseError!Document {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.trim(u8, line, " \t").len == 0) continue;
        try lines.append(allocator, line);
    }

    const components_index = findLine(lines.items, 0, 0, "components:") orelse return ParseError.ExpectedComponents;
    const schemas_index = findLine(lines.items, components_index + 1, 2, "schemas:") orelse return ParseError.ExpectedSchemas;

    var doc = Document{};
    var index = schemas_index + 1;
    while (index < lines.items.len) {
        const line = lines.items[index];
        const line_indent = indentOf(line);
        if (line_indent < 4) break;
        if (line_indent != 4 or !std.mem.endsWith(u8, std.mem.trim(u8, line, " "), ":")) {
            index += 1;
            continue;
        }

        const name = try allocator.dupe(u8, stripTrailingColon(std.mem.trim(u8, line, " ")));
        var schema_item = Schema{ .name = name };
        index += 1;
        const block_start = index;
        while (index < lines.items.len and indentOf(lines.items[index]) > 4) : (index += 1) {}
        try parseSchemaBlock(allocator, &schema_item, lines.items[block_start..index]);
        try doc.schemas.append(allocator, schema_item);
    }

    return doc;
}

fn findLine(lines: []const []const u8, start: usize, indent: usize, text: []const u8) ?usize {
    for (lines[start..], start..) |line, index| {
        if (indentOf(line) == indent and std.mem.eql(u8, std.mem.trim(u8, line, " "), text)) return index;
    }
    return null;
}

fn parseSchemaBlock(allocator: std.mem.Allocator, schema_item: *Schema, lines: []const []const u8) ParseError!void {
    var index: usize = 0;
    while (index < lines.len) {
        const line = lines[index];
        if (indentOf(line) != 6) {
            index += 1;
            continue;
        }
        const trimmed = std.mem.trim(u8, line, " ");
        if (std.mem.startsWith(u8, trimmed, "type: ")) {
            schema_item.typ = try allocator.dupe(u8, cleanScalar(trimmed["type: ".len..]));
            index += 1;
        } else if (std.mem.startsWith(u8, trimmed, "format: ")) {
            schema_item.format = try allocator.dupe(u8, cleanScalar(trimmed["format: ".len..]));
            index += 1;
        } else if (std.mem.eql(u8, trimmed, "enum:")) {
            index += 1;
            while (index < lines.len and indentOf(lines[index]) == 8 and std.mem.startsWith(u8, std.mem.trim(u8, lines[index], " "), "- ")) : (index += 1) {
                const item = std.mem.trim(u8, lines[index], " ")[2..];
                try schema_item.enum_values.append(allocator, try allocator.dupe(u8, cleanScalar(item)));
            }
        } else if (std.mem.eql(u8, trimmed, "x-enum-varnames:")) {
            index += 1;
            while (index < lines.len and indentOf(lines[index]) == 8 and std.mem.startsWith(u8, std.mem.trim(u8, lines[index], " "), "- ")) : (index += 1) {
                const item = std.mem.trim(u8, lines[index], " ")[2..];
                try schema_item.enum_names.append(allocator, try allocator.dupe(u8, cleanScalar(item)));
            }
        } else if (std.mem.eql(u8, trimmed, "required:")) {
            index += 1;
            while (index < lines.len and indentOf(lines[index]) == 8 and std.mem.startsWith(u8, std.mem.trim(u8, lines[index], " "), "- ")) : (index += 1) {
                const item = std.mem.trim(u8, lines[index], " ")[2..];
                try schema_item.required.append(allocator, try allocator.dupe(u8, cleanScalar(item)));
            }
        } else if (std.mem.eql(u8, trimmed, "properties:")) {
            index = try parseProperties(allocator, schema_item, lines, index + 1);
        } else if (std.mem.eql(u8, trimmed, "discriminator:")) {
            index = try parseDiscriminator(allocator, schema_item, lines, index + 1);
        } else {
            index += 1;
        }
    }
}

fn parseProperties(
    allocator: std.mem.Allocator,
    schema_item: *Schema,
    lines: []const []const u8,
    start_index: usize,
) ParseError!usize {
    var index = start_index;
    while (index < lines.len) {
        const line = lines[index];
        const line_indent = indentOf(line);
        if (line_indent <= 6) break;
        if (line_indent != 8 or !std.mem.endsWith(u8, std.mem.trim(u8, line, " "), ":")) {
            index += 1;
            continue;
        }
        var property = Property{
            .name = try allocator.dupe(u8, stripTrailingColon(std.mem.trim(u8, line, " "))),
        };
        index += 1;
        const block_start = index;
        while (index < lines.len and indentOf(lines[index]) > 8) : (index += 1) {}
        property.spec = try parseTypeSpec(allocator, lines[block_start..index], 10);
        try schema_item.properties.append(allocator, property);
    }
    return index;
}

fn parseDiscriminator(
    allocator: std.mem.Allocator,
    schema_item: *Schema,
    lines: []const []const u8,
    start_index: usize,
) ParseError!usize {
    var index = start_index;
    while (index < lines.len) {
        const line = lines[index];
        const line_indent = indentOf(line);
        if (line_indent <= 6) break;
        const trimmed = std.mem.trim(u8, line, " ");
        if (line_indent == 8 and std.mem.startsWith(u8, trimmed, "propertyName: ")) {
            schema_item.discriminator_property = try allocator.dupe(u8, cleanScalar(trimmed["propertyName: ".len..]));
            index += 1;
        } else if (line_indent == 8 and std.mem.eql(u8, trimmed, "mapping:")) {
            index += 1;
            while (index < lines.len and indentOf(lines[index]) == 10) : (index += 1) {
                const mapping = std.mem.trim(u8, lines[index], " ");
                const separator = std.mem.indexOfScalar(u8, mapping, ':') orelse return ParseError.InvalidSchema;
                const raw = try allocator.dupe(u8, cleanScalar(mapping[0..separator]));
                const ref = refName(cleanScalar(std.mem.trim(u8, mapping[separator + 1 ..], " "))) orelse return ParseError.InvalidSchema;
                try schema_item.variants.append(allocator, .{
                    .raw = raw,
                    .schema = try allocator.dupe(u8, ref),
                });
            }
        } else {
            index += 1;
        }
    }
    return index;
}

fn parseTypeSpec(allocator: std.mem.Allocator, lines: []const []const u8, base_indent: usize) ParseError!TypeSpec {
    var spec: TypeSpec = .none;
    var index: usize = 0;
    while (index < lines.len) : (index += 1) {
        if (indentOf(lines[index]) != base_indent) continue;
        const trimmed = std.mem.trim(u8, lines[index], " ");
        if (std.mem.startsWith(u8, trimmed, "\"$ref\": ")) {
            const ref = refName(cleanScalar(trimmed["\"$ref\": ".len..])) orelse return ParseError.InvalidSchema;
            spec = .{ .ref = try allocator.dupe(u8, ref) };
        } else if (std.mem.startsWith(u8, trimmed, "$ref: ")) {
            const ref = refName(cleanScalar(trimmed["$ref: ".len..])) orelse return ParseError.InvalidSchema;
            spec = .{ .ref = try allocator.dupe(u8, ref) };
        } else if (std.mem.startsWith(u8, trimmed, "type: ")) {
            const raw_type = cleanScalar(trimmed["type: ".len..]);
            if (std.mem.eql(u8, raw_type, "array")) continue;
            spec = .{ .primitive = primitiveFromString(raw_type) orelse return ParseError.InvalidSchema };
        } else if (std.mem.eql(u8, trimmed, "items:")) {
            const child = try allocator.create(TypeSpec);
            child.* = try parseTypeSpec(allocator, lines[index + 1 ..], base_indent + 2);
            spec = .{ .array = child };
        } else if (std.mem.eql(u8, trimmed, "additionalProperties:")) {
            spec = .raw_json;
        }
    }

    switch (spec) {
        .primitive => |primitive| {
            if (primitive == .object and !hasNestedProperties(lines, base_indent + 2)) {
                return .raw_json;
            }
        },
        else => {},
    }
    return spec;
}

fn hasNestedProperties(lines: []const []const u8, indent: usize) bool {
    for (lines) |line| {
        if (indentOf(line) == indent and std.mem.eql(u8, std.mem.trim(u8, line, " "), "properties:")) return true;
    }
    return false;
}

fn primitiveFromString(value: []const u8) ?Primitive {
    if (std.mem.eql(u8, value, "string")) return .string;
    if (std.mem.eql(u8, value, "integer")) return .integer;
    if (std.mem.eql(u8, value, "number")) return .number;
    if (std.mem.eql(u8, value, "boolean")) return .boolean;
    if (std.mem.eql(u8, value, "object")) return .object;
    if (std.mem.eql(u8, value, "array")) return null;
    return null;
}

fn renderDocument(allocator: std.mem.Allocator, doc: Document, exclusions: SchemaExclusions) RenderError![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    const w = &out.writer;

    try w.writeAll(
        \\// SPDX-FileCopyrightText: 2026 Davide De Rosa
        \\//
        \\// SPDX-License-Identifier: GPL-3.0
        \\
        \\// Generated by tools/openapi_codegen.zig from scripts/openapi.yaml.
        \\// Do not edit by hand.
        \\
        \\const std = @import("std");
        \\const manual = @import("api_manual.zig");
        \\const util = @import("util.zig");
        \\const uuid = @import("uuid.zig");
        \\
        \\const JsonStringifyError = std.json.Stringify.Error;
        \\
        \\pub const DecodeError = error{
        \\    InvalidJson,
        \\    InvalidModel,
        \\    OutOfMemory,
        \\    UnsupportedModel,
        \\};
        \\
        \\pub const EncodeError = error{
        \\    InvalidModel,
        \\    OutOfMemory,
        \\    Stringify,
        \\};
        \\
        \\pub const JsonErrorInfo = struct {
        \\    key: ?[]const u8 = null,
        \\};
        \\
        \\pub const RawJsonValue = struct {
        \\    bytes: []const u8 = "null",
        \\    owned: bool = false,
        \\
        \\    pub fn parseValue(allocator: std.mem.Allocator, value: std.json.Value) DecodeError!RawJsonValue {
        \\        return .{
        \\            .bytes = try util.encodeJsonValue(allocator, value),
        \\            .owned = true,
        \\        };
        \\    }
        \\
        \\    pub fn clone(self: RawJsonValue, allocator: std.mem.Allocator) DecodeError!RawJsonValue {
        \\        return .{
        \\            .bytes = try allocator.dupe(u8, self.bytes),
        \\            .owned = true,
        \\        };
        \\    }
        \\
        \\    pub fn deinit(self: *const RawJsonValue, allocator: std.mem.Allocator) void {
        \\        if (self.owned) allocator.free(self.bytes);
        \\    }
        \\
        \\    pub fn jsonStringify(self: RawJsonValue, jw: anytype) JsonStringifyError!void {
        \\        try jw.print("{s}", .{self.bytes});
        \\    }
        \\};
        \\
    );

    try renderRuntime(w);

    for (doc.schemas.items) |schema_item| {
        if (exclusions.contains(schema_item.name)) continue;
        if (integerType(schema_item.name) != null) continue;
        if (doc.isDiscriminatorVariant(schema_item.name)) continue;
        try renderSchema(w, doc, schema_item, exclusions);
    }

    return out.toOwnedSlice();
}

fn renderRuntime(w: *std.Io.Writer) WriterError!void {
    try w.writeAll(
        \\
        \\pub fn encodeJsonValue(allocator: std.mem.Allocator, value: anytype) EncodeError![]u8 {
        \\    var out: std.Io.Writer.Allocating = .init(allocator);
        \\    errdefer out.deinit();
        \\    std.json.Stringify.value(value, .{}, &out.writer) catch |err| return mapJsonStringifyError(err);
        \\    return out.toOwnedSlice() catch error.OutOfMemory;
        \\}
        \\
        \\pub fn encodeJsonValueZ(allocator: std.mem.Allocator, value: anytype) EncodeError![:0]u8 {
        \\    var out: std.Io.Writer.Allocating = .init(allocator);
        \\    errdefer out.deinit();
        \\    std.json.Stringify.value(value, .{}, &out.writer) catch |err| return mapJsonStringifyError(err);
        \\    return out.toOwnedSliceSentinel(0) catch error.OutOfMemory;
        \\}
        \\
        \\fn mapJsonStringifyError(err: JsonStringifyError) EncodeError {
        \\    return switch (err) {
        \\        error.WriteFailed => error.Stringify,
        \\    };
        \\}
        \\
        \\fn parseJson(comptime T: type, allocator: std.mem.Allocator, value: std.json.Value) DecodeError!T {
        \\    return parseJsonWithErrorInfo(T, allocator, value, null);
        \\}
        \\
        \\fn parseJsonWithErrorInfo(comptime T: type, allocator: std.mem.Allocator, value: std.json.Value, error_info: ?*JsonErrorInfo) DecodeError!T {
        \\    if (comptime T == uuid.UUID) {
        \\        return parseUUID(value);
        \\    }
        \\
        \\    if (comptime std.meta.hasFn(T, "parseValueWithErrorInfo")) {
        \\        return T.parseValueWithErrorInfo(allocator, value, error_info);
        \\    }
        \\
        \\    if (comptime std.meta.hasFn(T, "parseValue")) {
        \\        return T.parseValue(allocator, value);
        \\    }
        \\
        \\    switch (@typeInfo(T)) {
        \\        .bool => return switch (value) {
        \\            .bool => |inner| inner,
        \\            else => error.InvalidModel,
        \\        },
        \\        .int, .comptime_int => return parseInteger(T, value),
        \\        .float, .comptime_float => return parseFloat(T, value),
        \\        .pointer => |pointer| {
        \\            if (pointer.size != .slice) @compileError("only slices are supported");
        \\            if (pointer.child == u8) return parseString(allocator, value);
        \\            const values = switch (value) {
        \\                .array => |array| array.items,
        \\                else => return error.InvalidModel,
        \\            };
        \\            const out = try allocator.alloc(pointer.child, values.len);
        \\            var initialized: usize = 0;
        \\            errdefer {
        \\                for (out[0..initialized]) |*item| deinitJson(pointer.child, allocator, item);
        \\                if (out.len > 0) allocator.free(out);
        \\            }
        \\            for (values, 0..) |item, index| {
        \\                out[index] = try parseJsonWithErrorInfo(pointer.child, allocator, item, error_info);
        \\                initialized += 1;
        \\            }
        \\            return out;
        \\        },
        \\        else => @compileError("unsupported generated OpenAPI type: " ++ @typeName(T)),
        \\    }
        \\}
        \\
        \\fn parseJsonField(comptime T: type, allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8, error_info: ?*JsonErrorInfo) DecodeError!T {
        \\    const raw = object.get(key) orelse {
        \\        setJsonErrorKey(error_info, key);
        \\        return error.InvalidModel;
        \\    };
        \\    return parseJsonWithErrorInfo(T, allocator, raw, error_info) catch |err| {
        \\        setJsonErrorKeyForError(error_info, key, err);
        \\        return err;
        \\    };
        \\}
        \\
        \\fn parseOptionalJsonField(comptime T: type, allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8, error_info: ?*JsonErrorInfo) DecodeError!?T {
        \\    const raw = object.get(key) orelse return null;
        \\    if (isNullValue(raw)) return null;
        \\    return parseJsonWithErrorInfo(T, allocator, raw, error_info) catch |err| {
        \\        setJsonErrorKeyForError(error_info, key, err);
        \\        return err;
        \\    };
        \\}
        \\
        \\fn setJsonErrorKey(error_info: ?*JsonErrorInfo, key: []const u8) void {
        \\    const info = error_info orelse return;
        \\    if (info.key == null) info.key = key;
        \\}
        \\
        \\fn setJsonErrorKeyForError(error_info: ?*JsonErrorInfo, key: []const u8, err: DecodeError) void {
        \\    switch (err) {
        \\        error.OutOfMemory => {},
        \\        else => setJsonErrorKey(error_info, key),
        \\    }
        \\}
        \\
        \\fn resetJsonErrorInfo(error_info: ?*JsonErrorInfo) void {
        \\    const info = error_info orelse return;
        \\    info.* = .{};
        \\}
        \\
        \\fn deinitJson(comptime T: type, allocator: std.mem.Allocator, value: *const T) void {
        \\    if (comptime std.meta.hasFn(T, "deinit")) {
        \\        value.deinit(allocator);
        \\        return;
        \\    }
        \\
        \\    switch (@typeInfo(T)) {
        \\        .pointer => |pointer| {
        \\            if (pointer.size != .slice) return;
        \\            if (pointer.child == u8) {
        \\                if (value.*.len > 0) allocator.free(value.*);
        \\                return;
        \\            }
        \\            for (value.*) |item| {
        \\                var mutable = item;
        \\                deinitJson(pointer.child, allocator, &mutable);
        \\            }
        \\            if (value.*.len > 0) allocator.free(value.*);
        \\        },
        \\        else => {},
        \\    }
        \\}
        \\
        \\fn writeJson(jw: anytype, value: anytype) JsonStringifyError!void {
        \\    const T = @TypeOf(value);
        \\    if (comptime T == uuid.UUID) {
        \\        try jw.write(value[0..]);
        \\        return;
        \\    }
        \\    if (comptime isUuidSlice(T)) {
        \\        try jw.beginArray();
        \\        for (value) |item| {
        \\            try writeJson(jw, item);
        \\        }
        \\        try jw.endArray();
        \\        return;
        \\    }
        \\    try jw.write(value);
        \\}
        \\
        \\fn isUuidSlice(comptime T: type) bool {
        \\    return switch (@typeInfo(T)) {
        \\        .pointer => |pointer| pointer.size == .slice and pointer.child == uuid.UUID,
        \\        else => false,
        \\    };
        \\}
        \\
        \\fn parseInteger(comptime T: type, value: std.json.Value) DecodeError!T {
        \\    return switch (value) {
        \\        .integer => |inner| std.math.cast(T, inner) orelse error.InvalidModel,
        \\        .number_string => |inner| std.fmt.parseInt(T, inner, 10) catch error.InvalidModel,
        \\        else => error.InvalidModel,
        \\    };
        \\}
        \\
        \\fn parseFloat(comptime T: type, value: std.json.Value) DecodeError!T {
        \\    return switch (value) {
        \\        .integer => |inner| @floatFromInt(inner),
        \\        .float => |inner| @floatCast(inner),
        \\        .number_string => |inner| std.fmt.parseFloat(T, inner) catch error.InvalidModel,
        \\        else => error.InvalidModel,
        \\    };
        \\}
        \\
        \\fn parseString(allocator: std.mem.Allocator, value: std.json.Value) DecodeError![]const u8 {
        \\    const string = switch (value) {
        \\        .string => |inner| inner,
        \\        else => return error.InvalidModel,
        \\    };
        \\    return try allocator.dupe(u8, string);
        \\}
        \\
        \\fn parseUUID(value: std.json.Value) DecodeError!uuid.UUID {
        \\    const raw = stringValue(value) orelse return error.InvalidModel;
        \\    return uuid.parse(raw) orelse error.InvalidModel;
        \\}
        \\
        \\fn objectValue(value: std.json.Value) ?std.json.ObjectMap {
        \\    return switch (value) {
        \\        .object => |object| object,
        \\        else => null,
        \\    };
        \\}
        \\
        \\fn stringValue(value: std.json.Value) ?[]const u8 {
        \\    return switch (value) {
        \\        .string => |string| string,
        \\        else => null,
        \\    };
        \\}
        \\
        \\fn isNullValue(value: std.json.Value) bool {
        \\    return switch (value) {
        \\        .null => true,
        \\        else => false,
        \\    };
        \\}
        \\
    );
}

fn renderSchema(w: *std.Io.Writer, doc: Document, schema_item: Schema, exclusions: SchemaExclusions) RenderError!void {
    if (schema_item.variants.items.len > 0) {
        try renderUnion(w, doc, schema_item, exclusions);
    } else if (schema_item.enum_values.items.len > 0) {
        try renderEnum(w, schema_item);
    } else if (schema_item.properties.items.len > 0) {
        try renderStruct(w, doc, schema_item, false, exclusions);
    } else {
        try renderAlias(w, schema_item);
    }
}

fn renderAlias(w: *std.Io.Writer, schema_item: Schema) WriterError!void {
    try w.print("\npub const {s} = {s};\n", .{
        zigTypeName(schema_item.name),
        aliasType(schema_item),
    });
}

fn renderEnum(w: *std.Io.Writer, schema_item: Schema) WriterError!void {
    const name = zigTypeName(schema_item.name);
    const is_integer = schema_item.typ != null and std.mem.eql(u8, schema_item.typ.?, "integer");
    try w.print("\npub const {s} = enum{s} {{\n", .{ name, if (is_integer) "(i32)" else "" });
    for (schema_item.enum_names.items, 0..) |enum_name, index| {
        if (is_integer) {
            try w.print("    {s} = {s},\n", .{ zigEnumField(enum_name), schema_item.enum_values.items[index] });
        } else {
            try w.print("    {s},\n", .{zigEnumField(enum_name)});
        }
    }
    try w.writeAll(
        \\
        \\    pub fn parseValue(_: std.mem.Allocator, value: std.json.Value) DecodeError!@This() {
        \\
    );
    if (is_integer) {
        try w.writeAll(
            \\        const raw_value = try parseInteger(i32, value);
            \\        return parseFromRaw(raw_value) orelse error.UnsupportedModel;
            \\
        );
    } else {
        try w.writeAll(
            \\        const raw_value = stringValue(value) orelse return error.InvalidModel;
            \\        return parseFromRaw(raw_value) orelse error.UnsupportedModel;
            \\
        );
    }
    try w.writeAll("    }\n\n");
    if (is_integer) {
        try w.writeAll(
            \\    pub fn parseFromRaw(raw_value: i32) ?@This() {
            \\        return switch (raw_value) {
            \\
        );
        for (schema_item.enum_names.items, 0..) |enum_name, index| {
            try w.print("            {s} => .{s},\n", .{ schema_item.enum_values.items[index], zigEnumField(enum_name) });
        }
        try w.writeAll(
            \\            else => null,
            \\        };
            \\    }
            \\
            \\    pub fn raw(self: @This()) i32 {
            \\        return switch (self) {
            \\
        );
    } else {
        try w.writeAll(
            \\    pub fn parseFromRaw(raw_value: []const u8) ?@This() {
            \\
        );
        for (schema_item.enum_names.items, 0..) |enum_name, index| {
            try w.print("        if (std.mem.eql(u8, raw_value, \"{s}\")) return .{s};\n", .{
                schema_item.enum_values.items[index],
                zigEnumField(enum_name),
            });
        }
        try w.writeAll(
            \\        return null;
            \\    }
            \\
            \\    pub fn raw(self: @This()) []const u8 {
            \\        return switch (self) {
            \\
        );
    }
    for (schema_item.enum_names.items, 0..) |enum_name, index| {
        if (is_integer) {
            try w.print("            .{s} => {s},\n", .{ zigEnumField(enum_name), schema_item.enum_values.items[index] });
        } else {
            try w.print("            .{s} => \"{s}\",\n", .{
                zigEnumField(enum_name),
                schema_item.enum_values.items[index],
            });
        }
    }
    try w.writeAll(
        \\        };
        \\    }
        \\
        \\    pub fn jsonStringify(self: @This(), jw: anytype) JsonStringifyError!void {
        \\        try jw.write(self.raw());
        \\    }
        \\};
        \\
    );
}

fn renderStruct(w: *std.Io.Writer, doc: Document, schema_item: Schema, omit_discriminator: bool, exclusions: SchemaExclusions) RenderError!void {
    const name = zigTypeName(schema_item.name);
    try w.print("\npub const {s} = struct {{\n", .{name});
    for (schema_item.properties.items) |property| {
        if (omit_discriminator and std.mem.eql(u8, property.name, "type")) continue;
        const field_type = try typeExprAlloc(std.heap.page_allocator, doc, property.spec, exclusions);
        defer std.heap.page_allocator.free(field_type);
        if (isRequired(schema_item, property.name)) {
            const default_value = try defaultValueForSpec(std.heap.page_allocator, doc, property.spec, exclusions);
            defer std.heap.page_allocator.free(default_value);
            try w.print("    {s}: {s} = {s},\n", .{
                zigFieldName(property.name),
                field_type,
                default_value,
            });
        } else {
            try w.print("    {s}: ?{s} = null,\n", .{
                zigFieldName(property.name),
                field_type,
            });
        }
    }
    try renderStructMethods(w, doc, schema_item, omit_discriminator, exclusions);
    try w.writeAll("};\n");
}

fn renderStructMethods(w: *std.Io.Writer, doc: Document, schema_item: Schema, omit_discriminator: bool, exclusions: SchemaExclusions) RenderError!void {
    const name = zigTypeName(schema_item.name);
    const const_receiver = usesConstPointerReceiver(name);
    const property_count = effectivePropertyCount(schema_item, omit_discriminator);
    if (property_count > 0) try w.writeAll("\n");
    try w.print(
        \\    pub fn parse(allocator: std.mem.Allocator, text: []const u8) DecodeError!{s} {{
        \\        return parseWithErrorInfo(allocator, text, null);
        \\    }}
        \\
        \\    pub fn parseWithErrorInfo(allocator: std.mem.Allocator, text: []const u8, error_info: ?*JsonErrorInfo) DecodeError!{s} {{
        \\        resetJsonErrorInfo(error_info);
        \\        var parsed = try util.parseJsonValue(allocator, text);
        \\        defer parsed.deinit();
        \\        return parseValueWithErrorInfo(allocator, parsed.value, error_info);
        \\    }}
        \\
        \\    pub fn parseValue(allocator: std.mem.Allocator, value: std.json.Value) DecodeError!{s} {{
        \\        return parseValueWithErrorInfo(allocator, value, null);
        \\    }}
        \\
        \\    pub fn parseValueWithErrorInfo(allocator: std.mem.Allocator, value: std.json.Value, error_info: ?*JsonErrorInfo) DecodeError!{s} {{
        \\        resetJsonErrorInfo(error_info);
        \\
    , .{ name, name, name, name });
    if (property_count == 0) {
        try w.writeAll(
            \\        _ = objectValue(value) orelse return error.InvalidModel;
            \\
        );
    } else {
        try w.writeAll(
            \\        const object = objectValue(value) orelse return error.InvalidModel;
            \\
        );
    }
    try w.print(
        \\        var result = {s}{{}};
        \\        errdefer result.deinit(allocator);
        \\
    , .{name});

    for (schema_item.properties.items) |property| {
        if (omit_discriminator and std.mem.eql(u8, property.name, "type")) continue;
        const field_type = try typeExprAlloc(std.heap.page_allocator, doc, property.spec, exclusions);
        defer std.heap.page_allocator.free(field_type);
        const field = zigFieldName(property.name);
        if (isRequired(schema_item, property.name)) {
            try w.print(
                \\        result.{s} = try parseJsonField({s}, allocator, object, "{s}", error_info);
                \\
            , .{ field, field_type, property.name });
        } else {
            try w.print(
                \\        result.{s} = try parseOptionalJsonField({s}, allocator, object, "{s}", error_info);
                \\
            , .{ field, field_type, property.name });
        }
    }

    try w.writeAll(
        \\        return result;
        \\    }
        \\
    );
    try w.writeAll("\n");
    try w.print(
        \\    pub fn clone(self: {s}, allocator: std.mem.Allocator) DecodeError!@This() {{
        \\
    , .{if (const_receiver) "*const @This()" else "@This()"});
    try w.writeAll(
        \\        const encoded = try util.encodeJsonValue(allocator, self);
        \\        defer allocator.free(encoded);
        \\        return parse(allocator, encoded);
        \\    }
        \\
        \\    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        \\
    );
    if (property_count == 0) {
        try w.writeAll(
            \\        _ = self;
            \\        _ = allocator;
            \\
        );
    } else {
        for (schema_item.properties.items) |property| {
            if (omit_discriminator and std.mem.eql(u8, property.name, "type")) continue;
            const field_type = try typeExprAlloc(std.heap.page_allocator, doc, property.spec, exclusions);
            defer std.heap.page_allocator.free(field_type);
            const field = zigFieldName(property.name);
            if (isRequired(schema_item, property.name)) {
                try w.print("        deinitJson({s}, allocator, &self.{s});\n", .{ field_type, field });
            } else {
                try w.print(
                    \\        if (self.{s}) |*value| deinitJson({s}, allocator, value);
                    \\
                , .{ field, field_type });
            }
        }
    }
    try w.writeAll(
        \\    }
        \\
    );
    try w.writeAll("\n");
    try w.print(
        \\    pub fn jsonStringify(self: {s}, jw: anytype) JsonStringifyError!void {{
        \\
    , .{if (const_receiver) "*const @This()" else "@This()"});
    if (property_count == 0) {
        try w.writeAll(
            \\        _ = self;
            \\
        );
    }
    try w.writeAll(
        \\        try jw.beginObject();
        \\
    );
    for (schema_item.properties.items) |property| {
        if (omit_discriminator and std.mem.eql(u8, property.name, "type")) continue;
        const field = zigFieldName(property.name);
        if (isRequired(schema_item, property.name)) {
            try w.print(
                \\        try jw.objectField("{s}");
                \\        try writeJson(jw, self.{s});
                \\
            , .{ property.name, field });
        } else if (const_receiver) {
            try w.print(
                \\        if (self.{s}) |*value| {{
                \\            try jw.objectField("{s}");
                \\            try writeJson(jw, value);
                \\        }}
                \\
            , .{ field, property.name });
        } else {
            try w.print(
                \\        if (self.{s}) |value| {{
                \\            try jw.objectField("{s}");
                \\            try writeJson(jw, value);
                \\        }}
                \\
            , .{ field, property.name });
        }
    }
    try w.writeAll(
        \\        try jw.endObject();
        \\    }
        \\
    );
}

fn effectivePropertyCount(schema_item: Schema, omit_discriminator: bool) usize {
    var count: usize = 0;
    for (schema_item.properties.items) |property| {
        if (omit_discriminator and std.mem.eql(u8, property.name, "type")) continue;
        count += 1;
    }
    return count;
}

fn usesConstPointerReceiver(name: []const u8) bool {
    return std.mem.eql(u8, name, "Profile") or std.mem.endsWith(u8, name, "Module");
}

fn renderUnion(w: *std.Io.Writer, doc: Document, schema_item: Schema, exclusions: SchemaExclusions) RenderError!void {
    const name = zigTypeName(schema_item.name);
    const discriminator = schema_item.discriminator_property orelse "type";
    const const_receiver = usesConstPointerReceiver(name);

    for (schema_item.variants.items) |variant| {
        if (exclusions.contains(variant.schema)) continue;
        const variant_schema = doc.schema(variant.schema) orelse return ParseError.InvalidSchema;
        if (variantValueProperty(variant_schema) == null) {
            try renderStruct(w, doc, variant_schema.*, true, exclusions);
        } else {
            const alias_name = zigTypeName(variant.schema);
            const value_property = variantValueProperty(variant_schema).?;
            const field_type = try typeExprAlloc(std.heap.page_allocator, doc, value_property.spec, exclusions);
            defer std.heap.page_allocator.free(field_type);
            try w.print("\npub const {s} = {s};\n", .{ alias_name, field_type });
        }
    }

    try w.print("\npub const {s} = union(enum) {{\n", .{name});
    for (schema_item.variants.items) |variant| {
        if (exclusions.contains(variant.schema)) continue;
        const variant_schema = doc.schema(variant.schema) orelse return ParseError.InvalidSchema;
        const payload_type = try unionPayloadType(std.heap.page_allocator, doc, variant_schema.*, exclusions);
        defer std.heap.page_allocator.free(payload_type);
        try w.print("    {s}: {s},\n", .{ zigEnumField(variant.raw), payload_type });
    }
    try w.print(
        \\
        \\    pub fn parse(allocator: std.mem.Allocator, text: []const u8) DecodeError!{s} {{
        \\        return parseWithErrorInfo(allocator, text, null);
        \\    }}
        \\
        \\    pub fn parseWithErrorInfo(allocator: std.mem.Allocator, text: []const u8, error_info: ?*JsonErrorInfo) DecodeError!{s} {{
        \\        resetJsonErrorInfo(error_info);
        \\        var parsed = try util.parseJsonValue(allocator, text);
        \\        defer parsed.deinit();
        \\        return parseValueWithErrorInfo(allocator, parsed.value, error_info);
        \\    }}
        \\
        \\    pub fn parseValue(allocator: std.mem.Allocator, value: std.json.Value) DecodeError!{s} {{
        \\        return parseValueWithErrorInfo(allocator, value, null);
        \\    }}
        \\
        \\    pub fn parseValueWithErrorInfo(allocator: std.mem.Allocator, value: std.json.Value, error_info: ?*JsonErrorInfo) DecodeError!{s} {{
        \\        resetJsonErrorInfo(error_info);
        \\        const object = objectValue(value) orelse return error.InvalidModel;
        \\        const raw_discriminator = object.get("{s}") orelse {{
        \\            setJsonErrorKey(error_info, "{s}");
        \\            return error.InvalidModel;
        \\        }};
        \\        const raw_type = stringValue(raw_discriminator) orelse {{
        \\            setJsonErrorKey(error_info, "{s}");
        \\            return error.InvalidModel;
        \\        }};
        \\
    , .{ name, name, name, name, discriminator, discriminator, discriminator });

    for (schema_item.variants.items) |variant| {
        if (exclusions.contains(variant.schema)) continue;
        const variant_schema = doc.schema(variant.schema) orelse return ParseError.InvalidSchema;
        const payload_type = try unionPayloadType(std.heap.page_allocator, doc, variant_schema.*, exclusions);
        defer std.heap.page_allocator.free(payload_type);
        if (variantValueProperty(variant_schema)) |value_property| {
            try w.print(
                \\        if (std.mem.eql(u8, raw_type, "{s}")) return .{{ .{s} = try parseJsonField({s}, allocator, object, "{s}", error_info) }};
                \\
            , .{
                variant.raw,
                zigEnumField(variant.raw),
                payload_type,
                value_property.name,
            });
        } else {
            try w.print(
                \\        if (std.mem.eql(u8, raw_type, "{s}")) return .{{ .{s} = try parseJsonWithErrorInfo({s}, allocator, value, error_info) }};
                \\
            , .{ variant.raw, zigEnumField(variant.raw), payload_type });
        }
    }
    try w.print(
        \\        setJsonErrorKey(error_info, "{s}");
        \\
    , .{discriminator});
    try w.writeAll(
        \\        return error.UnsupportedModel;
        \\    }
        \\
    );
    try w.writeAll("\n");
    try w.print(
        \\    pub fn clone(self: {s}, allocator: std.mem.Allocator) DecodeError!@This() {{
        \\
    , .{if (const_receiver) "*const @This()" else "@This()"});
    try w.writeAll(
        \\        const encoded = try util.encodeJsonValue(allocator, self);
        \\        defer allocator.free(encoded);
        \\        return parse(allocator, encoded);
        \\    }
        \\
        \\    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        \\        switch (self.*) {
        \\
    );
    for (schema_item.variants.items) |variant| {
        if (exclusions.contains(variant.schema)) continue;
        const variant_schema = doc.schema(variant.schema) orelse return ParseError.InvalidSchema;
        const payload_type = try unionPayloadType(std.heap.page_allocator, doc, variant_schema.*, exclusions);
        defer std.heap.page_allocator.free(payload_type);
        try w.print(
            \\            .{s} => |*value| deinitJson({s}, allocator, value),
            \\
        , .{ zigEnumField(variant.raw), payload_type });
    }
    try w.writeAll(
        \\        }
        \\    }
        \\
    );
    try w.writeAll("\n");
    try w.print(
        \\    pub fn jsonStringify(self: {s}, jw: anytype) JsonStringifyError!void {{
        \\        try jw.beginObject();
        \\        switch ({s}) {{
        \\
    , .{
        if (const_receiver) "*const @This()" else "@This()",
        if (const_receiver) "self.*" else "self",
    });
    for (schema_item.variants.items) |variant| {
        if (exclusions.contains(variant.schema)) continue;
        const variant_schema = doc.schema(variant.schema) orelse return ParseError.InvalidSchema;
        if (variantValueProperty(variant_schema)) |value_property| {
            try w.print(
                \\            .{s} => |{s}value| {{
                \\                try jw.objectField("{s}");
                \\                try jw.write("{s}");
                \\                try jw.objectField("{s}");
                \\                try writeJson(jw, value);
                \\            }},
                \\
            , .{
                zigEnumField(variant.raw),
                if (const_receiver) "*" else "",
                discriminator,
                variant.raw,
                value_property.name,
            });
        } else {
            const variant_property_count = effectivePropertyCount(variant_schema.*, true);
            try w.print(
                \\            .{s} => |{s}value| {{
                \\                try jw.objectField("{s}");
                \\                try jw.write("{s}");
                \\
            , .{
                zigEnumField(variant.raw),
                if (const_receiver) "*" else "",
                discriminator,
                variant.raw,
            });
            if (variant_property_count == 0) {
                try w.writeAll(
                    \\                _ = value;
                    \\
                );
            }
            for (variant_schema.properties.items) |property| {
                if (std.mem.eql(u8, property.name, discriminator)) continue;
                const field = zigFieldName(property.name);
                if (isRequired(variant_schema.*, property.name)) {
                    try w.print(
                        \\                try jw.objectField("{s}");
                        \\                try writeJson(jw, value.{s});
                        \\
                    , .{ property.name, field });
                } else {
                    try w.print(
                        \\                if (value.{s}) |inner| {{
                        \\                    try jw.objectField("{s}");
                        \\                    try writeJson(jw, inner);
                        \\                }}
                        \\
                    , .{ field, property.name });
                }
            }
            try w.writeAll("            },\n");
        }
    }
    try w.writeAll(
        \\        }
        \\        try jw.endObject();
        \\    }
        \\};
        \\
    );
}

fn unionPayloadType(allocator: std.mem.Allocator, doc: Document, schema_item: Schema, exclusions: SchemaExclusions) AllocError![]u8 {
    if (variantValueProperty(&schema_item)) |property| {
        return typeExprAlloc(allocator, doc, property.spec, exclusions);
    }
    return allocator.dupe(u8, zigTypeName(schema_item.name));
}

fn variantValueProperty(schema_item: *const Schema) ?Property {
    if (schema_item.properties.items.len != 2) return null;
    for (schema_item.properties.items) |property| {
        if (std.mem.eql(u8, property.name, "value")) return property;
    }
    return null;
}

fn aliasType(schema_item: Schema) []const u8 {
    if (std.mem.eql(u8, schema_item.name, "JSONValue")) return "RawJsonValue";
    if (integerType(schema_item.name)) |typ| return typ;
    if (schema_item.typ) |typ| {
        if (std.mem.eql(u8, typ, "string")) return "[]const u8";
        if (std.mem.eql(u8, typ, "integer")) return "i32";
        if (std.mem.eql(u8, typ, "number")) return "f64";
        if (std.mem.eql(u8, typ, "boolean")) return "bool";
        if (std.mem.eql(u8, typ, "object")) return "RawJsonValue";
    }
    return "RawJsonValue";
}

fn typeExprAlloc(allocator: std.mem.Allocator, doc: Document, spec: TypeSpec, exclusions: SchemaExclusions) AllocError![]u8 {
    return switch (spec) {
        .none, .raw_json => allocator.dupe(u8, "RawJsonValue"),
        .primitive => |primitive| allocator.dupe(u8, switch (primitive) {
            .string => "[]const u8",
            .integer => "i32",
            .number => "f64",
            .boolean => "bool",
            .object => "RawJsonValue",
        }),
        .ref => |ref| blk: {
            if (integerType(ref)) |typ| break :blk allocator.dupe(u8, typ);
            if (std.mem.eql(u8, ref, "UniqueID")) break :blk allocator.dupe(u8, "uuid.UUID");
            if (exclusions.contains(ref)) {
                break :blk std.fmt.allocPrint(allocator, "manual.{s}", .{zigTypeName(ref)});
            }
            break :blk allocator.dupe(u8, zigTypeName(ref));
        },
        .array => |child| blk: {
            const child_expr = try typeExprAlloc(allocator, doc, child.*, exclusions);
            defer allocator.free(child_expr);
            break :blk try std.fmt.allocPrint(allocator, "[]const {s}", .{child_expr});
        },
    };
}

fn defaultValueForSpec(allocator: std.mem.Allocator, doc: Document, spec: TypeSpec, exclusions: SchemaExclusions) AllocError![]const u8 {
    return switch (spec) {
        .none, .raw_json => allocator.dupe(u8, ".{}"),
        .primitive => |primitive| allocator.dupe(u8, switch (primitive) {
            .string => "\"\"",
            .integer => "0",
            .number => "0",
            .boolean => "false",
            .object => ".{}",
        }),
        .ref => |ref| blk: {
            if (std.mem.eql(u8, ref, "UniqueID")) {
                break :blk allocator.dupe(u8, "uuid.zero_id");
            }
            if (exclusions.contains(ref)) {
                break :blk try std.fmt.allocPrint(allocator, "manual.defaultValue(manual.{s})", .{zigTypeName(ref)});
            }
            if (doc.schema(ref)) |schema_item| {
                if (schema_item.enum_names.items.len > 0) {
                    break :blk allocator.dupe(u8, "undefined");
                }
                if (schema_item.variants.items.len > 0) {
                    var variant: ?Variant = null;
                    for (schema_item.variants.items) |item| {
                        if (!exclusions.contains(item.schema)) {
                            variant = item;
                            break;
                        }
                    }
                    const selected_variant = variant orelse break :blk allocator.dupe(u8, ".{}");
                    const variant_schema = doc.schema(selected_variant.schema) orelse break :blk allocator.dupe(u8, ".{}");
                    const payload_default = if (variantValueProperty(variant_schema)) |property|
                        try defaultValueForSpec(allocator, doc, property.spec, exclusions)
                    else
                        try allocator.dupe(u8, ".{}");
                    break :blk try std.fmt.allocPrint(allocator, ".{{ .{s} = {s} }}", .{
                        zigEnumField(selected_variant.raw),
                        payload_default,
                    });
                }
                if (integerType(schema_item.name) != null) {
                    break :blk allocator.dupe(u8, "0");
                }
                if (schema_item.typ) |typ| {
                    if (std.mem.eql(u8, typ, "string")) break :blk allocator.dupe(u8, "\"\"");
                    if (std.mem.eql(u8, typ, "integer")) break :blk allocator.dupe(u8, "0");
                    if (std.mem.eql(u8, typ, "number")) break :blk allocator.dupe(u8, "0");
                    if (std.mem.eql(u8, typ, "boolean")) break :blk allocator.dupe(u8, "false");
                }
            }
            break :blk allocator.dupe(u8, ".{}");
        },
        .array => allocator.dupe(u8, "&.{}"),
    };
}

fn isUniqueIDSpec(spec: TypeSpec) bool {
    return switch (spec) {
        .ref => |ref| std.mem.eql(u8, ref, "UniqueID"),
        else => false,
    };
}

fn integerType(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "UInt")) return "u32";
    if (std.mem.startsWith(u8, name, "UInt")) return integerTypeWithWidth("u", name["UInt".len..]);
    if (std.mem.startsWith(u8, name, "Int")) return integerTypeWithWidth("i", name["Int".len..]);
    return null;
}

fn integerTypeWithWidth(comptime prefix: []const u8, width: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, width, "8")) return prefix ++ "8";
    if (std.mem.eql(u8, width, "16")) return prefix ++ "16";
    if (std.mem.eql(u8, width, "32")) return prefix ++ "32";
    if (std.mem.eql(u8, width, "64")) return prefix ++ "64";
    return null;
}

fn isRequired(schema_item: Schema, property_name: []const u8) bool {
    for (schema_item.required.items) |required| {
        if (std.mem.eql(u8, required, property_name)) return true;
    }
    return false;
}

fn zigTypeName(name: []const u8) []const u8 {
    const allocator = std.heap.page_allocator;
    var buffer = allocator.alloc(u8, 128) catch @panic("out of memory");
    var len: usize = 0;
    var parts = std.mem.splitScalar(u8, name, '.');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        const first = part[0];
        buffer[len] = if (std.ascii.isLower(first)) std.ascii.toUpper(first) else first;
        len += 1;
        @memcpy(buffer[len .. len + part.len - 1], part[1..]);
        len += part.len - 1;
    }
    return buffer[0..len];
}

fn zigEnumField(raw: []const u8) []const u8 {
    const allocator = std.heap.page_allocator;
    var buffer = allocator.alloc(u8, 128) catch @panic("out of memory");
    var len: usize = 0;
    for (raw) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '_') {
            buffer[len] = byte;
            len += 1;
        }
    }
    if (len == 0) return "@\"\"";
    if (!std.ascii.isAlphabetic(buffer[0]) and buffer[0] != '_') {
        return quotedIdentifier(buffer[0..len]);
    }
    if (isZigKeyword(buffer[0..len])) return quotedIdentifier(buffer[0..len]);
    return buffer[0..len];
}

fn zigFieldName(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "withSSIDs")) return "with_ssids";
    if (std.mem.eql(u8, name, "checksEKU")) return "checks_eku";
    if (std.mem.eql(u8, name, "checksSANHost")) return "checks_san_host";
    if (std.mem.eql(u8, name, "pacURL")) return "pac_url";
    if (std.mem.eql(u8, name, "proxyAutoConfigurationURL")) return "proxy_auto_configuration_url";
    if (std.mem.eql(u8, name, "routesThroughVPN")) return "routes_through_vpn";
    if (std.mem.eql(u8, name, "inheritsVPN")) return "inherits_vpn";
    if (std.mem.eql(u8, name, "allowedIPs")) return "allowed_ips";

    const allocator = std.heap.page_allocator;
    var buffer = allocator.alloc(u8, 128) catch @panic("out of memory");
    var len: usize = 0;
    for (name, 0..) |byte, index| {
        if (std.ascii.isUpper(byte)) {
            const prev_is_lower = index > 0 and std.ascii.isLower(name[index - 1]);
            const next_is_lower = index + 1 < name.len and std.ascii.isLower(name[index + 1]);
            const prev_is_upper = index > 0 and std.ascii.isUpper(name[index - 1]);
            if (len > 0 and (prev_is_lower or (prev_is_upper and next_is_lower))) {
                buffer[len] = '_';
                len += 1;
            }
            buffer[len] = std.ascii.toLower(byte);
            len += 1;
        } else {
            buffer[len] = byte;
            len += 1;
        }
    }
    if (isZigKeyword(buffer[0..len])) return quotedIdentifier(buffer[0..len]);
    return buffer[0..len];
}

fn quotedIdentifier(name: []const u8) []const u8 {
    const allocator = std.heap.page_allocator;
    var buffer = allocator.alloc(u8, name.len + 3) catch @panic("out of memory");
    buffer[0] = '@';
    buffer[1] = '"';
    @memcpy(buffer[2 .. 2 + name.len], name);
    buffer[2 + name.len] = '"';
    return buffer[0 .. name.len + 3];
}

fn isZigKeyword(value: []const u8) bool {
    const keywords = [_][]const u8{
        "addrspace",      "align",       "allowzero", "and",       "anyframe",
        "anytype",        "asm",         "async",     "await",     "break",
        "callconv",       "catch",       "comptime",  "const",     "continue",
        "defer",          "else",        "enum",      "errdefer",  "error",
        "export",         "extern",      "fn",        "for",       "if",
        "inline",         "noalias",     "noinline",  "nosuspend", "opaque",
        "or",             "orelse",      "packed",    "pub",       "resume",
        "return",         "linksection", "struct",    "suspend",   "switch",
        "test",           "threadlocal", "try",       "union",     "unreachable",
        "usingnamespace", "var",         "volatile",  "while",
    };
    for (keywords) |keyword| {
        if (std.mem.eql(u8, value, keyword)) return true;
    }
    return false;
}

fn cleanScalar(raw: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw, " ");
    if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') {
        return trimmed[1 .. trimmed.len - 1];
    }
    return trimmed;
}

fn refName(value: []const u8) ?[]const u8 {
    const prefix = "#/components/schemas/";
    if (!std.mem.startsWith(u8, value, prefix)) return null;
    return value[prefix.len..];
}

fn stripTrailingColon(value: []const u8) []const u8 {
    return value[0 .. value.len - 1];
}

fn indentOf(line: []const u8) usize {
    var count: usize = 0;
    while (count < line.len and line[count] == ' ') : (count += 1) {}
    return count;
}
