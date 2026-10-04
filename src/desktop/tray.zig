const std = @import("std");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const w = @import("../ui/components/widgets.zig");
const service = @import("../services/tray.zig");
const log = std.log.scoped(.desktop);
const a = std.heap.c_allocator;
/// Use a named icon only when the current display's theme can resolve it.
fn updateIcon(image: *gtk.Image, item: *const service.Item) void {
    const theme = gtk.IconTheme.getForDisplay(image.as(gtk.Widget).getDisplay());
    if (item.icon.len != 0 and theme.hasIcon(item.icon.z()) != 0) {
        image.setFromIconName(item.icon.z());
    } else if (item.image) |pixmap| {
        image.setFromPixbuf(pixmap);
    } else {
        image.setFromIconName("pearl-application-x-executable-symbolic");
    }
    image.setPixelSize(20);
}
fn itemName(item: *const service.Item) [:0]const u8 {
    if (item.title.len != 0) return item.title.z();
    if (item.tooltip_title.len != 0) return item.tooltip_title.z();
    if (item.id.len != 0) return item.id.z();
    return "Tray application";
}
fn describeItem(button: *gtk.Button, item: *const service.Item) void {
    button.as(gtk.Widget).setTooltipText(if (item.tooltip.len != 0) item.tooltip.z() else itemName(item));
    w.name(button.as(gtk.Widget), itemName(item));
}
const Button = struct { bar: *Bar, generation: u64 = 0, widget: *gtk.Button, image: *gtk.Image };
pub const Bar = struct {
    service: *service.Tray,
    context: *anyopaque,
    open: *const fn (*anyopaque, *gtk.Widget) void,
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
            button.as(gtk.Widget).addCssClass("pearl-tray-icon");
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
        self.service.showChooser();
        self.open(self.context, self.overflow.as(gtk.Widget));
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
            updateIcon(row.image, item);
            describeItem(row.widget, item);
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
        row.bar.open(row.bar.context, row.widget.as(gtk.Widget));
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
const ItemChoice = struct { view: *View, button: *gtk.Button, image: *gtk.Image, generation: u64 = 0 };
const Row = struct { button: *gtk.Button, label: *gtk.Label, check: *gtk.Image, arrow: *gtk.Label };
const Choice = struct { view: *View, row: Row, separator: ?*gtk.Separator = null, slot: ?*gtk.Box = null, id: i32 = 0, generation: u64 = 0, revision: u64 = 0, submenu: bool = false };

/// Compact context-menu row: check gutter, left-aligned label, submenu arrow.
fn menuRow() Row {
    const button = gtk.Button.new();
    button.as(gtk.Widget).addCssClass("pearl-menu-item");
    button.as(gtk.Widget).setHexpand(1);
    const box = w.row(8);
    const check = gtk.Image.newFromIconName("pearl-emblem-ok-symbolic");
    check.setPixelSize(14);
    check.as(gtk.Widget).addCssClass("pearl-menu-check");
    check.as(gtk.Widget).setValign(.center);
    check.as(gtk.Widget).setVisible(0);
    const label = gtk.Label.new("");
    label.setXalign(0);
    label.setEllipsize(.end);
    label.setMaxWidthChars(32);
    label.as(gtk.Widget).setHexpand(1);
    label.as(gtk.Widget).setValign(.center);
    const arrow = gtk.Label.new("›");
    arrow.as(gtk.Widget).addCssClass("pearl-menu-arrow");
    arrow.as(gtk.Widget).setValign(.center);
    arrow.as(gtk.Widget).setVisible(0);
    box.append(check.as(gtk.Widget));
    box.append(label.as(gtk.Widget));
    box.append(arrow.as(gtk.Widget));
    button.setChild(box.as(gtk.Widget));
    return .{ .button = button, .label = label, .check = check, .arrow = arrow };
}
pub const View = struct {
    probe_focus: ?*gtk.Widget = null,
    probe_choices: usize = std.math.maxInt(usize),
    probe_back: ?bool = null,
    service: *service.Tray,
    root: *gtk.Box,
    host: *gtk.Box,
    pages: *gtk.Stack,
    scroll: *gtk.ScrolledWindow,
    header: *gtk.Box,
    title: *gtk.Label,
    state: *gtk.Label,
    back: *gtk.Button,
    choices: [32]ItemChoice = undefined,
    bar_items: [32]u64 = @splat(0),
    nodes: [128]Choice = undefined,
    parent: i32 = 0,
    generation: u64 = 0,
    revision: u64 = std.math.maxInt(u64),
    pub fn create(host: *gtk.Box, tray: *service.Tray) !*View {
        const self = try a.create(View);
        // Own wrapper box: the popup panel receives a size request, which would
        // otherwise feed back into preferred-size measurement.
        const root = w.column(6);
        // Fill the panel so centering uses its entire padded content rectangle.
        root.as(gtk.Widget).setHexpand(1);
        root.as(gtk.Widget).setVexpand(1);
        host.append(root.as(gtk.Widget));
        const header = w.row(8);
        const back = gtk.Button.newWithLabel("‹");
        back.as(gtk.Widget).addCssClass("pearl-icon");
        back.as(gtk.Widget).setTooltipText("Back");
        w.name(back.as(gtk.Widget), "Back");
        const title = w.label("", "pearl-card-title");
        header.append(back.as(gtk.Widget));
        header.append(title.as(gtk.Widget));
        root.append(header.as(gtk.Widget));
        const state = w.label("", "pearl-secondary");
        root.append(state.as(gtk.Widget));
        const pages = gtk.Stack.new();
        pages.setHhomogeneous(0);
        pages.setVhomogeneous(0);
        pages.as(gtk.Widget).setHexpand(1);
        pages.as(gtk.Widget).setVexpand(1);
        const scroll = gtk.ScrolledWindow.new();
        self.* = .{ .service = tray, .root = root, .host = host, .pages = pages, .scroll = scroll, .header = header, .title = title, .state = state, .back = back };
        _ = gtk.Button.signals.clicked.connect(back, *View, goBack, self, .{});
        scroll.setPolicy(.never, .automatic);
        // Preferred-size measurement drives the popup surface, so the window must
        // report its content instead of collapsing to min-content.
        scroll.setPropagateNaturalWidth(1);
        scroll.setPropagateNaturalHeight(1);
        scroll.as(gtk.Widget).setVexpand(1);
        const content = w.column(2);
        content.as(gtk.Widget).addCssClass("pearl-tray-chooser");
        content.as(gtk.Widget).setHalign(.center);
        content.as(gtk.Widget).setValign(.center);
        const menu_content = w.column(2);
        _ = pages.addNamed(content.as(gtk.Widget), "chooser");
        _ = pages.addNamed(menu_content.as(gtk.Widget), "menu");
        scroll.setChild(pages.as(gtk.Widget));
        root.append(scroll.as(gtk.Widget));
        for (&self.choices) |*choice| {
            const button = gtk.Button.new();
            button.as(gtk.Widget).addCssClass("pearl-menu-item");
            button.as(gtk.Widget).addCssClass("pearl-tray-icon");
            button.as(gtk.Widget).setHalign(.center);
            const image = w.icon("pearl-application-x-executable-symbolic");
            image.as(gtk.Widget).setHalign(.center);
            image.as(gtk.Widget).setValign(.center);
            button.setChild(image.as(gtk.Widget));
            choice.* = .{ .view = self, .button = button, .image = image };
            _ = gtk.Button.signals.clicked.connect(button, *ItemChoice, choose, choice, .{});
            const context_click = gtk.GestureClick.new();
            context_click.as(gtk.GestureSingle).setButton(3);
            _ = gtk.GestureClick.signals.pressed.connect(context_click, *ItemChoice, choiceMenu, choice, .{});
            button.as(gtk.Widget).addController(context_click.as(gtk.EventController));
            const middle = gtk.GestureClick.new();
            middle.as(gtk.GestureSingle).setButton(2);
            _ = gtk.GestureClick.signals.pressed.connect(middle, *ItemChoice, choiceSecondary, choice, .{});
            button.as(gtk.Widget).addController(middle.as(gtk.EventController));
            const keys = gtk.EventControllerKey.new();
            _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *ItemChoice, choiceKey, choice, .{});
            button.as(gtk.Widget).addController(keys.as(gtk.EventController));
            content.append(button.as(gtk.Widget));
        }
        for (&self.nodes) |*node| {
            const row = menuRow();
            const separator = gtk.Separator.new(.horizontal);
            const slot = w.column(2);
            slot.append(separator.as(gtk.Widget));
            slot.append(row.button.as(gtk.Widget));
            node.* = .{ .view = self, .row = row, .separator = separator, .slot = slot };
            _ = gtk.Button.signals.clicked.connect(row.button, *Choice, clickNode, node, .{});
            menu_content.append(slot.as(gtk.Widget));
        }
        self.update();
        return self;
    }
    /// Snapshot visible generations rather than retaining a bar that may rebuild.
    pub fn setBar(self: *View, bar: ?*Bar) void {
        var items: [32]u64 = @splat(0);
        if (bar) |visible_bar| for (&visible_bar.rows, 0..) |*row, i| {
            if (row.widget.as(gtk.Widget).getVisible() != 0) items[i] = row.generation;
        };
        if (std.mem.eql(u64, &items, &self.bar_items)) return;
        self.bar_items = items;
        self.revision = std.math.maxInt(u64);
    }
    pub fn probe(self: *View, window: *gtk.Window) void {
        const back_visible = self.back.as(gtk.Widget).getVisible() != 0;
        if (self.probe_back == null or self.probe_back.? != back_visible) {
            self.probe_back = back_visible;
            log.info("event=tray-choices back={s} parent={d} chooser={s}", .{ if (back_visible) "true" else "false", self.parent, if (self.service.menu_from_chooser) "true" else "false" });
            if (self.service.find(self.generation) != null) log.info("event=tray-choices title={s}", .{std.mem.span(self.title.getText())});
        }
        var visible: usize = 0;
        for (&self.choices) |*choice| if (choice.button.as(gtk.Widget).getVisible() != 0) {
            visible += 1;
        };
        if (visible != self.probe_choices) {
            self.probe_choices = visible;
            log.info("event=tray-choices visible={d}", .{visible});
            if (visible == 1) for (&self.choices) |*choice| {
                const widget = choice.button.as(gtk.Widget);
                if (widget.getVisible() == 0) continue;
                var x: f64 = 0;
                var y: f64 = 0;
                if (widget.translateCoordinates(self.host.as(gtk.Widget), 0, 0, &x, &y) != 0) {
                    log.info("event=tray-choices panel={d}x{d} button={d}x{d} x={d} y={d}", .{ self.host.as(gtk.Widget).getWidth(), self.host.as(gtk.Widget).getHeight(), widget.getWidth(), widget.getHeight(), x, y });
                    const image = choice.image.as(gtk.Widget);
                    if (image.translateCoordinates(self.host.as(gtk.Widget), 0, 0, &x, &y) != 0) {
                        log.info("event=tray-choices panel={d}x{d} image={d}x{d} x={d} y={d}", .{ self.host.as(gtk.Widget).getWidth(), self.host.as(gtk.Widget).getHeight(), image.getWidth(), image.getHeight(), x, y });
                    }
                }
            };
        }
        const focus = window.getFocus();
        if (focus == self.probe_focus) return;
        self.probe_focus = focus;
        if (focus == self.back.as(gtk.Widget)) {
            log.info("event=session-focus target=tray-back", .{});
            return;
        }
        for (&self.choices) |*choice| if (focus == choice.button.as(gtk.Widget)) {
            log.info("event=session-focus target=tray-choice-{d}", .{choice.generation});
            return;
        };
        for (&self.nodes) |*node| if (focus == node.row.button.as(gtk.Widget)) {
            log.info("event=session-focus target=tray-{d}", .{node.id});
            return;
        };
        log.info("event=session-focus target=other", .{});
    }
    pub fn destroy(self: *View) void {
        self.service.selected = 0;
        self.service.menu_from_chooser = false;
        a.destroy(self);
    }
    /// Content size of the menu, used to size the popup surface to its entries.
    pub fn preferred(self: *View) struct { width: i32, height: i32 } {
        var minimum: gtk.Requisition = undefined;
        var natural: gtk.Requisition = undefined;
        self.root.as(gtk.Widget).getPreferredSize(&minimum, &natural);
        return .{ .width = natural.f_width, .height = natural.f_height };
    }
    pub fn update(self: *View) void {
        if (self.revision == self.service.revision and self.generation == self.service.selected) return;
        self.revision = self.service.revision;
        if (self.generation != self.service.selected) {
            self.generation = self.service.selected;
            self.parent = 0;
        }
        const selected = self.service.find(self.generation);
        self.pages.setVisibleChildName(if (selected == null) "chooser" else "menu");
        self.header.as(gtk.Widget).setVisible(@intFromBool(selected != null));
        self.title.setText(if (selected) |item| itemName(item) else "");
        self.title.as(gtk.Widget).setVisible(@intFromBool(selected != null and self.title.getText()[0] != 0));
        self.state.setText(if (self.service.err) |err| blk: {
            var text: @import("../services/policy.zig").Text(512) = .{};
            text.set(err);
            self.state.setText(text.z());
            break :blk self.state.getText();
        } else if (selected) |item| (if (item.menu_error) "Menu unavailable. Close and reopen to retry." else if (!item.menu_ready) "Loading menu…" else "") else "");
        self.state.as(gtk.Widget).setVisible(@intFromBool(std.mem.span(self.state.getText()).len != 0));
        self.back.as(gtk.Widget).setVisible(@intFromBool(selected != null and (self.parent != 0 or self.service.menu_from_chooser)));
        var visible_choices: usize = 0;
        for (&self.choices, &self.service.items) |*choice, *item| {
            choice.generation = item.generation;
            const visible = selected == null and item.ready and std.mem.indexOfScalar(u64, &self.bar_items, item.generation) == null;
            choice.button.as(gtk.Widget).setVisible(@intFromBool(visible));
            if (!visible) continue;
            visible_choices += 1;
            updateIcon(choice.image, item);
            describeItem(choice.button, item);
        }
        // An automatic scrollbar has a minimum height larger than one icon.
        // A single chooser row needs no scrolling and should keep its own size.
        self.scroll.setPolicy(.never, if (selected == null and visible_choices <= 1) .never else .automatic);
        for (&self.nodes, 0..) |*choice, i| {
            const slot = choice.slot.?;
            const item = selected orelse {
                slot.as(gtk.Widget).setVisible(0);
                continue;
            };
            const node = if (i < item.node_count) &item.nodes[i] else {
                slot.as(gtk.Widget).setVisible(0);
                continue;
            };
            const visible = item.menu_ready and node.parent == self.parent and node.visible;
            slot.as(gtk.Widget).setVisible(@intFromBool(visible));
            if (!visible) continue;
            const separator = node.separator;
            choice.separator.?.as(gtk.Widget).setVisible(@intFromBool(separator));
            choice.row.button.as(gtk.Widget).setVisible(@intFromBool(!separator));
            if (separator) continue;
            choice.id = node.id;
            choice.generation = item.generation;
            choice.revision = item.menu_revision;
            choice.submenu = node.submenu;
            choice.row.label.setText(node.label.z());
            choice.row.check.as(gtk.Widget).setVisible(@intFromBool(node.toggle));
            if (node.toggle) {
                if (node.checked) choice.row.check.setFromIconName("pearl-emblem-ok-symbolic") else choice.row.check.clear();
            }
            choice.row.arrow.as(gtk.Widget).setVisible(@intFromBool(node.submenu));
            choice.row.button.as(gtk.Widget).setSensitive(@intFromBool(node.enabled));
        }
    }
    fn choose(_: *gtk.Button, choice: *ItemChoice) callconv(.c) void {
        const item = choice.view.service.find(choice.generation) orelse return;
        if (item.is_menu) openChoiceMenu(choice) else choice.view.service.activate(choice.generation, false) catch {};
    }
    fn openChoiceMenu(choice: *ItemChoice) void {
        choice.view.service.openChooserMenu(choice.generation) catch {
            choice.view.service.contextMenu(choice.generation) catch {};
        };
    }
    fn choiceMenu(gesture: *gtk.GestureClick, _: c_int, _: f64, _: f64, choice: *ItemChoice) callconv(.c) void {
        _ = gesture.as(gtk.Gesture).setState(.claimed);
        openChoiceMenu(choice);
    }
    fn choiceSecondary(gesture: *gtk.GestureClick, _: c_int, _: f64, _: f64, choice: *ItemChoice) callconv(.c) void {
        _ = gesture.as(gtk.Gesture).setState(.claimed);
        choice.view.service.activate(choice.generation, true) catch {};
    }
    fn choiceKey(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, modifiers: gdk.ModifierType, choice: *ItemChoice) callconv(.c) c_int {
        if (keyval == 0xff67 or (keyval == 0xffc7 and modifiers.shift_mask)) {
            openChoiceMenu(choice);
            return 1;
        }
        return 0;
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
            if (!self.service.menu_from_chooser) return;
            self.service.showChooser();
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
