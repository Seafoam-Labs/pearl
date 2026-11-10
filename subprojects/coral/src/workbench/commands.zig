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
    quick_open,
    workspace_search,
    workspace_policy,
    workspace_trust,
    workspace_revoke,
    save_workspace_session,
    restore_workspace_session,
    toggle_explorer,
    toggle_search,
    focus_explorer,
    focus_search,
    focus_editor,
    hide_panel,
    dock_left,
    dock_right,
    dock_bottom,
    reset_docks,
    dock_grow,
    dock_shrink,
    next_tab,
    previous_tab,
    new_window,
    close_window,
    next_window,
    previous_window,
    create_workspace_file,
    create_workspace_directory,
    rename_workspace_entry,
    move_workspace_entry,
    delete_workspace_entry,

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
            .quit => i18n.dtr("coral", "Quit All"),
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
            .quick_open => i18n.dtr("coral", "Quick Open…"),
            .workspace_search => i18n.dtr("coral", "Search workspace…"),
            .workspace_policy => i18n.dtr("coral", "Workspace: Settings and Trust…"),
            .workspace_trust => i18n.dtr("coral", "Trust workspace…"),
            .workspace_revoke => i18n.dtr("coral", "Workspace: Revoke trust"),
            .save_workspace_session => i18n.dtr("coral", "Save Workspace Session"),
            .restore_workspace_session => i18n.dtr("coral", "Restore Workspace Session"),
            .toggle_explorer => i18n.dtr("coral", "Toggle Explorer dock"),
            .toggle_search => i18n.dtr("coral", "Toggle Search dock"),
            .focus_explorer => i18n.dtr("coral", "Focus Explorer"),
            .focus_search => i18n.dtr("coral", "Focus Search"),
            .focus_editor => i18n.dtr("coral", "Focus editor"),
            .hide_panel => i18n.dtr("coral", "Hide active panel"),
            .dock_left => i18n.dtr("coral", "Move active panel left"),
            .dock_right => i18n.dtr("coral", "Move active panel right"),
            .dock_bottom => i18n.dtr("coral", "Move active panel bottom"),
            .reset_docks => i18n.dtr("coral", "Reset dock layout"),
            .dock_grow => i18n.dtr("coral", "Grow active dock"),
            .dock_shrink => i18n.dtr("coral", "Shrink active dock"),
            .next_tab => i18n.dtr("coral", "Next editor tab"),
            .previous_tab => i18n.dtr("coral", "Previous editor tab"),
            .new_window => i18n.dtr("coral", "New Window"),
            .close_window => i18n.dtr("coral", "Close Window"),
            .next_window => i18n.dtr("coral", "Next Window"),
            .previous_window => i18n.dtr("coral", "Previous Window"),
            .create_workspace_file => i18n.dtr("coral", "Explorer: New file…"),
            .create_workspace_directory => i18n.dtr("coral", "Explorer: New directory…"),
            .rename_workspace_entry => i18n.dtr("coral", "Explorer: Rename…"),
            .move_workspace_entry => i18n.dtr("coral", "Explorer: Move…"),
            .delete_workspace_entry => i18n.dtr("coral", "Explorer: Delete permanently…"),
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
    .{ .command = .new, .action = "new", .detailed_action = "win.new", .label = "New document", .shortcut = "Ctrl+N" },
    .{ .command = .open, .action = "open", .detailed_action = "win.open", .label = "Open…", .shortcut = "Ctrl+O" },
    .{ .command = .save, .action = "save", .detailed_action = "win.save", .label = "Save", .shortcut = "Ctrl+S" },
    .{ .command = .save_as, .action = "save-as", .detailed_action = "win.save-as", .label = "Save As…", .shortcut = "Ctrl+Shift+S" },
    .{ .command = .reload, .action = "reload", .detailed_action = "win.reload", .label = "Reload from Disk", .shortcut = null },
    .{ .command = .find, .action = "find", .detailed_action = "win.find", .label = "Find / Replace", .shortcut = "Ctrl+F" },
    .{ .command = .goto_line, .action = "goto", .detailed_action = "win.goto", .label = "Go to Line…", .shortcut = "Ctrl+G" },
    .{ .command = .spelling, .action = "spelling", .detailed_action = "win.spelling", .label = "Spelling suggestions", .shortcut = "Shift+F10" },
    .{ .command = .preferences, .action = "preferences", .detailed_action = "win.preferences", .label = "Preferences…", .shortcut = "Ctrl+," },
    .{ .command = .about, .action = "about", .detailed_action = "win.about", .label = "About Coral", .shortcut = null },
    .{ .command = .close, .action = "close", .detailed_action = "win.close", .label = "Close tab", .shortcut = "Ctrl+W" },
    .{ .command = .quit, .action = "quit", .detailed_action = "win.quit", .label = "Quit All", .shortcut = "Ctrl+Q" },
    .{ .command = .command_palette, .action = "command-palette", .detailed_action = "win.command-palette", .label = "Command Palette…", .shortcut = "Ctrl+Shift+P" },
    .{ .command = .split_group, .action = "split-group", .detailed_action = "win.split-group", .label = "Split editor group", .shortcut = "Ctrl+\\" },
    .{ .command = .focus_next_group, .action = "focus-next-group", .detailed_action = "win.focus-next-group", .label = "Focus next editor group", .shortcut = null },
    .{ .command = .focus_previous_group, .action = "focus-previous-group", .detailed_action = "win.focus-previous-group", .label = "Focus previous editor group", .shortcut = null },
    .{ .command = .close_group, .action = "close-group", .detailed_action = "win.close-group", .label = "Close editor group", .shortcut = null },
    .{ .command = .excerpt, .action = "excerpt", .detailed_action = "win.excerpt", .label = "Edit selection as excerpt", .shortcut = null },
    .{ .command = .grouped_undo, .action = "grouped-undo", .detailed_action = "win.grouped-undo", .label = "Undo grouped edit", .shortcut = null },
    .{ .command = .grouped_redo, .action = "grouped-redo", .detailed_action = "win.grouped-redo", .label = "Redo grouped edit", .shortcut = null },
    .{ .command = .open_folder, .action = "open-folder", .detailed_action = "win.open-folder", .label = "Open Folder…", .shortcut = null },
    .{ .command = .open_workspace, .action = "open-workspace", .detailed_action = "win.open-workspace", .label = "Open Workspace…", .shortcut = null },
    .{ .command = .workspace_roots, .action = "workspace-roots", .detailed_action = "win.workspace-roots", .label = "Workspace: Roots", .shortcut = null },
    .{ .command = .workspace_back, .action = "workspace-back", .detailed_action = "win.workspace-back", .label = "Workspace: Back", .shortcut = null },
    .{ .command = .workspace_rescan, .action = "workspace-rescan", .detailed_action = "win.workspace-rescan", .label = "Workspace: Rescan directory", .shortcut = null },
    .{ .command = .close_workspace, .action = "close-workspace", .detailed_action = "win.close-workspace", .label = "Close workspace (keep documents)", .shortcut = null },
    .{ .command = .quick_open, .action = "quick-open", .detailed_action = "win.quick-open", .label = "Quick Open…", .shortcut = "Ctrl+P" },
    .{ .command = .workspace_search, .action = "workspace-search", .detailed_action = "win.workspace-search", .label = "Search workspace…", .shortcut = "Ctrl+Shift+F" },
    .{ .command = .workspace_policy, .action = "workspace-policy", .detailed_action = "win.workspace-policy", .label = "Workspace: Settings and Trust…", .shortcut = null },
    .{ .command = .workspace_trust, .action = "workspace-trust", .detailed_action = "win.workspace-trust", .label = "Trust workspace…", .shortcut = null },
    .{ .command = .workspace_revoke, .action = "workspace-revoke", .detailed_action = "win.workspace-revoke", .label = "Workspace: Revoke trust", .shortcut = null },
    .{ .command = .save_workspace_session, .action = "save-workspace-session", .detailed_action = "win.save-workspace-session", .label = "Save Workspace Session", .shortcut = null },
    .{ .command = .restore_workspace_session, .action = "restore-workspace-session", .detailed_action = "win.restore-workspace-session", .label = "Restore Workspace Session", .shortcut = null },
    .{ .command = .toggle_explorer, .action = "toggle-explorer", .detailed_action = "win.toggle-explorer", .label = "Toggle Explorer dock", .shortcut = "Ctrl+B" },
    .{ .command = .toggle_search, .action = "toggle-search", .detailed_action = "win.toggle-search", .label = "Toggle Search dock", .shortcut = null },
    .{ .command = .focus_explorer, .action = "focus-explorer", .detailed_action = "win.focus-explorer", .label = "Focus Explorer", .shortcut = "Ctrl+Shift+E" },
    .{ .command = .focus_search, .action = "focus-search", .detailed_action = "win.focus-search", .label = "Focus Search", .shortcut = null },
    .{ .command = .focus_editor, .action = "focus-editor", .detailed_action = "win.focus-editor", .label = "Focus editor", .shortcut = "Ctrl+1" },
    .{ .command = .hide_panel, .action = "hide-panel", .detailed_action = "win.hide-panel", .label = "Hide active panel", .shortcut = "Ctrl+Shift+B" },
    .{ .command = .dock_left, .action = "dock-left", .detailed_action = "win.dock-left", .label = "Move active panel left", .shortcut = "Ctrl+Alt+Left" },
    .{ .command = .dock_right, .action = "dock-right", .detailed_action = "win.dock-right", .label = "Move active panel right", .shortcut = "Ctrl+Alt+Right" },
    .{ .command = .dock_bottom, .action = "dock-bottom", .detailed_action = "win.dock-bottom", .label = "Move active panel bottom", .shortcut = "Ctrl+Alt+Down" },
    .{ .command = .reset_docks, .action = "reset-docks", .detailed_action = "win.reset-docks", .label = "Reset dock layout", .shortcut = null },
    .{ .command = .dock_grow, .action = "dock-grow", .detailed_action = "win.dock-grow", .label = "Grow active dock", .shortcut = "Ctrl+Alt+PageUp" },
    .{ .command = .dock_shrink, .action = "dock-shrink", .detailed_action = "win.dock-shrink", .label = "Shrink active dock", .shortcut = "Ctrl+Alt+PageDown" },
    .{ .command = .next_tab, .action = "next-tab", .detailed_action = "win.next-tab", .label = "Next editor tab", .shortcut = "Ctrl+Tab" },
    .{ .command = .previous_tab, .action = "previous-tab", .detailed_action = "win.previous-tab", .label = "Previous editor tab", .shortcut = "Ctrl+Shift+Tab" },
    .{ .command = .new_window, .action = "new-window", .detailed_action = "win.new-window", .label = "New Window", .shortcut = "Ctrl+Shift+N" },
    .{ .command = .close_window, .action = "close-window", .detailed_action = "win.close-window", .label = "Close Window", .shortcut = "Ctrl+Shift+W" },
    .{ .command = .next_window, .action = "next-window", .detailed_action = "win.next-window", .label = "Next Window", .shortcut = null },
    .{ .command = .previous_window, .action = "previous-window", .detailed_action = "win.previous-window", .label = "Previous Window", .shortcut = null },
    .{ .command = .create_workspace_file, .action = "workspace-create-file", .detailed_action = "win.workspace-create-file", .label = "Explorer: New file…", .shortcut = null },
    .{ .command = .create_workspace_directory, .action = "workspace-create-directory", .detailed_action = "win.workspace-create-directory", .label = "Explorer: New directory…", .shortcut = null },
    .{ .command = .rename_workspace_entry, .action = "workspace-rename", .detailed_action = "win.workspace-rename", .label = "Explorer: Rename…", .shortcut = null },
    .{ .command = .move_workspace_entry, .action = "workspace-move", .detailed_action = "win.workspace-move", .label = "Explorer: Move…", .shortcut = null },
    .{ .command = .delete_workspace_entry, .action = "workspace-delete", .detailed_action = "win.workspace-delete", .label = "Explorer: Delete permanently…", .shortcut = null },
};

pub fn fromAction(action: []const u8) ?Command {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.action, action)) return entry.command;
    }
    return null;
}

/// GDK keyvals/modifier bits, kept independent of GTK so these tests need no
/// native libraries or display. Lock and mouse-button state are irrelevant;
/// Only explicitly registered modifier combinations become commands; Super,
/// Hyper, Meta and unknown modifier bits never do.
pub fn fromKey(key: u32, state: u32) ?Command {
    const shift = 1 << 0;
    const lock = 1 << 1;
    const ctrl = 1 << 2;
    const buttons = 0x1f << 8;
    const modifiers = state & ~@as(u32, lock | buttons);
    const lower = if (key >= 'A' and key <= 'Z') key + ('a' - 'A') else key;
    if (modifiers == ctrl | (1 << 3)) return switch (key) {
        0xff51 => .dock_left,
        0xff53 => .dock_right,
        0xff54 => .dock_bottom,
        0xff55 => .dock_grow,
        0xff56 => .dock_shrink,
        else => null,
    };
    if (modifiers == ctrl | shift) return switch (lower) {
        0xff09, 0xfe20 => .previous_tab, // Tab and ISO_Left_Tab
        'n' => .new_window,
        'w' => .close_window,
        'e' => .focus_explorer,
        'b' => .hide_panel,
        's' => .save_as,
        'p' => .command_palette,
        'f' => .workspace_search,
        else => null,
    };
    if (modifiers == shift and key == 0xffc7) return .spelling; // GDK_KEY_F10
    if (modifiers != ctrl) return null;
    return switch (lower) {
        0xff09 => .next_tab,
        0xfe20 => .previous_tab,
        'b' => .toggle_explorer,
        '1' => .focus_editor,
        'n' => .new,
        'o' => .open,
        'p' => .quick_open,
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
    const actions = [_][]const u8{ "new", "open", "save", "save-as", "reload", "find", "goto", "spelling", "preferences", "about", "close", "quit", "command-palette", "split-group", "focus-next-group", "focus-previous-group", "close-group", "excerpt", "grouped-undo", "grouped-redo", "open-folder", "open-workspace", "workspace-roots", "workspace-back", "workspace-rescan", "close-workspace", "quick-open", "workspace-search", "workspace-policy", "workspace-trust", "workspace-revoke", "save-workspace-session", "restore-workspace-session", "toggle-explorer", "toggle-search", "focus-explorer", "focus-search", "focus-editor", "hide-panel", "dock-left", "dock-right", "dock-bottom", "reset-docks", "dock-grow", "dock-shrink", "next-tab", "previous-tab", "new-window", "close-window", "next-window", "previous-window", "workspace-create-file", "workspace-create-directory", "workspace-rename", "workspace-move", "workspace-delete" };
    for (entries, actions, 0..) |entry, action, index| {
        try std.testing.expectEqual(index, @backingInt(entry.command));
        try std.testing.expectEqualStrings(action, entry.action);
        try std.testing.expectEqual(entry.command, fromAction(action).?);
        try std.testing.expectEqualStrings(action, entry.detailed_action[4..]);
        try std.testing.expect(std.mem.startsWith(u8, entry.detailed_action, "win."));
        try std.testing.expect(entry.label.len > 0);
        try std.testing.expectEqualStrings(entry.label, entry.command.metadata().label);
        for (entries[0..index]) |other| try std.testing.expect(!std.mem.eql(u8, other.action, action));
    }
    for ([_][]const u8{ "", "win.save", "SAVE", "save_as", "goto-line", "terminal", "agent" }) |unknown| {
        try std.testing.expectEqual(@as(?Command, null), fromAction(unknown));
    }
}

test "native window actions are owner scoped and distinct from document actions" {
    try std.testing.expectEqual(Command.new, fromKey('n', 4).?);
    try std.testing.expectEqual(Command.new_window, fromKey('N', 5).?);
    try std.testing.expectEqual(Command.close, fromKey('w', 4).?);
    try std.testing.expectEqual(Command.close_window, fromKey('W', 5).?);
    try std.testing.expectEqualStrings("Quit All", Command.quit.metadata().label);
    inline for (.{ Command.new_window, Command.close_window, Command.next_window, Command.previous_window }) |command| {
        const entry = command.metadata();
        try std.testing.expect(std.mem.startsWith(u8, entry.detailed_action, "win."));
        try std.testing.expectEqual(command, fromAction(entry.action).?);
    }
    try std.testing.expectEqual(@as(?[:0]const u8, null), Command.next_window.metadata().shortcut);
    try std.testing.expectEqual(@as(?[:0]const u8, null), Command.previous_window.metadata().shortcut);
}

test "workspace sessions are explicit palette actions without automatic shortcuts" {
    inline for (.{ Command.save_workspace_session, Command.restore_workspace_session }) |command| {
        const metadata = command.metadata();
        try std.testing.expectEqual(command, fromAction(metadata.action).?);
        try std.testing.expectEqual(@as(?[:0]const u8, null), metadata.shortcut);
    }
    try std.testing.expectEqualStrings("Save Workspace Session", Command.save_workspace_session.metadata().label);
    try std.testing.expectEqualStrings("Restore Workspace Session", Command.restore_workspace_session.metadata().label);
}

test "dock shortcuts are explicit and do not claim unmodified typing or AltGr letters" {
    try std.testing.expectEqual(Command.toggle_explorer, fromKey('b', 4).?);
    try std.testing.expectEqual(Command.focus_explorer, fromKey('E', 5).?);
    try std.testing.expectEqual(Command.focus_editor, fromKey('1', 4).?);
    try std.testing.expectEqual(Command.hide_panel, fromKey('B', 5).?);
    try std.testing.expectEqual(Command.dock_left, fromKey(0xff51, 12).?);
    try std.testing.expectEqual(Command.dock_right, fromKey(0xff53, 12).?);
    try std.testing.expectEqual(Command.dock_bottom, fromKey(0xff54, 12).?);
    try std.testing.expectEqual(Command.dock_grow, fromKey(0xff55, 12).?);
    try std.testing.expectEqual(Command.dock_shrink, fromKey(0xff56, 12).?);
    for ([_]u32{ 'b', 'e', '1', 0xff51, 0xff53, 0xff54 }) |key| {
        try std.testing.expectEqual(@as(?Command, null), fromKey(key, 0));
        try std.testing.expectEqual(@as(?Command, null), fromKey(key, 8));
        try std.testing.expectEqual(@as(?Command, null), fromKey(key, 4 | (1 << 26)));
    }
    try std.testing.expectEqual(@as(?Command, null), fromKey('e', 12));
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
        .{ .key = 'N', .state = 5, .command = .new_window },
        .{ .key = 'W', .state = 5, .command = .close_window },
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
        .{ .key = 'p', .state = 4, .command = .quick_open },
        .{ .key = 'F', .state = 5, .command = .workspace_search },
        .{ .key = 'p', .state = 5, .command = .command_palette },
        .{ .key = 'P', .state = 5, .command = .command_palette },
        .{ .key = 0xffc7, .state = 1, .command = .spelling },
    }) |case| try std.testing.expectEqual(case.command, fromKey(case.key, case.state).?);
}

test "tab navigation is explicit and rejects text input and unrelated modifiers" {
    try std.testing.expectEqual(Command.next_tab, fromKey(0xff09, 4).?);
    try std.testing.expectEqual(Command.previous_tab, fromKey(0xff09, 5).?);
    try std.testing.expectEqual(Command.previous_tab, fromKey(0xfe20, 5).?);
    try std.testing.expectEqual(Command.previous_tab, fromKey(0xfe20, 4).?);
    for ([_]u32{ 0xff09, 0xfe20 }) |key| {
        for ([_]u32{ 0, 1, 8, 12, 4 | (1 << 26) }) |state| {
            try std.testing.expectEqual(@as(?Command, null), fromKey(key, state));
        }
    }
}

test "unmapped editor keys and other modifiers remain with the parent" {
    for ([_]u32{ 0xff1b, 0xffc0, 'z', 'Z', 'y', '+', '=', '-', '0' }) |key| {
        try std.testing.expectEqual(@as(?Command, null), fromKey(key, 4));
    }
    for ([_]u32{ 0, 1, 4 | 8, 4 | (1 << 26), 4 | (1 << 27), 4 | (1 << 28), 4 | (1 << 7) }) |state| {
        try std.testing.expectEqual(@as(?Command, null), fromKey('n', state));
    }
    try std.testing.expectEqual(@as(?Command, null), fromKey(0xffc7, 0));
    try std.testing.expectEqual(@as(?Command, null), fromKey(0xffc7, 5));
    try std.testing.expectEqual(Command.save, fromKey('s', 4 | (1 << 8)).?);
}
