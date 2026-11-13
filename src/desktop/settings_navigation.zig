//! Shared, stable settings IDs. No GTK or service ownership belongs here.
const std = @import("std");

pub const Route = enum {
    overview,
    network,
    bluetooth,
    sound,
    power,
    appearance,
    assistant,
    bar,
    notifications,
    system,
    startup,
    aqueous,
    advanced,
    plugins,

    pub fn id(self: Route) [:0]const u8 {
        return @tagName(self);
    }

    pub fn title(self: Route) [:0]const u8 {
        return switch (self) {
            .overview => @import("i18n").mark("Overview"),
            .network => @import("i18n").mark("Network"),
            .bluetooth => @import("i18n").mark("Bluetooth"),
            .sound => @import("i18n").mark("Sound"),
            .power => @import("i18n").mark("Power & session"),
            .appearance => @import("i18n").mark("Appearance"),
            .assistant => @import("i18n").mark("Assistant"),
            .bar => @import("i18n").mark("Bar & dock"),
            .notifications => @import("i18n").mark("Notifications"),
            .system => @import("i18n").mark("System"),
            .startup => @import("i18n").mark("Startup applications"),
            .aqueous => @import("i18n").mark("Aqueous"),
            .advanced => @import("i18n").mark("Advanced"),
            .plugins => @import("i18n").mark("Plugins"),
        };
    }

    pub fn isCompact(self: Route) bool {
        return switch (self) {
            .overview, .network, .bluetooth, .sound, .power => true,
            .appearance, .assistant, .bar, .notifications, .system, .startup, .aqueous, .advanced, .plugins => false,
        };
    }
};

pub fn parse(id: []const u8) !Route {
    // The merged Power & session page keeps the old Session & lock route id.
    if (std.mem.eql(u8, id, "session")) return .power;
    return std.meta.stringToEnum(Route, id) orelse error.InvalidRoute;
}

/// Preserve the existing Aqueous editor's section IDs and notebook order.
/// "advanced" remains parseable for compatibility but normalizes to the shared
/// Advanced page; the Aqueous editor itself only hosts the first six sections.
pub const aqueous_sections = [_][]const u8{ "appearance", "layouts", "input", "keybinds", "rules", "displays", "advanced" };
pub const aqueous_page_sections = aqueous_sections[0..6];

pub fn aqueousSectionIndex(id: []const u8) !usize {
    for (aqueous_sections, 0..) |name, index| if (std.mem.eql(u8, id, name)) return index;
    return error.UnknownPage;
}

/// The retired Aqueous parent category is flattened: every editor section is a
/// permanent top-level destination in its subject group. Internal routing keeps
/// the stable aqueous page/section IDs for CLI and wire compatibility.
pub const Group = enum { general, connections, devices, desktop, system };

pub fn groupTitle(group: Group) [:0]const u8 {
    return switch (group) {
        .general => @import("i18n").mark("GENERAL"),
        .connections => @import("i18n").mark("CONNECTIONS"),
        .devices => @import("i18n").mark("DEVICES"),
        .desktop => @import("i18n").mark("DESKTOP"),
        .system => @import("i18n").mark("SYSTEM"),
    };
}

pub const Entry = struct { target: Target, group: Group };

pub const entries = [_]Entry{
    .{ .target = .{ .page = .overview }, .group = .general },
    .{ .target = .{ .page = .network }, .group = .connections },
    .{ .target = .{ .page = .bluetooth }, .group = .connections },
    .{ .target = .{ .page = .sound }, .group = .devices },
    .{ .target = .{ .page = .power }, .group = .devices },
    .{ .target = .{ .page = .aqueous, .section = "displays" }, .group = .devices },
    .{ .target = .{ .page = .aqueous, .section = "input" }, .group = .devices },
    .{ .target = .{ .page = .aqueous, .section = "keybinds" }, .group = .devices },
    .{ .target = .{ .page = .appearance }, .group = .desktop },
    .{ .target = .{ .page = .aqueous, .section = "appearance" }, .group = .desktop },
    .{ .target = .{ .page = .aqueous, .section = "layouts" }, .group = .desktop },
    .{ .target = .{ .page = .aqueous, .section = "rules" }, .group = .desktop },
    .{ .target = .{ .page = .assistant }, .group = .desktop },
    .{ .target = .{ .page = .bar }, .group = .desktop },
    .{ .target = .{ .page = .notifications }, .group = .desktop },
    .{ .target = .{ .page = .system }, .group = .system },
    .{ .target = .{ .page = .startup }, .group = .system },
    .{ .target = .{ .page = .advanced }, .group = .system },
    .{ .target = .{ .page = .plugins }, .group = .system },
};

pub fn entryIndex(target: Target) ?usize {
    const normalized = normalize(target);
    for (entries, 0..) |entry, index| {
        if (entry.target.page != normalized.page) continue;
        const a = entry.target.section orelse "";
        const b = normalized.section orelse "";
        if (std.mem.eql(u8, a, b)) return index;
    }
    return null;
}

/// The merged Advanced page owns the former Aqueous Advanced section. Legacy
/// destinations normalize before validation decisions, storage and rendering.
pub fn normalize(target: Target) Target {
    if (target.page == .aqueous) {
        if (target.section) |section| {
            if (std.mem.eql(u8, section, "advanced")) return .{ .page = .advanced };
        }
    }
    return target;
}

pub const Target = struct {
    page: Route = .overview,
    section: ?[]const u8 = null,

    pub fn validate(self: Target) !void {
        if (self.section) |section| {
            if (self.page != .aqueous) return error.InvalidSection;
            _ = try aqueousSectionIndex(section);
        }
    }
};

test "application targets reuse routes and preserve Aqueous sections" {
    for (aqueous_sections, 0..) |section, index| {
        try std.testing.expectEqual(index, try aqueousSectionIndex(section));
        try (Target{ .page = .aqueous, .section = section }).validate();
        try std.testing.expectError(error.InvalidSection, (Target{ .page = .appearance, .section = section }).validate());
    }
    try (Target{}).validate();
    try std.testing.expectError(error.UnknownPage, (Target{ .page = .aqueous, .section = "unknown" }).validate());
}

test "flattened entries cover every route and Aqueous editor section exactly once" {
    const t = std.testing;
    for (entries) |entry| try entry.target.validate();
    for (std.enums.values(Route)) |route| {
        if (route == .aqueous) continue;
        const index = entryIndex(.{ .page = route }) orelse return error.MissingEntry;
        try t.expectEqual(route, entries[index].target.page);
        try t.expect(entries[index].target.section == null);
    }
    for (aqueous_page_sections) |section| {
        const index = entryIndex(.{ .page = .aqueous, .section = section }) orelse return error.MissingEntry;
        try t.expectEqualStrings(section, entries[index].target.section.?);
    }
    // The retired parent and the merged Advanced section have no own entry.
    try t.expect(entryIndex(.{ .page = .aqueous }) == null);
    try t.expectEqual(entryIndex(.{ .page = .advanced }), entryIndex(.{ .page = .aqueous, .section = "advanced" }));
    var groups: usize = 0;
    var previous: ?Group = null;
    for (entries) |entry| {
        if (previous == null or previous.? != entry.group) groups += 1;
        previous = entry.group;
    }
    try t.expectEqual(@as(usize, 5), groups);
}

test "normalize merges the Aqueous Advanced section into the shared Advanced page" {
    const t = std.testing;
    const merged = normalize(.{ .page = .aqueous, .section = "advanced" });
    try t.expectEqual(Route.advanced, merged.page);
    try t.expect(merged.section == null);
    const kept = normalize(.{ .page = .aqueous, .section = "displays" });
    try t.expectEqual(Route.aqueous, kept.page);
    try t.expectEqualStrings("displays", kept.section.?);
    const plain = normalize(.{ .page = .appearance });
    try t.expectEqual(Route.appearance, plain.page);
    try t.expect(plain.section == null);
}

pub const compact_routes = blk: {
    var count = 0;
    for (std.enums.values(Route)) |route| if (route.isCompact()) {
        count += 1;
    };
    var routes: [count]Route = undefined;
    var index = 0;
    for (std.enums.values(Route)) |route| if (route.isCompact()) {
        routes[index] = route;
        index += 1;
    };
    break :blk routes;
};

pub fn parseCompact(id: []const u8) !Route {
    const route = try parse(id);
    if (!route.isCompact()) return error.InvalidRoute;
    return route;
}

/// Output IDs are borrowed; the host owns their lifetime and supplies only live,
/// enabled outputs. A null selection also represents an unrelated task popup.
pub const Selection = struct { page: Route, output: []const u8 };
pub const Intent = enum { show, toggle, navigate };
pub const Action = enum { open, close, select, replace };
pub const Position = enum { heading, restore };
pub const Transition = struct {
    action: Action,
    selection: ?Selection,
    position: Position,
};

/// Validate before making any decision, including closing a matching popup.
/// External links reset page position; internal navigation restores host-owned
/// scroll/focus state. Applying the returned decision is the host's responsibility.
pub fn transition(current: ?Selection, target: Selection, intent: Intent, outputs: []const []const u8) !Transition {
    if (!target.page.isCompact()) return error.InvalidRoute;
    if (target.output.len == 0 or target.output.len > 1024 or std.mem.indexOfScalar(u8, target.output, 0) != null) return error.InvalidOutput;
    for (outputs) |output| {
        if (std.mem.eql(u8, output, target.output)) break;
    } else return error.InvalidOutput;

    const position: Position = if (intent == .navigate) .restore else .heading;
    if (current) |visible| {
        if (!std.mem.eql(u8, visible.output, target.output))
            return .{ .action = .replace, .selection = target, .position = position };
        if (intent == .toggle and visible.page == target.page)
            return .{ .action = .close, .selection = null, .position = position };
        return .{ .action = .select, .selection = target, .position = position };
    }
    return .{ .action = .open, .selection = target, .position = position };
}

test "shared route IDs round trip and compact parsing excludes application pages" {
    const t = std.testing;
    for (std.enums.values(Route)) |route| {
        try t.expectEqual(route, try parse(route.id()));
        try t.expect(route.title().len > 0);
        if (route.isCompact()) {
            try t.expectEqual(route, try parseCompact(route.id()));
        } else try t.expectError(error.InvalidRoute, parseCompact(route.id()));
    }
    for ([_][]const u8{ "", "Sound", "wifi", "sound/../network", "sound\x00", " sound" }) |id|
        try t.expectError(error.InvalidRoute, parse(id));
}

test "compact transition covers all pages, intents and output relationships" {
    const t = std.testing;
    const outputs = [_][]const u8{ "output:1", "output:2" };
    for (std.enums.values(Route)) |page| {
        if (!page.isCompact()) continue;
        for (std.enums.values(Intent)) |intent| {
            const target: Selection = .{ .page = page, .output = outputs[0] };
            const opened = try transition(null, target, intent, &outputs);
            try t.expectEqual(Action.open, opened.action);
            try t.expectEqual(page, opened.selection.?.page);
            try t.expectEqual(if (intent == .navigate) Position.restore else Position.heading, opened.position);
            for (std.enums.values(Route)) |previous| {
                if (!previous.isCompact()) continue;
                for (outputs, 0..) |output, index| {
                    const result = try transition(.{ .page = previous, .output = output }, target, intent, &outputs);
                    const closes = index == 0 and previous == page and intent == .toggle;
                    try t.expectEqual(if (index != 0) Action.replace else if (closes) Action.close else Action.select, result.action);
                    try t.expectEqual(opened.position, result.position);
                    if (closes) {
                        try t.expect(result.selection == null);
                    } else {
                        try t.expectEqual(page, result.selection.?.page);
                        try t.expectEqualStrings(target.output, result.selection.?.output);
                    }
                }
            }
        }
    }
}

test "invalid destinations and removed outputs cannot dismiss a matching flyout" {
    const t = std.testing;
    const visible: Selection = .{ .page = .sound, .output = "removed-output" };
    try t.expectError(error.InvalidOutput, transition(visible, visible, .toggle, &.{"live-output"}));
    try t.expectError(error.InvalidRoute, transition(visible, .{ .page = .appearance, .output = "live-output" }, .show, &.{"live-output"}));
    for ([_][]const u8{ "", "x\x00y", @import("test_strings").string("x", 1025) }) |output|
        try t.expectError(error.InvalidOutput, transition(null, .{ .page = .sound, .output = output }, .show, &.{output}));
    // IDs compare by value, independent of the event's storage.
    const copy = try t.allocator.dupe(u8, visible.output);
    defer t.allocator.free(copy);
    try t.expectEqual(Action.close, (try transition(visible, .{ .page = .sound, .output = copy }, .toggle, &.{copy})).action);
}
