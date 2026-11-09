//! The first workbench batch contains only actions Coral can actually execute.
//! This module installs no accelerators/controllers. Call fromKey only after the
//! owner has excluded terminal focus, modal UI and IME-owned input; null means
//! continue through the existing editor key handler, not consume the event.
const std = @import("std");

pub const Command = enum {
    new,
    open,
    save,
    save_as,
    reload,
    find,
    goto_line,
    spelling,
    preferences,
    about,
    close,
    quit,
    command_palette,
    split_group,
    focus_next_group,
    focus_previous_group,
    close_group,
    excerpt,
    grouped_undo,
    grouped_redo,
    open_folder,
    open_workspace,
    workspace_roots,
    workspace_back,
    workspace_rescan,
    close_workspace,

    pub fn metadata(self: Command) Metadata {
        return entries[@backingInt(self)];
    }

    pub fn label(self: Command) [:0]const u8 {
        // Literal call sites also allow the catalog extractor to find labels.
        const i18n = @import("i18n");
        return switch (self) {
            .new => i18n.dtr("coral", "New document"),
            .open => i18n.dtr("coral", "Open…"),
            .save => i18n.dtr("coral", "Save"),
            .save_as => i18n.dtr("coral", "Save As…"),
            .reload => i18n.dtr("coral", "Reload from Disk"),
            .find => i18n.dtr("coral", "Find / Replace"),
            .goto_line => i18n.dtr("coral", "Go to Line…"),
            .spelling => i18n.dtr("coral", "Spelling suggestions"),
            .preferences => i18n.dtr("coral", "Preferences…"),
            .about => i18n.dtr("coral", "About Coral"),
            .close => i18n.dtr("coral", "Close tab"),
            .quit => i18n.dtr("coral", "Quit"),
            .command_palette => i18n.dtr("coral", "Command Palette…"),
            .split_group => i18n.dtr("coral", "Split editor group"),
            .focus_next_group => i18n.dtr("coral", "Focus next editor group"),
            .focus_previous_group => i18n.dtr("coral", "Focus previous editor group"),
            .close_group => i18n.dtr("coral", "Close editor group"),
            .excerpt => i18n.dtr("coral", "Edit selection as excerpt"),
            .grouped_undo => i18n.dtr("coral", "Undo grouped edit"),
            .grouped_redo => i18n.dtr("coral", "Redo grouped edit"),
            .open_folder => i18n.dtr("coral", "Open Folder…"),
            .open_workspace => i18n.dtr("coral", "Open Workspace…"),
            .workspace_roots => i18n.dtr("coral", "Workspace: Roots"),
            .workspace_back => i18n.dtr("coral", "Workspace: Back"),
            .workspace_rescan => i18n.dtr("coral", "Workspace: Rescan directory"),
            .close_workspace => i18n.dtr("coral", "Close workspace (keep documents)"),
        };
    }
};

pub const Metadata = struct {
    command: Command,
    /// Unqualified GAction name. Use detailed_action when appending menu items.
    action: [:0]const u8,
    detailed_action: [:0]const u8,
    /// Source label for pure filtering/tests; use command.label() for UI text.
    label: [:0]const u8,
    shortcut: ?[:0]const u8,
};

pub const entries = [_]Metadata{
    .{ .command = .new, .action = "new", .detailed_action = "app.new", .label = "New document", .shortcut = "Ctrl+N" },
    .{ .command = .open, .action = "open", .detailed_action = "app.open", .label = "Open…", .shortcut = "Ctrl+O" },
    .{ .command = .save, .action = "save", .detailed_action = "app.save", .label = "Save", .shortcut = "Ctrl+S" },
    .{ .command = .save_as, .action = "save-as", .detailed_action = "app.save-as", .label = "Save As…", .shortcut = "Ctrl+Shift+S" },
    .{ .command = .reload, .action = "reload", .detailed_action = "app.reload", .label = "Reload from Disk", .shortcut = null },
    .{ .command = .find, .action = "find", .detailed_action = "app.find", .label = "Find / Replace", .shortcut = "Ctrl+F" },
    .{ .command = .goto_line, .action = "goto", .detailed_action = "app.goto", .label = "Go to Line…", .shortcut = "Ctrl+G" },
    .{ .command = .spelling, .action = "spelling", .detailed_action = "app.spelling", .label = "Spelling suggestions", .shortcut = "Shift+F10" },
    .{ .command = .preferences, .action = "preferences", .detailed_action = "app.preferences", .label = "Preferences…", .shortcut = "Ctrl+," },
    .{ .command = .about, .action = "about", .detailed_action = "app.about", .label = "About Coral", .shortcut = null },
    .{ .command = .close, .action = "close", .detailed_action = "app.close", .label = "Close tab", .shortcut = "Ctrl+W" },
    .{ .command = .quit, .action = "quit", .detailed_action = "app.quit", .label = "Quit", .shortcut = "Ctrl+Q" },
    .{ .command = .command_palette, .action = "command-palette", .detailed_action = "app.command-palette", .label = "Command Palette…", .shortcut = "Ctrl+Shift+P" },
    .{ .command = .split_group, .action = "split-group", .detailed_action = "app.split-group", .label = "Split editor group", .shortcut = "Ctrl+\\" },
    .{ .command = .focus_next_group, .action = "focus-next-group", .detailed_action = "app.focus-next-group", .label = "Focus next editor group", .shortcut = null },
    .{ .command = .focus_previous_group, .action = "focus-previous-group", .detailed_action = "app.focus-previous-group", .label = "Focus previous editor group", .shortcut = null },
    .{ .command = .close_group, .action = "close-group", .detailed_action = "app.close-group", .label = "Close editor group", .shortcut = null },
    .{ .command = .excerpt, .action = "excerpt", .detailed_action = "app.excerpt", .label = "Edit selection as excerpt", .shortcut = null },
    .{ .command = .grouped_undo, .action = "grouped-undo", .detailed_action = "app.grouped-undo", .label = "Undo grouped edit", .shortcut = null },
    .{ .command = .grouped_redo, .action = "grouped-redo", .detailed_action = "app.grouped-redo", .label = "Redo grouped edit", .shortcut = null },
    .{ .command = .open_folder, .action = "open-folder", .detailed_action = "app.open-folder", .label = "Open Folder…", .shortcut = null },
    .{ .command = .open_workspace, .action = "open-workspace", .detailed_action = "app.open-workspace", .label = "Open Workspace…", .shortcut = null },
    .{ .command = .workspace_roots, .action = "workspace-roots", .detailed_action = "app.workspace-roots", .label = "Workspace: Roots", .shortcut = null },
    .{ .command = .workspace_back, .action = "workspace-back", .detailed_action = "app.workspace-back", .label = "Workspace: Back", .shortcut = null },
    .{ .command = .workspace_rescan, .action = "workspace-rescan", .detailed_action = "app.workspace-rescan", .label = "Workspace: Rescan directory", .shortcut = null },
    .{ .command = .close_workspace, .action = "close-workspace", .detailed_action = "app.close-workspace", .label = "Close workspace (keep documents)", .shortcut = null },
};

pub fn fromAction(action: []const u8) ?Command {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.action, action)) return entry.command;
    }
    return null;
}

/// GDK keyvals/modifier bits, kept independent of GTK so these tests need no
/// native libraries or display. Lock and mouse-button state are irrelevant;
/// Alt, Super, Hyper, Meta (and unknown modifier bits) must not become commands.
pub fn fromKey(key: u32, state: u32) ?Command {
    const shift = 1 << 0;
    const lock = 1 << 1;
    const ctrl = 1 << 2;
    const buttons = 0x1f << 8;
    const modifiers = state & ~@as(u32, lock | buttons);
    const lower = if (key >= 'A' and key <= 'Z') key + ('a' - 'A') else key;
    if (modifiers == ctrl | shift) return switch (lower) {
        's' => .save_as,
        'p' => .command_palette,
        else => null,
    };
    if (modifiers == shift and key == 0xffc7) return .spelling; // GDK_KEY_F10
    if (modifiers != ctrl) return null;
    return switch (lower) {
        'n' => .new,
        'o' => .open,
        's' => .save,
        'f', 'h' => .find,
        'g' => .goto_line,
        ',' => .preferences,
        'w' => .close,
        'q' => .quit,
        '\\' => .split_group,
        else => null,
    };
}

test "registry is exhaustive, ordered and has unique stable actions" {
    try std.testing.expectEqual(@typeInfo(Command).@"enum".field_names.len, entries.len);
    const actions = [_][]const u8{ "new", "open", "save", "save-as", "reload", "find", "goto", "spelling", "preferences", "about", "close", "quit", "command-palette", "split-group", "focus-next-group", "focus-previous-group", "close-group", "excerpt", "grouped-undo", "grouped-redo", "open-folder", "open-workspace", "workspace-roots", "workspace-back", "workspace-rescan", "close-workspace" };
    for (entries, actions, 0..) |entry, action, index| {
        try std.testing.expectEqual(index, @backingInt(entry.command));
        try std.testing.expectEqualStrings(action, entry.action);
        try std.testing.expectEqual(entry.command, fromAction(action).?);
        try std.testing.expectEqualStrings(action, entry.detailed_action[4..]);
        try std.testing.expect(std.mem.startsWith(u8, entry.detailed_action, "app."));
        try std.testing.expect(entry.label.len > 0);
        try std.testing.expectEqualStrings(entry.label, entry.command.metadata().label);
        for (entries[0..index]) |other| try std.testing.expect(!std.mem.eql(u8, other.action, action));
    }
    for ([_][]const u8{ "", "app.save", "SAVE", "save_as", "goto-line", "terminal", "agent" }) |unknown| {
        try std.testing.expectEqual(@as(?Command, null), fromAction(unknown));
    }
}

test "reload is an explicit palette action without a key binding" {
    try std.testing.expectEqual(Command.reload, fromAction("reload").?);
    try std.testing.expectEqualStrings("Reload from Disk", Command.reload.metadata().label);
    try std.testing.expectEqual(@as(?[:0]const u8, null), Command.reload.metadata().shortcut);
    try std.testing.expectEqual(@as(?Command, null), fromKey('r', 4));
}

test "command shortcuts include shifted keyvals and existing find alias" {
    const Case = struct { key: u32, state: u32, command: Command };
    for ([_]Case{
        .{ .key = 'n', .state = 4, .command = .new },
        .{ .key = '\\', .state = 4, .command = .split_group },
        .{ .key = 'O', .state = 6, .command = .open },
        .{ .key = 's', .state = 4, .command = .save },
        .{ .key = 'S', .state = 4, .command = .save },
        .{ .key = 's', .state = 5, .command = .save_as },
        .{ .key = 'S', .state = 7, .command = .save_as },
        .{ .key = 'f', .state = 4, .command = .find },
        .{ .key = 'h', .state = 4, .command = .find },
        .{ .key = 'g', .state = 4, .command = .goto_line },
        .{ .key = ',', .state = 4, .command = .preferences },
        .{ .key = 'w', .state = 4, .command = .close },
        .{ .key = 'q', .state = 4, .command = .quit },
        .{ .key = 'p', .state = 5, .command = .command_palette },
        .{ .key = 'P', .state = 5, .command = .command_palette },
        .{ .key = 0xffc7, .state = 1, .command = .spelling },
    }) |case| try std.testing.expectEqual(case.command, fromKey(case.key, case.state).?);
}

test "unmapped editor keys and other modifiers remain with the parent" {
    for ([_]u32{ 0xff1b, 0xffc0, 0xff09, 0xfe20, 'z', 'Z', 'y', '+', '=', '-', '0', 'p' }) |key| {
        try std.testing.expectEqual(@as(?Command, null), fromKey(key, 4));
    }
    for ([_]u32{ 0, 1, 5, 4 | 8, 4 | (1 << 26), 4 | (1 << 27), 4 | (1 << 28), 4 | (1 << 7) }) |state| {
        try std.testing.expectEqual(@as(?Command, null), fromKey('n', state));
    }
    try std.testing.expectEqual(@as(?Command, null), fromKey(0xffc7, 0));
    try std.testing.expectEqual(@as(?Command, null), fromKey(0xffc7, 5));
    try std.testing.expectEqual(Command.save, fromKey('s', 4 | (1 << 8)).?);
}
