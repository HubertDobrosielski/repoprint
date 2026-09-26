const std = @import("std");

const OUTPUT_FILE = "output.txt";
const IGNORE_FILE = ".repoprintignore";
const MAX_FILE_SIZE = 10 * 1024 * 1024;
const DEBUG = false;

fn debug(comptime fmt: []const u8, args: anytype) void {
    if (DEBUG) {
        std.debug.print("[DEBUG] " ++ fmt ++ "\n", args);
    }
}

const RuleType = enum { ignore, content };
const PatternType = enum { exact, starts_with, ends_with };

const Rule = struct {
    pattern: []const u8,
    pattern_type: PatternType,
    rule_type: RuleType,

    pub fn init(raw: []const u8) Rule {
        var rule_type: RuleType = .ignore;
        var pattern = raw;
        if (std.mem.startsWith(u8, pattern, "@content ")) {
            rule_type = .content;
            pattern = pattern["@content ".len..];
        }
        const trimmed = std.mem.trimStart(u8, pattern, "/");
        if (std.mem.startsWith(u8, trimmed, "*")) {
            return .{ .pattern = trimmed[1..], .pattern_type = .ends_with, .rule_type = rule_type };
        }
        if (std.mem.endsWith(u8, trimmed, "*")) {
            return .{ .pattern = trimmed[0 .. trimmed.len - 1], .pattern_type = .starts_with, .rule_type = rule_type };
        }
        return .{ .pattern = trimmed, .pattern_type = .exact, .rule_type = rule_type };
    }

    pub fn matches(self: Rule, rel_path: []const u8) bool {
        const path = std.mem.trimStart(u8, rel_path, "/");
        return switch (self.pattern_type) {
            .exact => std.mem.eql(u8, path, self.pattern),
            .starts_with => std.mem.startsWith(u8, path, self.pattern),
            .ends_with => std.mem.endsWith(u8, path, self.pattern),
        };
    }
};

fn isPathIgnored(rel_path: []const u8, rules: []const Rule) bool {
    if (std.mem.eql(u8, rel_path, OUTPUT_FILE)) return true;
    for (rules) |rule| {
        if (rule.rule_type != .ignore) continue;
        if (rule.matches(rel_path)) return true;
    }
    return false;
}
fn isContentIgnored(rel_path: []const u8, rules: []const Rule) bool {
    for (rules) |rule| {
        if (rule.rule_type != .content) continue;
        if (rule.matches(rel_path)) return true;
    }
    return false;
}

const EntryNode = struct { name: []const u8, rel_path: []const u8, is_dir: bool };

fn collectEntries(io: std.Io, allocator: std.mem.Allocator, base_dir: *std.Io.Dir, sub_path: []const u8, rules: []const Rule, collected: *std.ArrayList(EntryNode)) !void {
    var current_dir = if (sub_path.len == 0)
        base_dir.*
    else
        try base_dir.openDir(io, sub_path, .{ .iterate = true });
    defer if (sub_path.len != 0) current_dir.close(io);
    var iter = current_dir.iterate();
    while (try iter.next(io)) |entry| {
        const rel_path = if (sub_path.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fs.path.join(allocator, &.{ sub_path, entry.name });
        errdefer allocator.free(rel_path);
        const is_dir = entry.kind == .directory;
        if (isPathIgnored(rel_path, rules)) {
            allocator.free(rel_path);
            continue;
        }
        const name_copy = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name_copy);
        try collected.append(allocator, .{ .name = name_copy, .rel_path = rel_path, .is_dir = is_dir });
        if (is_dir) try collectEntries(io, allocator, base_dir, rel_path, rules, collected);
    }
}

fn writeStr(file: std.Io.File, io: std.Io, text: []const u8) !void {
    try file.writeStreamingAll(io, text);
}

fn writeHeader(file: std.Io.File, io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, fmt, args) catch return error.FormatTooLong;
    try writeStr(file, io, "================================================================================\n");
    try writeStr(file, io, text);
    try writeStr(file, io, "\n");
    try writeStr(file, io, "================================================================================\n");
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    // get path
    // ========================================================================================================================
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);
    const target_dir_path = if (args.len > 1)
        args[1]
    else
        try std.process.currentPathAlloc(io, allocator);
    defer if (args.len <= 1) allocator.free(target_dir_path);
    debug("Root Path: {s}", .{target_dir_path});
    // ========================================================================================================================

    // open dir
    // ========================================================================================================================
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, target_dir_path, .{ .iterate = true }) catch |err| {
        debug("Failed to open dir: {s} ({any})", .{ target_dir_path, err });
        return err;
    };
    defer dir.close(io);
    debug("Dir opened: {s}", .{target_dir_path});
    // ========================================================================================================================

    // ========================================================================================================================
    const ignore_raw = dir.readFileAlloc(io, IGNORE_FILE, allocator, @enumFromInt(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (ignore_raw) |buf| allocator.free(buf);
    var rules: std.ArrayList(Rule) = .empty;
    defer rules.deinit(allocator);
    if (ignore_raw) |buf| {
        var iter = std.mem.splitScalar(u8, buf, '\n');
        while (iter.next()) |raw_line| {
            const clean = std.mem.trim(u8, raw_line, " \t\r");
            if (clean.len == 0 or clean[0] == '#') continue;
            try rules.append(allocator, Rule.init(clean));
        }
        debug("Loaded {} ignore rules", .{rules.items.len});
    } else {
        debug("ingore Rules is empty", .{});
    }
    if (DEBUG) {
        for (rules.items) |it| {
            std.debug.print(
                "\trule: {s} | pattern: {any} | type: {any}\n",
                .{ it.pattern, it.pattern_type, it.rule_type },
            );
        }
    }
    // ========================================================================================================================

    // ========================================================================================================================
    var entries: std.ArrayList(EntryNode) = .empty;
    defer {
        for (entries.items) |e| {
            allocator.free(e.name);
            allocator.free(e.rel_path);
        }
        entries.deinit(allocator);
    }
    try collectEntries(io, allocator, &dir, "", rules.items, &entries);
    // ========================================================================================================================

    // ========================================================================================================================
    // 5. Utworzenie pliku wynikowego
    var out_file = try dir.createFile(io, OUTPUT_FILE, .{ .truncate = true });
    defer out_file.close(io);
    debug("OUTPUT_FILE was created", .{});
    // ========================================================================================================================

    // ========================================================================================================================
    // directory tree
    try writeHeader(out_file, io, "DIRECTORY TREE", .{});
    try writeStr(out_file, io, ". (");
    try writeStr(out_file, io, target_dir_path);
    try writeStr(out_file, io, ")\n");
    for (entries.items) |item| {
        const depth = std.mem.count(u8, item.rel_path, "/");
        for (0..depth) |_| {
            try writeStr(out_file, io, "  ");
        }
        try writeStr(out_file, io, "├── ");
        try writeStr(out_file, io, item.name);
        try writeStr(out_file, io, if (item.is_dir) "/\n" else "\n");
    }
    try writeStr(out_file, io, "\n\n");
    debug("Generated {d} entries", .{entries.items.len});
    // ========================================================================================================================

    // ========================================================================================================================
    // file contents
    try writeHeader(out_file, io, "FILE CONTENTS", .{});
    for (entries.items) |item| {
        if (item.is_dir) {
            debug("Item {s} is a dir", .{item.rel_path});
            continue;
        }
        if (isContentIgnored(item.rel_path, rules.items)) {
            debug("Item {s} is ignored", .{item.rel_path});
            continue;
        }
        if ((dir.statFile(io, item.rel_path, .{}) catch |err| {
            debug("Could not stat {s}: {any}", .{ item.rel_path, err });
            continue;
        }).size > MAX_FILE_SIZE) {
            debug("Skipping large file: {s}", .{item.rel_path});
            continue;
        }
        const file_content = dir.readFileAlloc(io, item.rel_path, allocator, @enumFromInt(MAX_FILE_SIZE + 1)) catch |err| {
            debug("Could not read {s}: {any}", .{ item.rel_path, err });
            continue;
        };
        defer allocator.free(file_content);
        if (file_content.len > MAX_FILE_SIZE) {
            debug("Skipping large file: {s} ({d} bytes)", .{ item.rel_path, file_content.len });
            continue;
        }
        if (std.mem.indexOfScalar(u8, file_content, 0) != null) {
            debug("Skipping binary file: {s}", .{item.rel_path});
            continue;
        }
        try writeHeader(out_file, io, "FILE: {s}", .{item.rel_path});
        try writeStr(out_file, io, file_content);
        if (file_content.len == 0 or file_content[file_content.len - 1] != '\n') {
            try writeStr(out_file, io, "\n");
        }
        try writeStr(out_file, io, "\n");
    }
    debug("File contents written", .{});
}
