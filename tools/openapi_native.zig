// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
const std = @import("std");
const api = @import("openapi_codegen.zig");

pub const Language = enum { zig, swift, kotlin, cpp };
const File = struct { name: []const u8, contents: []const u8 };
const Context = struct {
    a: std.mem.Allocator,
    doc: api.Document,
    language: Language,
    package: []const u8,

    fn fmt(c: Context, comptime format: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(c.a, format, args);
    }

    fn name(c: Context, raw: []const u8) ![]const u8 {
        if (eq(raw, "Profile")) return "TaggedProfile";
        var out: std.Io.Writer.Allocating = .init(c.a);
        var upper = true;
        for (raw) |ch| {
            if (ch == '.') {
                upper = c.language != .kotlin;
                continue;
            }
            try out.writer.writeByte(if (upper) std.ascii.toUpper(ch) else ch);
            upper = false;
        }
        var result: []const u8 = out.written();
        if (c.language == .cpp) {
            // PARITY: legacy C++ acronym spelling. Remove with an API migration.
            result = try replace(c.a, result, "OpenVPN", "OpenVpn");
            result = try replace(c.a, result, "TaggedModuleDNS", "TaggedModuleDns");
            result = try replace(c.a, result, "TaggedModuleIP", "TaggedModuleIp");
            // Standalone OpenVPN-prefixed schemas did not contain a separating dot.
            if (eq(raw, "OpenVPNModule") or eq(raw, "OpenVPNErrorCode")) return raw;
        }
        return result;
    }

    fn typ(c: Context, spec: api.TypeSpec, format: ?[]const u8, unique: bool) anyerror![]const u8 {
        switch (spec) {
            .ref => |raw| {
                if (c.language == .swift) {
                    if (eq(raw, "JSONValue")) return "JSON";
                    // PARITY: the old Swift generator prefixes these mapped aliases.
                    if (eq(raw, "UInt16") or eq(raw, "UInt32") or eq(raw, "UInt64")) return c.fmt("Model{s}", .{raw});
                    if (swiftManual(raw)) return c.name(raw);
                }
                if (eq(raw, "JSONValue")) return if (c.language == .kotlin) "kotlinx.serialization.json.JsonElement" else "nlohmann::json";
                const schema = c.doc.schema(raw) orelse return error.UnknownReference;
                if (schema.enum_values.items.len != 0 or schema.properties.items.len != 0 or schema.variants.items.len != 0) {
                    const n = try c.name(raw);
                    return if (c.language == .cpp) c.fmt("{s}::{s}", .{ c.package, n }) else n;
                }
                const primitive = std.meta.stringToEnum(api.Primitive, schema.typ orelse return error.MissingType) orelse return error.UnsupportedSchemaType;
                if (primitive == .object) return c.typ(.raw_json, null, false);
                return c.typ(.{ .primitive = primitive }, schema.format, false);
            },
            .array => |child| {
                const t = try c.typ(child.*, null, false);
                return switch (c.language) {
                    .swift => if (unique) c.fmt("Set<{s}>", .{t}) else c.fmt("[{s}]", .{t}),
                    .kotlin => c.fmt("kotlin.collections.{s}<{s}>", .{ if (unique) "Set" else "List", if (contextual(c, child.*)) try c.fmt("@Contextual {s}", .{t}) else t }),
                    .cpp => c.fmt("std::vector<{s}>", .{t}),
                    else => unreachable,
                };
            },
            .primitive => |p| return switch (p) {
                .string => switch (c.language) {
                    .swift => if (eq(format orelse "", "uri")) "URL" else "String",
                    .kotlin => "kotlin.String",
                    .cpp => "std::string",
                    else => unreachable,
                },
                .integer => switch (c.language) {
                    .swift => if (eq(format orelse "", "int64")) "Int64" else "Int",
                    .kotlin => if (eq(format orelse "", "int64")) "kotlin.Long" else "kotlin.Int",
                    .cpp => if (eq(format orelse "", "int64")) "int64_t" else "int32_t",
                    else => unreachable,
                },
                .number => if (c.language == .cpp) "double" else if (c.language == .kotlin) "kotlin.Double" else "Double",
                .boolean => if (c.language == .cpp) "bool" else if (c.language == .kotlin) "kotlin.Boolean" else "Bool",
                .object => return error.UnsupportedObject,
            },
            .raw_json => return if (c.language == .swift) "JSON" else if (c.language == .kotlin) "kotlinx.serialization.json.JsonElement" else "nlohmann::json",
            .none => return error.MissingType,
        }
    }
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn replace(a: std.mem.Allocator, source: []const u8, from: []const u8, to: []const u8) ![]const u8 {
    return std.mem.replaceOwned(u8, a, source, from, to);
}

fn required(s: api.Schema, name: []const u8) bool {
    for (s.required.items) |r| {
        if (eq(r, name)) return true;
    }
    return false;
}

fn swiftManual(raw: []const u8) bool {
    for ([_][]const u8{ "Address", "DNSModule.ProtocolType", "Endpoint", "EndpointProtocol", "ExtendedEndpoint", "ModuleImportContext", "Subnet", "UniqueID", "UInt16", "UInt32", "UInt64", "SecureData", "TaggedModule", "OpenVPN.CryptoContainer", "OpenVPN.ObfuscationMethod", "WireGuard.Key" }) |manual| {
        if (eq(raw, manual)) return true;
    }
    return false;
}

fn field(c: Context, raw: []const u8) ![]const u8 {
    if (c.language == .swift and eq(raw, "type")) return "type";
    if (c.language == .cpp and eq(raw, "interface")) return "interface_";
    if (c.language == .kotlin and (eq(raw, "value") or eq(raw, "interface") or eq(raw, "data"))) return c.fmt("`{s}`", .{raw});
    return raw;
}

fn literal(c: Context, raw: []const u8, numeric: bool) ![]const u8 {
    if (numeric) return raw;
    return std.json.Stringify.valueAlloc(c.a, raw, .{});
}

pub fn generate(a: std.mem.Allocator, io: std.Io, doc: api.Document, language: Language, directory: []const u8, package: ?[]const u8) !void {
    const c = Context{ .a = a, .doc = doc, .language = language, .package = package orelse if (language == .cpp) "Partout::Models" else "io.partout.models" };
    try validateDocument(c);
    var files: std.ArrayList(File) = .empty;
    for (doc.schemas.items) |s| {
        if (language == .swift and swiftManual(s.name)) continue;
        if (s.enum_values.items.len == 0 and s.properties.items.len == 0 and s.variants.items.len == 0) continue;
        const n = try c.name(s.name);
        switch (language) {
            .swift => try files.append(a, .{ .name = try c.fmt("{s}.swift", .{n}), .contents = try swift(c, s) }),
            .kotlin => try files.append(a, .{ .name = try c.fmt("{s}.kt", .{n}), .contents = try kotlin(c, s) }),
            .cpp => {
                try files.append(a, .{ .name = try c.fmt("{s}.h", .{n}), .contents = try cppHeader(c, s) });
                if (s.variants.items.len == 0) try files.append(a, .{ .name = try c.fmt("{s}.cpp", .{n}), .contents = try cppSource(c, s) });
            },
            .zig => unreachable,
        }
    }
    if (language == .cpp) {
        try files.append(a, .{ .name = "Helpers.h", .contents = @embedFile("openapi_templates/Helpers.h") });
        try files.append(a, .{ .name = "Helpers.cpp", .contents = @embedFile("openapi_templates/Helpers.cpp") });
    }
    // Render and check every filename before touching the destination.
    for (files.items, 0..) |f, i| {
        for (files.items[0..i]) |previous| {
            if (std.ascii.eqlIgnoreCase(f.name, previous.name)) return error.FilenameCollision;
        }
    }
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, directory);
    for (files.items) |f| {
        try cwd.writeFile(io, .{ .sub_path = try c.fmt("{s}/{s}", .{ directory, f.name }), .data = f.contents });
    }
}

fn swift(c: Context, s: api.Schema) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(c.a);
    const w = &out.writer;
    const n = try c.name(s.name);
    // PARITY: preserve legacy attribution/whitespace until the migration is complete.
    try w.print("//\n// {s}.swift\n//\n// Generated by openapi-generator\n// https://openapi-generator.tech\n//\n\n", .{n});
    // PARITY: legacy inheritance models lose their descriptions. Restore after parity.
    if (s.description.len != 0 and s.parent == null) try w.print("/** {s} */\n", .{s.description});
    if (s.enum_values.items.len != 0) {
        const numeric = eq(s.typ orelse "", "integer");
        try w.print("public enum {s}: {s}, Sendable, Codable, CaseIterable {{\n", .{ n, if (numeric) "Int" else "String" });
        for (s.enum_values.items, 0..) |v, i| {
            if (i < s.enum_descriptions.items.len) try w.print("    /** {s} */\n", .{s.enum_descriptions.items[i]});
            try w.print("    case {s} = {s}\n", .{ s.enum_names.items[i], try literal(c, v, numeric) });
        }
        try w.writeAll("}\n");
        return out.toOwnedSlice();
    }
    try w.print("public struct {s}: Sendable, Codable, Hashable {{\n", .{n});
    // PARITY: legacy validation-rule removal eats this blank line for sets.
    var has_set = false;
    for (s.properties.items) |p| {
        if (p.unique) has_set = true;
    }
    if (!has_set) try w.writeByte('\n');
    for (s.properties.items) |p| {
        if (p.constant) |constant| {
            try w.print("    public enum ModelType: String, Sendable, Codable, CaseIterable {{\n        case {s} = {s}\n    }}\n", .{ try lowerFirst(c, constant), try literal(c, constant, false) });
        }
        if (p.description.len != 0) try w.print("    /** {s} */\n", .{p.description});
        try w.print("    public var {s}: {s}{s}\n", .{ try field(c, p.name), if (p.constant != null) "ModelType" else try propertyType(c, p), if (required(s, p.name)) "" else "?" });
    }
    try w.writeAll("\n    public init(");
    for (s.properties.items, 0..) |p, i| {
        if (i != 0) try w.writeAll(", ");
        try w.print("{s}: {s}{s}", .{ try field(c, p.name), if (p.constant != null) "ModelType" else try propertyType(c, p), if (required(s, p.name)) "" else "? = nil" });
    }
    try w.writeAll(") {\n");
    for (s.properties.items) |p| try w.print("        self.{s} = {s}\n", .{ try field(c, p.name), try field(c, p.name) });
    try w.writeAll("    }\n}\n\n");
    return out.toOwnedSlice();
}

fn lowerFirst(c: Context, raw: []const u8) ![]const u8 {
    const result = try c.a.dupe(u8, raw);
    if (eq(raw, "HTTPProxy")) return "httpproxy"; // PARITY: legacy inline enum casing.
    var all_upper = true;
    for (raw) |ch| {
        if (std.ascii.isLower(ch)) all_upper = false;
    }
    if (all_upper) {
        for (result) |*ch| ch.* = std.ascii.toLower(ch.*);
    } else if (result.len != 0) result[0] = std.ascii.toLower(result[0]);
    return result;
}

fn kotlin(c: Context, s: api.Schema) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(c.a);
    const w = &out.writer;
    const n = try c.name(s.name);
    try w.writeAll(@embedFile("openapi_templates/kotlin-header.txt"));
    try w.print("package {s}\n\n", .{c.package});
    if (s.enum_values.items.len != 0) {
        try kotlinEnum(c, s, n, w);
        return out.toOwnedSlice();
    }
    var props: std.ArrayList(api.Property) = .empty;
    // PARITY: Kotlin puts required constructor arguments first, preserving order within each group.
    for ([_]bool{ true, false }) |req| {
        for (s.properties.items) |p| {
            if (s.variants.items.len != 0 or (s.parent != null and p.constant != null)) continue;
            if (required(s, p.name) == req) {
                var property = p;
                // PARITY: Kotlin inherits descriptions only from primitive aliases.
                if (p.description.len == 0 and p.spec == .ref) {
                    const ref = c.doc.schema(p.spec.ref) orelse return error.UnknownReference;
                    if (ref.enum_values.items.len == 0 and ref.properties.items.len == 0) property.description = ref.description;
                }
                try props.append(c.a, property);
            }
        }
    }
    var imports: std.ArrayList([]const u8) = .empty;
    for (props.items) |p| try kotlinImports(c, p.spec, &imports);
    if (s.parent) |parent| try appendUnique(c.a, &imports, try c.name(parent));
    std.mem.sort([]const u8, imports.items, {}, less);
    for (imports.items) |imp| try w.print("import {s}.{s}\n", .{ c.package, imp });
    try w.writeAll("\nimport kotlinx.serialization.Serializable\nimport kotlinx.serialization.SerialName\nimport kotlinx.serialization.Contextual\n");
    if (s.variants.items.len != 0) try w.writeAll("import kotlinx.serialization.ExperimentalSerializationApi\nimport kotlinx.serialization.json.JsonClassDiscriminator\n");
    try w.print("\n/**\n * {s}\n *\n", .{if (s.parent == null) s.description else ""});
    for (props.items) |p| try w.print(" * @param {s} {s}\n", .{ try field(c, p.name), p.description });
    try w.writeAll(" */\n@Serializable\n\n");
    if (s.variants.items.len != 0) {
        try w.print("\n@OptIn(ExperimentalSerializationApi::class)\n@JsonClassDiscriminator(discriminator = \"{s}\")\nsealed class {s} {{\n\n\n}}\n\n", .{ s.discriminator_property orelse return error.MissingDiscriminator, n });
        return out.toOwnedSlice();
    }
    if (s.parent) |parent| {
        const base = c.doc.schema(parent) orelse return error.UnknownReference;
        for (base.variants.items) |v| {
            if (eq(v.schema, s.name)) try w.print("@SerialName(value = {s})\n", .{try literal(c, v.raw, false)});
        }
    }
    try w.print("{s}class {s} (\n", .{ if (props.items.len == 0) "" else "data ", n });
    for (props.items, 0..) |p, i| {
        try w.writeByte('\n');
        if (p.description.len != 0) try w.print("    /* {s} */\n", .{p.description});
        const t = try propertyType(c, p);
        const is_contextual = p.map_value == null and contextual(c, p.spec);
        try w.print("    {s}@SerialName(value = \"{s}\")\n    val {s}: {s}{s}{s}\n", .{ if (is_contextual) "@Contextual " else "", p.name, try field(c, p.name), t, if (required(s, p.name)) "" else "? = null", if (i + 1 == props.items.len) "" else "," });
    }
    try w.writeAll("\n)");
    if (s.parent) |parent| try w.print(" : {s}()", .{try c.name(parent)});
    try w.writeAll(" {\n\n\n}\n\n");
    return out.toOwnedSlice();
}

fn appendUnique(a: std.mem.Allocator, list: *std.ArrayList([]const u8), value: []const u8) !void {
    for (list.items) |existing| {
        if (eq(existing, value)) return;
    }
    try list.append(a, value);
}
fn less(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
fn kotlinImports(c: Context, spec: api.TypeSpec, imports: *std.ArrayList([]const u8)) anyerror!void {
    switch (spec) {
        .array => |child| try kotlinImports(c, child.*, imports),
        .ref => {
            const t = try c.typ(spec, null, false);
            if (std.mem.indexOfScalar(u8, t, '.') == null) try appendUnique(c.a, imports, t);
        },
        else => {},
    }
}

fn kotlinEnum(c: Context, s: api.Schema, n: []const u8, w: *std.Io.Writer) !void {
    const numeric = eq(s.typ orelse "", "integer");
    const t = if (numeric) "kotlin.Int" else "kotlin.String";
    try w.writeAll("\nimport kotlinx.serialization.SerialName\nimport kotlinx.serialization.Serializable\n\n");
    if (numeric) try w.writeAll(@embedFile("openapi_templates/kotlin-numeric-imports.txt"));
    try w.print("\n/**\n * {s}\n *\n * Values: ", .{s.description});
    for (s.enum_names.items, 0..) |en, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll(en);
    }
    try w.writeAll("\n */\n");
    if (numeric) try w.print("@Serializable(with = {s}Serializer::class)\n", .{n}) else try w.writeAll("@Serializable\n");
    try w.print("enum class {s}(val value: {s}) {{\n", .{ n, t });
    for (s.enum_values.items, 0..) |v, i| {
        try w.writeByte('\n');
        if (i < s.enum_descriptions.items.len) try w.print("    /**\n     * {s}\n     */\n", .{try html(c, s.enum_descriptions.items[i])}); // PARITY: legacy enum doc HTML escaping.
        if (!numeric) try w.print("    @SerialName(value = {s})\n", .{try literal(c, v, false)});
        try w.print("    {s}({s}){s}\n", .{ s.enum_names.items[i], try literal(c, v, numeric), if (i + 1 == s.enum_values.items.len) ";" else "," });
    }
    var tail = try replace(c.a, @embedFile("openapi_templates/kotlin-enum-tail.txt"), "@NAME@", n);
    tail = try replace(c.a, tail, "@VALUE@", if (numeric) "value.toString()" else "value");
    try w.writeAll(tail);
    if (numeric) try w.writeAll(try replace(c.a, @embedFile("openapi_templates/kotlin-serializer.txt"), "@NAME@", n));
    try w.writeAll("\n\n");
}

fn contextual(c: Context, spec: api.TypeSpec) bool {
    // PARITY: the Kotlin backend marks enums/raw JSON contextual, not objects.
    return switch (spec) {
        .ref => |raw| if (c.doc.schema(raw)) |s| s.enum_values.items.len != 0 or eq(raw, "JSONValue") else false,
        .raw_json => true,
        else => false,
    };
}
fn propertyType(c: Context, p: api.Property) ![]const u8 {
    if (p.map_value) |value| {
        const t = try c.typ(value, null, false);
        return switch (c.language) {
            .swift => c.fmt("[String: {s}]", .{t}),
            .kotlin => c.fmt("kotlin.collections.Map<kotlin.String, {s}>", .{t}),
            .cpp => c.fmt("std::map<std::string, {s}>", .{t}),
            else => unreachable,
        };
    }
    return c.typ(p.spec, p.format, p.unique);
}

fn template(c: Context, raw: []const u8, n: []const u8) ![]const u8 {
    const named = try replace(c.a, raw, "@NAME@", n);
    return replace(c.a, named, "Partout::Models", c.package);
}

fn cppHeader(c: Context, s: api.Schema) ![]const u8 {
    if (s.variants.items.len != 0) return cppUnion(c, s);
    var out: std.Io.Writer.Allocating = .init(c.a);
    const w = &out.writer;
    const n = try c.name(s.name);
    const is_enum = s.enum_values.items.len != 0;
    try w.writeAll(@embedFile("openapi_templates/cpp-banner.txt"));
    try w.print("/*\n * {s}.h\n *\n *{s}{s}\n */\n\n#ifndef {s}_H_\n#define {s}_H_\n\n", .{ n, if (s.description.len != 0) " " else "", try html(c, s.description), n, n });
    var imports: std.ArrayList([]const u8) = .empty;
    if (!is_enum) for (s.properties.items) |p| {
        if (p.map_value != null) {
            try appendUnique(c.a, &imports, "#include <map>");
            try appendUnique(c.a, &imports, "#include <string>");
        } else try cppImports(c, p.spec, &imports);
    };
    // PARITY: old HashSet iteration order. Replace with lexical imports after parity.
    var capacity: u32 = 16;
    while (imports.items.len > capacity * 3 / 4) capacity *= 2;
    std.mem.sort([]const u8, imports.items, capacity, importLess);
    for (imports.items) |imp| try w.print("{s}\n", .{imp});
    try w.writeAll("#include \"../json.h\"\n");
    var optional = false;
    for (s.properties.items) |p| {
        if (!required(s, p.name)) optional = true;
    }
    if (optional) try w.writeAll("#include <optional>\n");
    try w.print("\nnamespace {s}\n{{\n\nstruct  {s}\n{{\n\n", .{ c.package, n });
    if (is_enum) {
        try w.writeAll(try template(c, @embedFile("openapi_templates/cpp-enum-prefix.txt"), n));
        for (s.enum_names.items, 0..) |en, i| try w.print("        {s}{s}\n", .{ en, if (i + 1 == s.enum_names.items.len) "" else "," });
        try w.print("    }};\n\n    {s}::e{s} value = {s}::e{s}::INVALID_VALUE_OPENAPI_GENERATED;\n\n", .{ n, n, n, n });
    } else {
        for (s.properties.items) |p| {
            const t = try propertyType(c, p);
            const f = try field(c, p.name);
            if (required(s, p.name)) {
                try w.print("    {s} {s}", .{ t, f });
            } else {
                try w.print("    std::optional<{s}> {s}", .{ t, f });
            }
            if (p.constant) |constant| try w.print(" = {s}", .{try literal(c, constant, false)});
            try w.writeAll(";\n");
        }
        try w.writeByte('\n');
    }
    try w.writeAll(try template(c, @embedFile("openapi_templates/cpp-header-tail.txt"), n));
    return cppWhitespace(c, out.written());
}

fn javaHash(raw: []const u8) u32 {
    var h: u32 = 0;
    for (raw) |ch| h = h *% 31 +% ch;
    return h ^ (h >> 16);
}
fn importLess(capacity: u32, a: []const u8, b: []const u8) bool {
    const ah = javaHash(a) & (capacity - 1);
    const bh = javaHash(b) & (capacity - 1);
    return if (ah == bh) less({}, a, b) else ah < bh;
}
fn cppImports(c: Context, spec: api.TypeSpec, imports: *std.ArrayList([]const u8)) anyerror!void {
    switch (spec) {
        .array => |child| {
            try cppImports(c, child.*, imports);
            try appendUnique(c.a, imports, "#include <vector>");
        },
        else => {
            const t = try c.typ(spec, null, false);
            if (eq(t, "std::string")) {
                try appendUnique(c.a, imports, "#include <string>");
            } else if (eq(t, "nlohmann::json")) {
                // PARITY: the legacy pipeline emits a duplicate JSON include.
                try appendUnique(c.a, imports, "#include <nlohmann/json.hpp>");
            } else if (std.mem.startsWith(u8, t, c.package)) {
                try appendUnique(c.a, imports, try c.fmt("#include \"{s}.h\"", .{t[c.package.len + 2 ..]}));
            }
        },
    }
}

fn cppSource(c: Context, s: api.Schema) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(c.a);
    const w = &out.writer;
    const n = try c.name(s.name);
    const is_enum = s.enum_values.items.len != 0;
    const numeric = eq(s.typ orelse "", "integer");
    try w.writeAll(@embedFile("openapi_templates/cpp-banner.txt"));
    try w.writeByte('\n');
    try w.writeAll(try template(c, @embedFile("openapi_templates/cpp-source-prefix.txt"), n));
    if (is_enum) {
        try w.print("\n    if (value == {s}::e{s}::INVALID_VALUE_OPENAPI_GENERATED)\n    {{\n        success = false;\n        msg << _pathPrefix << \": has no value;\";\n    }}\n", .{ n, n });
    } else {
        for (s.properties.items) |p| {
            if (p.spec == .array) try cppArrayValidation(c, s, p, w);
        }
    }
    try w.print("\n    return success;\n}}\n\nbool {s}::operator==(const {s}& other) const\n{{\n    return\n", .{ n, n });
    if (is_enum) {
        try w.writeAll("    value == other.value\n    ;\n");
    } else {
        try w.writeAll("\n    ");
        for (s.properties.items, 0..) |p, i| {
            if (i != 0) try w.writeAll(" && ");
            const f = try field(c, p.name);
            try w.print("{s} == other.{s}", .{ f, f });
        }
        if (s.properties.items.len == 0) try w.writeAll("true");
        try w.writeAll(";\n");
    }
    try w.print("}}\n\nbool {s}::operator!=(const {s}& other) const\n{{\n    return !(*this == other);\n}}\n\nvoid to_json(nlohmann::json& j, const {s}& o)\n{{\n", .{ n, n, n });
    for (s.properties.items) |p| {
        if (p.constant) |constant| try w.print("    if (o.{s} != {s}) throw std::invalid_argument(\"Invalid constant field {s} in {s}\");\n", .{ try field(c, p.name), try literal(c, constant, false), p.name, n });
    }
    try w.writeAll("    j = nlohmann::json::object();\n");
    if (is_enum) {
        try w.print("\n    switch (o.value)\n    {{\n    case {s}::e{s}::INVALID_VALUE_OPENAPI_GENERATED:\n        j = {s};\n        break;\n", .{ n, n, if (numeric) "0" else "\"INVALID_VALUE_OPENAPI_GENERATED\"" });
        for (s.enum_values.items, 0..) |v, i| try w.print("    case {s}::e{s}::{s}:\n        j = {s};\n        break;\n", .{ n, n, s.enum_names.items[i], try literal(c, v, numeric) });
        try w.writeAll("    }\n");
    } else {
        for (s.properties.items) |p| {
            const f = try field(c, p.name);
            if (required(s, p.name)) {
                try w.print("\n        j[\"{s}\"] = o.{s};\n", .{ p.name, f });
            } else {
                try w.print("    if (o.{s}.has_value())\n        j[\"{s}\"] = o.{s}.value();\n", .{ f, p.name, f });
            }
        }
        try w.writeByte('\n');
    }
    try w.print("}}\n\nvoid from_json(const nlohmann::json& j, {s}& o)\n{{\n", .{n});
    if (!is_enum) try w.print("    if (!j.is_object()) throw std::invalid_argument(\"Expected {s} object\");\n", .{n});
    for (s.properties.items) |p| {
        if (p.constant) |constant| try w.print("    if (j.at(\"{s}\") != {s}) throw std::invalid_argument(\"Invalid constant field {s} in {s}\");\n", .{ p.name, try literal(c, constant, false), p.name, n });
    }
    try w.print("    {s} parsed{{}};\n", .{n});
    if (is_enum) {
        try w.writeAll(if (numeric) "\n    int32_t s;\n    ReadJsonValue(j, s);\n" else "\n    auto s = j.get<std::string>();\n");
        for (s.enum_values.items, 0..) |v, i| {
            try w.print("    {s}if(s == {s}) {{\n        parsed.value = {s}::e{s}::{s};\n    }}", .{ if (i == 0) "" else "else ", try literal(c, v, numeric), n, n, s.enum_names.items[i] });
            if (i + 1 != s.enum_values.items.len) try w.writeByte('\n');
        }
        try w.print("  else {{\n        std::stringstream ss;\n        ss << \"Unexpected value \" << s << \" in json\"\n           << \" cannot be converted to enum of type\"\n           << \" {s}::e{s}\";\n        throw std::invalid_argument(ss.str());\n    }}\n\n", .{ n, n });
    } else {
        for (s.properties.items) |p| {
            const f = try field(c, p.name);
            if (required(s, p.name)) {
                try w.print("    ReadJsonValue(j.at(\"{s}\"), parsed.{s});\n\n", .{ p.name, f });
            } else {
                const t = try propertyType(c, p);
                if (eq(t, "nlohmann::json")) {
                    try w.print("\n    if (j.find(\"{s}\") != j.end()) {{\n", .{p.name});
                } else {
                    try w.print("\n    if (j.find(\"{s}\") != j.end() && !j.at(\"{s}\").is_null()) {{\n", .{ p.name, p.name });
                }
                try w.print("        {s} temporary_{s};\n        ReadJsonValue(j.at(\"{s}\"), temporary_{s});\n        parsed.{s} = std::move(temporary_{s});\n    }}\n", .{ t, f, p.name, f, f, f });
            }
        }
        try w.writeByte('\n');
    }
    try w.print("    o = std::move(parsed);\n}}\n\n}} // namespace {s}\n\n", .{c.package});
    return cppWhitespace(c, out.written());
}

fn cppArrayValidation(c: Context, s: api.Schema, p: api.Property, w: *std.Io.Writer) !void {
    const f = try field(c, p.name);
    const t = try propertyType(c, p);
    const child = p.spec.array.*;
    const element = try c.typ(child, null, false);
    if (required(s, p.name)) {
        try w.print("\n    /* {s} */ {{\n        const {s}& value = {s};\n", .{ f, t, f });
    } else {
        try w.print("\n    if ({s}.has_value())\n    {{\n        const {s}& value = {s}.value();\n", .{ f, t, f });
    }
    try w.print("        const std::string currentValuePath = _pathPrefix + \".{s}\";\n\n", .{f});
    if (p.unique) try w.writeAll("        if (!Partout::Helpers::hasOnlyUniqueItems(value))\n        {\n            success = false;\n            msg << currentValuePath << \": may not contain the same item more than once;\";\n        }\n");
    try w.print("        {{ // Recursive validation of array elements\n            const std::string oldValuePath = currentValuePath;\n            int i = 0;\n            for (const {s}& value : value)\n            {{\n                const std::string currentValuePath = oldValuePath + \"[\" + std::to_string(i) + \"]\";\n\n", .{element});
    if (std.mem.startsWith(u8, element, c.package)) {
        const ref = if (child == .ref) c.doc.schema(child.ref) else null;
        const suffix = if (ref) |r| if (r.enum_values.items.len != 0) "" else try c.fmt(" + \".{s}\"", .{f}) else "";
        // PARITY: legacy validation omits scalar models and repeats array field paths.
        try w.print("        success = ValidateModel(value, msg, currentValuePath{s}) && success;\n\n", .{suffix});
    }
    try w.writeAll("                i++;\n            }\n        }\n\n    }\n");
}

fn cppWhitespace(c: Context, source: []const u8) ![]const u8 {
    var result = try replace(c.a, source, "#include <nlohmann/json.hpp>", "#include \"../json.h\"");
    while (std.mem.indexOf(u8, result, "\n\n\n") != null) result = try replace(c.a, result, "\n\n\n", "\n\n");
    return result;
}

fn cppUnion(c: Context, s: api.Schema) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(c.a);
    const w = &out.writer;
    const n = try c.name(s.name);
    const discriminator = s.discriminator_property orelse return error.MissingDiscriminator;
    const variants = try c.a.dupe(api.Variant, s.variants.items);
    std.mem.sort(api.Variant, variants, {}, struct {
        fn lessVariant(_: void, a: api.Variant, b: api.Variant) bool {
            return less({}, a.schema, b.schema);
        }
    }.lessVariant);
    try w.writeAll(@embedFile("openapi_templates/cpp-union-prefix.txt"));
    for (variants) |v| try w.print("#include \"{s}.h\"\n", .{try c.name(v.schema)});
    // PARITY: httplib leaked imports from the last discriminator child into its parent.
    if (variants.len != 0) {
        const last = c.doc.schema(variants[variants.len - 1].schema) orelse return error.UnknownReference;
        for (last.properties.items) |p| {
            if (p.spec != .ref) continue;
            const ref = c.doc.schema(p.spec.ref) orelse return error.UnknownReference;
            if (ref.properties.items.len != 0) try w.print("#include \"{s}.h\"\n", .{try c.name(ref.name)});
        }
    }
    try w.print("\nnamespace {s} {{\n\n// oneOf schema - type alias for std::variant\nusing {s} = std::variant<\n", .{ c.package, n });
    for (variants, 0..) |v, i| try w.print("    {s}{s}\n", .{ try c.name(v.schema), if (i + 1 == variants.len) ">;" else "," });
    try w.print("\n// JSON serialization functions (inline for header-only)\ninline void from_json(const nlohmann::json& j, {s}& obj) {{\n    if (!j.contains(\"{s}\")) {{\n        throw nlohmann::json::type_error::create(302, \"Discriminator property '{s}' not found in JSON\", &j);\n    }}\n    std::string discriminatorValue = j[\"{s}\"].get<std::string>();\n", .{ n, discriminator, discriminator, discriminator });
    std.mem.sort(api.Variant, variants, {}, struct {
        fn lessVariant(_: void, a: api.Variant, b: api.Variant) bool {
            return less({}, a.raw, b.raw);
        }
    }.lessVariant);
    for (variants) |v| try w.print("    if (discriminatorValue == {s}) {{\n        obj = j.get<{s}>();\n        return;\n    }}\n", .{ try literal(c, v.raw, false), try c.name(v.schema) });
    try w.print("    throw nlohmann::json::type_error::create(302, \"Unknown discriminator value: \" + discriminatorValue, &j);\n}}\n\ninline void to_json(nlohmann::json& j, const {s}& obj)\n{{\n    std::visit([&j](const auto& val) {{ j = nlohmann::json(val); }}, obj);\n}}\n\n}} // namespace {s}\n\n", .{ n, c.package });
    return out.toOwnedSlice();
}

fn html(c: Context, raw: []const u8) ![]const u8 {
    // PARITY: remove legacy template HTML escaping from code comments later.
    var result = raw;
    for ([_][2][]const u8{ .{ "&", "&amp;" }, .{ "`", "&#x60;" }, .{ "<", "&lt;" }, .{ ">", "&gt;" }, .{ "\"", "&quot;" } }) |pair| {
        result = try replace(c.a, result, pair[0], pair[1]);
    }
    return result;
}

// This is deliberately a schema dialect, not a general YAML/OpenAPI parser.
// New constructs must be implemented and tested, never silently ignored.
pub fn validateInput(input: []const u8) !void {
    var lines = std.mem.splitScalar(u8, input, '\n');
    var in_schemas = false;
    var section: []const u8 = "";
    var subsection: []const u8 = "";
    var child_section: []const u8 = "";
    var schema_keys_seen: u32 = 0;
    var property_keys_seen: u32 = 0;
    var child_keys_seen: u32 = 0;
    var parents: usize = 0;
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const text = std.mem.trimStart(u8, line, " ");
        const indent = line.len - text.len;
        if (eq(text, "schemas:") and indent == 2) {
            in_schemas = true;
            continue;
        }
        if (!in_schemas or text.len == 0) continue;
        if (indent < 4) break;
        if (std.mem.indexOfScalar(u8, line, '\t') != null) return error.UnsupportedYaml;
        if (indent % 2 != 0 or indent > 12) return error.UnsupportedYaml;
        if (indent == 4) {
            if (!std.mem.endsWith(u8, text, ":")) return error.UnsupportedYaml;
            section = "";
            schema_keys_seen = 0;
            parents = 0;
            continue;
        }
        if (indent == 8) {
            if (eq(section, "properties")) {
                if (!std.mem.endsWith(u8, text, ":")) return error.UnsupportedYaml;
                property_keys_seen = 0;
                child_section = "";
            } else if (eq(section, "discriminator")) {
                if (std.mem.startsWith(u8, text, "propertyName: ")) {
                    subsection = "propertyName";
                } else if (eq(text, "mapping:")) {
                    subsection = "mapping";
                } else return error.UnsupportedDiscriminator;
            } else if (eq(section, "allOf")) {
                parents += 1;
                if (parents != 1 or !std.mem.startsWith(u8, text, "- $ref: \"#/components/schemas/")) return error.UnsupportedInheritance;
            } else if (eq(section, "required") or eq(section, "enum") or eq(section, "x-enum-varnames") or eq(section, "x-enum-descriptions")) {
                if (!std.mem.startsWith(u8, text, "- ")) return error.UnsupportedYaml;
            } else return error.UnsupportedYaml;
            continue;
        }
        if (indent == 10 and !eq(section, "properties") and !(eq(section, "discriminator") and eq(subsection, "mapping"))) return error.UnsupportedYaml;
        if (indent == 12 and (!eq(section, "properties") or (!eq(child_section, "items") and !eq(child_section, "additionalProperties")))) return error.UnsupportedYaml;
        if (std.mem.startsWith(u8, text, "- ")) return error.UnsupportedYaml;
        const colon = std.mem.indexOfScalar(u8, text, ':') orelse return error.UnsupportedYaml;
        const key = text[0..colon];
        const value = std.mem.trim(u8, text[colon + 1 ..], " ");
        // At depth 10 the discriminator mapping keys are arbitrary; only local refs are allowed.
        if (indent == 10 and eq(section, "discriminator")) {
            if (!std.mem.startsWith(u8, value, "\"#/components/schemas/")) return error.UnsupportedDiscriminator;
            continue;
        }
        var supported = false;
        const schema_keys = [_][]const u8{ "type", "format", "description", "properties", "required", "enum", "x-enum-varnames", "x-enum-descriptions", "additionalProperties", "allOf", "discriminator" };
        const property_keys = [_][]const u8{ "type", "format", "description", "$ref", "\"$ref\"", "const", "items", "additionalProperties", "uniqueItems" };
        const keys: []const []const u8 = if (indent == 6) &schema_keys else &property_keys;
        const seen = if (indent == 6) &schema_keys_seen else if (indent == 10) &property_keys_seen else &child_keys_seen;
        for (keys, 0..) |allowed, ki| {
            if (!eq(key, allowed)) continue;
            const mask = @as(u32, 1) << @as(u5, @intCast(ki));
            if (seen.* & mask != 0) return error.DuplicateSchemaKeyword;
            seen.* |= mask;
            supported = true;
        }
        if (indent == 6) {
            section = key;
            subsection = "";
        }
        if (indent == 10) {
            child_section = key;
            child_keys_seen = 0;
        }
        if (indent == 12 and (eq(key, "items") or eq(key, "additionalProperties"))) return error.UnsupportedNestedContainer;
        if (!supported) {
            std.debug.print("Unsupported native schema keyword: {s}\n", .{key});
            return error.UnsupportedSchemaKeyword;
        }
        if (std.mem.indexOfScalar(u8, value, '\\') != null) return error.UnsupportedYaml;
        if (eq(key, "additionalProperties") and value.len != 0 and !eq(value, "false")) return error.UnsupportedAdditionalProperties;
        if (eq(key, "format") and !eq(value, "int64") and !eq(value, "uri")) return error.UnsupportedFormat;
        if (eq(key, "description")) {
            if (eq(value, "|") or eq(value, ">") or std.mem.indexOfScalar(u8, value, '\\') != null) return error.UnsupportedYaml;
        }
        if (value.len != 0 and (value[0] == '\'' or value[0] == '&' or value[0] == '*' or value[0] == '[' or value[0] == '{')) return error.UnsupportedYaml;
    }
}

fn identifier(raw: []const u8, dotted: bool) bool {
    if (raw.len == 0 or (!std.ascii.isAlphabetic(raw[0]) and raw[0] != '_')) return false;
    for (raw) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and !(dotted and ch == '.')) return false;
    }
    return true;
}

fn validateDocument(c: Context) !void {
    if (c.language == .cpp and !eq(c.package, "Partout::Models")) return error.UnsupportedNativeCppPackage;
    const package_id = try replace(c.a, c.package, "::", ".");
    if (!identifier(package_id, true)) return error.InvalidPackage;
    if (c.doc.schemas.items.len == 0) return error.EmptySchema;
    for (c.doc.schemas.items, 0..) |s, si| {
        if (!identifier(s.name, true)) return error.InvalidIdentifier;
        for (c.doc.schemas.items[0..si]) |prior| {
            if (eq(s.name, prior.name)) return error.DuplicateSchema;
        }
        if (s.enum_values.items.len != 0 and s.format != null) return error.UnsupportedEnumFormat;
        if (s.enum_values.items.len != s.enum_names.items.len) return error.InvalidEnumNames;
        if (s.enum_descriptions.items.len != 0 and s.enum_descriptions.items.len != s.enum_values.items.len) return error.InvalidEnumDescriptions;
        for (s.enum_names.items, 0..) |en, ei| {
            if (!identifier(en, false)) return error.InvalidIdentifier;
            for (s.enum_names.items[0..ei]) |prior| {
                if (eq(en, prior)) return error.DuplicateEnumName;
            }
        }
        for (s.enum_values.items, 0..) |ev, ei| {
            for (s.enum_values.items[0..ei]) |prior| {
                if (eq(ev, prior)) return error.DuplicateEnumValue;
            }
            if (eq(s.typ orelse "", "integer")) _ = try std.fmt.parseInt(i32, ev, 10);
        }
        for (s.properties.items, 0..) |p, pi| {
            if (!identifier(p.name, false)) return error.InvalidIdentifier;
            for (s.properties.items[0..pi]) |prior| {
                if (eq(p.name, prior.name)) return error.DuplicateProperty;
            }
            try validateSpec(c, p.spec);
            if (p.map_value) |value| {
                if (value != .primitive) return error.UnsupportedMapValue;
                try validateSpec(c, value);
            }
            if (p.unique and p.spec != .array) return error.InvalidUniqueItems;
            if (p.constant != null and s.parent == null) return error.UnsupportedConstant;
            if (p.constant != null and (!eq(p.name, "type") or p.spec != .primitive or p.spec.primitive != .string)) return error.UnsupportedConstant;
        }
        for (s.required.items) |r| {
            var found = false;
            for (s.properties.items) |p| {
                if (eq(p.name, r)) found = true;
            }
            if (!found) return error.UnknownRequiredProperty;
        }
        if (s.parent) |parent_name| {
            const parent = c.doc.schema(parent_name) orelse return error.UnknownReference;
            var found = false;
            for (parent.variants.items) |v| {
                if (eq(v.schema, s.name)) found = true;
            }
            if (!found) return error.UnsupportedInheritance;
        }
        if (s.variants.items.len != 0 and (s.properties.items.len != 1 or !eq(s.properties.items[0].name, s.discriminator_property orelse ""))) return error.UnsupportedInheritedProperties;
        for (s.variants.items) |v| {
            const child = c.doc.schema(v.schema) orelse return error.UnknownReference;
            if (!eq(child.parent orelse "", s.name)) return error.UnsupportedInheritance;
            var found = false;
            for (child.properties.items) |p| {
                if (eq(p.name, s.discriminator_property orelse "") and eq(p.constant orelse "", v.raw)) found = true;
            }
            if (!found) return error.InvalidDiscriminator;
        }
        if (s.typ) |t| {
            if (!eq(t, "object") and !eq(t, "integer") and !eq(t, "number") and !eq(t, "boolean") and !eq(t, "string")) return error.UnsupportedSchemaType;
        }
    }
}

fn validateSpec(c: Context, spec: api.TypeSpec) anyerror!void {
    switch (spec) {
        .ref => |raw| {
            if (c.doc.schema(raw) == null) return error.UnknownReference;
        },
        .array => |child| try validateSpec(c, child.*),
        .none => return error.MissingType,
        .primitive => |p| {
            if (p == .object) return error.UnsupportedInlineObject;
        },
        .raw_json => {},
    }
}
