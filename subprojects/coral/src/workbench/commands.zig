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
    toggle_source_control,
    focus_source_control,
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
    recent_projects,
    open_buffers,
    forget_project_session,
    add_workspace_root,
    remove_workspace_root,
    save_workspace_as,
    language_start,
    language_stop,
    language_restart,
    language_status,
    language_completion,
    language_hover,
    language_signature,
    language_definition,
    language_declaration,
    language_type_definition,
    language_implementation,
    language_references,
    language_document_symbols,
    language_workspace_symbols,
    language_problems,
    language_formatting,
    language_range_formatting,
    language_rename,
    language_code_actions,
    language_semantic_tokens,
    language_inlay_hints,
    language_code_lenses,
    language_document_links,
    git_status,
    git_refresh,
    git_diff,
    git_staged_diff,
    git_stage,
    git_unstage,
    git_stage_hunk,
    git_unstage_hunk,
    git_next_hunk,
    git_previous_hunk,
    git_commit,
    git_uncommit,
    git_stage_tracked_commit,
    git_branches,
    git_create_branch,
    git_switch_branch,
    git_delete_branch,
    git_tags,
    git_create_tag,
    git_worktrees,
    git_add_worktree,
    git_remove_worktree,
    git_stash_push,
    git_stash_list,
    git_stash_apply,
    git_stash_pop,
    git_stash_drop,
    git_conflicts,
    git_resolve_current,
    git_resolve_incoming,
    git_resolve_both,
    git_conflict_manual,
    git_continue,
    git_abort,
    git_remotes,
    git_fetch,
    git_pull,
    git_push,
    git_force_push,
    git_history,
    git_blame,
    git_commit_diff,
    git_permalink,
    git_project_diff,
    git_project_diff_refresh,
    git_project_diff_next_hunk,
    git_project_diff_previous_hunk,
    git_project_diff_stage_hunk,
    git_project_diff_unstage_hunk,
    git_project_diff_stage_selection,
    git_project_diff_unstage_selection,
    git_project_diff_unified,
    git_project_diff_split,
    git_project_diff_word,
    toggle_terminal,
    focus_terminal,
    terminal_new,
    terminal_close,
    terminal_restart,
    terminal_cancel,
    tasks_show,
    tasks_run,
    tasks_stop,
    tasks_restart,

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
            .toggle_source_control => i18n.dtr("coral", "Toggle Source Control dock"),
            .focus_source_control => i18n.dtr("coral", "Focus Source Control"),
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
            .recent_projects => i18n.dtr("coral", "Open Recent Project…"),
            .open_buffers => i18n.dtr("coral", "Open Buffers…"),
            .forget_project_session => i18n.dtr("coral", "Forget Recent Session…"),
            .add_workspace_root => i18n.dtr("coral", "Workspace: Add Folder…"),
            .remove_workspace_root => i18n.dtr("coral", "Workspace: Remove Selected Root…"),
            .save_workspace_as => i18n.dtr("coral", "Save Workspace As…"),
            .language_start => i18n.dtr("coral", "Language: Start / resume…"),
            .language_stop => i18n.dtr("coral", "Language: Stop all sessions / pause workspace"),
            .language_restart => i18n.dtr("coral", "Language: Restart current server"),
            .language_status => i18n.dtr("coral", "Language: Status"),
            .language_completion => i18n.dtr("coral", "Language: Completion…"),
            .language_hover => i18n.dtr("coral", "Language: Hover"),
            .language_signature => i18n.dtr("coral", "Language: Signature help"),
            .language_definition => i18n.dtr("coral", "Language: Definition…"),
            .language_declaration => i18n.dtr("coral", "Language: Declaration…"),
            .language_type_definition => i18n.dtr("coral", "Language: Type definition…"),
            .language_implementation => i18n.dtr("coral", "Language: Implementation…"),
            .language_references => i18n.dtr("coral", "Language: References…"),
            .language_document_symbols => i18n.dtr("coral", "Language: Document symbols…"),
            .language_workspace_symbols => i18n.dtr("coral", "Language: Workspace symbols…"),
            .language_problems => i18n.dtr("coral", "Language: Problems"),
            .language_formatting => i18n.dtr("coral", "Language: Format document…"),
            .language_range_formatting => i18n.dtr("coral", "Language: Format selection…"),
            .language_rename => i18n.dtr("coral", "Language: Rename…"),
            .language_code_actions => i18n.dtr("coral", "Language: Code actions…"),
            .language_semantic_tokens => i18n.dtr("coral", "Language: Refresh semantic tokens"),
            .language_inlay_hints => i18n.dtr("coral", "Language: Inlay hints…"),
            .language_code_lenses => i18n.dtr("coral", "Language: Code lenses…"),
            .language_document_links => i18n.dtr("coral", "Language: Document links…"),
            .git_status => i18n.dtr("coral", "Git: Source Control…"),
            .git_refresh => i18n.dtr("coral", "Git: Refresh repositories"),
            .git_diff => i18n.dtr("coral", "Git: Unstaged diff"),
            .git_staged_diff => i18n.dtr("coral", "Git: Staged diff"),
            .git_stage => i18n.dtr("coral", "Git: Stage selected file…"),
            .git_unstage => i18n.dtr("coral", "Git: Unstage selected file…"),
            .git_stage_hunk => i18n.dtr("coral", "Git: Stage selected hunk…"),
            .git_unstage_hunk => i18n.dtr("coral", "Git: Unstage selected hunk…"),
            .git_next_hunk => i18n.dtr("coral", "Git: Next hunk"),
            .git_previous_hunk => i18n.dtr("coral", "Git: Previous hunk"),
            .git_commit => i18n.dtr("coral", "Git: Commit staged…"),
            .git_uncommit => i18n.dtr("coral", "Git: Uncommit last…"),
            .git_stage_tracked_commit => i18n.dtr("coral", "Git: Stage tracked and commit…"),
            .git_branches => i18n.dtr("coral", "Git: Branches…"),
            .git_create_branch => i18n.dtr("coral", "Git: Create branch…"),
            .git_switch_branch => i18n.dtr("coral", "Git: Switch branch…"),
            .git_delete_branch => i18n.dtr("coral", "Git: Delete branch…"),
            .git_tags => i18n.dtr("coral", "Git: Tags…"),
            .git_create_tag => i18n.dtr("coral", "Git: Create lightweight tag…"),
            .git_worktrees => i18n.dtr("coral", "Git: Worktrees…"),
            .git_add_worktree => i18n.dtr("coral", "Git: Add worktree…"),
            .git_remove_worktree => i18n.dtr("coral", "Git: Remove worktree…"),
            .git_stash_push => i18n.dtr("coral", "Git: Stash push…"),
            .git_stash_list => i18n.dtr("coral", "Git: Stash list…"),
            .git_stash_apply => i18n.dtr("coral", "Git: Stash apply…"),
            .git_stash_pop => i18n.dtr("coral", "Git: Stash pop…"),
            .git_stash_drop => i18n.dtr("coral", "Git: Stash drop…"),
            .git_conflicts => i18n.dtr("coral", "Git: Conflicts…"),
            .git_resolve_current => i18n.dtr("coral", "Git: Resolve conflict using current…"),
            .git_resolve_incoming => i18n.dtr("coral", "Git: Resolve conflict using incoming…"),
            .git_resolve_both => i18n.dtr("coral", "Git: Resolve conflict using both…"),
            .git_conflict_manual => i18n.dtr("coral", "Git: Manual conflict resolution"),
            .git_continue => i18n.dtr("coral", "Git: Continue merge/rebase…"),
            .git_abort => i18n.dtr("coral", "Git: Abort merge/rebase…"),
            .git_remotes => i18n.dtr("coral", "Git: Remotes…"),
            .git_fetch => i18n.dtr("coral", "Git: Fetch…"),
            .git_pull => i18n.dtr("coral", "Git: Pull…"),
            .git_push => i18n.dtr("coral", "Git: Push…"),
            .git_force_push => i18n.dtr("coral", "Git: Force push with lease…"),
            .git_history => i18n.dtr("coral", "Git: File history…"),
            .git_blame => i18n.dtr("coral", "Git: Blame…"),
            .git_commit_diff => i18n.dtr("coral", "Git: Commit diff…"),
            .git_permalink => i18n.dtr("coral", "Git: Open permalink…"),
            .git_project_diff => i18n.dtr("coral", "Git: Project Diff…"),
            .git_project_diff_refresh => i18n.dtr("coral", "Git: Refresh Project Diff"),
            .git_project_diff_next_hunk => i18n.dtr("coral", "Git: Project Diff next hunk"),
            .git_project_diff_previous_hunk => i18n.dtr("coral", "Git: Project Diff previous hunk"),
            .git_project_diff_stage_hunk => i18n.dtr("coral", "Git: Project Diff stage hunk…"),
            .git_project_diff_unstage_hunk => i18n.dtr("coral", "Git: Project Diff unstage hunk…"),
            .git_project_diff_stage_selection => i18n.dtr("coral", "Git: Project Diff stage selection…"),
            .git_project_diff_unstage_selection => i18n.dtr("coral", "Git: Project Diff unstage selection…"),
            .git_project_diff_unified => i18n.dtr("coral", "Git: Project Diff unified view"),
            .git_project_diff_split => i18n.dtr("coral", "Git: Project Diff split view"),
            .git_project_diff_word => i18n.dtr("coral", "Git: Project Diff word view"),
            .toggle_terminal => i18n.dtr("coral", "Toggle Terminal dock"),
            .focus_terminal => i18n.dtr("coral", "Focus Terminal"),
            .terminal_new => i18n.dtr("coral", "Terminal: New session"),
            .terminal_close => i18n.dtr("coral", "Terminal: Close session"),
            .terminal_restart => i18n.dtr("coral", "Terminal: Restart session"),
            .terminal_cancel => i18n.dtr("coral", "Terminal: Cancel running command"),
            .tasks_show => i18n.dtr("coral", "Tasks: Run task…"),
            .tasks_run => i18n.dtr("coral", "Tasks: Run selected task"),
            .tasks_stop => i18n.dtr("coral", "Tasks: Stop task"),
            .tasks_restart => i18n.dtr("coral", "Tasks: Restart task"),
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
    .{ .command = .toggle_source_control, .action = "toggle-source-control", .detailed_action = "win.toggle-source-control", .label = "Toggle Source Control dock", .shortcut = null },
    .{ .command = .focus_source_control, .action = "focus-source-control", .detailed_action = "win.focus-source-control", .label = "Focus Source Control", .shortcut = null },
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
    .{ .command = .recent_projects, .action = "recent-projects", .detailed_action = "win.recent-projects", .label = "Open Recent Project…", .shortcut = "Ctrl+Alt+P" },
    .{ .command = .open_buffers, .action = "open-buffers", .detailed_action = "win.open-buffers", .label = "Open Buffers…", .shortcut = "Ctrl+Shift+O" },
    .{ .command = .forget_project_session, .action = "forget-project-session", .detailed_action = "win.forget-project-session", .label = "Forget Recent Session…", .shortcut = null },
    .{ .command = .add_workspace_root, .action = "workspace-add-root", .detailed_action = "win.workspace-add-root", .label = "Workspace: Add Folder…", .shortcut = null },
    .{ .command = .remove_workspace_root, .action = "workspace-remove-root", .detailed_action = "win.workspace-remove-root", .label = "Workspace: Remove Selected Root…", .shortcut = null },
    .{ .command = .save_workspace_as, .action = "save-workspace-as", .detailed_action = "win.save-workspace-as", .label = "Save Workspace As…", .shortcut = null },
    .{ .command = .language_start, .action = "language-start", .detailed_action = "win.language-start", .label = "Language: Start / resume…", .shortcut = null },
    .{ .command = .language_stop, .action = "language-stop", .detailed_action = "win.language-stop", .label = "Language: Stop all sessions / pause workspace", .shortcut = null },
    .{ .command = .language_restart, .action = "language-restart", .detailed_action = "win.language-restart", .label = "Language: Restart current server", .shortcut = null },
    .{ .command = .language_status, .action = "language-status", .detailed_action = "win.language-status", .label = "Language: Status", .shortcut = null },
    .{ .command = .language_completion, .action = "language-completion", .detailed_action = "win.language-completion", .label = "Language: Completion…", .shortcut = null },
    .{ .command = .language_hover, .action = "language-hover", .detailed_action = "win.language-hover", .label = "Language: Hover", .shortcut = null },
    .{ .command = .language_signature, .action = "language-signature", .detailed_action = "win.language-signature", .label = "Language: Signature help", .shortcut = null },
    .{ .command = .language_definition, .action = "language-definition", .detailed_action = "win.language-definition", .label = "Language: Definition…", .shortcut = null },
    .{ .command = .language_declaration, .action = "language-declaration", .detailed_action = "win.language-declaration", .label = "Language: Declaration…", .shortcut = null },
    .{ .command = .language_type_definition, .action = "language-type-definition", .detailed_action = "win.language-type-definition", .label = "Language: Type definition…", .shortcut = null },
    .{ .command = .language_implementation, .action = "language-implementation", .detailed_action = "win.language-implementation", .label = "Language: Implementation…", .shortcut = null },
    .{ .command = .language_references, .action = "language-references", .detailed_action = "win.language-references", .label = "Language: References…", .shortcut = null },
    .{ .command = .language_document_symbols, .action = "language-document-symbols", .detailed_action = "win.language-document-symbols", .label = "Language: Document symbols…", .shortcut = null },
    .{ .command = .language_workspace_symbols, .action = "language-workspace-symbols", .detailed_action = "win.language-workspace-symbols", .label = "Language: Workspace symbols…", .shortcut = null },
    .{ .command = .language_problems, .action = "language-problems", .detailed_action = "win.language-problems", .label = "Language: Problems", .shortcut = null },
    .{ .command = .language_formatting, .action = "language-formatting", .detailed_action = "win.language-formatting", .label = "Language: Format document…", .shortcut = null },
    .{ .command = .language_range_formatting, .action = "language-range-formatting", .detailed_action = "win.language-range-formatting", .label = "Language: Format selection…", .shortcut = null },
    .{ .command = .language_rename, .action = "language-rename", .detailed_action = "win.language-rename", .label = "Language: Rename…", .shortcut = null },
    .{ .command = .language_code_actions, .action = "language-code-actions", .detailed_action = "win.language-code-actions", .label = "Language: Code actions…", .shortcut = null },
    .{ .command = .language_semantic_tokens, .action = "language-semantic-tokens", .detailed_action = "win.language-semantic-tokens", .label = "Language: Refresh semantic tokens", .shortcut = null },
    .{ .command = .language_inlay_hints, .action = "language-inlay-hints", .detailed_action = "win.language-inlay-hints", .label = "Language: Inlay hints…", .shortcut = null },
    .{ .command = .language_code_lenses, .action = "language-code-lenses", .detailed_action = "win.language-code-lenses", .label = "Language: Code lenses…", .shortcut = null },
    .{ .command = .language_document_links, .action = "language-document-links", .detailed_action = "win.language-document-links", .label = "Language: Document links…", .shortcut = null },
    .{ .command = .git_status, .action = "git-status", .detailed_action = "win.git-status", .label = "Git: Source Control…", .shortcut = null },
    .{ .command = .git_refresh, .action = "git-refresh", .detailed_action = "win.git-refresh", .label = "Git: Refresh repositories", .shortcut = null },
    .{ .command = .git_diff, .action = "git-diff", .detailed_action = "win.git-diff", .label = "Git: Unstaged diff", .shortcut = null },
    .{ .command = .git_staged_diff, .action = "git-staged-diff", .detailed_action = "win.git-staged-diff", .label = "Git: Staged diff", .shortcut = null },
    .{ .command = .git_stage, .action = "git-stage", .detailed_action = "win.git-stage", .label = "Git: Stage selected file…", .shortcut = null },
    .{ .command = .git_unstage, .action = "git-unstage", .detailed_action = "win.git-unstage", .label = "Git: Unstage selected file…", .shortcut = null },
    .{ .command = .git_stage_hunk, .action = "git-stage-hunk", .detailed_action = "win.git-stage-hunk", .label = "Git: Stage selected hunk…", .shortcut = null },
    .{ .command = .git_unstage_hunk, .action = "git-unstage-hunk", .detailed_action = "win.git-unstage-hunk", .label = "Git: Unstage selected hunk…", .shortcut = null },
    .{ .command = .git_next_hunk, .action = "git-next-hunk", .detailed_action = "win.git-next-hunk", .label = "Git: Next hunk", .shortcut = null },
    .{ .command = .git_previous_hunk, .action = "git-previous-hunk", .detailed_action = "win.git-previous-hunk", .label = "Git: Previous hunk", .shortcut = null },
    .{ .command = .git_commit, .action = "git-commit", .detailed_action = "win.git-commit", .label = "Git: Commit staged…", .shortcut = null },
    .{ .command = .git_uncommit, .action = "git-uncommit", .detailed_action = "win.git-uncommit", .label = "Git: Uncommit last…", .shortcut = null },
    .{ .command = .git_stage_tracked_commit, .action = "git-stage-tracked-commit", .detailed_action = "win.git-stage-tracked-commit", .label = "Git: Stage tracked and commit…", .shortcut = null },
    .{ .command = .git_branches, .action = "git-branches", .detailed_action = "win.git-branches", .label = "Git: Branches…", .shortcut = null },
    .{ .command = .git_create_branch, .action = "git-create-branch", .detailed_action = "win.git-create-branch", .label = "Git: Create branch…", .shortcut = null },
    .{ .command = .git_switch_branch, .action = "git-switch-branch", .detailed_action = "win.git-switch-branch", .label = "Git: Switch branch…", .shortcut = null },
    .{ .command = .git_delete_branch, .action = "git-delete-branch", .detailed_action = "win.git-delete-branch", .label = "Git: Delete branch…", .shortcut = null },
    .{ .command = .git_tags, .action = "git-tags", .detailed_action = "win.git-tags", .label = "Git: Tags…", .shortcut = null },
    .{ .command = .git_create_tag, .action = "git-create-tag", .detailed_action = "win.git-create-tag", .label = "Git: Create lightweight tag…", .shortcut = null },
    .{ .command = .git_worktrees, .action = "git-worktrees", .detailed_action = "win.git-worktrees", .label = "Git: Worktrees…", .shortcut = null },
    .{ .command = .git_add_worktree, .action = "git-add-worktree", .detailed_action = "win.git-add-worktree", .label = "Git: Add worktree…", .shortcut = null },
    .{ .command = .git_remove_worktree, .action = "git-remove-worktree", .detailed_action = "win.git-remove-worktree", .label = "Git: Remove worktree…", .shortcut = null },
    .{ .command = .git_stash_push, .action = "git-stash-push", .detailed_action = "win.git-stash-push", .label = "Git: Stash push…", .shortcut = null },
    .{ .command = .git_stash_list, .action = "git-stash-list", .detailed_action = "win.git-stash-list", .label = "Git: Stash list…", .shortcut = null },
    .{ .command = .git_stash_apply, .action = "git-stash-apply", .detailed_action = "win.git-stash-apply", .label = "Git: Stash apply…", .shortcut = null },
    .{ .command = .git_stash_pop, .action = "git-stash-pop", .detailed_action = "win.git-stash-pop", .label = "Git: Stash pop…", .shortcut = null },
    .{ .command = .git_stash_drop, .action = "git-stash-drop", .detailed_action = "win.git-stash-drop", .label = "Git: Stash drop…", .shortcut = null },
    .{ .command = .git_conflicts, .action = "git-conflicts", .detailed_action = "win.git-conflicts", .label = "Git: Conflicts…", .shortcut = null },
    .{ .command = .git_resolve_current, .action = "git-resolve-current", .detailed_action = "win.git-resolve-current", .label = "Git: Resolve conflict using current…", .shortcut = null },
    .{ .command = .git_resolve_incoming, .action = "git-resolve-incoming", .detailed_action = "win.git-resolve-incoming", .label = "Git: Resolve conflict using incoming…", .shortcut = null },
    .{ .command = .git_resolve_both, .action = "git-resolve-both", .detailed_action = "win.git-resolve-both", .label = "Git: Resolve conflict using both…", .shortcut = null },
    .{ .command = .git_conflict_manual, .action = "git-conflict-manual", .detailed_action = "win.git-conflict-manual", .label = "Git: Manual conflict resolution", .shortcut = null },
    .{ .command = .git_continue, .action = "git-continue", .detailed_action = "win.git-continue", .label = "Git: Continue merge/rebase…", .shortcut = null },
    .{ .command = .git_abort, .action = "git-abort", .detailed_action = "win.git-abort", .label = "Git: Abort merge/rebase…", .shortcut = null },
    .{ .command = .git_remotes, .action = "git-remotes", .detailed_action = "win.git-remotes", .label = "Git: Remotes…", .shortcut = null },
    .{ .command = .git_fetch, .action = "git-fetch", .detailed_action = "win.git-fetch", .label = "Git: Fetch…", .shortcut = null },
    .{ .command = .git_pull, .action = "git-pull", .detailed_action = "win.git-pull", .label = "Git: Pull…", .shortcut = null },
    .{ .command = .git_push, .action = "git-push", .detailed_action = "win.git-push", .label = "Git: Push…", .shortcut = null },
    .{ .command = .git_force_push, .action = "git-force-push", .detailed_action = "win.git-force-push", .label = "Git: Force push with lease…", .shortcut = null },
    .{ .command = .git_history, .action = "git-history", .detailed_action = "win.git-history", .label = "Git: File history…", .shortcut = null },
    .{ .command = .git_blame, .action = "git-blame", .detailed_action = "win.git-blame", .label = "Git: Blame…", .shortcut = null },
    .{ .command = .git_commit_diff, .action = "git-commit-diff", .detailed_action = "win.git-commit-diff", .label = "Git: Commit diff…", .shortcut = null },
    .{ .command = .git_permalink, .action = "git-permalink", .detailed_action = "win.git-permalink", .label = "Git: Open permalink…", .shortcut = null },
    .{ .command = .git_project_diff, .action = "git-project-diff", .detailed_action = "win.git-project-diff", .label = "Git: Project Diff…", .shortcut = null },
    .{ .command = .git_project_diff_refresh, .action = "git-project-diff-refresh", .detailed_action = "win.git-project-diff-refresh", .label = "Git: Refresh Project Diff", .shortcut = null },
    .{ .command = .git_project_diff_next_hunk, .action = "git-project-diff-next-hunk", .detailed_action = "win.git-project-diff-next-hunk", .label = "Git: Project Diff next hunk", .shortcut = null },
    .{ .command = .git_project_diff_previous_hunk, .action = "git-project-diff-previous-hunk", .detailed_action = "win.git-project-diff-previous-hunk", .label = "Git: Project Diff previous hunk", .shortcut = null },
    .{ .command = .git_project_diff_stage_hunk, .action = "git-project-diff-stage-hunk", .detailed_action = "win.git-project-diff-stage-hunk", .label = "Git: Project Diff stage hunk…", .shortcut = null },
    .{ .command = .git_project_diff_unstage_hunk, .action = "git-project-diff-unstage-hunk", .detailed_action = "win.git-project-diff-unstage-hunk", .label = "Git: Project Diff unstage hunk…", .shortcut = null },
    .{ .command = .git_project_diff_stage_selection, .action = "git-project-diff-stage-selection", .detailed_action = "win.git-project-diff-stage-selection", .label = "Git: Project Diff stage selection…", .shortcut = null },
    .{ .command = .git_project_diff_unstage_selection, .action = "git-project-diff-unstage-selection", .detailed_action = "win.git-project-diff-unstage-selection", .label = "Git: Project Diff unstage selection…", .shortcut = null },
    .{ .command = .git_project_diff_unified, .action = "git-project-diff-unified", .detailed_action = "win.git-project-diff-unified", .label = "Git: Project Diff unified view", .shortcut = null },
    .{ .command = .git_project_diff_split, .action = "git-project-diff-split", .detailed_action = "win.git-project-diff-split", .label = "Git: Project Diff split view", .shortcut = null },
    .{ .command = .git_project_diff_word, .action = "git-project-diff-word", .detailed_action = "win.git-project-diff-word", .label = "Git: Project Diff word view", .shortcut = null },
    .{ .command = .toggle_terminal, .action = "toggle-terminal", .detailed_action = "win.toggle-terminal", .label = "Toggle Terminal dock", .shortcut = null },
    .{ .command = .focus_terminal, .action = "focus-terminal", .detailed_action = "win.focus-terminal", .label = "Focus Terminal", .shortcut = null },
    .{ .command = .terminal_new, .action = "terminal-new", .detailed_action = "win.terminal-new", .label = "Terminal: New session", .shortcut = null },
    .{ .command = .terminal_close, .action = "terminal-close", .detailed_action = "win.terminal-close", .label = "Terminal: Close session", .shortcut = null },
    .{ .command = .terminal_restart, .action = "terminal-restart", .detailed_action = "win.terminal-restart", .label = "Terminal: Restart session", .shortcut = null },
    .{ .command = .terminal_cancel, .action = "terminal-cancel", .detailed_action = "win.terminal-cancel", .label = "Terminal: Cancel running command", .shortcut = null },
    .{ .command = .tasks_show, .action = "tasks-show", .detailed_action = "win.tasks-show", .label = "Tasks: Run task…", .shortcut = null },
    .{ .command = .tasks_run, .action = "tasks-run", .detailed_action = "win.tasks-run", .label = "Tasks: Run selected task", .shortcut = null },
    .{ .command = .tasks_stop, .action = "tasks-stop", .detailed_action = "win.tasks-stop", .label = "Tasks: Stop task", .shortcut = null },
    .{ .command = .tasks_restart, .action = "tasks-restart", .detailed_action = "win.tasks-restart", .label = "Tasks: Restart task", .shortcut = null },
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
    if (modifiers == ctrl | (1 << 3) and lower == 'p') return .recent_projects;
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
        'o' => .open_buffers,
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
    const actions = [_][]const u8{ "new", "open", "save", "save-as", "reload", "find", "goto", "spelling", "preferences", "about", "close", "quit", "command-palette", "split-group", "focus-next-group", "focus-previous-group", "close-group", "excerpt", "grouped-undo", "grouped-redo", "open-folder", "open-workspace", "workspace-roots", "workspace-back", "workspace-rescan", "close-workspace", "quick-open", "workspace-search", "workspace-policy", "workspace-trust", "workspace-revoke", "save-workspace-session", "restore-workspace-session", "toggle-explorer", "toggle-search", "toggle-source-control", "focus-source-control", "focus-explorer", "focus-search", "focus-editor", "hide-panel", "dock-left", "dock-right", "dock-bottom", "reset-docks", "dock-grow", "dock-shrink", "next-tab", "previous-tab", "new-window", "close-window", "next-window", "previous-window", "workspace-create-file", "workspace-create-directory", "workspace-rename", "workspace-move", "workspace-delete", "recent-projects", "open-buffers", "forget-project-session", "workspace-add-root", "workspace-remove-root", "save-workspace-as", "language-start", "language-stop", "language-restart", "language-status", "language-completion", "language-hover", "language-signature", "language-definition", "language-declaration", "language-type-definition", "language-implementation", "language-references", "language-document-symbols", "language-workspace-symbols", "language-problems", "language-formatting", "language-range-formatting", "language-rename", "language-code-actions", "language-semantic-tokens", "language-inlay-hints", "language-code-lenses", "language-document-links", "git-status", "git-refresh", "git-diff", "git-staged-diff", "git-stage", "git-unstage", "git-stage-hunk", "git-unstage-hunk", "git-next-hunk", "git-previous-hunk", "git-commit", "git-uncommit", "git-stage-tracked-commit", "git-branches", "git-create-branch", "git-switch-branch", "git-delete-branch", "git-tags", "git-create-tag", "git-worktrees", "git-add-worktree", "git-remove-worktree", "git-stash-push", "git-stash-list", "git-stash-apply", "git-stash-pop", "git-stash-drop", "git-conflicts", "git-resolve-current", "git-resolve-incoming", "git-resolve-both", "git-conflict-manual", "git-continue", "git-abort", "git-remotes", "git-fetch", "git-pull", "git-push", "git-force-push", "git-history", "git-blame", "git-commit-diff", "git-permalink", "git-project-diff", "git-project-diff-refresh", "git-project-diff-next-hunk", "git-project-diff-previous-hunk", "git-project-diff-stage-hunk", "git-project-diff-unstage-hunk", "git-project-diff-stage-selection", "git-project-diff-unstage-selection", "git-project-diff-unified", "git-project-diff-split", "git-project-diff-word", "toggle-terminal", "focus-terminal", "terminal-new", "terminal-close", "terminal-restart", "terminal-cancel", "tasks-show", "tasks-run", "tasks-stop", "tasks-restart" };
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
