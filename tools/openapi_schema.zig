// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
// Restricted, ordered block-YAML reader for the native model schema dialect.
const std = @import("std");
const api = @import("openapi_codegen.zig");
const Pair = struct { key: []const u8, value: Node };
const Node = union(enum) {
    scalar: []const u8,
    map: []Pair,
    list: []Node,

    fn get(n: Node, key: []const u8) ?Node {
        if (n != .map) return null;
        for (n.map) |p| if (eq(p.key, key)) return p.value;
        return null;
    }
    fn text(n: Node) ![]const u8 {
        if (n != .scalar) return error.ExpectedScalar;
        return n.scalar;
    }
};
const Line = struct { indent: usize, text: []const u8 };
const Reader = struct {
    a: std.mem.Allocator,
    lines: []Line,
    index: usize = 0,

    fn scalar(r: *Reader, raw: []const u8) !Node {
        if (raw.len == 0) return error.ExpectedScalar;
        if (raw[0] == '"') {
            const parsed = try std.json.parseFromSlice([]const u8, r.a, raw, .{ .allocate = .alloc_always });
            return .{ .scalar = parsed.value };
        }
        if (raw[0] == '\'') {
            if (raw.len < 2 or raw[raw.len - 1] != '\'') return error.InvalidQuotedScalar;
            return .{ .scalar = try std.mem.replaceOwned(u8, r.a, raw[1 .. raw.len - 1], "''", "'") };
        }
        if (std.mem.indexOfAny(u8, raw[0..1], "&*|>[{") != null) return error.UnsupportedYaml;
        return .{ .scalar = raw };
    }
    fn block(r: *Reader, indent: usize) anyerror!Node {
        const sequence = std.mem.startsWith(u8, r.lines[r.index].text, "- ");
        var pairs: std.ArrayList(Pair) = .empty;
        var items: std.ArrayList(Node) = .empty;
        while (r.index < r.lines.len and r.lines[r.index].indent >= indent) {
            const line = r.lines[r.index];
            if (line.indent != indent) return error.InvalidIndentation;
            if (std.mem.startsWith(u8, line.text, "- ") != sequence) break;
            r.index += 1;
            if (sequence) {
                const value = line.text[2..];
                if (std.mem.startsWith(u8, value, "$ref:") or std.mem.startsWith(u8, value, "\"$ref\":")) {
                    const colon = std.mem.indexOfScalar(u8, value, ':') orelse unreachable;
                    const pair = try r.a.alloc(Pair, 1);
                    pair[0] = .{ .key = "$ref", .value = try r.scalar(std.mem.trim(u8, value[colon + 1 ..], " ")) };
                    try items.append(r.a, .{ .map = pair });
                } else try items.append(r.a, try r.scalar(value));
                continue;
            }
            const colon = std.mem.indexOfScalar(u8, line.text, ':') orelse return error.ExpectedMapping;
            const key = try (try r.scalar(line.text[0..colon])).text();
            for (pairs.items) |p| if (eq(p.key, key)) return error.DuplicateSchemaKeyword;
            const raw = std.mem.trim(u8, line.text[colon + 1 ..], " ");
            const value: Node = if (raw.len != 0) try r.scalar(raw) else if (r.index < r.lines.len and
                (r.lines[r.index].indent > indent or (r.lines[r.index].indent == indent and std.mem.startsWith(u8, r.lines[r.index].text, "- "))))
                try r.block(r.lines[r.index].indent)
            else
                .{ .map = &.{} };
            try pairs.append(r.a, .{ .key = key, .value = value });
        }
        return if (sequence) .{ .list = try items.toOwnedSlice(r.a) } else .{ .map = try pairs.toOwnedSlice(r.a) };
    }
};
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn ref(n: Node) ![]const u8 {
    const raw = try n.text();
    const prefix = "#/components/schemas/";
    if (!std.mem.startsWith(u8, raw, prefix)) return error.UnsupportedReference;
    return raw[prefix.len..];
}
fn strings(a: std.mem.Allocator, node: ?Node) !std.ArrayList([]const u8) {
    var result: std.ArrayList([]const u8) = .empty;
    const n = node orelse return result;
    if (n != .list) return error.ExpectedSequence;
    for (n.list) |item| try result.append(a, try item.text());
    return result;
}
fn optionalText(node: ?Node) !?[]const u8 {
    return if (node) |n| try n.text() else null;
}
fn check(n: Node) !void {
    if (n != .map) return error.ExpectedMapping;
    if (n.get("format")) |f| {
        const format = try f.text();
        if (!eq(format, "int64") and !eq(format, "uri") and !eq(format, "uuid") and !eq(format, "byte")) return error.UnsupportedFormat;
    }
    for (n.map) |p| {
        var allowed = false;
        for ([_][]const u8{ "$ref", "type", "format", "description", "properties", "required", "enum", "x-enum-varnames", "x-enum-descriptions", "additionalProperties", "allOf", "discriminator", "const", "items", "uniqueItems", "default" }) |key| {
            if (eq(key, p.key)) allowed = true;
        }
        if (!allowed) {
            std.debug.print("Unsupported native schema keyword: {s}\n", .{p.key});
            return error.UnsupportedSchemaKeyword;
        }
    }
}
const Builder = struct {
    a: std.mem.Allocator,
    doc: api.Document = .{},
    fn inlineName(b: *Builder, parent: []const u8, child: []const u8) ![]const u8 {
        return std.fmt.allocPrint(b.a, "{s}_{s}", .{ parent, child });
    }
    fn typ(n: Node) !?[]const u8 {
        const t = n.get("type") orelse return null;
        if (t == .scalar) return t.scalar;
        if (t != .list or t.list.len != 2) return error.UnsupportedTypeUnion;
        const first = try t.list[0].text();
        const second = try t.list[1].text();
        if (eq(first, "null")) return second;
        if (eq(second, "null")) return first;
        return error.UnsupportedTypeUnion;
    }
    fn spec(b: *Builder, n: Node, inline_name: []const u8, property_context: bool) anyerror!api.TypeSpec {
        try check(n);
        if (n.get("enum") != null) return error.UnsupportedInlineEnum;
        if (!property_context) {
            if (n.get("additionalProperties") != null) return error.UnsupportedNestedMap;
            if (n.get("type")) |t| if (t == .list) return error.UnsupportedNestedNullable;
        }
        if (n.get("$ref")) |r| return .{ .ref = try ref(r) };
        if (n.get("properties") != null) {
            try b.schema(inline_name, n, true);
            return .{ .ref = inline_name };
        }
        const t = try typ(n) orelse return error.MissingType;
        if (eq(t, "array")) {
            const items = n.get("items") orelse return error.MissingItems;
            const child = try b.a.create(api.TypeSpec);
            child.* = try b.spec(items, try b.inlineName(inline_name, "inner"), false);
            return .{ .array = child };
        }
        if (eq(t, "object")) return .raw_json;
        return .{ .primitive = std.meta.stringToEnum(api.Primitive, t) orelse return error.UnsupportedSchemaType };
    }
    fn schema(b: *Builder, name: []const u8, n: Node, inline_model: bool) anyerror!void {
        try check(n);
        var s = api.Schema{ .name = name, .inline_model = inline_model };
        s.typ = try typ(n);
        s.format = try optionalText(n.get("format"));
        s.description = (try optionalText(n.get("description"))) orelse "";
        s.enum_values = try strings(b.a, n.get("enum"));
        s.enum_names = try strings(b.a, n.get("x-enum-varnames"));
        s.enum_descriptions = try strings(b.a, n.get("x-enum-descriptions"));
        s.required = try strings(b.a, n.get("required"));
        if (n.get("allOf")) |parents| {
            if (parents != .list or parents.list.len != 1) return error.UnsupportedInheritance;
            s.parent = try ref(parents.list[0].get("$ref") orelse return error.UnsupportedInheritance);
        }
        if (n.get("discriminator")) |d| {
            if (d != .map or d.map.len != 2) return error.UnsupportedDiscriminator;
            s.discriminator_property = try (d.get("propertyName") orelse return error.MissingDiscriminator).text();
            const mapping = d.get("mapping") orelse return error.MissingDiscriminator;
            if (mapping != .map) return error.UnsupportedDiscriminator;
            for (mapping.map) |p| try s.variants.append(b.a, .{ .raw = p.key, .schema = try ref(p.value) });
        }
        if (n.get("additionalProperties")) |additional| {
            if (additional != .scalar or !eq(additional.scalar, "false")) return error.UnsupportedAdditionalProperties;
        }
        if (n.get("properties")) |properties| {
            if (properties != .map) return error.ExpectedMapping;
            for (properties.map) |entry| {
                const p = entry.value;
                var property = api.Property{ .name = entry.key, .spec = try b.spec(p, try b.inlineName(name, entry.key), true) };
                if (p.get("type")) |t| property.nullable = t == .list;
                property.description = (try optionalText(p.get("description"))) orelse "";
                property.format = try optionalText(p.get("format"));
                property.constant = try optionalText(p.get("const"));
                property.default_value = try optionalText(p.get("default"));
                if (p.get("uniqueItems")) |u| {
                    const v = try u.text();
                    if (!eq(v, "true") and !eq(v, "false")) return error.InvalidUniqueItems;
                    property.unique = eq(v, "true");
                }
                if (p.get("additionalProperties")) |value| {
                    if (value != .map) return error.UnsupportedAdditionalProperties;
                    property.map_value = try b.spec(value, try b.inlineName(name, entry.key), false);
                }
                try s.properties.append(b.a, property);
            }
        }
        try b.doc.schemas.append(b.a, s);
    }
};
pub fn parse(a: std.mem.Allocator, input: []const u8) !api.Document {
    var lines: std.ArrayList(Line) = .empty;
    var it = std.mem.splitScalar(u8, input, '\n');
    var found = false;
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const text = std.mem.trimStart(u8, line, " ");
        const indent = line.len - text.len;
        if (eq(line, "  schemas:")) {
            found = true;
            continue;
        }
        if (!found or text.len == 0) continue;
        if (indent < 4) break;
        if (indent % 2 != 0 or std.mem.indexOfScalar(u8, line, '\t') != null) return error.InvalidIndentation;
        try lines.append(a, .{ .indent = indent, .text = text });
    }
    if (!found or lines.items.len == 0) return error.ExpectedSchemas;
    var reader = Reader{ .a = a, .lines = lines.items };
    const schemas = try reader.block(4);
    if (reader.index != lines.items.len or schemas != .map) return error.InvalidSchema;
    var builder = Builder{ .a = a };
    for (schemas.map) |p| try builder.schema(p.key, p.value, false);
    return builder.doc;
}

test "inline schemas, indentless sequences, nullable values and defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc = try parse(arena.allocator(),
        \\components:
        \\  schemas:
        \\    Sample:
        \\      type: object
        \\      properties:
        \\        nested:
        \\          type: object
        \\          properties:
        \\            count:
        \\              type: integer
        \\              default: 0
        \\          required:
        \\          - count
        \\        age:
        \\          type:
        \\          - number
        \\          - 'null'
        \\      required:
        \\      - nested
    );
    const nested = doc.schema("Sample_nested") orelse return error.MissingInlineModel;
    try std.testing.expect(nested.inline_model);
    try std.testing.expectEqualStrings("count", nested.required.items[0]);
    try std.testing.expectEqualStrings("0", nested.properties.items[0].default_value orelse return error.MissingDefault);
    const root = doc.schema("Sample") orelse return error.MissingSchema;
    try std.testing.expectEqualStrings("Sample_nested", root.properties.items[0].spec.ref);
    try std.testing.expectEqual(api.Primitive.number, root.properties.items[1].spec.primitive);
}

test "unknown constraints and duplicate keys fail instead of being ignored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnsupportedSchemaKeyword, parse(arena.allocator(),
        \\components:
        \\  schemas:
        \\    Sample:
        \\      type: object
        \\      properties:
        \\        field:
        \\          type: string
        \\          minLength: 3
    ));
    try std.testing.expectError(error.DuplicateSchemaKeyword, parse(arena.allocator(),
        \\components:
        \\  schemas:
        \\    Sample:
        \\      type: string
        \\      type: integer
    ));
}
