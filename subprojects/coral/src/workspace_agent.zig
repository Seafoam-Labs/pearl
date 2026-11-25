//! GTK session navigation and composer. Session snapshots own server state, while drafts belong to the window.
const std = @import("std");
const api = @import("opencode.zig");
const u = @import("c.zig");
const c = u.c;
const App = @import("app.zig").App;
const Value = api.Value;
const a = u.a;
const i18n = @import("i18n");
const permission_ui = @import("workspace_permissions.zig");
const storage = @import("workspace_state.zig");
const Draft = storage.Draft;
pub const Agent = struct {
    app: *App,
    root: [:0]u8,
    server: [:0]u8,
    location: [:0]u8,
    session: ?[:0]u8 = null,
    epoch: u64 = 0,
    client: api.Client,
    sessions: u.W,
    models: u.W,
    choices: u.W,
    title: u.W,
    status: u.W,
    thread: @import("workspace_thread.zig").Thread,
    thread_generation: u64 = 0,
    loading_older: bool = false,
    composer: u.W,
    send: u.W,
    chip: u.W,
    caption: u.W,
    snapshot: u.W,
    anchor: storage.Anchor = .{},
    review_button: u.W,
    base: ?[:0]u8 = null,
    captured: ?[:0]u8 = null,
    tag: ?[:0]u8 = null,
    drafts: std.StringHashMapUnmanaged(Draft) = .empty,
    model_id: [:0]u8,
    provider: [:0]u8,
    draft_timer: c_uint = 0,
    pending: bool = false,
    model_generation: u64 = 0,
    catalog_retry: c_uint = 0,
    catalog_attempt: u3 = 0,
    model_feedback: u.W,
    connected: bool = false,
    sending: bool = false,
    operation: ?[:0]u8 = null,
    delivery_notice: u.W,
    attach: u.W,
    new_session: u.W,
    permissions: u.W,
    pending_scroll: u.W,
    permission_state: permission_ui.State = .{},
    inbox: u.W,
    update_timer: c_uint = 0,
    reconnect_timer: c_uint = 0,
    need_info: bool = false,
    need_list: bool = false,
    rehydrate: bool = true,
    need_thread: bool = false,
    need_queue: bool = false,
    need_permissions: bool = false,
    pub fn create(app: *App, dir: [:0]const u8, sessions: u.W, panel: u.W) *Agent {
        const self = a.create(Agent) catch unreachable;
        const new_session = u.icon("list-add-symbolic", i18n.dtr("coral", "New OpenCode session"));
        const heading = u.box(true, 6);
        const title = u.label(i18n.dtr("coral", "OpenCode"));
        c.gtk_widget_add_css_class(title, "workspace-thread-title");
        c.gtk_label_set_ellipsize(u.cast(c.GtkLabel, title), c.PANGO_ELLIPSIZE_END);
        c.gtk_widget_set_hexpand(title, 1);
        u.append(heading, title);
        u.append(heading, new_session);
        const reconnect_button = u.icon("view-refresh-symbolic", i18n.dtr("coral", "Reconnect to OpenCode"));
        u.append(heading, reconnect_button);
        u.append(panel, heading);
        const status = u.label("");
        c.gtk_label_set_wrap(u.cast(c.GtkLabel, status), 1);
        u.append(panel, status);
        const earlier = u.button(i18n.dtr("coral", "Earlier messages"));
        u.append(panel, earlier);
        c.gtk_widget_set_visible(earlier, 0);
        const transcript = c.gtk_text_view_new().?;
        c.gtk_text_view_set_editable(u.cast(c.GtkTextView, transcript), 0);
        c.gtk_text_view_set_wrap_mode(u.cast(c.GtkTextView, transcript), c.GTK_WRAP_WORD_CHAR);
        const scroll = c.gtk_scrolled_window_new().?;
        c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, scroll), transcript);
        c.gtk_widget_set_vexpand(scroll, 1);
        u.append(panel, scroll);
        const review_button = u.button(i18n.dtr("coral", "Review changes"));
        u.append(panel, review_button);
        c.gtk_widget_set_visible(review_button, 0);
        const permissions = u.box(false, 3);
        const inbox = u.box(false, 2);
        const pending_rows = u.box(false, 3);
        u.append(pending_rows, permissions);
        u.append(pending_rows, inbox);
        const pending_scroll = c.gtk_scrolled_window_new().?;
        const pending = u.cast(c.GtkScrolledWindow, pending_scroll);
        c.gtk_scrolled_window_set_policy(pending, c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
        c.gtk_scrolled_window_set_propagate_natural_height(pending, 1);
        c.gtk_scrolled_window_set_max_content_height(pending, 210);
        c.gtk_scrolled_window_set_child(pending, pending_rows);
        u.append(panel, pending_scroll);
        c.gtk_widget_set_visible(pending_scroll, 0);
        const card = u.box(false, 4);
        c.gtk_widget_add_css_class(card, "workspace-composer");
        u.append(panel, card);
        const chip = c.gtk_menu_button_new().?;
        const preview = c.gtk_popover_new().?;
        const preview_box = u.box(false, 5);
        u.margin(preview_box, 8);
        c.gtk_popover_set_child(u.cast(c.GtkPopover, preview), preview_box);
        c.gtk_menu_button_set_popover(u.cast(c.GtkMenuButton, chip), preview);
        const caption = u.label("");
        c.gtk_label_set_wrap(u.cast(c.GtkLabel, caption), 1);
        u.append(preview_box, caption);
        const selection_scroll = c.gtk_scrolled_window_new().?;
        c.gtk_widget_set_size_request(selection_scroll, 260, 120);
        const snapshot = c.gtk_text_view_new().?;
        c.gtk_text_view_set_editable(u.cast(c.GtkTextView, snapshot), 0);
        c.gtk_text_view_set_monospace(u.cast(c.GtkTextView, snapshot), 1);
        c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, selection_scroll), snapshot);
        u.append(preview_box, selection_scroll);
        const actions = u.box(true, 4);
        const replace = u.button(i18n.dtr("coral", "Refresh from selection"));
        const remove = u.button(i18n.dtr("coral", "Remove selection"));
        u.append(actions, replace);
        u.append(actions, remove);
        u.append(preview_box, actions);
        u.append(card, chip);
        c.gtk_widget_set_visible(chip, 0);
        c.gtk_widget_add_css_class(transcript, "workspace-thread");
        const composer = c.gtk_text_view_new().?;
        c.gtk_widget_add_css_class(composer, "workspace-input");
        c.gtk_text_view_set_wrap_mode(u.cast(c.GtkTextView, composer), c.GTK_WRAP_WORD_CHAR);
        const input = c.gtk_scrolled_window_new().?;
        c.gtk_widget_set_size_request(input, -1, 70);
        c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, input), composer);
        u.append(card, input);
        const delivery_notice = u.button(i18n.dtr("coral", "Delivery unknown · Retry this prompt"));
        u.append(card, delivery_notice);
        c.gtk_widget_set_visible(delivery_notice, 0);
        const model_feedback = u.label("");
        c.gtk_label_set_wrap(u.cast(c.GtkLabel, model_feedback), 1);
        u.append(card, model_feedback);
        c.gtk_widget_set_visible(model_feedback, 0);
        const controls = u.box(true, 6);
        const attach = u.icon("mail-attachment-symbolic", i18n.dtr("coral", "Attach selected code"));
        u.append(controls, attach);
        const models = c.gtk_menu_button_new().?;
        c.gtk_widget_set_hexpand(models, 1);
        c.gtk_menu_button_set_label(u.cast(c.GtkMenuButton, models), i18n.dtr("coral", "Session model"));
        c.gtk_menu_button_set_direction(u.cast(c.GtkMenuButton, models), c.GTK_ARROW_UP);
        const pop = c.gtk_popover_new().?;
        c.gtk_popover_set_has_arrow(u.cast(c.GtkPopover, pop), 0);
        const options = u.box(false, 2);
        u.margin(options, 5);
        const menu_scroll = c.gtk_scrolled_window_new().?;
        c.gtk_scrolled_window_set_propagate_natural_height(u.cast(c.GtkScrolledWindow, menu_scroll), 1);
        c.gtk_scrolled_window_set_max_content_height(u.cast(c.GtkScrolledWindow, menu_scroll), 360);
        c.gtk_widget_set_size_request(menu_scroll, 240, -1);
        c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, menu_scroll), options);
        c.gtk_popover_set_child(u.cast(c.GtkPopover, pop), menu_scroll);
        c.gtk_menu_button_set_popover(u.cast(c.GtkMenuButton, models), pop);
        u.append(controls, models);
        const send = u.icon("mail-send-symbolic", i18n.dtr("coral", "Send to this session"));
        c.gtk_widget_add_css_class(send, "suggested-action");
        u.append(controls, send);
        u.append(card, controls);
        self.* = .{ .caption = caption, .snapshot = snapshot, .attach = attach, .delivery_notice = delivery_notice, .model_feedback = model_feedback, .review_button = review_button, .new_session = new_session, .permissions = permissions, .pending_scroll = pending_scroll, .inbox = inbox, .app = app, .root = u.z(dir), .server = u.z(""), .location = u.z(dir), .client = api.Client.init(), .sessions = sessions, .models = models, .choices = options, .title = title, .status = status, .thread = .init(transcript, scroll, earlier), .composer = composer, .send = send, .chip = chip, .model_id = u.z(""), .provider = u.z("") };
        u.connect(earlier, "clicked", &olderMessages, self);
        u.connect(c.gtk_scrolled_window_get_vadjustment(u.cast(c.GtkScrolledWindow, scroll)).?, "value-changed", &readPositionChanged, self);
        c.gtk_actionable_set_action_name(u.cast(c.GtkActionable, review_button), "win.workspace-open-review");
        u.connect(new_session, "clicked", &newSession, self);
        c.gtk_widget_set_sensitive(new_session, 0);
        u.connect(reconnect_button, "clicked", &reconnect, self);
        u.connect(send, "clicked", &submit, self);
        u.connect(delivery_notice, "clicked", &submit, self);
        c.gtk_accessible_update_property(u.cast(c.GtkAccessible, composer), @as(c_int, c.GTK_ACCESSIBLE_PROPERTY_LABEL), @as([*:0]const u8, i18n.dtr("coral", "Message OpenCode")), @as(c_int, -1));
        u.connect(buffer(composer), "changed", &draftChanged, self);
        c.gtk_actionable_set_action_name(u.cast(c.GtkActionable, attach), "win.workspace-attach-selection");
        u.connect(remove, "clicked", &detach, self);
        u.connect(replace, "clicked", &attachCode, self);
        u.connect(preview, "show", &showSnapshot, self);
        c.gtk_widget_set_sensitive(models, 0);
        c.gtk_widget_set_sensitive(send, 0);
        u.setLabel(status, i18n.dtr("coral", "Open a project to see its sessions"));
        return self;
    }
    pub fn deinit(self: *Agent) void {
        if (self.draft_timer != 0) _ = c.g_source_remove(self.draft_timer);
        if (self.catalog_retry != 0) _ = c.g_source_remove(self.catalog_retry);
        if (self.session) |sid| self.saveDraft(sid);
        if (self.update_timer != 0) _ = c.g_source_remove(self.update_timer);
        if (self.reconnect_timer != 0) _ = c.g_source_remove(self.reconnect_timer);
        if (self.base) |base| a.free(base);
        if (self.operation) |id| a.free(id);
        self.thread.deinit();
        self.client.deinit();
        if (self.session) |s| a.free(s);
        self.clearSelection();
        var it = self.drafts.iterator();
        while (it.next()) |e| {
            a.free(e.key_ptr.*);
            e.value_ptr.deinit();
        }
        self.drafts.deinit(a);
        self.permission_state.deinit();
        a.free(self.server);
        a.free(self.root);
        a.free(self.location);
        a.free(self.model_id);
        a.free(self.provider);
        a.destroy(self);
    }
    pub fn handleCommand(self: *Agent, command: @import("workbench/commands.zig").Command) bool {
        switch (command) {
            .agent_new_thread => if (c.gtk_widget_get_sensitive(self.new_session) != 0) newSession(null, self),
            .agent_send => submit(null, self),
            .agent_cancel => if (self.connected and self.session != null) {
                const id = api.escaped(self.session.?);
                defer a.free(id);
                const path = u.fmt("/api/session/{s}/interrupt", .{id});
                defer a.free(path);
                self.client.requestMethod("POST", path, null, self, self.epoch, &interrupted);
            },
            .agent_allow, .agent_deny => {
                if (self.connected and c.gtk_widget_get_sensitive(self.permissions) != 0) {
                    var child = c.gtk_widget_get_first_child(self.permissions);
                    while (child) |card| : (child = c.gtk_widget_get_next_sibling(card)) {
                        const row = c.gtk_widget_get_last_child(card).?;
                        const button = if (command == .agent_allow) c.gtk_widget_get_first_child(row) else c.gtk_widget_get_last_child(row);
                        if (c.gtk_widget_is_sensitive(button) == 0) continue;
                        replyPermission(u.cast(c.GtkButton, button.?), self);
                        break;
                    }
                }
            },
            .agent_accept_review, .agent_reject_review => if (self.app.review) |r| {
                if (r.visible()) r.choose(command == .agent_accept_review) else showReview(null, self);
            },
            else => return false,
        }
        return true;
    }
    pub fn attachSelection(self: *Agent) void {
        if (self.session != null and self.operation == null) attachCode(null, self);
    }
    pub fn openReview(self: *Agent) void {
        if (self.base == null) {
            self.app.message(i18n.dtr("coral", "This session has no worktree changes to review."));
            return;
        }
        showReview(null, self);
    }
    pub fn workspaceChanged(self: *Agent) void {
        var path: []const u8 = "";
        if (self.app.browser.model) |model| {
            for (model.roots) |root| {
                if (root.canonical_path) |p| {
                    path = p;
                    break;
                }
            }
        }
        if (std.mem.eql(u8, self.root, path)) return;
        self.epoch += 1;
        self.permission_state.fetch = 0;
        self.model_generation += 1;
        self.connected = false;
        self.sending = false;
        c.gtk_widget_set_visible(self.review_button, 0);
        c.gtk_widget_set_visible(self.model_feedback, 0);
        clear(self.permissions);
        clear(self.inbox);
        self.pendingVisible();
        c.gtk_widget_set_sensitive(self.new_session, 0);
        if (self.session) |id| {
            self.saveDraft(id);
            a.free(id);
            self.session = null;
        }
        self.resetOperation();
        self.deliveryControls();
        a.free(self.root);
        self.root = u.z(path);
        clear(self.sessions);
        clear(self.choices);
        self.thread_generation += 1;
        self.loading_older = false;
        self.thread.clear();
        setText(self.composer, "");
        self.clearSelection();
        self.showSelection();
        c.gtk_widget_set_sensitive(self.models, 0);
        c.gtk_widget_set_sensitive(self.send, 0);
        if (path.len != 0) self.refresh() else u.setLabel(self.status, i18n.dtr("coral", "Open a project to see its sessions"));
    }
    fn refresh(self: *Agent) void {
        self.client.discover() catch {
            if (self.session == null) self.restoreOffline();
            self.connected = false;
            self.deliveryControls();
            c.gtk_widget_set_sensitive(self.models, 0);
            c.gtk_widget_set_sensitive(self.new_session, 0);
            self.disablePermissions();
            c.gtk_widget_set_sensitive(self.inbox, 0);
            if (self.reconnect_timer == 0) self.reconnect_timer = c.g_timeout_add_seconds(3, &retryConnection, self);
            u.setLabel(self.status, i18n.dtr("coral", "Start OpenCode with opencode service start, then reconnect."));
            return;
        };
        const id = self.client.identity();
        if (!std.mem.eql(u8, id, self.server)) {
            if (self.session) |sid| {
                self.saveDraft(sid);
                self.epoch += 1;
                self.permission_state.fetch = 0;
                self.model_generation += 1;
                a.free(sid);
                self.session = null;
                self.resetOperation();
                self.clearSelection();
                self.showSelection();
                setText(self.composer, "");
                self.thread_generation += 1;
                self.loading_older = false;
                self.thread.clear();
                clear(self.permissions);
                clear(self.inbox);
                self.pendingVisible();
                if (self.app.review) |r| r.hide();
                c.gtk_widget_set_visible(self.review_button, 0);
            }
            a.free(self.server);
            self.server = u.z(id);
        }
        u.setLabel(self.status, i18n.dtr("coral", "Connecting…"));
        self.rehydrate = true;
        self.client.subscribe(self, &eventReceived);
        self.loadSessions();
    }
    fn loadSessions(self: *Agent) void {
        const dir = api.escaped(self.root);
        defer a.free(dir);
        const path = u.fmt("/api/location?location%5Bdirectory%5D={s}", .{dir});
        defer a.free(path);
        self.client.request(path, null, self, self.epoch, &projectInfo);
    }
    fn call(self: *Agent, suffix: []const u8, body: ?[]const u8, done: api.Callback) void {
        const sid = self.session orelse return;
        const id = api.escaped(sid);
        defer a.free(id);
        const path = u.fmt("/api/session/{s}{s}", .{ id, suffix });
        defer a.free(path);
        self.client.request(path, body, self, self.epoch, done);
    }
    fn requestInfo(self: *Agent) void {
        if (!self.connected or self.pending) return;
        const sid = api.escaped(self.session orelse return);
        defer a.free(sid);
        const path = u.fmt("/api/session/{s}", .{sid});
        defer a.free(path);
        self.model_generation += 1;
        self.client.request(path, null, self, self.model_generation, &sessionInfo);
    }
    fn pendingVisible(self: *Agent) void {
        c.gtk_widget_set_visible(self.pending_scroll, @intFromBool(c.gtk_widget_get_first_child(self.permissions) != null or c.gtk_widget_get_first_child(self.inbox) != null));
    }
    fn disablePermissions(self: *Agent) void {
        self.permission_state.fetch = 0;
        c.gtk_widget_set_sensitive(self.permissions, 0);
        var card = c.gtk_widget_get_first_child(self.permissions);
        while (card) |w| : (card = c.gtk_widget_get_next_sibling(w)) permission_ui.setAnswerable(w, false);
    }
    fn readPermissions(self: *Agent) void {
        if (!self.connected) return;
        const sid = api.escaped(self.session orelse return);
        defer a.free(sid);
        const path = u.fmt("/api/session/{s}/permission", .{sid});
        defer a.free(path);
        self.permission_state.fetch = self.permission_state.next();
        self.client.request(path, null, self, self.permission_state.fetch, &permissionList);
    }
    fn readThread(self: *Agent) void {
        const sid = api.escaped(self.session orelse return);
        defer a.free(sid);
        const path = u.fmt("/api/session/{s}/message?limit=100&order=desc", .{sid});
        defer a.free(path);
        self.thread_generation += 1;
        self.client.request(path, null, self, self.thread_generation, &history);
    }
    fn queryModel(self: *Agent, endpoint: []const u8, done: api.Callback) void {
        const dir = api.escaped(self.location);
        defer a.free(dir);
        const path = u.fmt("{s}?location%5Bdirectory%5D={s}", .{ endpoint, dir });
        defer a.free(path);
        self.client.request(path, null, self, self.model_generation, done);
    }
    fn stateGroup(self: *Agent, location: []const u8) [:0]u8 {
        return u.fmt("{s}\x00{s}\x00{s}", .{ self.server, self.root, location });
    }
    fn restoreOffline(self: *Agent) void {
        const saved = storage.read(self.root, "last-open-thread") orelse return;
        defer saved.deinit();
        const id = api.string(saved.value, "session");
        const dir = api.string(saved.value, "location");
        const server = api.string(saved.value, "server");
        if (id.len == 0 or dir.len == 0 or server.len == 0) return;
        a.free(self.server);
        self.server = u.z(server);
        self.activate(id, dir);
        self.reviewBase(api.string(saved.value, "base"));
        const title = api.string(saved.value, "title");
        if (title.len > 0) u.setLabel(self.title, title);
    }
    fn reviewBase(self: *Agent, base: []const u8) void {
        if (self.base) |old| a.free(old);
        self.base = null;
        if ((base.len == 40 or base.len == 64) and std.mem.indexOfNone(u8, base, "0123456789abcdef") == null) self.base = u.z(base);
        c.gtk_widget_set_visible(self.review_button, @intFromBool(self.base != null));
    }
    fn activate(self: *Agent, id: []const u8, directory: []const u8) void {
        c.gtk_menu_button_popdown(u.cast(c.GtkMenuButton, self.models));
        clear(self.choices);
        c.gtk_widget_set_visible(self.model_feedback, 0);
        self.model_generation += 1;
        self.sending = false;
        self.catalog_attempt = 0;
        const next_id = u.z(id);
        if (self.session) |previous| {
            self.saveDraft(previous);
            a.free(previous);
        }
        self.resetOperation();
        const next_dir = u.z(if (directory.len > 0) directory else self.root);
        a.free(self.location);
        self.location = next_dir;
        self.session = next_id;
        self.markSession();
        if (self.app.review) |r| r.hide();
        self.reviewBase("");
        self.epoch += 1;
        self.permission_state.fetch = 0;
        self.pending = false;
        c.gtk_text_view_set_editable(u.cast(c.GtkTextView, self.composer), 1);
        self.clearSelection();
        const group = self.stateGroup(self.location);
        defer a.free(group);
        const cache_key = u.fmt("{s}\x00{s}", .{ group, next_id });
        defer a.free(cache_key);
        var persisted = storage.loadDraft(group, next_id);
        defer if (persisted) |*snapshot| snapshot.deinit();
        const draft = persisted orelse self.drafts.get(cache_key);
        const project = self.stateGroup("");
        defer a.free(project);
        if (self.connected) {
            storage.write(project, "", .{ .session = @as([]const u8, next_id) }) catch u.setLabel(self.status, i18n.dtr("coral", "Could not save session state"));
            storage.write(self.root, "last-open-thread", .{ .session = @as([]const u8, next_id), .server = @as([]const u8, self.server), .location = @as([]const u8, self.location) }) catch u.setLabel(self.status, i18n.dtr("coral", "Could not save session state"));
        }
        setText(self.composer, if (draft) |d| d.text else "");
        if (draft) |d| {
            if (d.selection) |s| self.captured = u.z(s);
            if (d.tag) |s| self.tag = u.z(s);
            self.anchor = d.anchor;
            if (d.operation) |s| self.operation = u.z(s);
        }
        self.showSelection();
        self.deliveryControls();
        self.thread_generation += 1;
        self.loading_older = false;
        self.thread.clear();
        if (draft) |d| self.thread.restore = d.read.copy();
        u.setLabel(self.title, i18n.dtr("coral", "OpenCode"));
        u.setLabel(self.status, i18n.dtr("coral", "Loading session…"));
        c.gtk_widget_set_sensitive(self.models, 0);
        c.gtk_widget_set_sensitive(self.send, 0);
        clear(self.permissions);
        clear(self.inbox);
        self.pendingVisible();
        if (!self.connected) return;
        self.requestInfo();
        self.readThread();
        self.readPermissions();
        self.call("/inbox", null, &inboxList);
    }
    fn resetOperation(self: *Agent) void {
        if (self.operation) |id| a.free(id);
        self.operation = null;
    }
    fn deliveryControls(self: *Agent) void {
        const editable: c_int = @intFromBool(self.operation == null);
        c.gtk_text_view_set_editable(u.cast(c.GtkTextView, self.composer), editable);
        c.gtk_widget_set_sensitive(self.attach, editable);
        c.gtk_widget_set_sensitive(self.chip, editable);
        c.gtk_widget_set_visible(self.delivery_notice, @intFromBool(self.operation != null and !self.sending));
        c.gtk_widget_set_sensitive(self.delivery_notice, @intFromBool(self.connected and !self.pending));
        c.gtk_widget_set_sensitive(self.send, @intFromBool(self.session != null and self.connected and !self.pending and !self.sending and self.operation == null));
    }
    fn saveDraft(self: *Agent, id: []const u8) void {
        self.persistDraft(id) catch u.setLabel(self.status, i18n.dtr("coral", "Could not save draft"));
    }
    fn persistDraft(self: *Agent, id: []const u8) !void {
        const group = self.stateGroup(self.location);
        defer a.free(group);
        const cache_key = u.fmt("{s}\x00{s}", .{ group, id });
        defer a.free(cache_key);
        const entry = self.drafts.getOrPut(a, cache_key) catch unreachable;
        if (entry.found_existing) {
            entry.value_ptr.deinit();
        } else entry.key_ptr.* = u.z(cache_key);
        entry.value_ptr.* = .{ .read = self.thread.position(), .anchor = self.anchor, .operation = if (self.operation) |s| u.z(s) else null, .text = u.bufferText(buffer(self.composer)), .selection = if (self.captured) |s| u.z(s) else null, .tag = if (self.tag) |s| u.z(s) else null };
        try storage.write(group, id, entry.value_ptr.*);
    }
    fn markSession(self: *Agent) void {
        var row = c.gtk_widget_get_first_child(self.sessions);
        while (row) |button| : (row = c.gtk_widget_get_next_sibling(button)) {
            if (c.g_object_get_data(u.cast(c.GObject, button), "sid") == null) continue;
            if (self.session != null and std.mem.eql(u8, widgetData(button, "sid"), self.session.?)) c.gtk_widget_add_css_class(button, "workspace-current-session") else c.gtk_widget_remove_css_class(button, "workspace-current-session");
        }
    }
    fn clearSelection(self: *Agent) void {
        if (self.captured) |s| a.free(s);
        if (self.tag) |s| a.free(s);
        self.captured = null;
        self.tag = null;
        self.anchor = .{};
    }
    fn showSelection(self: *Agent) void {
        draftChanged(null, self);
        c.gtk_widget_set_visible(self.chip, @intFromBool(self.tag != null));
        if (self.tag) |name| c.gtk_menu_button_set_label(u.cast(c.GtkMenuButton, self.chip), name);
    }
    pub fn documentChanged(self: *Agent, id: u64) void {
        if (self.tag == null or id != self.anchor.document) return;
        c.gtk_widget_set_tooltip_text(self.chip, i18n.dtr("coral", "The source has changed since this selection was attached"));
    }
};
fn buffer(widget: u.W) *c.GtkTextBuffer {
    return c.gtk_text_view_get_buffer(u.cast(c.GtkTextView, widget)).?;
}
fn setText(widget: u.W, text: []const u8) void {
    c.gtk_text_buffer_set_text(buffer(widget), text.ptr, @intCast(text.len));
}
fn clear(box: u.W) void {
    while (c.gtk_widget_get_first_child(box)) |w| c.gtk_box_remove(u.cast(c.GtkBox, box), w);
}
fn setData(w: u.W, key: [*:0]const u8, value: []const u8) void {
    const text = u.z(value);
    defer a.free(text);
    c.g_object_set_data_full(u.cast(c.GObject, w), key, c.g_strdup(text), &c.g_free);
}
fn widgetData(w: anytype, key: [*:0]const u8) []const u8 {
    return std.mem.span(@as([*:0]const u8, @ptrCast(c.g_object_get_data(u.cast(c.GObject, w), key).?)));
}
fn interrupted(ctx: *anyopaque, epoch: u64, _: Value, err: ?[]const u8) void {
    const self = u.cast(Agent, ctx);
    if (epoch != self.epoch or failure(self, err)) return;
    self.requestInfo();
}
fn reconnect(_: ?*c.GtkButton, ctx: ?*anyopaque) callconv(.c) void {
    u.cast(Agent, ctx.?).refresh();
}
fn failure(self: *Agent, err: ?[]const u8) bool {
    if (err) |s| {
        u.setLabel(self.status, s);
        return true;
    }
    return false;
}
fn listed(ctx: *anyopaque, epoch: u64, result: Value, err: ?[]const u8) void {
    const self = u.cast(Agent, ctx);
    if (epoch != self.epoch or failure(self, err)) return;
    clear(self.sessions);
    sessionPage(self, result);
}
fn olderSessions(b: ?*c.GtkButton, ctx: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Agent, ctx.?);
    const cursor = u.z(widgetData(b.?, "cursor"));
    defer a.free(cursor);
    const encoded = api.escaped(cursor);
    defer a.free(encoded);
    const path = u.fmt("/api/session?cursor={s}", .{encoded});
    defer a.free(path);
    c.gtk_widget_set_sensitive(u.cast(c.GtkWidget, b.?), 0);
    self.client.request(path, null, self, self.epoch, &olderPage);
}
fn olderPage(ctx: *anyopaque, epoch: u64, result: Value, err: ?[]const u8) void {
    const self = u.cast(Agent, ctx);
    if (epoch != self.epoch) return;
    if (c.gtk_widget_get_last_child(self.sessions)) |last| {
        if (c.g_object_get_data(u.cast(c.GObject, last), "cursor") == null) return;
        if (failure(self, err)) {
            c.gtk_widget_set_sensitive(last, 1);
            return;
        }
        c.gtk_box_remove(u.cast(c.GtkBox, self.sessions), last);
    }
    sessionPage(self, result);
}
fn sessionState(row: Value) [*:0]const u8 {
    const times = api.get(row, "time");
    const busy = api.get(times, "busy");
    const idle = api.get(times, "idle");
    if (busy == .integer and (idle != .integer or busy.integer > idle.integer)) return i18n.dtr("coral", "Running");
    const outcome = api.string(row, "outcome");
    if (std.mem.eql(u8, outcome, "failed")) return i18n.dtr("coral", "Needs attention");
    if (std.mem.eql(u8, outcome, "succeeded")) return i18n.dtr("coral", "Completed");
    if (std.mem.eql(u8, outcome, "interrupted")) return i18n.dtr("coral", "Interrupted");
    return i18n.dtr("coral", "Ready");
}
fn sessionPage(self: *Agent, result: Value) void {
    const list = api.items(api.get(result, "data"));
    const project = self.stateGroup("");
    defer a.free(project);
    const last = storage.lastSession(project);
    defer if (last) |sid| a.free(sid);
    var first: ?[]const u8 = null;
    var first_dir: []const u8 = "";
    for (list) |row| {
        const id = api.string(row, "id");
        if (id.len == 0) continue;
        const owned = api.string(api.get(row, "metadata"), "coralRoot");
        const directory = api.string(api.get(row, "location"), "directory");
        if (!std.mem.eql(u8, self.root, owned) and !std.mem.eql(u8, self.root, directory)) continue;
        if (first == null or (last != null and std.mem.eql(u8, last.?, id))) {
            first = id;
            first_dir = directory;
        }
        const title = u.z(api.string(row, "title"));
        defer a.free(title);
        const b = c.gtk_button_new().?;
        c.gtk_widget_add_css_class(b, "flat");
        c.gtk_widget_add_css_class(b, "workspace-session");
        const labels = u.box(false, 1);
        const name = u.label(title);
        c.gtk_label_set_ellipsize(u.cast(c.GtkLabel, name), c.PANGO_ELLIPSIZE_END);
        u.append(labels, name);
        const status = u.label(std.mem.span(sessionState(row)));
        c.gtk_widget_add_css_class(status, "caption");
        u.append(labels, status);
        c.gtk_button_set_child(u.cast(c.GtkButton, b), labels);
        c.gtk_accessible_update_property(u.cast(c.GtkAccessible, b), @as(c_int, c.GTK_ACCESSIBLE_PROPERTY_LABEL), title.ptr, @as(c_int, -1));
        setData(b, "sid", id);
        setData(b, "location", directory);
        setData(b, "title", title);
        u.connect(b, "clicked", &selectSession, self);
        u.append(self.sessions, b);
    }
    const next = api.string(api.get(result, "cursor"), "next");
    if (next.len > 0) {
        const more = u.button(i18n.dtr("coral", "Older sessions"));
        setData(more, "cursor", next);
        u.connect(more, "clicked", &olderSessions, self);
        u.append(self.sessions, more);
    }
    self.markSession();
    if (!self.rehydrate and self.session != null) return;
    self.rehydrate = false;
    u.setLabel(self.status, i18n.dtr("coral", "Connected"));
    self.connected = true;
    c.gtk_widget_set_sensitive(self.new_session, 1);
    if (self.session != null) {
        self.requestInfo();
        self.readThread();
        self.readPermissions();
        self.call("/inbox", null, &inboxList);
    } else if (first) |id| self.activate(id, first_dir);
}
fn selectSession(b: ?*c.GtkButton, ctx: ?*anyopaque) callconv(.c) void {
    u.cast(Agent, ctx.?).activate(widgetData(b.?, "sid"), widgetData(b.?, "location"));
}
fn sessionInfo(ctx: *anyopaque, epoch: u64, result: Value, err: ?[]const u8) void {
    const self = u.cast(Agent, ctx);
    if (epoch != self.model_generation or failure(self, err)) return;
    if (self.pending or !self.connected) return;
    const info = api.get(result, "data");
    u.setLabel(self.title, api.string(info, "title"));
    self.reviewBase(api.string(api.get(info, "metadata"), "coralBase"));
    const ref = api.get(info, "model");
    a.free(self.model_id);
    a.free(self.provider);
    self.model_id = u.z(api.string(ref, "id"));
    self.provider = u.z(api.string(ref, "providerID"));
    const dir = api.string(api.get(info, "location"), "directory");
    if (dir.len > 0) {
        a.free(self.location);
        self.location = u.z(dir);
    }
    storage.write(self.root, "last-open-thread", .{ .session = @as([]const u8, self.session orelse return), .server = @as([]const u8, self.server), .location = @as([]const u8, self.location), .base = @as([]const u8, self.base orelse ""), .title = api.string(info, "title") }) catch u.setLabel(self.status, i18n.dtr("coral", "Could not save session state"));
    c.gtk_menu_button_set_label(u.cast(c.GtkMenuButton, self.models), if (self.model_id.len > 0) self.model_id else i18n.dtr("coral", "Service default"));
    if (self.model_id.len == 0) self.queryModel("/api/model/default", &defaultModel) else self.queryModel("/api/model", &catalog);
    self.deliveryControls();
    u.setLabel(self.status, i18n.dtr("coral", "Connected"));
}
fn defaultModel(ctx: *anyopaque, generation: u64, result: Value, err: ?[]const u8) void {
    const self = u.cast(Agent, ctx);
    if (generation != self.model_generation) return;
    if (!failure(self, err)) {
        const ref = api.get(result, "data");
        a.free(self.model_id);
        a.free(self.provider);
        self.model_id = u.z(api.string(ref, "id"));
        self.provider = u.z(api.string(ref, "providerID"));
    }
    self.queryModel("/api/model", &catalog);
}
fn modelName(row: Value) []const u8 {
    const name = api.string(row, "name");
    return if (name.len > 0) name else api.string(row, "id");
}
fn available(row: Value) bool {
    const enabled = api.get(row, "enabled");
    return !(enabled == .bool and !enabled.bool) and api.string(row, "id").len != 0 and api.string(row, "providerID").len != 0;
}
fn catalog(ctx: *anyopaque, epoch: u64, result: Value, err: ?[]const u8) void {
    const self = u.cast(Agent, ctx);
    if (epoch != self.model_generation or failure(self, err)) return;
    clear(self.choices);
    const heading = u.label(i18n.dtr("coral", "Session model"));
    c.gtk_widget_add_css_class(heading, "workspace-section");
    u.append(self.choices, heading);
    var providers: std.StringHashMapUnmanaged(u.W) = .empty;
    defer providers.deinit(a);
    const rows = api.items(api.get(result, "data"));
    var names: std.StringHashMapUnmanaged(usize) = .empty;
    defer names.deinit(a);
    for (rows) |row| {
        if (!available(row)) continue;
        const entry = names.getOrPut(a, modelName(row)) catch unreachable;
        entry.value_ptr.* = if (entry.found_existing) entry.value_ptr.* + 1 else 1;
    }
    for (rows) |model| {
        if (!available(model)) continue;
        const provider = api.string(model, "providerID");
        const id = api.string(model, "id");
        const group = providers.getOrPut(a, provider) catch unreachable;
        if (!group.found_existing) {
            const caption = u.label(provider);
            c.gtk_widget_add_css_class(caption, "caption");
            u.margin(caption, 4);
            u.append(self.choices, caption);
            group.value_ptr.* = u.box(false, 1);
            u.append(self.choices, group.value_ptr.*);
        }
        const name = modelName(model);
        const display = if (names.get(name).? > 1) u.fmt("{s} · {s}", .{ name, provider }) else u.z(name);
        defer a.free(display);
        const active = std.mem.eql(u8, id, self.model_id) and std.mem.eql(u8, provider, self.provider);
        const label = u.fmt("{s}{s}", .{ if (active) "✓ " else "", display });
        defer a.free(label);
        const b = u.button(label);
        c.gtk_widget_add_css_class(b, "flat");
        if (active) c.gtk_widget_add_css_class(b, "workspace-current-session");
        if (active) c.gtk_menu_button_set_label(u.cast(c.GtkMenuButton, self.models), display);
        setData(b, "sid", self.session orelse return);
        setData(b, "provider", provider);
        setData(b, "model", id);
        u.connect(b, "clicked", &switchModel, self);
        u.append(group.value_ptr.*, b);
    }
    if (providers.count() == 0) {
        u.append(self.choices, u.label(i18n.dtr("coral", "No configured chat models")));
        // The service initially returns an empty catalog while its providers initialize.
        if (self.catalog_retry == 0 and self.catalog_attempt < 5) {
            self.catalog_retry = c.g_timeout_add_seconds(@as(c_uint, 1) << self.catalog_attempt, &retryCatalog, self);
            self.catalog_attempt += 1;
        }
    } else {
        if (self.catalog_retry != 0) _ = c.g_source_remove(self.catalog_retry);
        self.catalog_retry = 0;
        self.catalog_attempt = 0;
    }
    c.gtk_widget_set_sensitive(self.models, @intFromBool(!self.pending));
}
fn retryCatalog(ctx: ?*anyopaque) callconv(.c) c_int {
    const self = u.cast(Agent, ctx.?);
    self.catalog_retry = 0;
    self.requestInfo();
    return 0;
}
fn switchModel(b: ?*c.GtkButton, ctx: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Agent, ctx.?);
    if (self.pending or !self.connected or !std.mem.eql(u8, self.session orelse return, widgetData(b.?, "sid"))) return;
    self.model_generation += 1;
    c.gtk_widget_set_visible(self.model_feedback, 0);
    c.gtk_menu_button_popdown(u.cast(c.GtkMenuButton, self.models));
    const body = api.json(.{ .model = .{ .id = widgetData(b.?, "model"), .providerID = widgetData(b.?, "provider") } });
    defer a.free(body);
    self.pending = true;
    c.gtk_widget_set_sensitive(self.models, 0);
    self.deliveryControls();
    u.setLabel(self.status, i18n.dtr("coral", "Switching model…"));
    self.call("/model", body, &switched);
}
fn switched(ctx: *anyopaque, epoch: u64, _: Value, err: ?[]const u8) void {
    const self = u.cast(Agent, ctx);
    if (epoch != self.epoch) return;
    self.pending = false;
    if (err) |reason| {
        u.setLabel(self.model_feedback, reason);
        c.gtk_widget_set_visible(self.model_feedback, 1);
    }
    if (!self.connected) return;
    self.requestInfo();
}
fn history(ctx: *anyopaque, generation: u64, result: Value, err: ?[]const u8) void {
    const self = u.cast(Agent, ctx);
    if (generation != self.thread_generation or failure(self, err)) return;
    reconcileDelivery(self, api.items(api.get(result, "data")));
    self.thread.page(result, false);
    if (self.thread.restore.id != null and self.thread.cursor != null) olderMessages(null, self);
}
fn olderMessages(_: ?*c.GtkButton, ctx: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Agent, ctx.?);
    if (self.loading_older) return;
    const cursor = api.escaped(self.thread.cursor orelse return);
    defer a.free(cursor);
    const suffix = u.fmt("/message?limit=100&cursor={s}", .{cursor});
    defer a.free(suffix);
    self.loading_older = true;
    c.gtk_widget_set_sensitive(self.thread.older, 0);
    self.call(suffix, null, &earlierHistory);
}
fn earlierHistory(ctx: *anyopaque, epoch: u64, result: Value, err: ?[]const u8) void {
    const self = u.cast(Agent, ctx);
    if (epoch != self.epoch) return;
    self.loading_older = false;
    c.gtk_widget_set_sensitive(self.thread.older, 1);
    if (failure(self, err)) return;
    const prior = self.thread.messages.items.len;
    self.thread.page(result, true);
    if (self.thread.restore.id != null and self.thread.cursor != null and self.thread.messages.items.len > prior) olderMessages(null, self);
}
fn readPositionChanged(_: ?*c.GtkAdjustment, ctx: ?*anyopaque) callconv(.c) void {
    draftChanged(null, ctx);
}
fn attachCode(_: ?*c.GtkButton, ctx: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Agent, ctx.?);
    const doc = self.app.active() orelse return;
    const selected = self.app.activeBuffer() orelse return;
    var start: c.GtkTextIter = undefined;
    var end: c.GtkTextIter = undefined;
    if (c.gtk_text_buffer_get_selection_bounds(selected, &start, &end) == 0) {
        u.setLabel(self.status, i18n.dtr("coral", "Select code in the editor first"));
        return;
    }
    const p = c.gtk_text_buffer_get_text(selected, &start, &end, 1);
    defer c.g_free(p);
    self.clearSelection();
    self.captured = u.z(std.mem.span(p));
    const path: []const u8 = if (doc.path) |full| blk: {
        if (std.mem.startsWith(u8, full, self.root) and full.len > self.root.len and full[self.root.len] == '/') break :blk full[self.root.len + 1 ..];
        break :blk full;
    } else i18n.dtr("coral", "Untitled");
    const base = self.app.activeSelectionBase();
    var source_start: c.GtkTextIter = undefined;
    var source_end: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_iter_at_offset(doc.buffer, &source_start, base + c.gtk_text_iter_get_offset(&start));
    c.gtk_text_buffer_get_iter_at_offset(doc.buffer, &source_end, base + c.gtk_text_iter_get_offset(&end));
    self.anchor = .{ .document = doc.id, .revision = doc.revision, .start = @intCast(c.gtk_text_iter_get_offset(&source_start)), .end = @intCast(c.gtk_text_iter_get_offset(&source_end)) };
    self.tag = u.fmt("{s} · L{d}–{d}", .{ path, c.gtk_text_iter_get_line(&source_start) + 1, c.gtk_text_iter_get_line(&source_end) + 1 });
    c.gtk_menu_button_popdown(u.cast(c.GtkMenuButton, self.chip));
    c.gtk_widget_set_tooltip_text(self.chip, i18n.dtr("coral", "Show captured code"));
    self.showSelection();
}
fn showSnapshot(_: ?*c.GtkWidget, ctx: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Agent, ctx.?);
    setText(self.snapshot, self.captured orelse "");
    const doc = self.app.documents.get(self.anchor.document);
    const text = u.fmt("{s}   ·   r{d}{s}", .{ self.tag orelse return, self.anchor.revision, if (doc == null or doc.?.revision != self.anchor.revision) i18n.dtr("coral", " · Source changed or closed") else "" });
    defer a.free(text);
    u.setLabel(self.caption, text);
}
fn detach(_: ?*c.GtkButton, ctx: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Agent, ctx.?);
    c.gtk_menu_button_popdown(u.cast(c.GtkMenuButton, self.chip));
    self.clearSelection();
    self.showSelection();
}
fn submit(_: ?*c.GtkButton, ctx: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Agent, ctx.?);
    if (self.session == null or self.pending or self.sending or !self.connected) return;
    const draft = u.bufferText(buffer(self.composer));
    defer a.free(draft);
    if (std.mem.trim(u8, draft, " \n\t").len == 0) return;
    const prompt = if (self.captured) |s| u.fmt("{s}\n\n{s}\n{s}", .{ draft, self.tag.?, s }) else u.z(draft);
    defer a.free(prompt);
    if (self.operation == null) {
        const uuid = c.g_uuid_string_random();
        defer c.g_free(uuid);
        self.operation = u.fmt("msg_{s}", .{std.mem.span(uuid)});
        self.persistDraft(self.session.?) catch {
            self.resetOperation();
            u.setLabel(self.status, i18n.dtr("coral", "Could not save the prompt for delivery"));
            return;
        };
    }
    const body = api.json(.{ .id = @as([]const u8, self.operation.?), .text = @as([]const u8, prompt), .metadata = .{ .selection = if (self.captured != null) self.anchor else @as(?storage.Anchor, null) } });
    defer a.free(body);
    self.sending = true;
    self.deliveryControls();
    self.call("/prompt", body, &sent);
}
fn sent(ctx: *anyopaque, epoch: u64, _: Value, err: ?[]const u8) void {
    const self = u.cast(Agent, ctx);
    if (epoch != self.epoch) return;
    self.sending = false;
    if (!failure(self, err)) delivered(self) else self.deliveryControls();
    self.call("/inbox", null, &inboxList);
    self.readThread();
}
fn delivered(self: *Agent) void {
    if (self.operation == null) return;
    self.resetOperation();
    setText(self.composer, "");
    self.clearSelection();
    self.showSelection();
    self.deliveryControls();
    self.saveDraft(self.session.?);
    u.setLabel(self.status, i18n.dtr("coral", "Prompt delivered"));
}
fn reconcileDelivery(self: *Agent, rows: []const Value) void {
    const id = self.operation orelse return;
    if (self.sending) return;
    for (rows) |row| if (std.mem.eql(u8, api.string(row, "id"), id)) {
        delivered(self);
        return;
    };
}

fn eventReceived(ctx: *anyopaque, _: u64, event: Value, err: ?[]const u8) void {
    const self = u.cast(Agent, ctx);
    if (err != null) {
        self.connected = false;
        self.model_generation += 1;
        c.gtk_widget_set_sensitive(self.send, 0);
        c.gtk_widget_set_sensitive(self.new_session, 0);
        self.deliveryControls();
        c.gtk_widget_set_sensitive(self.inbox, 0);
        u.setLabel(self.status, i18n.dtr("coral", "Reconnecting to OpenCode…"));
        c.gtk_widget_set_sensitive(self.models, 0);
        self.disablePermissions();
        if (self.reconnect_timer == 0) self.reconnect_timer = c.g_timeout_add_seconds(3, &retryConnection, self);
        return;
    }
    const kind = api.string(event, "type");
    if (std.mem.eql(u8, kind, "server.connected")) return;
    if (std.mem.eql(u8, kind, "session.created") or std.mem.eql(u8, kind, "session.deleted") or std.mem.eql(u8, kind, "session.renamed") or std.mem.eql(u8, kind, "session.archived") or std.mem.startsWith(u8, kind, "session.execution.")) {
        self.need_list = true;
        if (self.update_timer == 0) self.update_timer = c.g_timeout_add(120, &flushEvents, self);
    }
    const data = api.get(event, "data");
    const sid = api.string(data, "sessionID");
    if (sid.len != 0 and !std.mem.eql(u8, self.session orelse return, sid)) return;
    if (std.mem.eql(u8, kind, "session.model.selected") or std.mem.eql(u8, kind, "model.updated") or std.mem.eql(u8, kind, "provider.updated")) self.need_info = true;
    if (std.mem.startsWith(u8, kind, "session.text.") or std.mem.startsWith(u8, kind, "session.step.") or std.mem.startsWith(u8, kind, "session.execution.")) self.need_thread = true;
    if (std.mem.startsWith(u8, kind, "session.inbox.")) self.need_queue = true;
    if (std.mem.startsWith(u8, kind, "permission.")) self.need_permissions = true;
    if (self.update_timer == 0 and (self.need_info or self.need_thread or self.need_queue or self.need_permissions)) self.update_timer = c.g_timeout_add(120, &flushEvents, self);
}
fn retryConnection(ctx: ?*anyopaque) callconv(.c) c_int {
    const self = u.cast(Agent, ctx.?);
    self.reconnect_timer = 0;
    if (self.root.len > 0) self.refresh();
    return 0;
}
fn flushEvents(ctx: ?*anyopaque) callconv(.c) c_int {
    const self = u.cast(Agent, ctx.?);
    self.update_timer = 0;
    if (self.need_list) self.loadSessions();
    self.need_list = false;
    if (self.need_info and !self.pending) self.requestInfo();
    if (self.need_thread) self.readThread();
    if (self.need_queue) self.call("/inbox", null, &inboxList);
    if (self.need_permissions) self.readPermissions();
    self.need_info = false;
    self.need_thread = false;
    self.need_queue = false;
    self.need_permissions = false;
    return 0;
}
fn permissionList(ctx: *anyopaque, generation: u64, value: Value, err: ?[]const u8) void {
    const self = u.cast(Agent, ctx);
    if (generation != self.permission_state.fetch or !self.connected or failure(self, err)) return;
    const sid = self.session orelse return;
    var title: []const u8 = sid;
    var row = c.gtk_widget_get_first_child(self.sessions);
    while (row) |w| : (row = c.gtk_widget_get_next_sibling(w)) {
        if (c.g_object_get_data(u.cast(c.GObject, w), "sid") != null and std.mem.eql(u8, widgetData(w, "sid"), sid)) {
            title = widgetData(w, "title");
            break;
        }
    }
    self.permission_state.present(self.permissions, self.app.window, self.server, sid, title, self.location, api.items(api.get(value, "data")), self, &replyPermission);
    self.pendingVisible();
    c.gtk_widget_set_sensitive(self.permissions, 1);
}
fn replyPermission(button: ?*c.GtkButton, ctx: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Agent, ctx.?);
    const widget = u.cast(c.GtkWidget, button.?);
    if (!self.connected or c.gtk_widget_is_sensitive(widget) == 0) return;
    const card = c.gtk_widget_get_parent(c.gtk_widget_get_parent(widget)).?;
    if (c.gtk_widget_get_parent(card) != self.permissions or permission_ui.pending(card)) return;
    const id = api.escaped(permission_ui.requestId(card));
    defer a.free(id);
    const sid = api.escaped(self.session orelse return);
    defer a.free(sid);
    const path = u.fmt("/api/session/{s}/permission/{s}/reply", .{ sid, id });
    defer a.free(path);
    const decision: []const u8 = if (c.g_object_get_data(u.cast(c.GObject, widget), "deny") != null) "reject" else "once";
    const body = api.json(.{ .decision = decision });
    defer a.free(body);
    self.permission_state.fetch = 0;
    const token = self.permission_state.next();
    c.g_object_set_data(u.cast(c.GObject, card), "reply", @ptrFromInt(token));
    permission_ui.setAnswerable(card, false);
    self.client.request(path, body, self, token, &replied);
}
fn replied(ctx: *anyopaque, token: u64, _: Value, err: ?[]const u8) void {
    const self = u.cast(Agent, ctx);
    var child = c.gtk_widget_get_first_child(self.permissions);
    while (child) |card| : (child = c.gtk_widget_get_next_sibling(card)) {
        if (@intFromPtr(c.g_object_get_data(u.cast(c.GObject, card), "reply")) != token) continue;
        c.g_object_set_data(u.cast(c.GObject, card), "reply", null);
        _ = failure(self, err);
        self.readPermissions();
        return;
    }
}
fn inboxList(ctx: *anyopaque, epoch: u64, value: Value, err: ?[]const u8) void {
    const self = u.cast(Agent, ctx);
    if (epoch != self.epoch or failure(self, err)) return;
    defer self.pendingVisible();
    clear(self.inbox);
    c.gtk_widget_set_sensitive(self.inbox, @intFromBool(self.connected));
    const rows = api.items(api.get(value, "data"));
    reconcileDelivery(self, rows);
    if (rows.len == 0) return;
    u.append(self.inbox, u.label(i18n.dtr("coral", "Queued prompts")));
    for (rows) |item| {
        const text = api.string(api.get(item, "payload"), "text");
        if (text.len == 0) continue;
        const label = u.label(text);
        c.gtk_label_set_ellipsize(u.cast(c.GtkLabel, label), c.PANGO_ELLIPSIZE_END);
        c.gtk_widget_set_tooltip_text(label, c.gtk_label_get_text(u.cast(c.GtkLabel, label)));
        const row = u.box(true, 4);
        c.gtk_widget_set_hexpand(label, 1);
        u.append(row, label);
        const id = api.string(item, "id");
        if (id.len > 0) {
            const cancel = u.icon("edit-delete-symbolic", i18n.dtr("coral", "Cancel queued prompt"));
            setData(cancel, "inbox", id);
            u.connect(cancel, "clicked", &cancelInbox, self);
            u.append(row, cancel);
        }
        u.append(self.inbox, row);
    }
}

fn cancelInbox(b: ?*c.GtkButton, ctx: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Agent, ctx.?);
    if (!self.connected) return;
    const sid = api.escaped(self.session orelse return);
    defer a.free(sid);
    const item = u.z(widgetData(b.?, "inbox"));
    defer a.free(item);
    const id = api.escaped(item);
    defer a.free(id);
    const path = u.fmt("/api/session/{s}/inbox/{s}", .{ sid, id });
    defer a.free(path);
    c.gtk_widget_set_sensitive(u.cast(c.GtkWidget, b.?), 0);
    self.client.requestMethod("DELETE", path, null, self, self.epoch, &cancelledInbox);
}
fn cancelledInbox(ctx: *anyopaque, epoch: u64, _: Value, err: ?[]const u8) void {
    const self = u.cast(Agent, ctx);
    if (epoch != self.epoch) return;
    _ = failure(self, err);
    self.call("/inbox", null, &inboxList);
}
fn projectInfo(ctx: *anyopaque, epoch: u64, value: Value, err: ?[]const u8) void {
    const self = u.cast(Agent, ctx);
    if (epoch != self.epoch or failure(self, err)) return;
    const id = u.z(api.string(api.get(value, "project"), "id"));
    defer a.free(id);
    const arg = api.escaped(if (id.len == 0) self.root else id);
    defer a.free(arg);
    const path = u.fmt("/api/session?{s}={s}&limit=100", .{ if (id.len == 0) "directory" else "project", arg });
    defer a.free(path);
    self.client.request(path, null, self, epoch, &listed);
}
fn newSession(_: ?*c.GtkButton, ctx: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Agent, ctx.?);
    if (self.root.len == 0) return;
    c.gtk_widget_set_sensitive(self.new_session, 0);
    u.setLabel(self.status, i18n.dtr("coral", "Preparing session…"));
    @import("workspace_worktree.zig").prepare(self.root, self.client.cancel, self, self.epoch, &prepared);
}
fn prepared(ctx: *anyopaque, epoch: u64, result: anyerror!?@import("workspace_worktree.zig").Snapshot) void {
    const self = u.cast(Agent, ctx);
    c.gtk_widget_set_sensitive(self.new_session, 1);
    if (epoch != self.epoch) return;
    const snapshot = result catch |err| {
        u.setLabel(self.status, @errorName(err));
        return;
    };
    const body = if (snapshot) |s| api.json(.{ .location = .{ .directory = @as([]const u8, s.directory) }, .metadata = .{ .coralRoot = @as([]const u8, self.root), .coralBase = @as([]const u8, s.base) } }) else api.json(.{ .agent = "plan", .location = .{ .directory = @as([]const u8, self.root) }, .metadata = .{ .coralRoot = @as([]const u8, self.root) } });
    defer a.free(body);
    c.gtk_widget_set_sensitive(self.new_session, 0);
    self.client.request("/api/session", body, self, epoch, &created);
}
fn created(ctx: *anyopaque, epoch: u64, value: Value, err: ?[]const u8) void {
    const self = u.cast(Agent, ctx);
    c.gtk_widget_set_sensitive(self.new_session, 1);
    if (epoch != self.epoch or failure(self, err)) return;
    const id = api.string(api.get(value, "data"), "id");
    if (id.len == 0) return;
    self.activate(id, api.string(api.get(api.get(value, "data"), "location"), "directory"));
    self.loadSessions();
}

fn showReview(_: ?*c.GtkButton, ctx: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Agent, ctx.?);
    const base = self.base orelse return;
    if (self.app.review) |r| r.open(self.root, self.location, base);
}

fn draftChanged(_: ?*c.GtkTextBuffer, ctx: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Agent, ctx.?);
    if (self.session == null) return;
    if (self.draft_timer != 0) _ = c.g_source_remove(self.draft_timer);
    self.draft_timer = c.g_timeout_add(400, &savePendingDraft, self);
}
fn savePendingDraft(ctx: ?*anyopaque) callconv(.c) c_int {
    const self = u.cast(Agent, ctx.?);
    self.draft_timer = 0;
    if (self.session) |id| self.saveDraft(id);
    return 0;
}
