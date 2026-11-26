//! Read the agent worktree into a temporary Git index. Applying a review only edits a Coral buffer.
const std = @import("std");
const u = @import("c.zig");
const c = u.c;
const a = u.a;
const git = @import("workspace_worktree.zig");
const diff = @import("git/diff_render.zig");
const hunk = @import("git/hunk.zig");
const codec = @import("platform/codec.zig");
const App = @import("app.zig").App;
const Document = @import("document.zig").Document;
const i18n = @import("i18n");
const Op = enum { patch, merge };
const Job = struct {
    review: *Review,
    generation: u64,
    op: Op,
    root: [:0]u8,
    base: [:0]u8,
    path: [:0]u8,
    local: [:0]u8,
    document: u64 = 0,
    revision: u64 = 0,
    ordinal: usize = 0,
    patch: ?[:0]u8 = null,
    target_tree: ?[:0]u8 = null,
    merged: ?[:0]u8 = null,
    theirs: ?[:0]u8 = null,
    err: ?anyerror = null,
    fn deinit(self: *Job) void {
        for ([_][:0]u8{ self.root, self.base, self.path, self.local }) |s| a.free(s);
        if (self.patch) |s| a.free(s);
        if (self.target_tree) |s| a.free(s);
        if (self.merged) |s| a.free(s);
        if (self.theirs) |s| a.free(s);
        a.destroy(self);
    }
};
const Receipt = struct {
    review: ?*Review,
    generation: u64,
    tree: [:0]u8,
    key: [64]u8,

    fn finish(context: *anyopaque, durable: bool) void {
        const receipt = u.cast(Receipt, context);
        defer a.destroy(receipt);
        defer a.free(receipt.tree);
        var confirmed = durable;
        if (durable) {
            @import("workspace_state.zig").write(receipt.tree, &receipt.key, .{ .decision = "applied" }) catch {
                confirmed = false;
            };
        }
        const review = receipt.review orelse return;
        review.pending_receipt = null;
        c.gtk_widget_set_sensitive(review.page, 1);
        if (review.generation != receipt.generation) return;
        if (confirmed) review.showDecision();
        u.setLabel(review.title, if (confirmed) i18n.dtr("coral", "Applied to unsaved buffer") else if (durable) i18n.dtr("coral", "Could not save the review decision") else i18n.dtr("coral", "Buffer edited. Recovery failed. Save your work."));
    }
};
pub const Review = struct {
    app: *App,
    host: ?u.W = null,
    removing_background: ?u.W = null,
    source_page: ?u.W = null,
    page: u.W,
    title: u.W,
    source: u.W,
    file_menu: u.W,
    file_list: @import("workspace/explorer.zig").View,
    action: u.W,
    content: u.W,
    toggle: u.W,
    old_source: u.W,
    new_source: u.W,
    decision: u.W,
    mine: u.W,
    edit: u.W,
    cancel: *c.GCancellable,
    arena: std.heap.ArenaAllocator,
    original: [:0]u8,
    tree: [:0]u8,
    base: [:0]u8,
    files: []const diff.FileDiff = &.{},
    target_tree: []const u8 = "",
    file: usize = 0,
    ordinal: usize = 0,
    generation: u64 = 0,
    conflict: ?*Job = null,
    editing: bool = false,
    pending_receipt: ?*Receipt = null,
    origin: c.GWeakRef = undefined,
    origin_drawer: ?@import("workbench/layout.zig").Panel = null,

    pub fn create(app: *App) *Review {
        const self = a.create(Review) catch unreachable;
        const page = u.box(false, 5);
        _ = c.g_object_ref_sink(page);
        c.gtk_widget_add_css_class(page, "workspace-review-page");
        const toolbar = u.box(true, 5);
        c.gtk_widget_add_css_class(toolbar, "workspace-review-controls");
        u.append(page, toolbar);
        const back = u.icon("go-previous-symbolic", i18n.dtr("coral", "Return to editor"));
        u.append(toolbar, back);
        const file_menu = c.gtk_menu_button_new().?;
        c.gtk_menu_button_set_icon_name(u.cast(c.GtkMenuButton, file_menu), "view-list-symbolic");
        const files_label = i18n.dtr("coral", "Changed files");
        c.gtk_widget_set_tooltip_text(file_menu, files_label);
        c.gtk_accessible_update_property(u.cast(c.GtkAccessible, file_menu), @as(c_int, c.GTK_ACCESSIBLE_PROPERTY_LABEL), files_label.ptr, @as(c_int, -1));
        const file_popover = c.gtk_popover_new().?;
        const file_box = u.box(false, 4);
        u.margin(file_box, 6);
        u.append(file_box, u.label(files_label));
        const file_list = @import("workspace/explorer.zig").View.init();
        const file_scroll = c.gtk_scrolled_window_new().?;
        const scrolled = u.cast(c.GtkScrolledWindow, file_scroll);
        c.gtk_scrolled_window_set_policy(scrolled, c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
        c.gtk_scrolled_window_set_propagate_natural_height(scrolled, 1);
        c.gtk_scrolled_window_set_max_content_height(scrolled, 320);
        c.gtk_widget_set_size_request(file_scroll, 240, -1);
        c.gtk_scrolled_window_set_child(scrolled, file_list.widget);
        u.append(file_box, file_scroll);
        c.gtk_popover_set_child(u.cast(c.GtkPopover, file_popover), file_box);
        c.gtk_menu_button_set_popover(u.cast(c.GtkMenuButton, file_menu), file_popover);
        u.append(toolbar, file_menu);
        const title = u.label("");
        c.gtk_widget_set_hexpand(title, 1);
        c.gtk_label_set_ellipsize(u.cast(c.GtkLabel, title), c.PANGO_ELLIPSIZE_MIDDLE);
        u.append(toolbar, title);
        const previous = u.icon("go-up-symbolic", i18n.dtr("coral", "Previous change"));
        const next = u.icon("go-down-symbolic", i18n.dtr("coral", "Next change"));
        u.append(toolbar, previous);
        u.append(toolbar, next);
        const toggle = c.gtk_toggle_button_new_with_label(i18n.dtr("coral", "Side by side")).?;
        u.append(toolbar, toggle);
        const content = c.gtk_stack_new().?;
        c.gtk_widget_set_vexpand(content, 1);
        u.append(page, content);
        const src = c.gtk_source_buffer_new(null).?;
        const source = c.gtk_source_view_new_with_buffer(src).?;
        c.g_object_unref(src);
        c.gtk_source_buffer_set_language(src, c.gtk_source_language_manager_get_language(c.gtk_source_language_manager_get_default(), "diff"));
        c.gtk_text_view_set_editable(u.cast(c.GtkTextView, source), 0);
        c.gtk_text_view_set_monospace(u.cast(c.GtkTextView, source), 1);
        const scroll = c.gtk_scrolled_window_new().?;
        c.gtk_widget_set_vexpand(scroll, 1);
        c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, scroll), source);
        _ = c.gtk_stack_add_named(u.cast(c.GtkStack, content), scroll, "unified");
        const columns = c.gtk_paned_new(c.GTK_ORIENTATION_HORIZONTAL).?;
        _ = c.gtk_stack_add_named(u.cast(c.GtkStack, content), columns, "split");
        const old = comparisonPane(i18n.dtr("coral", "Shared base"));
        const new = comparisonPane(i18n.dtr("coral", "Agent worktree"));
        c.gtk_paned_set_start_child(u.cast(c.GtkPaned, columns), old.box);
        c.gtk_paned_set_end_child(u.cast(c.GtkPaned, columns), new.box);
        c.gtk_scrolled_window_set_vadjustment(u.cast(c.GtkScrolledWindow, new.scroll), c.gtk_scrolled_window_get_vadjustment(u.cast(c.GtkScrolledWindow, old.scroll)));
        const decision = u.label("");
        u.append(page, decision);
        c.gtk_widget_set_visible(decision, 0);
        const buttons = u.box(true, 6);
        c.gtk_widget_add_css_class(buttons, "workspace-review-controls");
        u.append(page, buttons);
        const action = u.button(i18n.dtr("coral", "Apply hunk"));
        const mine = u.button(i18n.dtr("coral", "Skip hunk"));
        const edit = u.button(i18n.dtr("coral", "Edit resolution"));
        u.append(buttons, action);
        u.append(buttons, mine);
        u.append(buttons, edit);
        self.* = .{ .content = content, .toggle = toggle, .old_source = old.source, .new_source = new.source, .decision = decision, .app = app, .page = page, .file_menu = file_menu, .file_list = file_list, .title = title, .source = source, .action = action, .mine = mine, .edit = edit, .cancel = c.g_cancellable_new().?, .arena = .init(a), .original = u.z(""), .tree = u.z(""), .base = u.z("") };
        self.file_list.connect();
        u.connect(file_list.widget, "activate", &chooseFile, self);
        u.connect(back, "clicked", &close, self);
        c.g_weak_ref_init(&self.origin, null);
        c.gtk_actionable_set_action_name(u.cast(c.GtkActionable, previous), "win.workspace-previous-hunk");
        c.gtk_actionable_set_action_name(u.cast(c.GtkActionable, next), "win.workspace-next-hunk");
        u.connect(action, "clicked", &accept, self);
        u.connect(mine, "clicked", &skip, self);
        u.connect(toggle, "toggled", &toggleSplit, self);
        u.connect(edit, "clicked", &manual, self);
        return self;
    }
    pub fn deinit(self: *Review) void {
        if (self.pending_receipt) |receipt| receipt.review = null;
        c.g_weak_ref_clear(&self.origin);
        if (self.host) |host| {
            const book = u.cast(c.GtkNotebook, host);
            const index = c.gtk_notebook_page_num(book, self.page);
            if (index >= 0) c.gtk_notebook_remove_page(book, index);
        }
        c.g_object_unref(self.page);
        c.g_cancellable_cancel(self.cancel);
        c.g_object_unref(self.cancel);
        self.arena.deinit();
        a.free(self.original);
        a.free(self.tree);
        a.free(self.base);
        if (self.conflict) |job| job.deinit();
        a.destroy(self);
    }
    pub fn visible(self: *Review) bool {
        const host = self.host orelse return false;
        if (self.app.notebook != host) return false;
        const book = u.cast(c.GtkNotebook, host);
        return c.gtk_notebook_get_nth_page(book, c.gtk_notebook_get_current_page(book)) == self.page;
    }
    pub fn focusSource(self: *Review) void {
        const split = c.gtk_stack_get_visible_child_name(u.cast(c.GtkStack, self.content));
        const target = if (split != null and std.mem.eql(u8, std.mem.span(split), "split")) self.old_source else self.source;
        _ = c.gtk_widget_grab_focus(target);
    }
    pub fn step(self: *Review, backwards: bool) void {
        if (!self.visible() or self.editing or self.pending_receipt != null) return;
        if (backwards) prev(null, self) else advance(null, self);
    }
    pub fn choose(self: *Review, apply_change: bool) void {
        if (!self.visible() or self.files.len == 0 or self.pending_receipt != null) return;
        const button = if (apply_change) self.action else self.mine;
        if (c.gtk_widget_get_sensitive(button) != 0) {
            if (apply_change) accept(null, self) else skip(null, self);
        }
    }
    pub fn dismiss(self: *Review) bool {
        if (!self.visible() or self.editing) return false;
        const focus = c.gtk_window_get_focus(u.cast(c.GtkWindow, self.app.window));
        if (!@import("workbench/dock.zig").inside(focus, self.page)) return false;
        if (c.gtk_widget_get_ancestor(focus, c.gtk_popover_get_type()) != null) return false;
        const origin = c.g_weak_ref_get(&self.origin);
        const drawer = self.origin_drawer;
        self.hide();
        if (origin) |object| {
            defer c.g_object_unref(object);
            const widget = u.cast(c.GtkWidget, object);
            if (drawer) |panel| if (c.gtk_widget_get_mapped(widget) == 0) self.app.dock.show(panel);
            if (c.gtk_widget_get_mapped(widget) != 0) _ = c.gtk_widget_grab_focus(widget);
        }
        return true;
    }
    pub fn hide(self: *Review) void {
        c.g_weak_ref_set(&self.origin, null);
        self.origin_drawer = null;
        self.generation += 1;
        const was_open = self.visible();
        const host = self.host orelse return;
        const book = u.cast(c.GtkNotebook, host);
        const source_page = self.source_page;
        self.removing_background = if (host != self.app.notebook) host else null;
        defer self.removing_background = null;
        self.host = null;
        self.source_page = null;
        const review_index = c.gtk_notebook_page_num(book, self.page);
        if (review_index < 0) return;
        if (was_open) if (source_page) |source| {
            const index = c.gtk_notebook_page_num(book, source);
            if (index >= 0) c.gtk_notebook_set_current_page(book, index);
        };
        c.gtk_notebook_remove_page(book, review_index);
        if (was_open) if (self.app.activeWidget()) |widget| {
            _ = c.gtk_widget_grab_focus(widget);
        };
    }
    pub fn open(self: *Review, root: []const u8, tree: []const u8, base: []const u8) void {
        if (self.host != null and self.host != self.app.notebook) self.hide();
        if (!self.visible()) {
            const focus = c.gtk_window_get_focus(u.cast(c.GtkWindow, self.app.window));
            c.g_weak_ref_set(&self.origin, @ptrCast(focus));
            self.origin_drawer = if (self.app.dock.drawers) |d| d.open else null;
        }
        _ = self.app.dock.dismissDrawer(false);
        self.generation += 1;
        a.free(self.original);
        a.free(self.tree);
        a.free(self.base);
        self.original = u.z(root);
        self.tree = u.z(tree);
        self.base = u.z(base);
        self.file = 0;
        self.ordinal = 0;
        self.files = &.{};
        self.file_list.clear();
        c.gtk_widget_set_sensitive(self.file_menu, 0);
        self.resetConflict();
        if (self.host == null) {
            const book = u.cast(c.GtkNotebook, self.app.notebook);
            self.host = self.app.notebook;
            self.source_page = self.app.active_page;
            const tab = u.box(true, 5);
            u.append(tab, c.gtk_image_new_from_icon_name("document-properties-symbolic").?);
            const caption = if (self.app.opencode) |agent| std.mem.span(c.gtk_label_get_text(u.cast(c.GtkLabel, agent.title))) else "";
            var buf: [1024]u8 = undefined;
            const name = i18n.dfmt("coral", &buf, "Review · {s}", .{caption});
            const label = u.label(name);
            @import("editor/view.zig").sizeTabLabel(label, c.gtk_widget_get_width(self.app.notebook));
            c.gtk_label_set_max_width_chars(u.cast(c.GtkLabel, label), 24);
            c.gtk_label_set_ellipsize(u.cast(c.GtkLabel, label), c.PANGO_ELLIPSIZE_END);
            u.append(tab, label);
            const dismiss_button = u.icon("window-close-symbolic", i18n.dtr("coral", "Close review"));
            c.gtk_widget_add_css_class(dismiss_button, "flat");
            u.connect(dismiss_button, "clicked", &close, self);
            u.append(tab, dismiss_button);
            _ = c.gtk_notebook_append_page(book, self.page, tab);
            c.gtk_widget_set_tooltip_text(tab, self.tree);
        }
        self.selectTab();
        u.setLabel(self.title, i18n.dtr("coral", "Reading agent worktree…"));
        self.setSource("");
        c.gtk_stack_set_visible_child_name(u.cast(c.GtkStack, self.content), "unified");
        c.gtk_widget_set_visible(self.decision, 0);
        c.gtk_widget_set_sensitive(self.toggle, 0);
        c.gtk_widget_set_sensitive(self.mine, 0);
        c.gtk_widget_set_sensitive(self.action, 0);
        _ = c.gtk_widget_grab_focus(self.source);
        self.start(.patch, null);
    }
    fn selectTab(self: *Review) void {
        const book = u.cast(c.GtkNotebook, self.host orelse return);
        c.gtk_notebook_set_current_page(book, c.gtk_notebook_page_num(book, self.page));
    }
    fn resetConflict(self: *Review) void {
        if (self.conflict) |job| job.deinit();
        self.conflict = null;
        self.editing = false;
        c.gtk_widget_set_sensitive(self.file_menu, @intFromBool(self.files.len > 0));
        c.gtk_text_view_set_editable(u.cast(c.GtkTextView, self.source), 0);
        c.gtk_button_set_label(u.cast(c.GtkButton, self.action), i18n.dtr("coral", "Apply hunk"));
        c.gtk_button_set_label(u.cast(c.GtkButton, self.mine), i18n.dtr("coral", "Skip hunk"));
        c.gtk_widget_set_visible(self.edit, 0);
    }
    fn setSource(self: *Review, text: []const u8) void {
        const buf = c.gtk_text_view_get_buffer(u.cast(c.GtkTextView, self.source));
        @import("workspace_diff_style.zig").setText(buf.?, text, self.conflict != null);
    }
    pub fn scheme(self: *Review, active: ?*c.GtkSourceStyleScheme) void {
        for ([_]u.W{ self.source, self.old_source, self.new_source }) |view| {
            const buf = c.gtk_text_view_get_buffer(u.cast(c.GtkTextView, view)).?;
            c.gtk_source_buffer_set_style_scheme(u.cast(c.GtkSourceBuffer, buf), active);
            @import("workspace_diff_style.zig").configure(buf.?, active, self.app.appearance.palette);
        }
    }
    fn decisionKey(self: *Review, version: enum { current, legacy }) [64]u8 {
        const f = self.files[self.file];
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        for ([_][]const u8{ self.base, f.old_path, f.new_path, @tagName(f.kind) }) |part| {
            hash.update(part);
            hash.update("\x00");
        }
        if (version == .current) {
            // --full-index identifies the exact file version without invalidating
            // a decision when the agent edits an unrelated file. Pure renames and
            // mode-only changes can lack an index line, so use the snapshot tree.
            var target = self.target_tree;
            var lines = std.mem.splitScalar(u8, f.headers, '\n');
            while (lines.next()) |line| if (std.mem.startsWith(u8, line, "index ")) {
                target = line;
                break;
            };
            hash.update("target\x00");
            hash.update(target);
            hash.update("\x00");
        }
        if (f.kind != .text or f.hunks.len == 0) hash.update(f.headers);
        if (f.hunks.len != 0) {
            const h = f.hunks[self.ordinal];
            hash.update(std.mem.asBytes(&h.old_start));
            for (h.lines) |line| {
                hash.update(&.{line.tag});
                hash.update(line.text);
                hash.update(&.{ 0, @intFromBool(line.nonl) });
            }
        }
        return std.fmt.bytesToHex(hash.finalResult(), .lower);
    }
    fn record(self: *Review, decision: []const u8) bool {
        const key = self.decisionKey(.current);
        @import("workspace_state.zig").write(self.tree, &key, .{ .decision = decision }) catch {
            u.setLabel(self.decision, i18n.dtr("coral", "Could not save the review decision"));
            c.gtk_widget_set_visible(self.decision, 1);
            return false;
        };
        self.showDecision();
        return true;
    }
    fn showDecision(self: *Review) void {
        const key = self.decisionKey(.current);
        const state = @import("workspace_state.zig").read(self.tree, &key);
        if (state == null) {
            const old_key = self.decisionKey(.legacy);
            if (@import("workspace_state.zig").read(self.tree, &old_key)) |old| {
                defer old.deinit();
                u.setLabel(self.decision, i18n.dtr("coral", "Earlier review decision · verify this revision"));
                c.gtk_widget_set_visible(self.decision, 1);
                return;
            }
        }
        defer if (state) |value| value.deinit();
        const saved = if (state) |value| @import("opencode.zig").string(value.value, "decision") else "";
        c.gtk_widget_set_visible(self.decision, @intFromBool(saved.len != 0));
        if (saved.len > 0) u.setLabel(self.decision, if (std.mem.eql(u8, saved, "applied")) i18n.dtr("coral", "Previously applied to the editor") else if (std.mem.eql(u8, saved, "reviewed")) i18n.dtr("coral", "File reviewed") else i18n.dtr("coral", "Previously skipped"));
    }
    fn render(self: *Review) void {
        self.generation += 1;
        self.resetConflict();
        c.gtk_widget_set_sensitive(self.action, 0);
        if (self.files.len == 0) {
            u.setLabel(self.title, i18n.dtr("coral", "No changes in the agent worktree"));
            self.setSource("");
            return;
        }
        const f = self.files[self.file];
        c.gtk_single_selection_set_selected(self.file_list.selection, @intCast(self.file));
        self.showDecision();
        c.gtk_widget_set_sensitive(self.mine, 1);
        c.gtk_widget_set_sensitive(self.toggle, @intFromBool(f.kind == .text and f.hunks.len != 0));
        toggleSplit(null, self);
        const name = u.fmt("{s}   ·   {d}/{d}   ·   +{d} −{d}", .{ f.path(), self.ordinal + 1, @max(f.hunks.len, 1), f.added(), f.removed() });
        defer a.free(name);
        u.setLabel(self.title, name);
        if (f.hunks.len == 0 or f.kind != .text) {
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            const lines = diff.renderUnified(arena.allocator(), f, .unified) catch return;
            if (lines.len > 0) {
                const summary = u.fmt("{s}\n\n{s}\n", .{ lines[0].text, f.headers });
                defer a.free(summary);
                self.setSource(summary);
            }
            c.gtk_button_set_label(u.cast(c.GtkButton, self.mine), i18n.dtr("coral", "Skip file"));
            c.gtk_button_set_label(u.cast(c.GtkButton, self.action), i18n.dtr("coral", "Mark file reviewed"));
            c.gtk_widget_set_sensitive(self.action, 1);
            return;
        }
        const change = f.hunks[self.ordinal];
        var text: std.Io.Writer.Allocating = .init(a);
        defer text.deinit();
        text.writer.print("@@ -{d},{d} +{d},{d} @@\n", .{ change.old_start, change.old_count, change.new_start, change.new_count }) catch unreachable;
        for (change.lines) |line| text.writer.print("{c}{s}\n", .{ line.tag, line.text }) catch unreachable;
        self.setSource(text.written());
        c.gtk_widget_set_sensitive(self.action, 1);
    }
    fn start(self: *Review, op: Op, doc: ?*Document) void {
        const job = a.create(Job) catch unreachable;
        job.* = .{ .review = self, .generation = self.generation, .op = op, .root = u.z(self.tree), .base = u.z(self.base), .path = u.z(if (op == .merge) self.files[self.file].path() else ""), .local = if (doc) |d| u.bufferText(d.buffer) else u.z(""), .document = if (doc) |d| d.id else 0, .revision = if (doc) |d| d.revision else 0, .ordinal = self.ordinal };
        if (op == .merge) {
            const change = self.files[self.file].hunks[self.ordinal];
            var text: std.Io.Writer.Allocating = .init(a);
            defer text.deinit();
            text.writer.writeAll("--- a/source\n+++ b/source\n") catch unreachable;
            text.writer.print("@@ -{d},{d} +{d},{d} @@\n", .{ change.old_start, change.old_count, change.new_start, change.new_count }) catch unreachable;
            for (change.lines) |line| {
                text.writer.print("{c}{s}\n", .{ line.tag, line.text }) catch unreachable;
                if (line.nonl) text.writer.writeAll("\\ No newline at end of file\n") catch unreachable;
            }
            job.patch = u.z(text.written());
        }
        const task = c.g_task_new(null, self.cancel, &ready, job).?;
        c.g_task_set_task_data(task, job, null);
        c.g_task_run_in_thread(task, &worker);
        c.g_object_unref(task);
    }
    fn apply(self: *Review, job: *Job, result: []const u8) void {
        const doc = self.app.documents.get(job.document) orelse {
            u.setLabel(self.title, i18n.dtr("coral", "Reopen the source file to apply this change"));
            return;
        };
        if (doc.loading or doc.busy or doc.revision != job.revision) {
            u.setLabel(self.title, i18n.dtr("coral", "Buffer changed. Review the hunk again."));
            self.resetConflict();
            return;
        }
        const change = minimalEdit(job.local, result);
        self.app.performGrouped("Apply OpenCode hunk", &.{.{ .target = .{ .id = doc.id, .buffer = doc.buffer, .revision = &doc.revision, .expected_revision = doc.revision }, .replacements = &.{change} }}) catch |err| {
            u.setLabel(self.title, @errorName(err));
            return;
        };
        self.resetConflict();
        c.gtk_widget_set_sensitive(self.action, 0);
        const receipt = a.create(Receipt) catch unreachable;
        receipt.* = .{ .review = self, .generation = self.generation, .tree = u.z(self.tree), .key = self.decisionKey(.current) };
        self.pending_receipt = receipt;
        c.gtk_widget_set_sensitive(self.page, 0);
        if (self.app.recovery_flush) |flush| {
            flush(self.app.recovery_context, &Receipt.finish, receipt) catch Receipt.finish(receipt, false);
        } else Receipt.finish(receipt, false);
    }
};
const Comparison = struct { box: u.W, source: u.W, scroll: u.W };
fn comparisonPane(title: [*:0]const u8) Comparison {
    const box = u.box(false, 4);
    u.append(box, u.label(std.mem.span(title)));
    const buf = c.gtk_source_buffer_new(null).?;
    const source = c.gtk_source_view_new_with_buffer(buf).?;
    c.gtk_source_buffer_set_language(buf, c.gtk_source_language_manager_get_language(c.gtk_source_language_manager_get_default(), "diff"));
    c.g_object_unref(buf);
    c.gtk_text_view_set_editable(u.cast(c.GtkTextView, source), 0);
    c.gtk_text_view_set_monospace(u.cast(c.GtkTextView, source), 1);
    const scroll = c.gtk_scrolled_window_new().?;
    c.gtk_widget_set_vexpand(scroll, 1);
    c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, scroll), source);
    u.append(box, scroll);
    return .{ .box = box, .source = source, .scroll = scroll };
}
fn chooseFile(_: ?*c.GtkListView, position: c_uint, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Review, data.?);
    if (position >= self.files.len or self.pending_receipt != null) return;
    c.gtk_menu_button_popdown(u.cast(c.GtkMenuButton, self.file_menu));
    if (self.file != position) {
        self.file = position;
        self.ordinal = 0;
        self.render();
    }
    self.focusSource();
}
fn toggleSplit(_: ?*c.GtkToggleButton, ctx: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Review, ctx.?);
    const split = self.files.len > 0 and self.files[self.file].hunks.len > 0 and self.conflict == null and c.gtk_toggle_button_get_active(u.cast(c.GtkToggleButton, self.toggle)) != 0;
    c.gtk_stack_set_visible_child_name(u.cast(c.GtkStack, self.content), if (split) "split" else "unified");
    if (!split) return;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var file = self.files[self.file];
    file.hunks = file.hunks[self.ordinal..][0..1];
    const view = diff.renderSplit(arena.allocator(), file, .split) catch return;
    for ([_]u.W{ self.old_source, self.new_source }, 0..) |source, side| {
        var out: std.Io.Writer.Allocating = .init(arena.allocator());
        for (view.rows) |row| {
            if (if (side == 0) row.old else row.new) |line| {
                const sign: u8 = switch (line.tag) {
                    .added => '+',
                    .removed => '-',
                    else => ' ',
                };
                out.writer.print("{c}{s}", .{ sign, line.text }) catch unreachable;
            }
            out.writer.writeByte('\n') catch unreachable;
        }
        @import("workspace_diff_style.zig").setText(c.gtk_text_view_get_buffer(u.cast(c.GtkTextView, source)).?, out.written(), false);
    }
}
fn skip(_: ?*c.GtkButton, ctx: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Review, ctx.?);
    if (self.files.len == 0) return;
    if (self.record("skipped")) advance(null, ctx);
}
fn minimalEdit(old: []const u8, new: []const u8) @import("editor/transactions.zig").Replacement {
    var prefix: usize = 0;
    while (prefix < @min(old.len, new.len) and old[prefix] == new[prefix]) : (prefix += 1) {}
    while (prefix > 0 and prefix < old.len and old[prefix] & 0xc0 == 0x80) prefix -= 1;
    var suffix: usize = 0;
    while (suffix < @min(old.len, new.len) - prefix and old[old.len - 1 - suffix] == new[new.len - 1 - suffix]) : (suffix += 1) {}
    while (suffix > 0 and old[old.len - suffix] & 0xc0 == 0x80) suffix -= 1;
    return .{ .start = prefix, .end = old.len - suffix, .text = new[prefix .. new.len - suffix] };
}
fn close(_: ?*c.GtkButton, ctx: ?*anyopaque) callconv(.c) void {
    u.cast(Review, ctx.?).hide();
}
fn prev(_: ?*c.GtkButton, ctx: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Review, ctx.?);
    if (self.files.len == 0) return;
    if (self.ordinal > 0) self.ordinal -= 1 else if (self.file > 0) {
        self.file -= 1;
        self.ordinal = @max(self.files[self.file].hunks.len, 1) - 1;
    }
    self.render();
}
fn advance(_: ?*c.GtkButton, ctx: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Review, ctx.?);
    if (self.files.len == 0) return;
    if (self.ordinal + 1 < self.files[self.file].hunks.len) self.ordinal += 1 else if (self.file + 1 < self.files.len) {
        self.file += 1;
        self.ordinal = 0;
    } else {
        self.hide();
        return;
    }
    self.render();
}
fn manual(_: ?*c.GtkButton, ctx: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Review, ctx.?);
    self.editing = true;
    c.gtk_widget_set_sensitive(self.file_menu, 0);
    c.gtk_widget_set_visible(self.edit, 0);
    c.gtk_text_view_set_editable(u.cast(c.GtkTextView, self.source), 1);
    _ = c.gtk_widget_grab_focus(self.source);
    c.gtk_button_set_label(u.cast(c.GtkButton, self.action), i18n.dtr("coral", "Apply resolution"));
}
fn accept(_: ?*c.GtkButton, ctx: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Review, ctx.?);
    if (self.conflict) |job| {
        if (self.editing) {
            const text = u.bufferText(c.gtk_text_view_get_buffer(u.cast(c.GtkTextView, self.source)).?);
            defer a.free(text);
            self.apply(job, text);
        } else self.apply(job, job.theirs.?);
        return;
    }
    if (self.files.len == 0) return;
    const file = self.files[self.file];
    if (file.kind != .text or file.hunks.len == 0) {
        if (self.record("reviewed")) c.gtk_widget_set_sensitive(self.action, 0);
        return;
    }
    const path = file.path();
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return;
    const full = u.fmt("{s}/{s}", .{ self.original, path });
    defer a.free(full);
    const canonical = u.canonicalPath(full);
    defer a.free(canonical);
    if (!std.mem.eql(u8, canonical, full)) {
        u.setLabel(self.title, i18n.dtr("coral", "The file path changed. Reopen review."));
        return;
    }
    const selected = self.app.active();
    const recovered = if (selected) |doc| doc.path == null and doc.recovered_from != null and std.mem.eql(u8, doc.recovered_from.?, canonical) else false;
    const doc = (if (recovered) selected else self.app.documents.findPath(canonical)) orelse {
        self.app.openExisting(canonical, null);
        self.selectTab();
        u.setLabel(self.title, i18n.dtr("coral", "Opening file. Apply after it loads."));
        return;
    };
    if (doc.loading or doc.busy) return;
    c.gtk_widget_set_sensitive(self.action, 0);
    self.start(.merge, doc);
}
fn worker(task: ?*c.GTask, _: ?*anyopaque, data: ?*anyopaque, cancel: ?*c.GCancellable) callconv(.c) void {
    const job = u.cast(Job, data.?);
    run(job, cancel.?) catch |err| {
        job.err = err;
    };
    c.g_task_return_boolean(task, 1);
}
fn run(job: *Job, cancel: *c.GCancellable) !void {
    const temp = c.g_dir_make_tmp("coral-review-XXXXXX", null);
    if (temp == null) return error.TempDirectory;
    defer c.g_free(temp);
    defer _ = c.g_rmdir(temp);
    if (job.op == .patch) {
        const index = u.fmt("{s}/index", .{std.mem.span(temp)});
        defer a.free(index);
        defer _ = c.g_remove(index);
        a.free(try git.git(job.root, index, &.{ "read-tree", "HEAD" }, cancel));
        a.free(try git.git(job.root, index, &.{ "add", "-A", "--", "." }, cancel));
        job.target_tree = try git.git(job.root, index, &.{"write-tree"}, cancel);
        job.patch = try git.gitRaw(job.root, null, &.{ "diff", "--full-index", "--find-renames", "--no-color", "--no-ext-diff", "--no-textconv", "--relative", job.base, job.target_tree.?, "--", "." }, cancel, false);
        return;
    }
    const spec = u.fmt("{s}:./{s}", .{ job.base, job.path });
    defer a.free(spec);
    const raw = try git.gitRaw(job.root, null, &.{ "show", spec }, cancel, false);
    defer a.free(raw);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const parsed = try hunk.parse(arena.allocator(), job.patch.?);
    if (parsed.hunks.len != 1) return error.InvalidHunk;
    const updated = try hunk.apply(arena.allocator(), raw, parsed.hunks[0], .forward);
    const base = try codec.decode(arena.allocator(), raw);
    const agent = try codec.decode(arena.allocator(), updated);
    const names = [_][:0]u8{ u.fmt("{s}/local", .{std.mem.span(temp)}), u.fmt("{s}/base", .{std.mem.span(temp)}), u.fmt("{s}/agent", .{std.mem.span(temp)}) };
    defer for (names) |n| {
        _ = c.g_remove(n);
        a.free(n);
    };
    for (names, [_][]const u8{ job.local, base.text, agent.text }) |name, bytes| if (c.g_file_set_contents(name, bytes.ptr, @intCast(bytes.len), null) == 0) return error.TempFile;
    job.merged = try git.gitRaw(job.root, null, &.{ "merge-file", "--diff3", "-p", "-L", "Unsaved buffer", "-L", "Shared base", "-L", "Agent change", names[0], names[1], names[2] }, cancel, true);
    if (std.mem.indexOf(u8, job.merged.?, "<<<<<<< Unsaved buffer") != null) job.theirs = try git.gitRaw(job.root, null, &.{ "merge-file", "--theirs", "-p", names[0], names[1], names[2] }, cancel, false);
}
fn ready(_: ?*c.GObject, res: ?*c.GAsyncResult, ctx: ?*anyopaque) callconv(.c) void {
    const job = u.cast(Job, ctx.?);
    var keep = false;
    defer if (!keep) job.deinit();
    if (c.g_cancellable_is_cancelled(c.g_task_get_cancellable(u.cast(c.GTask, res.?))) != 0) return;
    const self = job.review;
    if (job.generation != self.generation) return;
    if (job.err) |err| {
        u.setLabel(self.title, @errorName(err));
        c.gtk_widget_set_sensitive(self.action, @intFromBool(job.op == .merge));
        return;
    }
    if (job.op == .patch) {
        _ = self.arena.reset(.free_all);
        const patch = self.arena.allocator().dupe(u8, job.patch.?) catch unreachable;
        const parsed = diff.parse(self.arena.allocator(), patch) catch |err| {
            u.setLabel(self.title, @errorName(err));
            return;
        };
        self.files = parsed.files;
        self.target_tree = self.arena.allocator().dupe(u8, job.target_tree.?) catch unreachable;
        for (self.files) |file| {
            const path = u.z(file.path());
            defer a.free(path);
            self.file_list.append(path);
        }
        c.gtk_widget_set_sensitive(self.file_menu, @intFromBool(self.files.len > 0));
        @import("workspace_state.zig").write(self.tree, "review-manifest", .{ .base = @as([]const u8, self.base), .target = @as([]const u8, job.target_tree.?), .source = @as([]const u8, self.original), .file_count = self.files.len }) catch u.setLabel(self.title, i18n.dtr("coral", "Could not save the review manifest"));
        self.render();
    } else if (job.theirs != null) {
        self.conflict = job;
        keep = true;
        c.gtk_widget_set_sensitive(self.toggle, 0);
        c.gtk_stack_set_visible_child_name(u.cast(c.GtkStack, self.content), "unified");
        self.setSource(job.merged.?);
        u.setLabel(self.title, i18n.dtr("coral", "Resolve overlapping edits"));
        c.gtk_button_set_label(u.cast(c.GtkButton, self.action), i18n.dtr("coral", "Use agent change"));
        c.gtk_button_set_label(u.cast(c.GtkButton, self.mine), i18n.dtr("coral", "Keep my edit"));
        c.gtk_widget_set_visible(self.edit, 1);
        c.gtk_widget_set_sensitive(self.action, 1);
    } else self.apply(job, job.merged.?);
}
