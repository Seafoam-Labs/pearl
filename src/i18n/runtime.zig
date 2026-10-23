//! Process-lifetime language packs. No locale mutation or reload during authentication.
const std = @import("std");
const options = @import("i18n_options");
pub const locale = @import("locale.zig");
pub const format = @import("format.zig");
pub const Catalog = @import("catalog.zig").Catalog;
const a = std.heap.c_allocator;
pub const domains = [_][]const u8{ "pearl", "pearl-greeter", "pearl-lock", "pearl-files", "pearl-agent", "phyto", "dome", "coral" };
pub const Domain = struct { name: []const u8, contract: u32 = 1, translated: u32 = 0, total: u32 = 0 };
pub const Manifest = struct {
    version: u32,
    locale: []const u8,
    native_name: []const u8,
    direction: enum { ltr, rtl } = .ltr,
    revision: []const u8,
    domains: []const Domain,
    pub fn validate(self: Manifest) !void {
        if (self.version != 1 or !locale.isCanonical(self.locale) or self.native_name.len == 0 or self.native_name.len > 128 or !std.unicode.utf8ValidateSlice(self.native_name) or self.revision.len == 0 or self.revision.len > 64 or self.domains.len == 0 or self.domains.len > domains.len) return error.InvalidLanguagePack;
        for (self.native_name) |byte| if (byte < 32 or byte == 127) return error.InvalidLanguagePack;
        for (self.revision) |byte| if (byte < 32 or byte > 126) return error.InvalidLanguagePack;
        for (self.domains, 0..) |d, i| {
            for (domains) |known| {
                if (std.mem.eql(u8, d.name, known)) break;
            } else return error.InvalidLanguagePack;
            if (d.translated > d.total) return error.InvalidLanguagePack;
            for (self.domains[0..i]) |other| if (std.mem.eql(u8, other.name, d.name)) return error.InvalidLanguagePack;
        }
    }
};
const Loaded = struct { language: []const u8, domain: []const u8, catalog: Catalog };
var state = std.atomic.Value(u8).init(0);
var catalogs: [64]Loaded = undefined;
var count: usize = 0;
var selected: []const u8 = "en";
var right_to_left = false;
var session_languages: [2048:0]u8 = @splat(0);
var session_languages_len: usize = 0;
pub fn env(name: [:0]const u8) []const u8 {
    return if (std.c.getenv(name)) |p| std.mem.span(p) else "";
}
fn read(path: [:0]const u8, limit: usize) ![]u8 {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true, .NOFOLLOW = true }, @as(c_uint, 0));
    if (fd < 0) return error.Unavailable;
    defer _ = std.c.close(fd);
    const bytes = try a.alloc(u8, limit + 1);
    errdefer a.free(bytes);
    var n: usize = 0;
    while (n < bytes.len) {
        const got = std.c.read(fd, bytes[n..].ptr, bytes.len - n);
        if (got < 0) return error.Unavailable;
        if (got == 0) return a.realloc(bytes, n);
        n += @intCast(got);
    }
    return error.TooLarge;
}
pub fn loadManifest(language: []const u8) !std.json.Parsed(Manifest) {
    if (!locale.valid(language)) return error.InvalidLanguagePack;
    var path: [4096]u8 = undefined;
    const bytes = try read(try std.fmt.bufPrintZ(&path, "{s}/share/pearl/language-packs/{s}.json", .{ options.prefix, language }), 16384);
    defer a.free(bytes);
    const parsed = try std.json.parseFromSlice(Manifest, a, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try parsed.value.validate();
    if (!std.mem.eql(u8, parsed.value.locale, language)) return error.InvalidLanguagePack;
    return parsed;
}
fn savedLanguage(system: bool) []const u8 {
    var path: [4096]u8 = undefined;
    const filename = if (system) (std.fmt.bufPrintZ(&path, "{s}", .{if (@hasDecl(options, "system_config")) options.system_config else "/etc/pearl/greeter.json"}) catch return "") else blk: {
        const xdg = env("XDG_CONFIG_HOME");
        if (xdg.len > 0 and xdg[0] == '/') break :blk std.fmt.bufPrintZ(&path, "{s}/pearl/preferences.json", .{xdg}) catch return "";
        const home = env("HOME");
        if (home.len == 0 or home[0] != '/') return "";
        break :blk std.fmt.bufPrintZ(&path, "{s}/.config/pearl/preferences.json", .{home}) catch return "";
    };
    const bytes = read(filename, 65536) catch return "";
    defer a.free(bytes);
    const parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{}) catch return "";
    defer parsed.deinit();
    if (parsed.value != .object) return "";
    const language = parsed.value.object.get("language") orelse return "";
    if (language != .string or !locale.valid(language.string)) return "";
    return a.dupe(u8, language.string) catch "";
}
/// Call before workers/UI. User utilities pass false; production greeters use initGreeter.
pub fn init(system: bool) void {
    initSelected(system, if (system) "" else env("PEARL_SESSION_LANGUAGES"), null);
}
/// Greeter passes its already validated, system-owned configuration before GTK.
pub fn initGreeter(language: []const u8) void {
    initSelected(true, "", language);
}
/// The caller must have verified the session peer before supplying this value.
pub fn initSession(value: []const u8) void {
    if (value.len > 2048) return;
    var parts = std.mem.splitScalar(u8, value, ':');
    while (parts.next()) |part| if (!locale.valid(part)) return;
    initSelected(false, value, null);
}
pub fn initShell() void {
    initSelected(false, "", null);
}
fn initSelected(system: bool, inherited: []const u8, configured: ?[]const u8) void {
    if (state.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) {
        while (state.load(.acquire) != 2) std.atomic.spinLoopHint();
        return;
    }
    defer state.store(2, .release);
    const saved = configured orelse savedLanguage(system);
    defer if (configured == null and saved.len > 0) a.free(saved);
    var preferences = locale.Preferences.resolve(saved, env("LANGUAGE"), env("LC_ALL"), env("LC_MESSAGES"), env("LANG"));
    if (inherited.len > 0 and inherited.len <= 2048) {
        preferences = .{};
        var parts = std.mem.splitScalar(u8, inherited, ':');
        while (parts.next()) |part| preferences.append(part);
        preferences.append("en");
    }
    for (0..preferences.len) |i| {
        const language = preferences.get(i);
        if (std.mem.eql(u8, language, "en")) break;
        const manifest = loadManifest(language) catch continue;
        defer manifest.deinit();
        var accepted = false;
        for (manifest.value.domains) |domain| {
            if (domain.contract != 1 or count == catalogs.len) continue;
            var path: [4096]u8 = undefined;
            const filename = std.fmt.bufPrintZ(&path, "{s}/share/locale/{s}/LC_MESSAGES/{s}.mo", .{ options.prefix, language, domain.name }) catch continue;
            const bytes = read(filename, @import("catalog.zig").max_bytes) catch continue;
            const catalog = Catalog.parse(bytes) catch {
                a.free(bytes);
                continue;
            };
            const lang = a.dupe(u8, language) catch {
                a.free(bytes);
                continue;
            };
            const name = a.dupe(u8, domain.name) catch {
                a.free(lang);
                a.free(bytes);
                continue;
            };
            catalogs[count] = .{ .language = lang, .domain = name, .catalog = catalog };
            count += 1;
            accepted = true;
        }
        if (accepted and std.mem.eql(u8, selected, "en")) {
            selected = catalogs[count - 1].language;
            right_to_left = manifest.value.direction == .rtl;
        }
        // Freeze only usable languages: installing a previously missing pack
        // must not silently change the language of a newly launched helper.
        if (accepted) appendSessionLanguage(language);
    }
    appendSessionLanguage("en");
}
fn appendSessionLanguage(name: []const u8) void {
    if (session_languages_len + name.len + 1 >= session_languages.len) return;
    if (session_languages_len > 0) {
        session_languages[session_languages_len] = ':';
        session_languages_len += 1;
    }
    @memcpy(session_languages[session_languages_len..][0..name.len], name);
    session_languages_len += name.len;
}
pub fn effectiveLanguage() []const u8 {
    init(false);
    return selected;
}
pub fn sessionLanguages() [:0]const u8 {
    init(false);
    return session_languages[0..session_languages_len :0];
}
pub fn rtl() bool {
    init(false);
    return right_to_left;
}
pub fn dtr(domain: []const u8, source: [:0]const u8) [:0]const u8 {
    return lookup(domain, null, source, null, null);
}
pub fn tr(source: [:0]const u8) [:0]const u8 {
    return dtr("pearl", source);
}
pub fn context(ctx: []const u8, source: [:0]const u8) [:0]const u8 {
    return dcontext("pearl", ctx, source);
}
pub fn dcontext(domain: []const u8, ctx: []const u8, source: [:0]const u8) [:0]const u8 {
    return lookup(domain, ctx, source, null, null);
}
pub fn ntr(singular: [:0]const u8, plural: [:0]const u8, n: u64) [:0]const u8 {
    return dntr("pearl", singular, plural, n);
}
pub fn dntr(domain: []const u8, singular: [:0]const u8, plural: [:0]const u8, n: u64) [:0]const u8 {
    return lookup(domain, null, singular, plural, n);
}
fn lookup(domain: []const u8, ctx: ?[]const u8, source: [:0]const u8, plural: ?[:0]const u8, n: ?u64) [:0]const u8 {
    init(false);
    const fallback = if (n != null and n.? != 1) plural orelse source else source;
    var key_buffer: [8192]u8 = undefined;
    const key = if (ctx) |c| std.fmt.bufPrint(&key_buffer, "{s}\x04{s}", .{ c, source }) catch return fallback else source;
    for (catalogs[0..count]) |entry| {
        if (!std.mem.eql(u8, entry.domain, domain)) continue;
        if (entry.catalog.translate(key, n)) |value| return value;
    }
    return fallback;
}
pub fn message(buffer: []u8, source: [:0]const u8, args: []const format.Arg) [:0]const u8 {
    return dmessage("pearl", buffer, source, args);
}
pub fn dmessage(domain: []const u8, buffer: []u8, source: [:0]const u8, args: []const format.Arg) [:0]const u8 {
    return render(buffer, source, dtr(domain, source), args);
}
pub fn nmessage(buffer: []u8, singular: [:0]const u8, plural: [:0]const u8, n: u64, args: []const format.Arg) [:0]const u8 {
    return dnmessage("pearl", buffer, singular, plural, n, args);
}
pub fn dnmessage(domain: []const u8, buffer: []u8, singular: [:0]const u8, plural: [:0]const u8, n: u64, args: []const format.Arg) [:0]const u8 {
    return render(buffer, if (n == 1) singular else plural, dntr(domain, singular, plural, n), args);
}
fn render(buffer: []u8, source: [:0]const u8, translated: [:0]const u8, args: []const format.Arg) [:0]const u8 {
    if (format.compatible(source, translated)) if (format.render(buffer, translated, args)) |s| return s else |_| {};
    return format.render(buffer, source, args) catch "";
}
test "manifest rejects traversal duplicate and impossible coverage" {
    var m: Manifest = .{ .version = 1, .locale = "de", .native_name = "Deutsch", .revision = "1", .domains = &.{.{ .name = "pearl" }} };
    try m.validate();
    m.locale = "../de";
    try std.testing.expectError(error.InvalidLanguagePack, m.validate());
    m.locale = "de";
    m.domains = &.{ .{ .name = "pearl" }, .{ .name = "pearl" } };
    try std.testing.expectError(error.InvalidLanguagePack, m.validate());
    m.domains = &.{.{ .name = "pearl", .translated = 2, .total = 1 }};
    try std.testing.expectError(error.InvalidLanguagePack, m.validate());
    m.domains = &.{.{ .name = "../other" }};
    try std.testing.expectError(error.InvalidLanguagePack, m.validate());
    m.domains = &.{.{ .name = "pearl" }};
    m.native_name = "Deutsch\x00extra";
    try std.testing.expectError(error.InvalidLanguagePack, m.validate());
}
pub fn fmt(buffer: []u8, comptime source: []const u8, args: anytype) [:0]const u8 {
    return dfmt("pearl", buffer, source, args);
}
pub fn dfmt(domain: []const u8, buffer: []u8, comptime source: []const u8, args: anytype) [:0]const u8 {
    var values: [args.len][4096]u8 = undefined;
    var named: [args.len]format.Arg = undefined;
    inline for (args, 0..) |arg, i| {
        const value = std.fmt.bufPrint(&values[i], "{" ++ format.spec(source, i) ++ "}", .{arg}) catch return (std.fmt.bufPrintZ(buffer, source, args) catch "");
        named[i] = .{ .name = std.fmt.comptimePrint("{d}", .{i}), .value = value };
    }
    return dmessage(domain, buffer, format.sourceTemplate(source), &named);
}
pub fn fmtAlloc(allocator: std.mem.Allocator, comptime source: []const u8, args: anytype) ![:0]u8 {
    return dfmtAlloc("pearl", allocator, source, args);
}
pub fn dfmtAlloc(domain: []const u8, allocator: std.mem.Allocator, comptime source: []const u8, args: anytype) ![:0]u8 {
    var buffer: [16384]u8 = undefined;
    const value = dfmt(domain, &buffer, source, args);
    if (value.len == 0 and source.len > 0) return error.MessageTooLong;
    return allocator.dupeZ(u8, value);
}

pub const Pack = struct { locale: [:0]const u8, name: [:0]const u8, translated: u32, total: u32 };
/// Returned strings belong to allocator; callers normally use their view arena.
pub fn installed(allocator: std.mem.Allocator) ![]Pack {
    var result: std.ArrayList(Pack) = .empty;
    const directory = std.c.opendir(options.prefix ++ "/share/pearl/language-packs") orelse return result.toOwnedSlice(allocator);
    defer _ = std.c.closedir(directory);
    while (std.c.readdir(directory)) |entry| {
        if (result.items.len >= 128) break;
        const filename = std.mem.sliceTo(&entry.name, 0);
        if (!std.mem.endsWith(u8, filename, ".json")) continue;
        const name = filename[0 .. filename.len - 5];
        const manifest = loadManifest(name) catch continue;
        defer manifest.deinit();
        var translated: u32 = 0;
        var total: u32 = 0;
        var compatible_domain = false;
        for (manifest.value.domains) |d| {
            if (d.contract != 1) continue;
            var path: [4096]u8 = undefined;
            const filename_z = std.fmt.bufPrintZ(&path, "{s}/share/locale/{s}/LC_MESSAGES/{s}.mo", .{ options.prefix, name, d.name }) catch continue;
            const bytes = read(filename_z, @import("catalog.zig").max_bytes) catch continue;
            defer a.free(bytes);
            _ = Catalog.parse(bytes) catch continue;
            compatible_domain = true;
            translated +|= d.translated;
            total +|= d.total;
        }
        if (!compatible_domain) continue;
        try result.append(allocator, .{ .locale = try allocator.dupeZ(u8, name), .name = try allocator.dupeZ(u8, manifest.value.native_name), .translated = translated, .total = total });
    }
    std.mem.sort(Pack, result.items, {}, struct {
        fn less(_: void, l: Pack, r: Pack) bool {
            return std.mem.lessThan(u8, l.locale, r.locale);
        }
    }.less);
    return result.toOwnedSlice(allocator);
}

/// Schema identities stay stable; unknown fields retain upstream text.
pub fn aqueousField(id: []const u8, kind: enum { label, description }, fallback: []const u8) []const u8 {
    for (@import("aqueous_fields.zig").fields) |field| {
        if (!std.mem.eql(u8, field.id, id)) continue;
        var buffer: [512]u8 = undefined;
        const ctx = std.fmt.bufPrint(&buffer, "aqueous.{s}.{s}", .{ id, @tagName(kind) }) catch return fallback;
        return context(ctx, if (kind == .label) field.label else field.description);
    }
    return fallback;
}
pub const region = @import("region.zig");
pub fn aqueousOption(id: []const u8, value: []const u8) []const u8 {
    for (@import("aqueous_fields.zig").fields) |field| {
        if (!std.mem.eql(u8, id, field.id)) continue;
        for (field.options) |option| {
            if (!std.mem.eql(u8, option, value)) continue;
            var buffer: [512]u8 = undefined;
            const ctx = std.fmt.bufPrint(&buffer, "aqueous.{s}.option", .{id}) catch return value;
            return context(ctx, option);
        }
    }
    return value;
}
/// Extraction marker for developer-owned static labels translated at their use site.
pub fn mark(comptime source: [:0]const u8) [:0]const u8 {
    return source;
}
