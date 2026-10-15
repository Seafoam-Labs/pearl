//! Shared native presentation for Assistant and model comparison settings.
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const object = @import("gobject2");
const w = @import("../ui/components/widgets.zig");

pub const Section = struct {
    expander: *gtk.Expander,
    body: *gtk.Box,
    summary: *gtk.Label,
    pub fn create(host: *gtk.Box, title: [:0]const u8, description: [:0]const u8) Section {
        const expander = gtk.Expander.new(null);
        expander.as(gtk.Widget).addCssClass("settings-card");
        expander.as(gtk.Widget).addCssClass("assistant-section");
        const heading = w.column(5);
        heading.as(gtk.Widget).addCssClass("assistant-section-heading");
        heading.append(w.label(title, "pearl-section-title").as(gtk.Widget));
        const summary = w.label(description, "pearl-secondary");
        heading.append(summary.as(gtk.Widget));
        expander.setLabelWidget(heading.as(gtk.Widget));
        w.name(expander.as(gtk.Widget), title);
        const body = w.column(12);
        body.as(gtk.Widget).addCssClass("assistant-section-body");
        expander.setChild(body.as(gtk.Widget));
        host.append(expander.as(gtk.Widget));
        return .{ .expander = expander, .body = body, .summary = summary };
    }
};

pub const ComputeChoice = struct {
    buttons: [3]*gtk.CheckButton,
    pub fn create(host: *gtk.Box) ComputeChoice {
        const flow = w.flow(3);
        var result: ComputeChoice = undefined;
        const titles = [_][:0]const u8{ "CPU", "Automatic", "Selected GPU" };
        const descriptions = [_][:0]const u8{ "Use the processor", "GPU, otherwise CPU", "Choose a device" };
        for (titles, descriptions, 0..) |title, description, i| {
            const check = gtk.CheckButton.new();
            if (i > 0) check.setGroup(result.buttons[0]);
            check.as(gtk.Widget).addCssClass("assistant-mode");
            const content = w.column(5);
            content.append(w.label(title, "settings-row-title").as(gtk.Widget));
            const subtitle = w.label(description, "pearl-secondary");
            subtitle.setMaxWidthChars(18);
            content.append(subtitle.as(gtk.Widget));
            check.setChild(content.as(gtk.Widget));
            w.name(check.as(gtk.Widget), title);
            flow.insert(check.as(gtk.Widget), -1);
            result.buttons[i] = check;
        }
        result.buttons[0].setActive(1);
        host.append(flow.as(gtk.Widget));
        return result;
    }
    pub fn getSelected(self: ComputeChoice) c_uint {
        for (self.buttons, 0..) |check, i| if (check.getActive() != 0) return @intCast(i);
        return 0;
    }
    pub fn setSelected(self: ComputeChoice, index: c_uint) void {
        self.buttons[@min(index, 2)].setActive(1);
    }
    pub fn as(self: ComputeChoice, comptime T: type) *T {
        return self.buttons[self.getSelected()].as(T);
    }
    pub fn connectKeys(self: *ComputeChoice) void {
        // FlowBox's spatial navigation stops at each child. Keep the radio group
        // traversable as one group even when its tiles wrap onto separate rows.
        const keys = gtk.EventControllerKey.new();
        keys.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *ComputeChoice, keyPressed, self, .{});
        self.buttons[0].as(gtk.Widget).getParent().?.getParent().?.addController(keys.as(gtk.EventController));
    }
    fn keyPressed(_: *gtk.EventControllerKey, key: c_uint, _: c_uint, modifiers: gdk.ModifierType, self: *ComputeChoice) callconv(.c) c_int {
        if (modifiers.control_mask or modifiers.alt_mask or modifiers.super_mask) return 0;
        const current = self.getSelected();
        const index = switch (key) {
            0xff51, 0xff52 => (current + 2) % 3, // Left / Up
            0xff53, 0xff54 => (current + 1) % 3, // Right / Down
            0xff50 => 0, // Home
            0xff57 => 2, // End
            else => return 0,
        };
        self.setSelected(index);
        _ = self.buttons[index].as(gtk.Widget).grabFocus();
        return 1;
    }
};

pub fn card(host: *gtk.Box, title: [:0]const u8) *gtk.Box {
    const box = w.column(12);
    box.as(gtk.Widget).addCssClass("settings-card");
    box.as(gtk.Widget).addCssClass("assistant-card");
    if (title.len > 0) box.append(w.label(title, "pearl-section-title").as(gtk.Widget));
    host.append(box.as(gtk.Widget));
    return box;
}

pub fn actions(host: *gtk.Box) *gtk.FlowBox {
    const flow = w.flow(3);
    flow.setHomogeneous(0);
    host.append(flow.as(gtk.Widget));
    return flow;
}

pub fn button(host: *gtk.FlowBox, title: [:0]const u8) *gtk.Button {
    const b = w.wrappingButton(title);
    b.as(gtk.Widget).addCssClass("settings-value");
    host.insert(b.as(gtk.Widget), -1);
    return b;
}

pub fn row(host: *gtk.Box, title: [:0]const u8, control: *gtk.Widget) void {
    const flow = w.flow(2);
    flow.setHomogeneous(0);
    const label = w.label(title, "settings-row-title");
    label.setMaxWidthChars(28);
    flow.insert(label.as(gtk.Widget), -1);
    control.setHalign(.end);
    control.setValign(.center);
    flow.insert(control, -1);
    w.name(control, title);
    host.append(flow.as(gtk.Widget));
}

pub fn showRow(control: *gtk.Widget, visible: bool) void {
    control.getParent().?.getParent().?.setVisible(@intFromBool(visible));
}

pub fn wrapChoice(choice: *gtk.DropDown) void {
    const factory = gtk.SignalListItemFactory.new();
    _ = gtk.SignalListItemFactory.signals.setup.connect(factory, ?*anyopaque, choiceSetup, null, .{});
    _ = gtk.SignalListItemFactory.signals.bind.connect(factory, ?*anyopaque, choiceBind, null, .{});
    choice.setFactory(factory.as(gtk.ListItemFactory));
    choice.setListFactory(factory.as(gtk.ListItemFactory));
    factory.unref();
}
fn choiceSetup(_: *gtk.SignalListItemFactory, obj: *object.Object, _: ?*anyopaque) callconv(.c) void {
    const item = object.ext.cast(gtk.ListItem, obj).?;
    const label = w.label("", null);
    label.setMaxWidthChars(24);
    item.setChild(label.as(gtk.Widget));
}
fn choiceBind(_: *gtk.SignalListItemFactory, obj: *object.Object, _: ?*anyopaque) callconv(.c) void {
    const item = object.ext.cast(gtk.ListItem, obj).?;
    const label = object.ext.cast(gtk.Label, item.getChild().?).?;
    label.setText(object.ext.cast(gtk.StringObject, item.getItem().?).?.getString());
}
