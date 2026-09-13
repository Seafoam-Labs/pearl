const std = @import("std");
const gtk = @import("gtk4");
const w = @import("../ui/components/widgets.zig");
const service = @import("../services/tray.zig");
const a = std.heap.c_allocator;
const Button = struct { bar: *Bar, generation: u64 = 0, widget: *gtk.Button, image: *gtk.Image };
pub const Bar = struct {
    service: *service.Tray,
    context: *anyopaque,
    open: *const fn (*anyopaque) void,
    rows: [32]Button = undefined,
    overflow: *gtk.Button,
    limit: usize = 4,
    revision: u64 = std.math.maxInt(u64),
    pub fn create(host: *gtk.Box, tray: *service.Tray, context: *anyopaque, open: @FieldType(Bar, "open")) !*Bar {
        const self = try a.create(Bar);
        self.* = .{ .service = tray, .context = context, .open = open, .overflow = gtk.Button.newWithLabel("⋯") };
        for (&self.rows) |*row| {
            const button = gtk.Button.new();
            const image = w.icon("pearl-application-x-executable-symbolic");
            button.setChild(image.as(gtk.Widget));
            button.as(gtk.Widget).addCssClass("pearl-bar-item");
            row.* = .{ .bar = self, .widget = button, .image = image };
            _ = gtk.Button.signals.clicked.connect(button, *Button, activated, row, .{});
            const click = gtk.GestureClick.new();
            click.as(gtk.GestureSingle).setButton(3);
            _ = gtk.GestureClick.signals.pressed.connect(click, *Button, menu, row, .{});
            button.as(gtk.Widget).addController(click.as(gtk.EventController));
            const middle = gtk.GestureClick.new();
            middle.as(gtk.GestureSingle).setButton(2);
            _ = gtk.GestureClick.signals.pressed.connect(middle, *Button, secondary, row, .{});
            button.as(gtk.Widget).addController(middle.as(gtk.EventController));
            const scroll = gtk.EventControllerScroll.new(.{ .vertical = true, .horizontal = true, .discrete = true });
            _ = gtk.EventControllerScroll.signals.scroll.connect(scroll, *Button, scrolled, row, .{});
            button.as(gtk.Widget).addController(scroll.as(gtk.EventController));
            host.append(button.as(gtk.Widget));
            button.as(gtk.Widget).setVisible(0);
        }
        host.append(self.overflow.as(gtk.Widget));
        w.name(self.overflow.as(gtk.Widget), "More tray items");
        _ = gtk.Button.signals.clicked.connect(self.overflow, *Bar, overflowClicked, self, .{});
        self.update();
        return self;
    }
    pub fn setLimit(self: *Bar, limit: usize) void {
        if (self.limit == limit) return;
        self.limit = limit;
        self.revision = std.math.maxInt(u64);
        self.update();
    }
    fn overflowClicked(_: *gtk.Button, self: *Bar) callconv(.c) void {
        self.service.selected = 0;
        self.open(self.context);
    }
    pub fn destroy(self: *Bar) void {
        a.destroy(self);
    }
    pub fn update(self: *Bar) void {
        if (self.revision == self.service.revision) return;
        self.revision = self.service.revision;
        var active: usize = 0;
        for (&self.rows, &self.service.items) |*row, *item| {
            const eligible = item.ready and !std.mem.eql(u8, item.status.slice(), "Passive");
            const visible = eligible and active < self.limit;
            if (eligible) active += 1;
            row.widget.as(gtk.Widget).setVisible(@intFromBool(visible));
            row.generation = item.generation;
            if (!visible) continue;
            if (item.icon.len != 0) row.image.setFromIconName(item.icon.z()) else if (item.image) |image| row.image.setFromPixbuf(image) else row.image.setFromIconName("pearl-application-x-executable-symbolic");
            row.image.setPixelSize(20);
            row.widget.as(gtk.Widget).setTooltipText(item.tooltip.z());
            w.name(row.widget.as(gtk.Widget), item.title.z());
            if (std.mem.eql(u8, item.status.slice(), "NeedsAttention")) row.widget.as(gtk.Widget).addCssClass("pearl-selected") else row.widget.as(gtk.Widget).removeCssClass("pearl-selected");
        }
        self.overflow.as(gtk.Widget).setVisible(@intFromBool(active > self.limit));
    }
    fn activated(_: *gtk.Button, row: *Button) callconv(.c) void {
        const item = row.bar.service.find(row.generation) orelse return;
        if (item.is_menu) openMenu(row) else row.bar.service.activate(row.generation, false) catch {};
    }
    fn openMenu(row: *Button) void {
        row.bar.service.openMenu(row.generation, 0) catch {
            row.bar.service.contextMenu(row.generation) catch {};
            return;
        };
        row.bar.open(row.bar.context);
    }
    fn menu(_: *gtk.GestureClick, _: c_int, _: f64, _: f64, row: *Button) callconv(.c) void {
        openMenu(row);
    }
    fn secondary(_: *gtk.GestureClick, _: c_int, _: f64, _: f64, row: *Button) callconv(.c) void {
        row.bar.service.activate(row.generation, true) catch {};
    }
    fn scrolled(_: *gtk.EventControllerScroll, dx: f64, dy: f64, row: *Button) callconv(.c) c_int {
        row.bar.service.scroll(row.generation, @intFromFloat(@max(-1200, @min(1200, (if (@abs(dy) > @abs(dx)) dy else dx) * -120))), @abs(dy) > @abs(dx)) catch {};
        return 1;
    }
};
const Choice = struct { view: *View, widget: *gtk.Button, id: i32 = 0, generation: u64 = 0, revision: u64 = 0, submenu: bool = false };
pub const View = struct {
    probe_focus: ?*gtk.Widget = null,
    service: *service.Tray,
    title: *gtk.Label,
    state: *gtk.Label,
    back: *gtk.Button,
    choices: [32]Choice = undefined,
    nodes: [128]Choice = undefined,
    parent: i32 = 0,
    generation: u64 = 0,
    revision: u64 = std.math.maxInt(u64),
    pub fn create(host: *gtk.Box, tray: *service.Tray) !*View {
        const self = try a.create(View);
        const title = w.label("System tray", "pearl-card-title");
        host.append(title.as(gtk.Widget));
        const state = w.label("", "pearl-secondary");
        host.append(state.as(gtk.Widget));
        const back = gtk.Button.newWithLabel("Back");
        host.append(back.as(gtk.Widget));
        self.* = .{ .service = tray, .title = title, .state = state, .back = back };
        _ = gtk.Button.signals.clicked.connect(back, *View, goBack, self, .{});
        const scroll = gtk.ScrolledWindow.new();
        scroll.setPolicy(.never, .automatic);
        scroll.as(gtk.Widget).setVexpand(1);
        const content = w.column(6);
        scroll.setChild(content.as(gtk.Widget));
        host.append(scroll.as(gtk.Widget));
        for (&self.choices) |*choice| {
            const button = gtk.Button.newWithLabel("");
            choice.* = .{ .view = self, .widget = button };
            if (@import("gobject2").ext.cast(gtk.Label, button.getChild().?)) |label| {
                label.setEllipsize(.end);
                label.setMaxWidthChars(32);
            }
            _ = gtk.Button.signals.clicked.connect(button, *Choice, choose, choice, .{});
            content.append(button.as(gtk.Widget));
        }
        for (&self.nodes) |*node| {
            const button = gtk.Button.newWithLabel("");
            node.* = .{ .view = self, .widget = button };
            if (@import("gobject2").ext.cast(gtk.Label, button.getChild().?)) |label| {
                label.setEllipsize(.end);
                label.setMaxWidthChars(32);
            }
            _ = gtk.Button.signals.clicked.connect(button, *Choice, clickNode, node, .{});
            content.append(button.as(gtk.Widget));
        }
        self.update();
        return self;
    }
    pub fn probe(self: *View, window: *gtk.Window) void {
        const focus = window.getFocus();
        if (focus == self.probe_focus) return;
        self.probe_focus = focus;
        for (&self.nodes) |*node| if (focus == node.widget.as(gtk.Widget)) {
            std.log.info("event=session-focus target=tray-{d}", .{node.id});
            return;
        };
        std.log.info("event=session-focus target=other", .{});
    }
    pub fn destroy(self: *View) void {
        self.service.selected = 0;
        a.destroy(self);
    }
    pub fn update(self: *View) void {
        if (self.revision == self.service.revision and self.generation == self.service.selected) return;
        self.revision = self.service.revision;
        if (self.generation != self.service.selected) {
            self.generation = self.service.selected;
            self.parent = 0;
        }
        const selected = self.service.find(self.generation);
        self.title.setText(if (selected) |item| item.title.z() else "System tray");
        self.state.setText(if (self.service.err) |err| blk: {
            var text: @import("../services/policy.zig").Text(512) = .{};
            text.set(err);
            self.state.setText(text.z());
            break :blk self.state.getText();
        } else if (selected) |item| (if (item.menu_error) "Menu unavailable. Go back and reopen to retry." else if (!item.menu_ready) "Loading menu…" else "") else "Choose a tray item");
        self.back.as(gtk.Widget).setVisible(@intFromBool(selected != null));
        for (&self.choices, &self.service.items) |*choice, *item| {
            choice.generation = item.generation;
            choice.widget.setLabel(item.title.z());
            choice.widget.as(gtk.Widget).setVisible(@intFromBool(selected == null and item.ready));
        }
        for (&self.nodes, 0..) |*choice, i| {
            const visible = if (selected) |item| item.menu_ready and i < item.node_count and item.nodes[i].parent == self.parent and item.nodes[i].visible else false;
            choice.widget.as(gtk.Widget).setVisible(@intFromBool(visible));
            if (!visible) continue;
            const item = selected.?;
            const node = &item.nodes[i];
            choice.id = node.id;
            choice.generation = item.generation;
            choice.revision = item.menu_revision;
            choice.submenu = node.submenu;
            var buffer: [320]u8 = undefined;
            choice.widget.setLabel(std.fmt.bufPrintZ(&buffer, "{s}{s}{s}", .{ if (node.separator) "────────" else if (node.toggle) (if (node.checked) "✓  " else "○  ") else "", node.label.slice(), if (node.submenu) "  ›" else "" }) catch "");
            choice.widget.as(gtk.Widget).setSensitive(@intFromBool(node.enabled and !node.separator));
        }
    }
    fn choose(_: *gtk.Button, choice: *Choice) callconv(.c) void {
        choice.view.service.openMenu(choice.generation, 0) catch {};
    }
    fn clickNode(_: *gtk.Button, choice: *Choice) callconv(.c) void {
        const self = choice.view;
        if (choice.submenu) {
            self.parent = choice.id;
            self.revision = std.math.maxInt(u64);
            self.service.openMenu(choice.generation, choice.id) catch {};
            self.update();
        } else self.service.menuClick(choice.generation, choice.revision, choice.id) catch {};
    }
    fn goBack(_: *gtk.Button, self: *View) callconv(.c) void {
        if (self.parent == 0) {
            self.service.selected = 0;
        } else if (self.service.find(self.generation)) |item| {
            for (item.nodes[0..item.node_count]) |node| if (node.id == self.parent) {
                self.parent = @max(0, node.parent);
                break;
            };
        }
        self.revision = std.math.maxInt(u64);
        self.update();
    }
};
