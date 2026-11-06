//! Scheduler profiles in Settings. It drives the same scheduler service as
//! the bar flyout, laid out like the Power page's power modes, and edits the
//! scx catalog's profiles for every user, behind an administrator password.
const std = @import("std");
const gtk = @import("gtk4");
const object = @import("gobject2");
const w = @import("../ui/components/widgets.zig");
const builder = @import("rule_builder.zig");
const p = @import("../services/sched_profiles.zig");
const editor = @import("../services/sched_editor.zig");
const Service = @import("../services/scheduling.zig").Service;
const log = std.log.scoped(.settings);
const a = std.heap.c_allocator;
const Connection = struct { obj: *object.Object, id: c_ulong };

pub const View = struct {
    service: *Service,
    /// Owns everything built from the current profile list.
    arena: std.heap.ArenaAllocator = .init(a),
    ids: []const []const u8 = &.{},
    buttons: []*gtk.CheckButton = &.{},
    /// Whether each profile's scheduler is installed.
    available: []bool = &.{},
    /// "Selected, stopped" under each profile, shown for a selection kept
    /// while the unit is stopped.
    stopped: []*gtk.Label = &.{},
    bindings: []Binding = &.{},
    root: *gtk.Box,
    status: *gtk.Label,
    message: *gtk.Label,
    /// The profiles to choose from, or in edit mode the list to edit.
    profiles: *gtk.Box,
    edit_button: *gtk.Button,
    add_button: *gtk.Button,
    restore_button: *gtk.Button,
    /// Signals of widgets rebuilt with the list.
    connections: std.ArrayList(Connection) = .empty,
    /// The profile list the widgets were built from.
    signature: u64 = 0,
    editing: bool = false,
    updating: bool = false,
    dialog: ?Dialog = null,
    const Binding = struct { view: *View, index: usize };
    const Dialog = struct {
        window: *gtk.Dialog,
        /// What the editor was opened on, copied out of the listing: the
        /// service frees a listing whenever scxcli lists again. Null for the
        /// restore dialog.
        draft: ?editor.Draft = null,
        /// Restoring the defaults asks first, in a dialog without fields.
        restore: bool = false,
        name: ?*gtk.Entry = null,
        description: ?*gtk.Entry = null,
        scheduler: ?*gtk.DropDown = null,
        options: ?*gtk.Entry = null,
        err: ?*gtk.Label = null,
        arena: std.heap.ArenaAllocator,
    };
    const respond_delete = 1;

    pub fn create(host: *gtk.Box, service: *Service) !*View {
        const self = try a.create(View);
        errdefer a.destroy(self);
        self.* = .{ .service = service, .root = w.column(16), .status = undefined, .message = undefined, .profiles = undefined, .edit_button = undefined, .add_button = undefined, .restore_button = undefined };
        errdefer self.arena.deinit();
        self.root.as(gtk.Widget).addCssClass("power-view");
        host.append(self.root.as(gtk.Widget));
        const section = w.column(8);
        const header = w.row(8);
        const title = w.label(@import("i18n").dtr("pearl", "CPU Scheduler"), "pearl-section-title");
        title.as(gtk.Widget).setHexpand(1);
        header.append(title.as(gtk.Widget));
        self.add_button = w.wrappingButton(@import("i18n").dtr("pearl", "Add profile"));
        self.restore_button = w.wrappingButton(@import("i18n").dtr("pearl", "Restore defaults"));
        self.edit_button = w.wrappingButton(@import("i18n").dtr("pearl", "Edit profiles"));
        for ([_]*gtk.Button{ self.add_button, self.restore_button, self.edit_button }) |button| {
            button.as(gtk.Widget).setValign(.center);
            header.append(button.as(gtk.Widget));
        }
        _ = gtk.Button.signals.clicked.connect(self.add_button, *View, addClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(self.restore_button, *View, restoreClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(self.edit_button, *View, editModeClicked, self, .{});
        section.append(header.as(gtk.Widget));
        self.root.append(section.as(gtk.Widget));
        self.status = w.label("", "pearl-secondary");
        self.status.setWrap(1);
        section.append(self.status.as(gtk.Widget));
        // What went wrong goes under the status, above the profiles.
        self.message = w.label("", "pearl-secondary");
        self.message.setWrap(1);
        section.append(self.message.as(gtk.Widget));
        self.profiles = w.column(8);
        section.append(self.profiles.as(gtk.Widget));
        self.update();
        return self;
    }

    pub fn destroy(self: *View) void {
        self.closeDialog();
        self.disconnect();
        self.connections.deinit(a);
        self.arena.deinit();
        a.destroy(self);
    }

    fn disconnect(self: *View) void {
        for (self.connections.items) |c| object.signalHandlerDisconnect(c.obj, c.id);
        self.connections.clearRetainingCapacity();
    }

    /// Identifies the profile list and the mode, so the widgets are rebuilt
    /// only when either changes.
    fn listSignature(self: *const View) u64 {
        var hash = std.hash.Wyhash.init(@intFromBool(self.editing));
        hash.update(std.mem.asBytes(&self.service.signature()));
        hash.update(if (self.service.shipped != null) "shipped" else "");
        return hash.final();
    }

    /// No rows, and nothing that refers to them.
    fn clear(self: *View) void {
        self.disconnect();
        while (self.profiles.as(gtk.Widget).getFirstChild()) |child| self.profiles.remove(child);
        self.ids = &.{};
        self.buttons = &.{};
        self.available = &.{};
        self.stopped = &.{};
        self.bindings = &.{};
        _ = self.arena.reset(.retain_capacity);
    }

    fn rebuild(self: *View) !void {
        self.clear();
        const listing = self.service.listing orelse return;
        const alloc = self.arena.allocator();
        const ids = try alloc.alloc([]const u8, listing.profiles.len);
        for (listing.profiles, ids) |profile, *id| id.* = try alloc.dupe(u8, profile.id);
        self.ids = ids;
        self.bindings = try alloc.alloc(Binding, listing.profiles.len);
        for (self.bindings, 0..) |*binding, i| binding.* = .{ .view = self, .index = i };
        if (self.editing) return self.buildEditor(listing.profiles);
        self.buttons = try alloc.alloc(*gtk.CheckButton, listing.profiles.len);
        self.available = try alloc.alloc(bool, listing.profiles.len);
        self.stopped = try alloc.alloc(*gtk.Label, listing.profiles.len);
        const flow = w.flow(3);
        flow.setHomogeneous(1);
        for (listing.profiles, self.buttons, self.available, self.stopped, self.bindings, 0..) |profile, *button, *available, *stopped, *binding, i| {
            button.* = gtk.CheckButton.new();
            available.* = profile.available;
            if (i > 0) button.*.setGroup(self.buttons[0]);
            const labels = w.column(5);
            labels.append(w.label(try alloc.dupeSentinel(u8, profile.label, 0), "settings-row-title").as(gtk.Widget));
            // A recommended scheduler that is not installed is listed, but
            // cannot be started.
            const text: ?[:0]const u8 = if (!profile.available) @import("i18n").dtr("pearl", "Not installed") else if (profile.description.len > 0) try alloc.dupeSentinel(u8, profile.description, 0) else null;
            if (text) |value| {
                const detail = w.label(value, "pearl-secondary");
                detail.setWrap(1);
                labels.append(detail.as(gtk.Widget));
            }
            stopped.* = w.label(@import("i18n").dtr("pearl", "Selected, stopped"), "pearl-secondary");
            stopped.*.as(gtk.Widget).setVisible(0);
            labels.append(stopped.*.as(gtk.Widget));
            button.*.setChild(labels.as(gtk.Widget));
            button.*.as(gtk.Widget).addCssClass("power-mode");
            w.name(button.*.as(gtk.Widget), try alloc.dupeSentinel(u8, profile.label, 0));
            flow.insert(button.*.as(gtk.Widget), -1);
            try self.connections.append(a, .{ .obj = button.*.as(object.Object), .id = gtk.CheckButton.signals.toggled.connect(button.*, *Binding, toggled, binding, .{}) });
        }
        self.profiles.append(flow.as(gtk.Widget));
    }

    /// One row per profile, with what it runs, whether it differs from the
    /// shipped profiles, and buttons to reorder and edit it.
    fn buildEditor(self: *View, profiles: []const p.Profile) !void {
        const alloc = self.arena.allocator();
        const system = if (self.service.customized()) self.service.shipped else null;
        for (profiles, self.bindings, 0..) |profile, *binding, i| {
            const card = builder.card();
            const top = w.row(8);
            const text = w.column(4);
            text.as(gtk.Widget).setHexpand(1);
            const kind: ?[:0]const u8 = if (system) |s| if (p.findIn(s, profile.id)) |j| (if (p.sameCommand(s[j], profile) and std.mem.eql(u8, s[j].label, profile.label) and std.mem.eql(u8, s[j].description, profile.description)) null else @import("i18n").dtr("pearl", "Modified")) else @import("i18n").dtr("pearl", "Custom") else null;
            const title = w.label(if (kind) |tag| try std.fmt.allocPrintSentinel(alloc, "{s}  ·  {s}", .{ profile.label, tag }, 0) else try alloc.dupeSentinel(u8, profile.label, 0), "settings-row-title");
            title.setWrap(1);
            text.append(title.as(gtk.Widget));
            const summary = w.label(try command(alloc, profile), "pearl-secondary");
            summary.setWrap(1);
            summary.setSelectable(1);
            text.append(summary.as(gtk.Widget));
            top.append(text.as(gtk.Widget));
            // Default is always first, so it does not move and nothing moves
            // above it.
            if (!profile.isDefault()) {
                const up = w.iconButton("go-up-symbolic", @import("i18n").dtr("pearl", "Move up"));
                const down = w.iconButton("go-down-symbolic", @import("i18n").dtr("pearl", "Move down"));
                up.as(gtk.Widget).setSensitive(@intFromBool(i > 1));
                down.as(gtk.Widget).setSensitive(@intFromBool(i + 1 < profiles.len));
                for ([_]*gtk.Button{ up, down }) |button| {
                    button.as(gtk.Widget).setValign(.center);
                    top.append(button.as(gtk.Widget));
                }
                try self.connections.appendSlice(a, &.{
                    .{ .obj = up.as(object.Object), .id = gtk.Button.signals.clicked.connect(up, *Binding, moveUp, binding, .{}) },
                    .{ .obj = down.as(object.Object), .id = gtk.Button.signals.clicked.connect(down, *Binding, moveDown, binding, .{}) },
                });
            }
            const edit = w.wrappingButton(@import("i18n").dtr("pearl", "Edit"));
            edit.as(gtk.Widget).setValign(.center);
            top.append(edit.as(gtk.Widget));
            if (profile.isDefault()) {
                // Default is the fallback when a scheduler fails, so it stays
                // as the system defines it.
                edit.as(gtk.Widget).setSensitive(0);
                edit.as(gtk.Widget).setTooltipText(@import("i18n").dtr("pearl", "Pearl switches back to this profile when a scheduler fails, so it cannot be changed."));
            } else {
                w.name(edit.as(gtk.Widget), try std.fmt.allocPrintSentinel(alloc, "{s}: {s}", .{ @import("i18n").dtr("pearl", "Edit profile"), profile.label }, 0));
                try self.connections.append(a, .{ .obj = edit.as(object.Object), .id = gtk.Button.signals.clicked.connect(edit, *Binding, editClicked, binding, .{}) });
            }
            card.append(top.as(gtk.Widget));
            self.profiles.append(card.as(gtk.Widget));
        }
        const help = w.label(@import("i18n").dtr("pearl", "Profiles are the scx scheduler catalog's, shared with scxcli and scxtui. Changes apply to every user of this computer and ask for an administrator password. Choosing a profile does not. Restore defaults returns to the profiles that came with scx."), "pearl-secondary");
        help.setWrap(1);
        self.profiles.append(help.as(gtk.Widget));
    }

    /// The command line a profile runs, as shown in the list.
    fn command(alloc: std.mem.Allocator, profile: p.Profile) ![:0]const u8 {
        if (profile.isDefault()) return @import("i18n").dtr("pearl", "Turns sched_ext schedulers off: the kernel's built-in scheduler runs.");
        const sched = profile.scheduler().?;
        // Translators: A scheduler started without options, such as scx_cosmos.
        if (!profile.custom()) return try @import("i18n").fmtAlloc(alloc, "{s} with its own defaults", .{sched});
        var out: std.Io.Writer.Allocating = .init(alloc);
        try out.writer.writeAll(sched);
        for (profile.args) |arg| try out.writer.print(" {s}", .{arg});
        return out.toOwnedSliceSentinel(0);
    }

    pub fn update(self: *View) void {
        self.updating = true;
        defer self.updating = false;
        const service = self.service;
        const signature = self.listSignature();
        if (signature != self.signature) {
            // Taken as built only once complete; a rebuild that failed part
            // way leaves no rows and is tried again at the next update.
            if (self.rebuild()) |_| {
                self.signature = signature;
            } else |err| {
                log.warn("event=sched-profile-editor result={s}", .{@errorName(err)});
                self.clear();
                self.signature = 0;
            }
        }
        var buffer: [512]u8 = undefined;
        self.status.setText(service.describe(&buffer));
        const usable = service.enabled and service.applying == null and !service.saving and service.status.kind != .unavailable;
        // The editor has no profile choices, only the ids its rows refer to.
        for (self.buttons, self.available, self.stopped, 0..) |button, available, stopped, i| {
            // What runs is the chosen mode; a selection kept while the unit
            // is stopped is not, but says so, and choosing it starts it.
            const mark = service.mark(i);
            const current = mark == .current;
            stopped.as(gtk.Widget).setVisible(@intFromBool(mark == .stopped));
            button.setActive(@intFromBool(current));
            if (current) button.as(gtk.Widget).addCssClass("power-selected") else button.as(gtk.Widget).removeCssClass("power-selected");
            button.as(gtk.Widget).setSensitive(@intFromBool(usable and available));
        }
        const editable = service.editable() and service.enabled and service.applying == null and !service.saving;
        self.edit_button.setLabel(if (self.editing) @import("i18n").dtr("pearl", "Done") else @import("i18n").dtr("pearl", "Edit profiles"));
        self.edit_button.as(gtk.Widget).setVisible(@intFromBool(service.listing != null));
        self.add_button.as(gtk.Widget).setVisible(@intFromBool(self.editing));
        self.add_button.as(gtk.Widget).setSensitive(@intFromBool(editable));
        self.restore_button.as(gtk.Widget).setVisible(@intFromBool(self.editing and service.customized() and service.shipped != null));
        self.restore_button.as(gtk.Widget).setSensitive(@intFromBool(editable));
        self.profiles.as(gtk.Widget).setSensitive(@intFromBool(!self.editing or editable));
        var message: [600]u8 = undefined;
        self.message.setText(if (service.applying != null or service.saving) "" else if (service.err) |err| std.mem.printSentinel(&message, "{s}", .{err}, 0) catch "" else service.describeNotice(&message));
        self.message.as(gtk.Widget).setVisible(@intFromBool(self.message.getText()[0] != 0));
    }

    fn showError(self: *View, text: [:0]const u8) void {
        self.message.setText(text);
        self.message.as(gtk.Widget).setVisible(1);
    }

    fn toggled(button: *gtk.CheckButton, binding: *Binding) callconv(.c) void {
        const self = binding.view;
        // Programmatic updates and the button being unset do not select anything.
        if (self.updating or button.getActive() == 0) return;
        const id = self.ids[binding.index];
        self.service.apply(id) catch |err| {
            log.warn("event=sched-profile-select profile={s} result={s}", .{ id, @errorName(err) });
            self.update();
            self.showError(switch (err) {
                error.Busy => @import("i18n").dtr("pearl", "Another profile is being applied."),
                error.NotInstalled => @import("i18n").dtr("pearl", "This profile's scheduler is not installed."),
                else => @import("i18n").dtr("pearl", "This profile cannot be applied right now."),
            });
            return;
        };
        self.update();
    }

    fn editModeClicked(_: *gtk.Button, self: *View) callconv(.c) void {
        self.editing = !self.editing;
        self.update();
    }

    /// Save a changed list. scxcli asks for a password, and a failure is
    /// reported on the page.
    fn save(self: *View, profiles: []const p.Profile, renamed: ?p.Rename) bool {
        self.service.saveProfiles(profiles, renamed) catch |err| {
            log.warn("event=sched-profile-save result={s}", .{@errorName(err)});
            self.update();
            self.showError(switch (err) {
                error.Busy => @import("i18n").dtr("pearl", "Wait until the profile being applied or saved is done."),
                // Translators: scxcli catalog save reads at most 64 KiB.
                error.CatalogTooLarge => @import("i18n").dtr("pearl", "The profiles do not fit in the scheduler catalog's 64 KiB; remove some or shorten their descriptions."),
                else => @import("i18n").dtr("pearl", "The profiles could not be saved."),
            });
            return false;
        };
        self.update();
        return true;
    }

    fn move(binding: *Binding, offset: isize) void {
        const self = binding.view;
        const listing = self.service.listing orelse return;
        const target = @as(isize, @intCast(binding.index)) + offset;
        // Default stays first.
        if (binding.index == 0 or target < 1 or target >= listing.profiles.len) return;
        var scratch = std.heap.ArenaAllocator.init(a);
        defer scratch.deinit();
        const profiles = scratch.allocator().dupe(p.Profile, listing.profiles) catch return;
        std.mem.swap(p.Profile, &profiles[binding.index], &profiles[@intCast(target)]);
        _ = self.save(profiles, null);
    }

    fn moveUp(_: *gtk.Button, binding: *Binding) callconv(.c) void {
        move(binding, -1);
    }

    fn moveDown(_: *gtk.Button, binding: *Binding) callconv(.c) void {
        move(binding, 1);
    }

    fn editClicked(_: *gtk.Button, binding: *Binding) callconv(.c) void {
        binding.view.openEditor(binding.index) catch |err| log.warn("event=sched-profile-editor result={s}", .{@errorName(err)});
    }

    fn addClicked(_: *gtk.Button, self: *View) callconv(.c) void {
        self.openEditor(null) catch |err| log.warn("event=sched-profile-editor result={s}", .{@errorName(err)});
    }

    fn restoreClicked(_: *gtk.Button, self: *View) callconv(.c) void {
        self.openRestore() catch |err| log.warn("event=sched-profile-editor result={s}", .{@errorName(err)});
    }

    fn parentWindow(self: *View) ?*gtk.Window {
        const root = self.root.as(gtk.Widget).getRoot() orelse return null;
        return object.ext.cast(gtk.Window, root);
    }

    fn closeDialog(self: *View) void {
        if (self.dialog) |*dialog| {
            dialog.window.as(gtk.Window).destroy();
            dialog.window.unref();
            if (dialog.draft) |*draft| draft.deinit();
            dialog.arena.deinit();
        }
        self.dialog = null;
    }

    fn openRestore(self: *View) !void {
        if (self.dialog != null) return;
        const parent = self.parentWindow() orelse return error.NoWindow;
        const shell = builder.open(parent, @import("i18n").dtr("pearl", "Restore default profiles"));
        self.dialog = .{ .window = shell.dialog, .restore = true, .arena = .init(a) };
        const text = w.label(@import("i18n").dtr("pearl", "The administrator's scheduler catalog is removed for every user, and the profiles that came with scx are used again. If the running profile changes, it is applied again. This asks for an administrator password."), null);
        text.setWrap(1);
        shell.body.append(text.as(gtk.Widget));
        _ = shell.dialog.addButton(@import("i18n").dtr("pearl", "Cancel"), @intFromEnum(gtk.ResponseType.cancel));
        _ = shell.dialog.addButton(@import("i18n").dtr("pearl", "Restore defaults"), @intFromEnum(gtk.ResponseType.accept));
        _ = gtk.Dialog.signals.response.connect(shell.dialog, *View, response, self, .{});
        shell.dialog.as(gtk.Window).setDefaultSize(420, 200);
        shell.dialog.as(gtk.Window).present();
    }

    fn openEditor(self: *View, index: ?usize) !void {
        if (self.dialog != null) return;
        const listing = self.service.listing orelse return error.Unavailable;
        const parent = self.parentWindow() orelse return error.NoWindow;
        // The draft has one owner at a time: this scope until the dialog
        // takes it, with nothing that can fail in between, then the dialog,
        // which closeDialog frees.
        const draft = try editor.Draft.open(a, listing, index);
        const shell = builder.open(parent, if (draft.id != null) @import("i18n").dtr("pearl", "Edit scheduler profile") else @import("i18n").dtr("pearl", "Add scheduler profile"));
        self.dialog = .{ .window = shell.dialog, .draft = draft, .arena = .init(a) };
        errdefer self.closeDialog();
        const dialog = &self.dialog.?;
        const alloc = dialog.arena.allocator();
        const data = &dialog.draft.?;
        dialog.name = builder.entryRow(shell.body, @import("i18n").dtr("pearl", "Name"), p.max_label);
        dialog.description = builder.entryRow(shell.body, @import("i18n").dtr("pearl", "Description"), p.max_description);
        dialog.name.?.as(gtk.Editable).setText(try alloc.dupeSentinel(u8, data.label, 0));
        dialog.description.?.as(gtk.Editable).setText(try alloc.dupeSentinel(u8, data.description, 0));
        // The schedulers marked by tier, in the order scx lists them.
        const shown = try alloc.alloc(?[*:0]const u8, data.choices.len + 1);
        for (data.choices, shown[0..data.choices.len]) |choice, *text| text.* = if (choice.tier) |tier| switch (tier) {
            .stable => try alloc.dupeSentinel(u8, choice.name, 0),
            // Translators: A scheduler the scx maintainers do not call stable.
            .experimental => try @import("i18n").fmtAlloc(alloc, "{s} (experimental)", .{choice.name}),
            // Translators: An installed scheduler the scx catalog says nothing about.
            .unknown => try @import("i18n").fmtAlloc(alloc, "{s} (not in the catalog)", .{choice.name}),
        } else try alloc.dupeSentinel(u8, choice.name, 0);
        shown[data.choices.len] = null;
        dialog.scheduler = builder.choiceRow(shell.body, @import("i18n").dtr("pearl", "Scheduler"), shown);
        if (data.selected) |i| dialog.scheduler.?.setSelected(@intCast(i));
        dialog.options = builder.entryRow(shell.body, @import("i18n").dtr("pearl", "Options"), p.max_args * 257);
        dialog.options.?.as(gtk.Editable).setText(try alloc.dupeSentinel(u8, data.options, 0));
        const help = w.label(@import("i18n").dtr("pearl", "Options are passed to the scheduler as typed, separated by spaces, for example --slice-us 1600. Run the scheduler with --help in a terminal to list them. Without options it starts with its own defaults. Saving asks for an administrator password."), "pearl-secondary");
        help.setWrap(1);
        shell.body.append(help.as(gtk.Widget));
        if (data.choices.len == 0) {
            const none = w.label(@import("i18n").dtr("pearl", "No sched_ext schedulers are installed."), "pearl-error");
            none.setWrap(1);
            shell.body.append(none.as(gtk.Widget));
        }
        dialog.err = w.label("", "pearl-error");
        dialog.err.?.setWrap(1);
        // Shown with the first problem; empty, it would still draw its color.
        dialog.err.?.as(gtk.Widget).setVisible(0);
        shell.body.append(dialog.err.?.as(gtk.Widget));
        if (data.id != null) _ = shell.dialog.addButton(@import("i18n").dtr("pearl", "Delete profile"), respond_delete);
        _ = shell.dialog.addButton(@import("i18n").dtr("pearl", "Cancel"), @intFromEnum(gtk.ResponseType.cancel));
        _ = shell.dialog.addButton(@import("i18n").dtr("pearl", "Save"), @intFromEnum(gtk.ResponseType.accept));
        _ = gtk.Dialog.signals.response.connect(shell.dialog, *View, response, self, .{});
        shell.dialog.as(gtk.Window).present();
        _ = dialog.name.?.as(gtk.Widget).grabFocus();
    }

    fn response(_: *gtk.Dialog, code: c_int, self: *View) callconv(.c) void {
        const dialog = if (self.dialog) |*value| value else return;
        if (dialog.restore) {
            self.closeDialog();
            if (code == @intFromEnum(gtk.ResponseType.accept)) self.service.restoreDefaults() catch |err| {
                log.warn("event=sched-profile-restore result={s}", .{@errorName(err)});
                self.showError(@import("i18n").dtr("pearl", "The default profiles could not be restored."));
            };
            self.update();
            return;
        }
        if (code == @intFromEnum(gtk.ResponseType.accept) or code == respond_delete) {
            const problem = self.commit(dialog, code == respond_delete) catch |err| switch (err) {
                error.InvalidArgument => @import("i18n").dtr("pearl", "Options may contain only letters, digits and - _ = . , : / +, separated by spaces, at most 256 characters each."),
                error.TooManyArguments => @import("i18n").dtr("pearl", "A profile takes at most 32 options."),
                error.InvalidName => @import("i18n").dtr("pearl", "Enter a name of at most 64 characters."),
                error.InvalidDescription => @import("i18n").dtr("pearl", "Enter a description of at most 256 characters."),
                error.NoScheduler => @import("i18n").dtr("pearl", "Choose a scheduler."),
                error.CatalogChanged => @import("i18n").dtr("pearl", "The profiles were changed elsewhere while this dialog was open. Nothing was saved; close it and edit the profile again."),
                else => @import("i18n").dtr("pearl", "The profiles could not be saved."),
            };
            if (problem) |text| {
                dialog.err.?.setText(text);
                dialog.err.?.as(gtk.Widget).setVisible(1);
                return;
            }
        }
        self.closeDialog();
        self.update();
    }

    /// Apply the dialog to the listing current now and save it. Returns a
    /// message for the dialog when saving failed.
    fn commit(self: *View, dialog: *Dialog, delete: bool) !?[:0]const u8 {
        const listing = self.service.listing orelse return error.Unavailable;
        const draft = &(dialog.draft orelse return error.Unavailable);
        var scratch = std.heap.ArenaAllocator.init(a);
        defer scratch.deinit();
        const input: ?editor.Input = if (delete) null else .{
            .label = std.mem.span(dialog.name.?.as(gtk.Editable).getText()),
            .description = std.mem.span(dialog.description.?.as(gtk.Editable).getText()),
            .scheduler = dialog.scheduler.?.getSelected(),
            .options = std.mem.span(dialog.options.?.as(gtk.Editable).getText()),
        };
        const edit = draft.commit(scratch.allocator(), listing, input) catch |err| switch (err) {
            error.InvalidArgument, error.TooManyArguments, error.InvalidName, error.InvalidDescription, error.NoScheduler, error.CatalogChanged => return err,
            else => {
                log.warn("event=sched-profile-editor result={s}", .{@errorName(err)});
                return @import("i18n").dtr("pearl", "The profiles could not be saved.");
            },
        };
        // Saving renders and copies the list before it returns.
        if (!self.save(edit.profiles, edit.renamed)) return @import("i18n").dtr("pearl", "The profiles could not be saved.");
        return null;
    }
};
