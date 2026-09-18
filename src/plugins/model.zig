//! Bounded public plugin documents. No runtime, GTK or filesystem ownership.
const std = @import("std");
pub const api = "pearl:plugin/guest@0.1.0";
pub const Limits = struct {
    pub const packages = 32;
    pub const enabled = 8;
    pub const manifest = 16384;
    pub const component = 16 * 1024 * 1024;
    pub const frame = 65536;
    pub const nodes = 32;
};
pub const PackageSource = struct { source: []const u8, path: []const u8, digest: []const u8 };
pub const Grants = struct { input_activity: bool = false, overlay: bool = false };
pub const Setting = struct { key: []const u8, value: []const u8 };
pub const Schema = struct { key: []const u8, label: []const u8, kind: enum { text, number, toggle } = .text, default: []const u8 = "", min: i32 = 0, max: i32 = 86400 };
pub const Placement = struct { mode: enum { bar, overlay } = .bar, output: []const u8 = "", x: u16 = 16, y: u16 = 16, width: u16 = 128, height: u16 = 96, interactive: bool = false, locked: bool = true, hide_fullscreen: bool = true };
pub const Config = struct {
    id: []const u8,
    enabled: bool = false,
    digest: []const u8 = "",
    grants: Grants = .{},
    placement: Placement = .{},
    settings: []const Setting = &.{},
    pub fn validate(self: Config) !void {
        if (!identifier(self.id)) return error.InvalidPluginId;
        if (self.digest.len != 0 and !digestValid(self.digest)) return error.InvalidPluginDigest;
        if (self.enabled and !digestValid(self.digest)) return error.PluginApprovalRequired;
        try text(self.placement.output, 128);
        if (self.placement.width < 16 or self.placement.width > 512 or self.placement.height < 16 or self.placement.height > 512) return error.InvalidPluginPlacement;
        if (self.settings.len > 16) return error.TooManyPluginSettings;
        for (self.settings, 0..) |s, i| {
            if (!identifier(s.key)) return error.InvalidPluginSetting;
            try text(s.value, 256);
            for (self.settings[0..i]) |old| if (std.mem.eql(u8, old.key, s.key)) return error.DuplicatePluginSetting;
        }
    }
};
pub const Preferences = struct {
    entries: []const Config = &.{},
    pub fn validate(self: Preferences) !void {
        if (self.entries.len > Limits.packages) return error.TooManyPlugins;
        var enabled: usize = 0;
        for (self.entries, 0..) |c, i| {
            try c.validate();
            enabled += @intFromBool(c.enabled);
            for (self.entries[0..i]) |old| if (std.mem.eql(u8, old.id, c.id)) return error.DuplicatePlugin;
        }
        if (enabled > Limits.enabled) return error.TooManyEnabledPlugins;
    }
    pub fn find(self: Preferences, id: []const u8) ?Config {
        for (self.entries) |c| if (std.mem.eql(u8, c.id, id)) return c;
        return null;
    }
};
pub const Asset = struct { id: []const u8, path: []const u8, license: []const u8, width: u16, height: u16 };
pub const Frame = struct { asset: []const u8, x: u16 = 0, y: u16 = 0, width: u16, height: u16, duration_ms: u16 = 100 };
pub const Clip = struct { id: []const u8, frames: []const Frame, loop: bool = false };
pub const Manifest = struct {
    id: []const u8,
    name: []const u8,
    version: []const u8,
    interface: []const u8 = api,
    component: []const u8 = "plugin.wasm",
    capabilities: Grants = .{},
    settings: []const Schema = &.{},
    assets: []const Asset = &.{},
    clips: []const Clip = &.{},
    pub fn validate(self: Manifest) !void {
        if (!identifier(self.id)) return error.InvalidPluginId;
        try text(self.name, 96);
        try text(self.version, 32);
        if (self.name.len == 0 or self.version.len == 0) return error.InvalidPluginManifest;
        if (!std.mem.eql(u8, self.interface, api)) return error.UnsupportedPluginInterface;
        if (!relative(self.component) or !std.mem.endsWith(u8, self.component, ".wasm")) return error.InvalidPluginPath;
        if (self.settings.len > 16 or self.assets.len > 32 or self.clips.len > 16) return error.PluginLimit;
        for (self.settings, 0..) |s, i| {
            if (!identifier(s.key) or s.min > s.max) return error.InvalidPluginSetting;
            try text(s.label, 96);
            try settingValue(s, s.default);
            for (self.settings[0..i]) |old| if (std.mem.eql(u8, old.key, s.key)) return error.DuplicatePluginSetting;
        }
        var pixels: usize = 0;
        for (self.assets, 0..) |asset, i| {
            if (!identifier(asset.id) or !relative(asset.path) or !std.mem.endsWith(u8, asset.path, ".png")) return error.InvalidPluginAsset;
            try text(asset.license, 256);
            if (asset.license.len == 0 or asset.width == 0 or asset.height == 0 or asset.width > 2048 or asset.height > 2048) return error.InvalidPluginAsset;
            pixels += @as(usize, asset.width) * asset.height * 4;
            for (self.assets[0..i]) |old| if (std.mem.eql(u8, old.id, asset.id) or std.mem.eql(u8, old.path, asset.path)) return error.DuplicatePluginAsset;
        }
        if (pixels > 16 * 1024 * 1024) return error.PluginImageLimit;
        var frames: usize = 0;
        for (self.clips, 0..) |clip, i| {
            if (!identifier(clip.id) or clip.frames.len == 0) return error.InvalidPluginClip;
            frames += clip.frames.len;
            for (self.clips[0..i]) |old| if (std.mem.eql(u8, old.id, clip.id)) return error.DuplicatePluginClip;
            for (clip.frames) |f| {
                const asset = self.findAsset(f.asset) orelse return error.UnknownPluginAsset;
                if (f.width == 0 or f.height == 0 or @as(u32, f.x) + f.width > asset.width or @as(u32, f.y) + f.height > asset.height or f.duration_ms < 17 or f.duration_ms > 10000) return error.InvalidPluginFrame;
            }
        }
        if (frames > 128) return error.PluginFrameLimit;
    }
    pub fn findAsset(self: Manifest, id: []const u8) ?Asset {
        for (self.assets) |v| if (std.mem.eql(u8, v.id, id)) return v;
        return null;
    }
    pub fn findClip(self: Manifest, id: []const u8) ?Clip {
        for (self.clips) |v| if (std.mem.eql(u8, v.id, id)) return v;
        return null;
    }
    pub fn config(self: Manifest, cfg: Config) !void {
        try cfg.validate();
        if (!std.mem.eql(u8, cfg.id, self.id)) return error.WrongPlugin;
        if ((cfg.grants.overlay and !self.capabilities.overlay) or (cfg.grants.input_activity and !self.capabilities.input_activity)) return error.UndeclaredPluginCapability;
        if (cfg.placement.mode == .overlay and !cfg.grants.overlay) return error.PluginOverlayDenied;
        for (cfg.settings) |s| {
            var found = false;
            for (self.settings) |spec| if (std.mem.eql(u8, s.key, spec.key)) {
                try settingValue(spec, s.value);
                found = true;
                break;
            };
            if (!found) return error.UnknownPluginSetting;
        }
    }
};
pub const Node = struct { id: u32, kind: enum { label, button, image }, text: []const u8 = "", asset: []const u8 = "", clip: []const u8 = "" };
pub const Scene = struct {
    nodes: []const Node = &.{},
    pub fn validate(self: Scene, manifest: Manifest) !void {
        if (self.nodes.len > Limits.nodes) return error.PluginNodeLimit;
        var images: usize = 0;
        for (self.nodes, 0..) |n, i| {
            try text(n.text, 4096);
            for (self.nodes[0..i]) |old| if (old.id == n.id) return error.DuplicatePluginNode;
            if (n.kind == .image) {
                images += 1;
                if (images > 4) return error.PluginImageLimit;
                if (n.clip.len > 0) {
                    if (manifest.findClip(n.clip) == null) return error.UnknownPluginClip;
                } else if (manifest.findAsset(n.asset) == null) return error.UnknownPluginAsset;
            } else if (n.asset.len != 0 or n.clip.len != 0) return error.InvalidPluginNode;
        }
    }
};
pub const Event = struct { kind: enum { activate, click, timer, settings, deactivate, activity, preview }, node: u32 = 0, count: u32 = 0, settings: []const Setting = &.{}, reduced_motion: bool = false };
pub fn identifier(value: []const u8) bool {
    if (value.len == 0 or value.len > 64 or !std.ascii.isAlphanumeric(value[0])) return false;
    for (value) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.')) return false;
    return true;
}
pub fn reference(value: []const u8) bool {
    if (!std.mem.startsWith(u8, value, "plugin:")) return false;
    var parts = std.mem.splitScalar(u8, value[7..], '/');
    return identifier(parts.next() orelse return false) and std.mem.eql(u8, parts.next() orelse return false, "main") and parts.next() == null;
}
pub fn relative(value: []const u8) bool {
    if (value.len == 0 or value.len > 256 or value[0] == '/') return false;
    var parts = std.mem.splitScalar(u8, value, '/');
    while (parts.next()) |p| if (!identifier(p) or std.mem.eql(u8, p, ".") or std.mem.eql(u8, p, "..")) return false;
    return true;
}
pub fn digestValid(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |ch| if (!std.ascii.isHex(ch)) return false;
    return true;
}
pub fn text(value: []const u8, max: usize) !void {
    if (value.len > max or !std.unicode.utf8ValidateSlice(value)) return error.InvalidPluginText;
    for (value) |ch| if (ch == 0 or ch == 127 or (ch < 32 and ch != '\n' and ch != '\t')) return error.InvalidPluginText;
}
pub fn settingValue(spec: Schema, value: []const u8) !void {
    try text(value, 256);
    switch (spec.kind) {
        .text => {},
        .toggle => if (!std.mem.eql(u8, value, "true") and !std.mem.eql(u8, value, "false")) return error.InvalidPluginSetting,
        .number => {
            const n = std.fmt.parseInt(i32, value, 10) catch return error.InvalidPluginSetting;
            if (n < spec.min or n > spec.max) return error.InvalidPluginSetting;
        },
    }
}
test "plugin capabilities require approved content and matching declared grants" {
    const t = std.testing;
    try t.expectError(error.PluginApprovalRequired, (Config{ .id = "cat", .enabled = true }).validate());
    try t.expectError(error.UndeclaredPluginCapability, (Manifest{ .id = "cat", .name = "Cat", .version = "1" }).config(.{ .id = "cat", .grants = .{ .overlay = true } }));
    try t.expect(!relative("assets/../secret.png"));
    try t.expect(reference("plugin:example.cat/main"));
    try t.expect(!reference("plugin:example.cat/main/extra"));
}
test "sprite rectangles and typed settings are bounded" {
    const m: Manifest = .{ .id = "cat", .name = "Cat", .version = "1", .assets = &.{.{ .id = "cat", .path = "cat.png", .license = "CC0", .width = 32, .height = 32 }}, .clips = &.{.{ .id = "tap", .frames = &.{.{ .asset = "cat", .x = 31, .width = 2, .height = 32 }} }} };
    try std.testing.expectError(error.InvalidPluginFrame, m.validate());
    try std.testing.expectError(error.InvalidPluginSetting, settingValue(.{ .key = "seconds", .label = "Seconds", .kind = .number, .min = 1, .max = 10 }, "11"));
}

test "scene nodes cannot refer to foreign assets or reuse event identities" {
    const manifest: Manifest = .{ .id = "demo", .name = "Demo", .version = "1" };
    try std.testing.expectError(error.UnknownPluginAsset, (Scene{ .nodes = &.{.{ .id = 1, .kind = .image, .asset = "other.plugin/cat" }} }).validate(manifest));
    try std.testing.expectError(error.DuplicatePluginNode, (Scene{ .nodes = &.{ .{ .id = 1, .kind = .button }, .{ .id = 1, .kind = .button } } }).validate(manifest));
    try std.testing.expectError(error.InvalidPluginNode, (Scene{ .nodes = &.{.{ .id = 1, .kind = .button, .clip = "idle" }} }).validate(manifest));
    try std.testing.expectError(error.PluginOverlayDenied, manifest.config(.{ .id = "demo", .placement = .{ .mode = .overlay } }));
}
