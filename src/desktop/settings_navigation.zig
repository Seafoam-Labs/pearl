//! Shared, stable settings IDs. No GTK or service ownership belongs here.
const std = @import("std");

pub const Route = enum {
    overview,
    network,
    bluetooth,
    sound,
    power,
    appearance,
    bar,
    notifications,
    session,
    aqueous,
    advanced,
    plugins,

    pub fn id(self: Route) [:0]const u8 {
        return @tagName(self);
    }

    pub fn title(self: Route) [:0]const u8 {
        return switch (self) {
            .overview => "Overview",
            .network => "Network",
            .bluetooth => "Bluetooth",
            .sound => "Sound",
            .power => "Power & battery",
            .appearance => "Appearance",
            .bar => "Bar & dock",
            .notifications => "Notifications",
            .session => "Session & lock",
            .aqueous => "Aqueous",
            .advanced => "Advanced",
            .plugins => "Plugins",
        };
    }

    pub fn isCompact(self: Route) bool {
        return switch (self) {
            .overview, .network, .bluetooth, .sound, .power => true,
            .appearance, .bar, .notifications, .session, .aqueous, .advanced, .plugins => false,
        };
    }
};

pub fn parse(id: []const u8) !Route {
    return std.meta.stringToEnum(Route, id) orelse error.InvalidRoute;
}

/// Preserve the existing Aqueous editor's section IDs and notebook order.
pub const aqueous_sections = [_][]const u8{ "appearance", "layouts", "input", "keybinds", "rules", "displays", "advanced" };

pub fn aqueousSectionIndex(id: []const u8) !usize {
    for (aqueous_sections, 0..) |name, index| if (std.mem.eql(u8, id, name)) return index;
    return error.UnknownPage;
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
    for ([_][]const u8{ "", "x\x00y", "x" ** 1025 }) |output|
        try t.expectError(error.InvalidOutput, transition(null, .{ .page = .sound, .output = output }, .show, &.{output}));
    // IDs compare by value, independent of the event's storage.
    const copy = try t.allocator.dupe(u8, visible.output);
    defer t.allocator.free(copy);
    try t.expectEqual(Action.close, (try transition(visible, .{ .page = .sound, .output = copy }, .toggle, &.{copy})).action);
}
