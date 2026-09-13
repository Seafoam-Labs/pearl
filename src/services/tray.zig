//! StatusNotifier watcher/host and bounded DBusMenu trees. All client calls target unique owners.
const std = @import("std");
const transport = @import("session_bus.zig");
const db = transport.db;
const gio = db.gio;
const glib = db.glib;
const pixbuf = @import("gdkpixbuf2");
const Text = db.Text;
const watcher_name = "org.kde.StatusNotifierWatcher";
const watcher_path = "/StatusNotifierWatcher";
const item_iface = "org.kde.StatusNotifierItem";
const menu_iface = "com.canonical.dbusmenu";
pub const Node = struct {
    id: i32 = 0, parent: i32 = -1, label: Text(256) = .{}, enabled: bool = true, visible: bool = true,
    separator: bool = false, submenu: bool = false, toggle: bool = false, checked: bool = false,
};
pub const Item = struct {
    name: Text(256) = .{}, owner: Text(256) = .{}, path: Text(512) = .{}, registration: Text(768) = .{}, generation: u64 = 0,
    title: Text(512) = .{}, tooltip: Text(512) = .{}, icon: Text(512) = .{}, status: Text(512) = .{}, menu: Text(512) = .{}, is_menu: bool = false,
    image: ?*pixbuf.Pixbuf = null, ready: bool = false, loading: bool = false, dirty: bool = false,
    menu_loading: bool = false, menu_dirty: bool = false, menu_ready: bool = false, menu_revision: u64 = 0,
    nodes: [128]Node = @splat(.{}), node_count: usize = 0,
};
pub const Tray = struct {
    bus: *transport.Bus, context: *anyopaque, changed: *const fn (*anyopaque) void,
    items: [32]Item = @splat(.{}), generation: u64 = 0, revision: u64 = 0, selected: u64 = 0,
    exported: db.Export = .{}, name_id: c_uint = 0, watcher: bool = false, external: Text(256) = .{}, external_epoch: u64 = 0,
    timer: c_uint = 0, err: ?[]const u8 = null,
    pub fn start(self: *Tray) void {
        if (self.exported.startConnection(self.bus.conn orelse return, watcher_path, @embedFile("tray_watcher.xml"), &vtable, self)) self.name_id = gio.busOwnNameOnConnection(self.bus.conn.?, watcher_name, .{}, acquired, lost, self, null);
        self.external_epoch += 1;
        transport.resolve(self.bus, self, self.external_epoch, watcher_name, resolvedWatcher) catch {};
    }
    pub fn stop(self: *Tray) void {
        if (self.timer != 0) _ = glib.Source.remove(self.timer);
        self.timer = 0;
        if (self.name_id != 0) gio.busUnownName(self.name_id);
        self.name_id = 0; self.watcher = false; self.external = .{}; self.external_epoch += 1;
        self.exported.stop();
        for (&self.items) |*item| self.remove(item);
        self.notify();
    }
    fn notify(self: *Tray) void { self.revision += 1; self.changed(self.context); }
    fn remove(self: *Tray, item: *Item) void {
        if (item.image) |image| image.unref();
        if (item.ready and self.watcher) self.bus.emit(null, watcher_path, watcher_name, "StatusNotifierItemUnregistered", db.tuple(&.{db.str(item.registration.z())}));
        item.* = .{};
    }
    fn acquired(_: *gio.DBusConnection, _: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
        const self: *Tray = @ptrCast(@alignCast(data.?));
        self.watcher = true; self.external = .{}; self.external_epoch += 1;
        self.bus.emit(null, watcher_path, watcher_name, "StatusNotifierHostRegistered", db.tuple(&.{})); self.notify();
    }
    fn lost(_: *gio.DBusConnection, _: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
        const self: *Tray = @ptrCast(@alignCast(data.?));
        self.watcher = false; self.notify();
        self.external_epoch += 1;
        transport.resolve(self.bus, self, self.external_epoch, watcher_name, resolvedWatcher) catch {};
    }
    fn resolvedWatcher(data: *anyopaque, token: u64, value: ?*glib.Variant) void {
        const self: *Tray = @ptrCast(@alignCast(data));
        if (token != self.external_epoch or self.watcher) return;
        const v = value orelse return;
        self.external = transport.childText(256, v, 0);
        const unique = self.bus.conn.?.getUniqueName() orelse return;
        if (std.mem.eql(u8, self.external.slice(), std.mem.span(unique))) return;
        self.bus.call(self, token, self.external.z(), watcher_path, watcher_name, "RegisterStatusNotifierHost", db.tuple(&.{db.str(std.mem.span(unique))}), "()", hostDone) catch {};
        transport.getAll(self.bus, self, token, self.external.z(), watcher_path, watcher_name, watcherProperties) catch {};
    }
    fn hostDone(data: *anyopaque, token: u64, value: ?*glib.Variant) void {
        const self: *Tray = @ptrCast(@alignCast(data));
        if (token != self.external_epoch) return;
        self.err = if (value == null) "Could not register with the existing tray watcher." else null; self.notify();
    }
    fn watcherProperties(data: *anyopaque, token: u64, value: ?*glib.Variant) void {
        const self: *Tray = @ptrCast(@alignCast(data));
        if (token != self.external_epoch or self.watcher) return;
        const v = value orelse return;
        if (v.getSize() > 64 * 1024) return;
        const props = v.getChildValue(0); defer props.unref();
        const entries = db.lookup(props, "RegisteredStatusNotifierItems", "as") orelse return; defer entries.unref();
        for (0..@min(32, entries.nChildren())) |i| { const registration = transport.childText(768, entries, i); self.register(registration.slice(), null) catch {}; }
    }
    pub fn find(self: *Tray, generation: u64) ?*Item {
        if (generation == 0) return null;
        for (&self.items) |*item| if (item.generation == generation and item.name.len != 0) return item;
        return null;
    }
    fn register(self: *Tray, registration: []const u8, sender: ?[]const u8) !void {
        if (registration.len == 0 or registration.len > 767) return error.InvalidValue;
        var bus_name: Text(256) = .{}; var object_path: Text(512) = .{};
        if (registration[0] == '/') { bus_name.set(sender orelse return error.InvalidValue); object_path.set(registration); } else {
            const split = std.mem.indexOfScalar(u8, registration, '/') orelse registration.len;
            if (split > 255 or registration.len - split > 511) return error.InvalidValue;
            bus_name.set(registration[0..split]); object_path.set(if (split == registration.len) "/StatusNotifierItem" else registration[split..]);
        }
        if (gio.dbusIsName(bus_name.z()) == 0 or glib.Variant.isObjectPath(object_path.z()) == 0) return error.InvalidValue;
        for (&self.items) |*item| if (std.mem.eql(u8, item.name.slice(), bus_name.slice()) and std.mem.eql(u8, item.path.slice(), object_path.slice())) return;
        for (&self.items) |*item| if (item.name.len == 0) {
            self.generation += 1;
            item.* = .{ .name = bus_name, .path = object_path, .generation = self.generation };
            var buf: [768]u8 = undefined; item.registration.set(std.fmt.bufPrint(&buf, "{s}{s}", .{bus_name.slice(), object_path.slice()}) catch unreachable);
            transport.resolve(self.bus, self, item.generation, bus_name.z(), resolvedItem) catch |err| { item.* = .{}; return err; };
            return;
        };
        return error.Limit;
    }
    fn resolvedItem(data: *anyopaque, token: u64, value: ?*glib.Variant) void {
        const self: *Tray = @ptrCast(@alignCast(data));
        const item = self.find(token) orelse return;
        const v = value orelse { self.remove(item); self.notify(); return; };
        item.owner = transport.childText(256, v, 0); item.dirty = true; self.arm();
    }
    pub fn ownerChanged(self: *Tray, name: [:0]const u8, new: []const u8) void {
        if (std.mem.eql(u8, name, watcher_name)) {
            self.external = .{}; self.external_epoch += 1;
            if (!self.watcher) { for (&self.items) |*item| self.remove(item); }
            if (new.len != 0) transport.resolve(self.bus, self, self.external_epoch, watcher_name, resolvedWatcher) catch {};
        }
        for (&self.items) |*item| if (std.mem.eql(u8, item.name.slice(), name) or std.mem.eql(u8, item.owner.slice(), name)) { self.remove(item); };
        self.notify();
    }
    pub fn signal(self: *Tray, sender: []const u8, object_path: []const u8, interface: []const u8, member: []const u8, params: *glib.Variant) void {
        if (self.external.len != 0 and std.mem.eql(u8, sender, self.external.slice()) and std.mem.eql(u8, interface, watcher_name) and std.mem.eql(u8, object_path, watcher_path) and db.is(params, "(s)")) {
            const registration = transport.childText(768, params, 0);
            if (std.mem.eql(u8, member, "StatusNotifierItemRegistered")) self.register(registration.slice(), null) catch {} else if (std.mem.eql(u8, member, "StatusNotifierItemUnregistered")) {
                for (&self.items) |*item| if (std.mem.eql(u8, item.registration.slice(), registration.slice())) self.remove(item);
                self.notify();
            }
            return;
        }
        for (&self.items) |*item| if (item.owner.len != 0 and std.mem.eql(u8, item.owner.slice(), sender)) {
            if (std.mem.eql(u8, item.path.slice(), object_path) and (std.mem.eql(u8, interface, item_iface) or std.mem.eql(u8, interface, "org.freedesktop.DBus.Properties"))) { item.dirty = true; self.arm(); }
            if (std.mem.eql(u8, item.menu.slice(), object_path) and std.mem.eql(u8, interface, menu_iface) and (std.mem.eql(u8, member, "LayoutUpdated") or std.mem.eql(u8, member, "ItemsPropertiesUpdated"))) {
                item.menu_ready = false; item.menu_revision += 1; item.menu_dirty = true; self.arm(); self.notify();
            }
        };
    }
    fn arm(self: *Tray) void { if (self.timer == 0) self.timer = glib.timeoutAdd(100, tick, self); }
    fn tick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Tray = @ptrCast(@alignCast(data.?)); self.timer = 0;
        for (&self.items) |*item| {
            if (item.dirty and !item.loading and item.owner.len != 0) {
                item.dirty = false; item.loading = true;
                transport.getAll(self.bus, self, item.generation, item.owner.z(), item.path.z(), item_iface, properties) catch { item.loading = false; };
            }
            if (item.menu_dirty and !item.menu_loading and item.menu.len != 0 and self.selected == item.generation) self.fetchMenu(item);
        }
        return 0;
    }
    fn properties(data: *anyopaque, token: u64, value: ?*glib.Variant) void {
        const self: *Tray = @ptrCast(@alignCast(data)); const item = self.find(token) orelse return;
        item.loading = false;
        const v = value orelse { item.ready = false; self.notify(); return; };
        if (v.getSize() > 1024 * 1024) { item.ready = false; self.notify(); return; }
        const props = v.getChildValue(0); defer props.unref();
        item.title = db.string(props, "Title", "s"); item.status = db.string(props, "Status", "s");
        item.icon = db.string(props, if (std.mem.eql(u8, item.status.slice(), "NeedsAttention")) "AttentionIconName" else "IconName", "s");
        for (item.icon.slice()) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) { item.icon = .{}; break; };
        item.tooltip = item.title;
        if (db.lookup(props, "ToolTip", "(sa(iiay)ss)")) |tip| { defer tip.unref(); const text = transport.childText(512, tip, 2); if (text.len != 0) item.tooltip = text; }
        const old_menu = item.menu;
        item.menu = db.string(props, "Menu", "o"); item.is_menu = db.boolean(props, "ItemIsMenu");
        if (!std.mem.eql(u8, old_menu.slice(), item.menu.slice())) { item.node_count = 0; item.menu_ready = false; item.menu_revision += 1; }
        if (item.image) |image| image.unref(); item.image = null;
        if (db.lookup(props, if (std.mem.eql(u8, item.status.slice(), "NeedsAttention")) "AttentionIconPixmap" else "IconPixmap", "a(iiay)")) |images| { defer images.unref(); item.image = decodePixmap(images); }
        if (!item.ready and self.watcher) self.bus.emit(null, watcher_path, watcher_name, "StatusNotifierItemRegistered", db.tuple(&.{db.str(item.registration.z())}));
        item.ready = true; self.notify(); if (item.dirty) self.arm();
    }
    pub fn activate(self: *Tray, generation: u64, secondary: bool) !void {
        const item = self.find(generation) orelse return error.InvalidValue;
        if (!item.ready) return error.Unavailable;
        try self.bus.call(self, generation, item.owner.z(), item.path.z(), item_iface, if (secondary) "SecondaryActivate" else "Activate", db.tuple(&.{glib.Variant.newInt32(0), glib.Variant.newInt32(0)}), "()", actionDone);
    }
    pub fn openMenu(self: *Tray, generation: u64, parent: i32) !void {
        const item = self.find(generation) orelse return error.InvalidValue;
        if (!item.ready or item.menu.len == 0 or std.mem.eql(u8, item.menu.slice(), "/NO_DBUSMENU")) return error.Unsupported;
        self.selected = generation;
        try self.bus.call(self, generation, item.owner.z(), item.menu.z(), menu_iface, "AboutToShow", db.tuple(&.{glib.Variant.newInt32(parent)}), "(b)", aboutDone);
        self.notify();
    }
    fn aboutDone(data: *anyopaque, token: u64, _: ?*glib.Variant) void {
        const self: *Tray = @ptrCast(@alignCast(data)); const item = self.find(token) orelse return;
        item.menu_dirty = true; self.arm();
    }
    fn fetchMenu(self: *Tray, item: *Item) void {
        item.menu_loading = true; item.menu_dirty = false;
        self.bus.call(self, item.generation, item.owner.z(), item.menu.z(), menu_iface, "GetLayout", db.tuple(&.{glib.Variant.newInt32(0), glib.Variant.newInt32(8), db.array("s", &.{})}), "(u(ia{sv}av))", menuDone) catch { item.menu_loading = false; };
    }
    fn menuDone(data: *anyopaque, token: u64, value: ?*glib.Variant) void {
        const self: *Tray = @ptrCast(@alignCast(data)); const item = self.find(token) orelse return;
        item.menu_loading = false; item.menu_ready = false; item.node_count = 0; item.menu_revision += 1;
        if (value) |v| if (v.getSize() <= 256 * 1024) {
            const layout = v.getChildValue(1); defer layout.unref();
            parseNode(item, layout, -1, 0) catch { item.node_count = 0; self.notify(); return; };
            item.menu_ready = true;
        };
        self.notify(); if (item.menu_dirty) self.arm();
    }
    pub fn menuClick(self: *Tray, generation: u64, revision: u64, id: i32) !void {
        const item = self.find(generation) orelse return error.InvalidValue;
        if (!item.menu_ready or item.menu_revision != revision) return error.InvalidValue;
        for (item.nodes[0..item.node_count]) |node| if (node.id == id and node.enabled and node.visible and !node.separator and !node.submenu and node.parent != -1) {
            try self.bus.call(self, generation, item.owner.z(), item.menu.z(), menu_iface, "Event", db.tuple(&.{glib.Variant.newInt32(id), db.str("clicked"), glib.Variant.newVariant(glib.Variant.newInt32(0)), glib.Variant.newUint32(@truncate(@as(u64, @intCast(@divTrunc(glib.getMonotonicTime(), 1000)))))}), "()", actionDone);
            return;
        };
        return error.InvalidValue;
    }
    fn actionDone(data: *anyopaque, _: u64, value: ?*glib.Variant) void {
        const self: *Tray = @ptrCast(@alignCast(data)); self.err = if (value == null) "The tray item did not accept the action." else null; self.notify();
    }
    const vtable: gio.DBusInterfaceVTable = .{ .f_method_call = method, .f_get_property = property, .f_set_property = null, .f_padding = @splat(undefined) };
    fn method(_: *gio.DBusConnection, sender: ?[*:0]const u8, _: [*:0]const u8, _: ?[*:0]const u8, member: [*:0]const u8, params: *glib.Variant, invocation: *gio.DBusMethodInvocation, data: ?*anyopaque) callconv(.c) void {
        const self: *Tray = @ptrCast(@alignCast(data.?));
        if (!self.watcher) { invocation.returnDbusError("org.freedesktop.DBus.Error.NotSupported", "Another watcher owns the name."); return; }
        if (params.getSize() > 1024) { invocation.returnDbusError("org.freedesktop.DBus.Error.LimitsExceeded", "Registration too long."); return; }
        const service = transport.childText(768, params, 0);
        if (std.mem.eql(u8, std.mem.span(member), "RegisterStatusNotifierItem")) {
            self.register(service.slice(), if (sender) |s| std.mem.span(s) else null) catch { invocation.returnDbusError("org.freedesktop.DBus.Error.InvalidArgs", "Invalid registration or item limit reached."); return; };
        } else if (std.mem.eql(u8, std.mem.span(member), "RegisterStatusNotifierHost")) {
            if (gio.dbusIsName(service.z()) == 0) { invocation.returnDbusError("org.freedesktop.DBus.Error.InvalidArgs", "Invalid host name."); return; }
        } else { invocation.returnDbusError("org.freedesktop.DBus.Error.UnknownMethod", "Unknown method."); return; }
        invocation.returnValue(null);
    }
    fn property(_: *gio.DBusConnection, _: ?[*:0]const u8, _: [*:0]const u8, _: [*:0]const u8, prop: [*:0]const u8, _: **glib.Error, data: ?*anyopaque) callconv(.c) ?*glib.Variant {
        const self: *Tray = @ptrCast(@alignCast(data.?)); const key = std.mem.span(prop);
        if (std.mem.eql(u8, key, "ProtocolVersion")) return glib.Variant.newInt32(0);
        if (std.mem.eql(u8, key, "IsStatusNotifierHostRegistered")) return glib.Variant.newBoolean(@intFromBool(self.watcher));
        if (std.mem.eql(u8, key, "RegisteredStatusNotifierItems")) {
            var values: [32]*glib.Variant = undefined; var n: usize = 0;
            for (&self.items) |*item| if (item.ready) { values[n] = db.str(item.registration.z()); n += 1; };
            return db.array("s", values[0..n]);
        }
        return null;
    }
};
fn optionalBool(props: *glib.Variant, key: [:0]const u8, default: bool) bool {
    const v = db.lookup(props, key, "b") orelse return default; defer v.unref(); return v.getBoolean() != 0;
}
fn parseNode(item: *Item, value: *glib.Variant, parent: i32, depth: usize) !void {
    if (depth > 8 or item.node_count >= item.nodes.len or !db.is(value, "(ia{sv}av)")) return error.InvalidMenu;
    const id = value.getChildValue(0); defer id.unref();
    for (item.nodes[0..item.node_count]) |n| if (n.id == id.getInt32()) return error.InvalidMenu;
    const props = value.getChildValue(1); defer props.unref();
    var node: Node = .{ .id = id.getInt32(), .parent = parent, .enabled = optionalBool(props, "enabled", true), .visible = optionalBool(props, "visible", true) };
    const label = db.string(props, "label", "s"); node.label = @import("notification_policy.zig").sanitize(256, label.slice());
    const kind = db.string(props, "type", "s"); node.separator = std.mem.eql(u8, kind.slice(), "separator");
    const display = db.string(props, "children-display", "s"); node.submenu = std.mem.eql(u8, display.slice(), "submenu");
    const toggle = db.string(props, "toggle-type", "s"); node.toggle = toggle.len != 0;
    if (db.lookup(props, "toggle-state", "i")) |v| { defer v.unref(); node.checked = v.getInt32() == 1; }
    item.nodes[item.node_count] = node; item.node_count += 1;
    const children = value.getChildValue(2); defer children.unref();
    if (children.nChildren() > 128) return error.InvalidMenu;
    for (0..children.nChildren()) |i| {
        const wrapped = children.getChildValue(i); defer wrapped.unref();
        const child = wrapped.getVariant(); defer child.unref();
        try parseNode(item, child, node.id, depth + 1);
    }
}
fn decodePixmap(images: *glib.Variant) ?*pixbuf.Pixbuf {
    var chosen: ?*glib.Variant = null; defer if (chosen) |v| v.unref();
    var best: i32 = std.math.maxInt(i32);
    for (0..@min(images.nChildren(), 16)) |i| {
        const v = images.getChildValue(i);
        const w = v.getChildValue(0); defer w.unref(); const h = v.getChildValue(1); defer h.unref();
        const width = w.getInt32(); const height = h.getInt32();
        if (width < 1 or height < 1 or width > 256 or height > 256) { v.unref(); continue; }
        const distance = @abs(width - 32) + @abs(height - 32);
        if (distance < best) { if (chosen) |old| old.unref(); chosen = v; best = @intCast(distance); } else v.unref();
    }
    const v = chosen orelse return null;
    const w = v.getChildValue(0); defer w.unref(); const h = v.getChildValue(1); defer h.unref(); const raw = v.getChildValue(2); defer raw.unref();
    const width = w.getInt32(); const height = h.getInt32();
    var count: usize = 0; const data: [*]const u8 = @ptrCast(raw.getFixedArray(&count, 1));
    if (count != @as(usize, @intCast(width * height * 4))) return null;
    const rgba = std.heap.c_allocator.alloc(u8, count) catch return null; defer std.heap.c_allocator.free(rgba);
    var i: usize = 0; while (i < count) : (i += 4) { rgba[i] = data[i + 1]; rgba[i + 1] = data[i + 2]; rgba[i + 2] = data[i + 3]; rgba[i + 3] = data[i]; }
    const bytes = glib.Bytes.new(rgba.ptr, rgba.len); defer bytes.unref();
    return pixbuf.Pixbuf.newFromBytes(bytes, .rgb, 1, 8, width, height, width * 4);
}
