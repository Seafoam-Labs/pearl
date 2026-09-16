//! Selected-output editor. All writes are staged canonical declaration operations.
const std = @import("std");
const gtk = @import("gtk4");
const glib = @import("glib2");
const gdk = @import("gdk4");
const object = @import("gobject2");
const cairo = @import("cairo1");
const m = @import("../config/aqueous_model.zig");
const model = @import("../config/aqueous_display_setup.zig");
const w = @import("../ui/components/widgets.zig");
pub fn For(comptime View: type) type {
    return struct {
        const Self = @This();
        const Control = enum { enabled, hdr, resolution, refresh, scale, transform, x, y, side, relative, mirror, hdr_level, sdr_white };
        const Binding = struct { form: *Form, key: Control };
        const Choice = struct { form: *Form, index: usize };
        const Head = struct { output: m.Value, rect: model.Rect, enabled: bool, number: usize };
        pub const Form = struct {
            view: *View,
            base: m.Value,
            draft: m.Value,
            projection: m.Value = .null,
            heads: []Head,
            selected: usize = 0,
            loading: bool = true,
            input_error: ?[]const u8 = null,
            canvas: *gtk.DrawingArea,
            title: *gtk.Label,
            subtitle: *gtk.Label,
            status: *gtk.Label,
            warning: *gtk.Label,
            hdr_help: *gtk.Label,
            position_help: *gtk.Label,
            enabled: *gtk.Switch,
            hdr: *gtk.CheckButton,
            resolution: *gtk.DropDown,
            refresh: *gtk.DropDown,
            scale: *gtk.DropDown,
            transform: *gtk.DropDown,
            x: *gtk.SpinButton,
            y: *gtk.SpinButton,
            side: *gtk.DropDown,
            relative: *gtk.DropDown,
            mirror: *gtk.DropDown,
            hdr_level: *gtk.DropDown,
            sdr_white: *gtk.DropDown,
            scales: []const f64 = &.{},
            whites: []const f64 = &.{},
            relatives: []const usize = &.{},
            mirror_targets: []const usize = &.{},
            tabs: []*gtk.ToggleButton,
            align_buttons: [3]*gtk.Button,
            level_reset: *gtk.Button,
            modes: []const m.Value = &.{},
            resolutions: []const []const u8 = &.{},
            rates: []const []const u8 = &.{},
            ratio: f64 = 1,
            origin_x: f64 = 0,
            origin_y: f64 = 0,
            dragging: bool = false,
            start: model.Rect = .{},
            fn alloc(f: *Form) std.mem.Allocator {
                return f.view.arena.allocator();
            }
            fn z(f: *Form, s: []const u8) [:0]const u8 {
                return f.view.z(s);
            }
            fn relativeIndex(f: *Form) usize {
                return if (f.relatives.len == 0) f.selected else f.relatives[@min(f.relatives.len - 1, f.relative.getSelected())];
            }
            fn output(f: *Form) m.Value {
                return f.heads[f.selected].output;
            }
            fn val(f: *Form, key: []const u8) m.Value {
                return model.value(f.base, f.draft, f.output(), key);
            }
            fn format(f: *Form, comptime fmt: []const u8, args: anytype) [:0]const u8 {
                return f.z(std.fmt.allocPrint(f.alloc(), fmt, args) catch "");
            }
            fn stage(f: *Form, key: []const u8, value: m.Value) !void {
                if (f.loading or f.view.client.job != null or f.view.client.conflict()) return;
                const bytes = try model.stage(f.alloc(), f.base, f.view.client.draft orelse try f.view.client.emptyDraft(f.alloc()), f.output(), key, value);
                try f.view.client.keepDraft(bytes);
                f.view.syncRequest();
                f.draft = try m.parse(f.alloc(), bytes, m.max_request);
            }
            fn position(f: *Form, r: model.Rect) !void {
                var v: m.Value = .{ .array = .init(f.alloc()) };
                try v.array.append(.{ .integer = @intFromFloat(std.math.clamp(@round(r.x), -2147483648, 2147483647)) });
                try v.array.append(.{ .integer = @intFromFloat(std.math.clamp(@round(r.y), -2147483648, 2147483647)) });
                try f.stage("position", v);
            }
            fn choose(f: *Form, i: usize) void {
                if (i >= f.heads.len) return;
                f.selected = i;
                const name = model.connector(f.output());
                @memset(&f.view.display_selected, 0);
                @memcpy(f.view.display_selected[0..@min(name.len, 127)], name[0..@min(name.len, 127)]);
                f.refreshControls() catch |err| f.view.fail(err);
            }
            fn sync(f: *Form) void {
                // Replacing a dropdown model from its own notify handler can
                // re-enter GTK while it is closing the selection popover.
                if (f.view.display_refresh_source == 0) f.view.display_refresh_source = glib.idleAdd(refreshIdle, f);
            }
            fn refreshIdle(data: ?*anyopaque) callconv(.c) c_int {
                const f: *Form = @ptrCast(@alignCast(data.?));
                f.view.display_refresh_source = 0;
                f.refreshControls() catch |err| f.view.fail(err);
                f.view.update();
                return 0;
            }
            fn refreshControls(f: *Form) !void {
                f.loading = true;
                defer f.loading = false;
                f.draft = m.parse(f.alloc(), f.view.client.draft orelse "{}", m.max_request) catch invalid: {
                    f.input_error = "The draft JSON is invalid. Open Aqueous Advanced to correct it.";
                    break :invalid .null;
                };
                var enabled_count: usize = 0;
                const candidate_current = f.view.client.review_revision == f.view.client.revision and !f.view.client.conflict();
                for (f.heads, 0..) |*h, i| {
                    h.rect = model.geometry(f.base, f.draft, h.output);
                    h.enabled = m.equal(model.value(f.base, f.draft, h.output, "enabled"), .{ .bool = true });
                    if (candidate_current) for (m.list(m.get(f.projection, "effective_outputs"))) |candidate| {
                        if (m.equal(m.get(candidate, "instance"), m.get(h.output, "instance"))) {
                            h.rect = model.resolvedGeometry(m.get(candidate, "resolved"));
                            h.enabled = m.equal(m.get(m.get(candidate, "resolved"), "enabled"), .{ .bool = true });
                        }
                    };
                    if (h.enabled) enabled_count += 1;
                    f.tabs[i].setActive(@intFromBool(i == f.selected));
                    f.tabs[i].as(gtk.Button).setLabel(f.format("{d}  {s}{s}", .{ h.number, model.connector(h.output), if (h.enabled) "" else " · Off" }));
                }
                const out = f.output();
                const head = f.heads[f.selected];
                const make = m.str(m.get(out, "make"));
                const name = m.str(m.get(out, "model"));
                f.title.setText(f.format("{d}  {s}{s}{s}", .{ head.number, if (name.len == 0) model.connector(out) else make, if (name.len > 0 and make.len > 0) " " else "", name }));
                f.subtitle.setText(f.z(model.connector(out)));
                f.enabled.setActive(@intFromBool(head.enabled));
                f.enabled.as(gtk.Widget).setSensitive(@intFromBool(!head.enabled or enabled_count > 1));
                const hdr = m.equal(f.val("hdr"), .{ .bool = true });
                const support = m.get(m.get(out, "support"), "hdr");
                const reason = m.str(m.get(support, "reason"));
                const hdr_supported = m.equal(m.get(support, "test"), .{ .bool = true }) or m.equal(m.get(support, "preview"), .{ .bool = true }) or m.equal(m.get(m.get(out, "actual"), "hdr"), .{ .bool = true });
                f.hdr.setActive(@intFromBool(hdr));
                f.hdr.as(gtk.Widget).setSensitive(@intFromBool(head.enabled and hdr_supported));
                const level = f.val("hdr_level");
                const custom = (level != .null and !std.mem.eql(u8, m.str(level), "auto") and (m.get(m.get(m.get(out, "configured"), "hdr_level"), "value") != .null or staged(f, "hdr_level"))) or (f.val("sdr_white_level") != .null and (m.get(m.get(m.get(out, "configured"), "sdr_white_level"), "value") != .null or staged(f, "sdr_white_level")));
                const white_value = f.val("sdr_white_level");
                f.hdr_help.setText(if (!head.enabled) "Turn on this display to use HDR." else if (!hdr_supported) (if (reason.len > 0) if (std.mem.eql(u8, reason, "hdr_unsupported")) "This display does not support HDR." else "HDR preview is not available for this display." else "HDR support is unknown.") else if (custom) "Custom settings in More display options." else "Uses automatic settings.");
                f.hdr_level.setSelected(if (std.mem.eql(u8, m.str(level), "100") or (custom and model.num(level, 0) == 100)) 1 else if (std.mem.eql(u8, m.str(level), "400") or (custom and model.num(level, 0) == 400)) 2 else if (std.mem.eql(u8, m.str(level), "1000") or (custom and model.num(level, 0) == 1000)) 3 else 0);
                const white_explicit = white_value != .null and (m.get(m.get(m.get(out, "configured"), "sdr_white_level"), "value") != .null or staged(f, "sdr_white_level"));
                try numericOptions(f, f.sdr_white, &f.whites, &.{ 0, 100, 200, 300 }, if (white_explicit) model.num(white_value, 200) else 0, false);
                for ([_]*gtk.Widget{ f.hdr_level.as(gtk.Widget), f.sdr_white.as(gtk.Widget), f.level_reset.as(gtk.Widget) }) |widget| widget.setSensitive(@intFromBool(head.enabled and hdr_supported and hdr));
                try numericOptions(f, f.scale, &f.scales, &.{ 50, 75, 100, 125, 150, 175, 200, 250, 300 }, model.num(f.val("scale"), 1) * 100, true);
                const transforms = [_][]const u8{ "normal", "90", "180", "270", "flipped", "flipped-90", "flipped-180", "flipped-270" };
                for (transforms, 0..) |t, i| if (std.mem.eql(u8, t, m.str(f.val("transform")))) {
                    f.transform.setSelected(@intCast(i));
                };
                try f.refreshModes();
                f.x.setValue(head.rect.x);
                f.y.setValue(head.rect.y);
                const mirrored = m.str(f.val("mirror_of")).len > 0;
                const previous_other = f.relativeIndex();
                var references: std.ArrayList(usize) = .empty;
                var labels: std.ArrayList([]const u8) = .empty;
                var mirrors: std.ArrayList(usize) = .empty;
                var mirror_labels: std.ArrayList([]const u8) = .empty;
                try mirror_labels.append(f.alloc(), "Extend desktop");
                var reference_selection: c_uint = 0;
                var mirror_selection: c_uint = 0;
                for (f.heads, 0..) |h, i| {
                    if (i == f.selected) continue;
                    const current_mirror = std.mem.eql(u8, model.connector(h.output), m.str(f.val("mirror_of")));
                    if (h.enabled) {
                        if (i == previous_other) reference_selection = @intCast(references.items.len);
                        try references.append(f.alloc(), i);
                        try labels.append(f.alloc(), try std.fmt.allocPrint(f.alloc(), "{d} · {s}", .{ h.number, model.connector(h.output) }));
                    }
                    if (h.enabled or current_mirror) {
                        try mirrors.append(f.alloc(), i);
                        try mirror_labels.append(f.alloc(), try std.fmt.allocPrint(f.alloc(), "Mirror {s}", .{model.connector(h.output)}));
                        if (current_mirror) mirror_selection = @intCast(mirrors.items.len);
                    }
                }
                f.relatives = try references.toOwnedSlice(f.alloc());
                f.mirror_targets = try mirrors.toOwnedSlice(f.alloc());
                if (labels.items.len == 0) try labels.append(f.alloc(), "No other enabled display");
                const reference_list = try f.strings(labels.items);
                f.relative.setModel(reference_list.as(@import("gio2").ListModel));
                reference_list.unref();
                f.relative.setSelected(reference_selection);
                const mirror_list = try f.strings(mirror_labels.items);
                f.mirror.setModel(mirror_list.as(@import("gio2").ListModel));
                mirror_list.unref();
                f.mirror.setSelected(mirror_selection);
                const other = f.relativeIndex();
                const can_position = head.enabled and enabled_count > 1 and !mirrored;
                for ([_]*gtk.Widget{ f.side.as(gtk.Widget), f.relative.as(gtk.Widget), f.x.as(gtk.Widget), f.y.as(gtk.Widget) }) |widget| widget.setSensitive(@intFromBool(can_position));
                const r = f.heads[other].rect;
                const side: usize = if (@abs(head.rect.x + head.rect.width - r.x) < 1) 0 else if (@abs(head.rect.x - r.x - r.width) < 1) 1 else if (@abs(head.rect.y + head.rect.height - r.y) < 1) 2 else if (@abs(head.rect.y - r.y - r.height) < 1) 3 else 4;
                f.side.setSelected(@intCast(side));
                const names = if (side < 2) [_][*:0]const u8{ "Top", "Center", "Bottom" } else [_][*:0]const u8{ "Left", "Center", "Right" };
                for (f.align_buttons, 0..) |button, i| {
                    button.setLabel(names[i]);
                    var aligned_rect = head.rect;
                    aligned_rect.place(r, @min(side, 3), i);
                    const active = side < 4 and @abs(head.rect.x - aligned_rect.x) < 1 and @abs(head.rect.y - aligned_rect.y) < 1;
                    if (active) button.as(gtk.Widget).addCssClass("display-alignment-selected") else button.as(gtk.Widget).removeCssClass("display-alignment-selected");
                    button.as(gtk.Widget).setSensitive(@intFromBool(can_position));
                }
                f.position_help.setText(if (mirrored) "This display mirrors another screen." else if (!can_position) "Turn on two displays to arrange them." else if (side == 4) "Custom arrangement. Drag a screen or set its exact position." else f.format("{s} display {d} · {d:.0}, {d:.0}", .{ ([_][]const u8{ "Left of", "Right of", "Above", "Below" })[@min(side, 3)], f.heads[other].number, head.rect.x, head.rect.y }));
                var overlap = false;
                for (f.heads, 0..) |h, i| for (f.heads[0..i]) |t| {
                    if (h.enabled and t.enabled and m.str(model.value(f.base, f.draft, h.output, "mirror_of")).len == 0 and m.str(model.value(f.base, f.draft, t.output, "mirror_of")).len == 0 and h.rect.overlaps(t.rect)) overlap = true;
                };
                f.view.display_blocked = overlap;
                var unavailable: []const u8 = "";
                if (model.changeCount(f.draft) > 0) for (f.heads) |h| {
                    for ([_][]const u8{ "placement", "mode", "enable" }) |feature| {
                        const s = m.get(m.get(h.output, "support"), feature);
                        if (!m.equal(m.get(s, "preview"), .{ .bool = true })) unavailable = m.str(m.get(s, "reason"));
                    }
                    if (m.equal(model.value(f.base, f.draft, h.output, "hdr"), .{ .bool = true }) and !m.equal(m.get(m.get(m.get(h.output, "support"), "hdr"), "preview"), .{ .bool = true })) unavailable = "HDR preview is unavailable on this backend.";
                };
                if (unavailable.len > 0 or f.input_error != null) f.view.display_blocked = true;
                f.warning.setText(if (f.input_error) |err| f.z(err) else if (overlap) "Displays overlap. Move them apart or choose mirroring before applying." else f.z(unavailable));
                f.warning.as(gtk.Widget).setVisible(@intFromBool(overlap or unavailable.len > 0 or f.input_error != null));
                const count = model.changeCount(f.draft);
                f.view.display_changes = count;
                f.view.display_other_changes = model.otherChanges(f.draft);
                f.status.setText(if (candidate_current and f.projection != .null) "Validated arrangement · unsaved" else if (count > 0) "Unsaved layout" else "Current layout");
                w.name(f.canvas.as(gtk.Widget), f.format("Display {d}, {s}, position {d:.0}, {d:.0}. Arrow keys move; Shift moves one pixel.", .{ head.number, model.connector(out), head.rect.x, head.rect.y }));
                f.canvas.as(gtk.Widget).queueDraw();
            }
            fn strings(f: *Form, values: []const []const u8) !*gtk.StringList {
                const list = try f.alloc().allocSentinel(?[*:0]const u8, values.len, null);
                for (values, 0..) |v, i| list[i] = f.z(v);
                return gtk.StringList.new(@ptrCast(list.ptr));
            }
            fn refreshModes(f: *Form) !void {
                const current = try model.modeText(f.alloc(), f.val("mode"));
                var modes: std.ArrayList([]const u8) = .empty;
                try modes.append(f.alloc(), current);
                for (m.list(m.get(f.output(), "modes"))) |mode| {
                    const text = try model.modeText(f.alloc(), mode);
                    var found = false;
                    for (modes.items) |v| {
                        if (std.mem.eql(u8, v, text)) found = true;
                    }
                    if (!found) try modes.append(f.alloc(), text);
                }
                var resolutions: std.ArrayList([]const u8) = .empty;
                var rates: std.ArrayList([]const u8) = .empty;
                const current_res = current[0..(std.mem.indexOfScalar(u8, current, '@') orelse current.len)];
                for (modes.items) |mode| {
                    const end = std.mem.indexOfScalar(u8, mode, '@') orelse mode.len;
                    const res = mode[0..end];
                    var found = false;
                    for (resolutions.items) |v| {
                        if (std.mem.eql(u8, v, res)) found = true;
                    }
                    if (!found) try resolutions.append(f.alloc(), res);
                    if (std.mem.eql(u8, res, current_res)) try rates.append(f.alloc(), mode);
                }
                f.resolutions = try resolutions.toOwnedSlice(f.alloc());
                f.rates = try rates.toOwnedSlice(f.alloc());
                const list = try f.strings(f.resolutions);
                f.resolution.setModel(list.as(@import("gio2").ListModel));
                list.unref();
                f.resolution.setSelected(0);
                const rate_labels = try f.alloc().alloc([]const u8, f.rates.len);
                for (f.rates, 0..) |rate, i| rate_labels[i] = if (std.mem.indexOfScalar(u8, rate, '@')) |at| try std.fmt.allocPrint(f.alloc(), "{s} Hz", .{rate[at + 1 ..]}) else "Current";
                const rates_list = try f.strings(rate_labels);
                f.refresh.setModel(rates_list.as(@import("gio2").ListModel));
                rates_list.unref();
                f.refresh.setSelected(0);
            }
        };
        fn staged(f: *Form, key: []const u8) bool {
            const target = model.target(f.base, f.output());
            for (m.list(m.get(m.get(f.draft, "display_declaration_changes"), "operations"))) |op| {
                if ((target != .null and m.equal(m.get(op, "id"), m.get(target, "id"))) or std.mem.eql(u8, m.str(m.get(m.get(op, "set"), "name")), model.connector(f.output()))) return m.get(m.get(op, "set"), key) != .null;
            }
            return false;
        }
        fn numericOptions(f: *Form, dropdown_: *gtk.DropDown, storage: *[]const f64, presets: []const f64, current: f64, percent: bool) !void {
            var values: std.ArrayList(f64) = .empty;
            try values.appendSlice(f.alloc(), presets);
            var index: ?usize = null;
            for (presets, 0..) |v, i| if (@abs(v - current) < 0.001) {
                index = i;
            };
            if (index == null) {
                index = values.items.len;
                try values.append(f.alloc(), current);
            }
            storage.* = try values.toOwnedSlice(f.alloc());
            const labels = try f.alloc().alloc([]const u8, storage.*.len);
            for (storage.*, 0..) |v, i| labels[i] = if (percent) try std.fmt.allocPrint(f.alloc(), "{d:.0}%", .{v}) else if (v == 0) "Automatic" else try std.fmt.allocPrint(f.alloc(), "{d:.0} nits", .{v});
            const list = try f.strings(labels);
            dropdown_.setModel(list.as(@import("gio2").ListModel));
            list.unref();
            dropdown_.setSelected(@intCast(index.?));
        }
        fn dropdown() *gtk.DropDown {
            return gtk.DropDown.newFromStrings(@ptrCast(&[_:null]?[*:0]const u8{""}));
        }
        fn options(names: [:null]const ?[*:0]const u8) *gtk.DropDown {
            return gtk.DropDown.newFromStrings(@ptrCast(names.ptr));
        }
        fn field(parent: *gtk.Box, title: [*:0]const u8, input: *gtk.Widget) void {
            const row = w.column(6);
            row.append(w.label(title, "pearl-secondary").as(gtk.Widget));
            row.append(input);
            input.setHexpand(1);
            w.name(input, title);
            if (@import("build_options").test_hooks) input.setName(title);
            parent.append(row.as(gtk.Widget));
        }
        fn pair(parent: *gtk.Box) [2]*gtk.Box {
            const row = w.row(12);
            parent.append(row.as(gtk.Widget));
            const left = w.column(12);
            const right = w.column(12);
            left.as(gtk.Widget).setHexpand(1);
            right.as(gtk.Widget).setHexpand(1);
            row.setHomogeneous(1);
            row.append(left.as(gtk.Widget));
            row.append(right.as(gtk.Widget));
            return .{ left, right };
        }
        fn register(f: *Form, id: []const u8, input: *gtk.Widget) !void {
            try f.view.display_controls.append(f.alloc(), .{ .id = try std.fmt.allocPrint(f.alloc(), "display.{s}", .{id}), .widget = input });
        }
        fn bind(f: *Form, input: *gtk.Widget, key: Control) !void {
            try register(f, @tagName(key), input);
            const b = try f.alloc().create(Binding);
            b.* = .{ .form = f, .key = key };
            if (object.ext.cast(gtk.SpinButton, input)) |spin| f.view.form_signals.add(spin.as(object.Object), gtk.SpinButton.signals.value_changed.connect(spin, *Binding, spun, b, .{})) else if (object.ext.cast(gtk.CheckButton, input)) |check| f.view.form_signals.add(check.as(object.Object), gtk.CheckButton.signals.toggled.connect(check, *Binding, toggled, b, .{})) else f.view.form_signals.add(input.as(object.Object), object.Object.signals.notify.connect(input.as(object.Object), *Binding, changed, b, .{ .detail = if (key == .enabled) "active" else "selected" }));
        }
        pub fn render(view: *View, box: *gtk.Box, base: m.Value) !void {
            const a = view.arena.allocator();
            const outputs = model.outputs(base);
            if (outputs.len == 0) {
                box.append(w.label("No connected displays. Refresh after reconnecting to Aqueous.", "pearl-secondary").as(gtk.Widget));
                return;
            }
            const f = try a.create(Form);
            const heads = try a.alloc(Head, outputs.len);
            const tabs = try a.alloc(*gtk.ToggleButton, outputs.len);
            for (outputs, 0..) |out, i| heads[i] = .{ .output = out, .rect = .{}, .enabled = true, .number = model.number(out, i + 1) };
            const arrangement = w.card();
            arrangement.setSpacing(8);
            arrangement.as(gtk.Widget).addCssClass("display-arrangement");
            box.append(arrangement.as(gtk.Widget));
            const identify = gtk.Button.newWithLabel("Identify");
            w.name(identify.as(gtk.Widget), "Identify displays");
            arrangement.append(w.section(w.label("Arrange your displays", "pearl-title"), w.label("Drag screens to match how they sit on your desk.", "pearl-secondary"), identify.as(gtk.Widget)).as(gtk.Widget));
            const status = w.label("Current layout", "pearl-secondary");
            arrangement.append(status.as(gtk.Widget));
            const canvas = gtk.DrawingArea.new();
            canvas.setContentHeight(160);
            canvas.as(gtk.Widget).setHexpand(1);
            canvas.as(gtk.Widget).setFocusable(1);
            arrangement.append(canvas.as(gtk.Widget));
            const side_by_side = gtk.Button.newWithLabel("Arrange side by side");
            side_by_side.as(gtk.Widget).addCssClass("flat");
            arrangement.append(w.section(w.label("Click a screen to change its settings.", "pearl-secondary"), null, side_by_side.as(gtk.Widget)).as(gtk.Widget));
            const selectors = w.flow(8);
            selectors.setHomogeneous(0);
            box.append(selectors.as(gtk.Widget));
            for (tabs, 0..) |*tab, i| {
                tab.* = gtk.ToggleButton.new();
                tab.*.as(gtk.Widget).addCssClass("display-selector");
                selectors.insert(tab.*.as(gtk.Widget), -1);
                const choice = try a.create(Choice);
                choice.* = .{ .form = f, .index = i };
                view.form_signals.add(tab.*.as(object.Object), gtk.Button.signals.clicked.connect(tab.*.as(gtk.Button), *Choice, select, choice, .{}));
            }
            const columns = w.flow(2);
            columns.setHomogeneous(1);
            box.append(columns.as(gtk.Widget));
            const settings = w.card();
            settings.as(gtk.Widget).addCssClass("display-editor");
            settings.setSpacing(10);
            columns.insert(settings.as(gtk.Widget), -1);
            const position = w.card();
            position.as(gtk.Widget).addCssClass("display-editor");
            columns.insert(position.as(gtk.Widget), -1);
            const title = w.label("", "pearl-title");
            const subtitle = w.label("", "pearl-secondary");
            const enabled = gtk.Switch.new();
            w.name(enabled.as(gtk.Widget), "Enable display");
            settings.append(w.section(title, subtitle, enabled.as(gtk.Widget)).as(gtk.Widget));
            const hdr = gtk.CheckButton.newWithLabel("Enable HDR");
            w.name(hdr.as(gtk.Widget), "Enable HDR");
            const hdr_row = w.column(4);
            settings.append(hdr_row.as(gtk.Widget));
            hdr_row.append(hdr.as(gtk.Widget));
            const hdr_help = w.label("Uses automatic settings.", "pearl-secondary");
            hdr_help.as(gtk.Widget).setMarginStart(24);
            hdr_row.append(hdr_help.as(gtk.Widget));
            const first = pair(settings);
            const resolution = dropdown();
            const refresh = dropdown();
            field(first[0], "Resolution", resolution.as(gtk.Widget));
            field(first[1], "Refresh rate", refresh.as(gtk.Widget));
            const second = pair(settings);
            const scale = dropdown();
            field(second[0], "Scale", scale.as(gtk.Widget));
            const transform = options(&[_:null]?[*:0]const u8{ "Landscape", "Portrait", "Inverted", "Portrait left", "Flipped", "Flipped 90°", "Flipped 180°", "Flipped 270°" });
            field(second[1], "Orientation", transform.as(gtk.Widget));
            position.append(w.label("Position", "pearl-title").as(gtk.Widget));
            const places = pair(position);
            const side = options(&[_:null]?[*:0]const u8{ "To the left of", "To the right of", "Above", "Below", "Custom position" });
            field(places[0], "Place this display", side.as(gtk.Widget));
            const names = try a.allocSentinel(?[*:0]const u8, outputs.len, null);
            const mirror_names = try a.allocSentinel(?[*:0]const u8, outputs.len + 1, null);
            mirror_names[0] = "Extend desktop";
            for (outputs, 0..) |out, i| {
                names[i] = view.z(try std.fmt.allocPrint(a, "{d} · {s}", .{ model.number(out, i + 1), model.connector(out) }));
                mirror_names[i + 1] = view.z(try std.fmt.allocPrint(a, "Mirror {s}", .{model.connector(out)}));
            }
            const relative = gtk.DropDown.newFromStrings(@ptrCast(names.ptr));
            field(places[1], "Next to", relative.as(gtk.Widget));
            position.append(w.label("Align edges", "pearl-secondary").as(gtk.Widget));
            const alignment = w.row(0);
            alignment.as(gtk.Widget).addCssClass("linked");
            alignment.setHomogeneous(1);
            position.append(alignment.as(gtk.Widget));
            var align_buttons: [3]*gtk.Button = undefined;
            for (&align_buttons, 0..) |*button, i| {
                button.* = gtk.Button.newWithLabel("Center");
                alignment.append(button.*.as(gtk.Widget));
                const choice = try a.create(Choice);
                choice.* = .{ .form = f, .index = i };
                view.form_signals.add(button.*.as(object.Object), gtk.Button.signals.clicked.connect(button.*, *Choice, aligned, choice, .{}));
            }
            const position_help = w.label("", "pearl-secondary");
            position.append(position_help.as(gtk.Widget));
            const exact = gtk.Expander.new("Exact position");
            exact.setExpanded(@intFromBool(view.display_exact));
            position.append(exact.as(gtk.Widget));
            const exact_box = w.column(10);
            exact.setChild(exact_box.as(gtk.Widget));
            const xy = pair(exact_box);
            const x = gtk.SpinButton.newWithRange(-2147483648, 2147483647, 1);
            const y = gtk.SpinButton.newWithRange(-2147483648, 2147483647, 1);
            x.as(gtk.Editable).setWidthChars(6);
            y.as(gtk.Editable).setWidthChars(6);
            field(xy[0], "Horizontal (X)", x.as(gtk.Widget));
            field(xy[1], "Vertical (Y)", y.as(gtk.Widget));
            const warning = w.label("", "pearl-secondary");
            box.append(warning.as(gtk.Widget));
            const more = gtk.Expander.new("More display options");
            more.setExpanded(@intFromBool(view.display_more));
            box.append(more.as(gtk.Widget));
            const advanced = w.card();
            more.setChild(advanced.as(gtk.Widget));
            const mirror = gtk.DropDown.newFromStrings(@ptrCast(mirror_names.ptr));
            field(advanced, "Display mode", mirror.as(gtk.Widget));
            advanced.append(w.label("HDR adjustments", "pearl-title").as(gtk.Widget));
            const hdr_pair = pair(advanced);
            const level = options(&[_:null]?[*:0]const u8{ "Automatic (recommended)", "100 nits", "400 nits", "1000 nits" });
            field(hdr_pair[0], "HDR brightness", level.as(gtk.Widget));
            const white = dropdown();
            field(hdr_pair[1], "SDR content brightness", white.as(gtk.Widget));
            const reset = gtk.Button.newWithLabel("Use automatic settings");
            advanced.append(reset.as(gtk.Widget));
            advanced.append(w.label("Automatic SDR brightness uses inherited/default settings. Other color options and display profiles are below.", "pearl-secondary").as(gtk.Widget));
            f.* = .{ .view = view, .base = base, .draft = .null, .heads = heads, .canvas = canvas, .title = title, .subtitle = subtitle, .status = status, .warning = warning, .hdr_help = hdr_help, .position_help = position_help, .enabled = enabled, .hdr = hdr, .resolution = resolution, .refresh = refresh, .scale = scale, .transform = transform, .x = x, .y = y, .side = side, .relative = relative, .mirror = mirror, .hdr_level = level, .sdr_white = white, .tabs = tabs, .align_buttons = align_buttons, .level_reset = reset };
            inline for (.{ .{ enabled, .enabled }, .{ hdr, .hdr }, .{ resolution, .resolution }, .{ refresh, .refresh }, .{ scale, .scale }, .{ transform, .transform }, .{ x, .x }, .{ y, .y }, .{ side, .side }, .{ relative, .relative }, .{ mirror, .mirror }, .{ level, .hdr_level }, .{ white, .sdr_white } }) |entry| try bind(f, entry[0].as(gtk.Widget), entry[1]);
            try register(f, "arrangement", canvas.as(gtk.Widget));
            try register(f, "exact", exact.as(gtk.Widget));
            try register(f, "more", more.as(gtk.Widget));
            try register(f, "automatic", reset.as(gtk.Widget));
            try register(f, "identify", identify.as(gtk.Widget));
            try register(f, "arrange", side_by_side.as(gtk.Widget));
            for (tabs, 0..) |tab, i| try register(f, try std.fmt.allocPrint(a, "select.{d}", .{i}), tab.as(gtk.Widget));
            for (align_buttons, 0..) |button, i| try register(f, try std.fmt.allocPrint(a, "align.{d}", .{i}), button.as(gtk.Widget));
            canvas.setDrawFunc(draw, f, null);
            const drag = gtk.GestureDrag.new();
            view.form_signals.add(drag.as(object.Object), gtk.GestureDrag.signals.drag_begin.connect(drag, *Form, dragBegin, f, .{}));
            view.form_signals.add(drag.as(object.Object), gtk.GestureDrag.signals.drag_update.connect(drag, *Form, dragUpdate, f, .{}));
            view.form_signals.add(drag.as(object.Object), gtk.GestureDrag.signals.drag_end.connect(drag, *Form, dragEnd, f, .{}));
            canvas.as(gtk.Widget).addController(drag.as(gtk.EventController));
            const keys = gtk.EventControllerKey.new();
            view.form_signals.add(keys.as(object.Object), gtk.EventControllerKey.signals.key_pressed.connect(keys, *Form, keyPressed, f, .{}));
            canvas.as(gtk.Widget).addController(keys.as(gtk.EventController));
            view.form_signals.add(side_by_side.as(object.Object), gtk.Button.signals.clicked.connect(side_by_side, *Form, arrange, f, .{}));
            view.form_signals.add(reset.as(object.Object), gtk.Button.signals.clicked.connect(reset, *Form, automatic, f, .{}));
            view.form_signals.add(identify.as(object.Object), gtk.Button.signals.clicked.connect(identify, *Form, identifyClicked, f, .{}));
            view.form_signals.add(exact.as(object.Object), object.Object.signals.notify.connect(exact.as(object.Object), *View, exactChanged, view, .{ .detail = "expanded" }));
            view.form_signals.add(more.as(object.Object), object.Object.signals.notify.connect(more.as(object.Object), *View, moreChanged, view, .{ .detail = "expanded" }));
            for (heads, 0..) |h, i| if (std.mem.eql(u8, model.connector(h.output), std.mem.sliceTo(&view.display_selected, 0))) {
                f.selected = i;
            };
            if (view.client.review) |review| {
                const document = m.parse(a, review, m.max_response) catch .null;
                f.projection = m.get(document, "display");
            }
            try f.refreshControls();
            // Native drawing callbacks must be detached before the view arena is reset.
            view.display_canvas = canvas;
            view.display_advanced_box = advanced;
            const declarations = gtk.Expander.new("Display declarations, profiles and custom settings");
            advanced.append(declarations.as(gtk.Widget));
            const details = w.column(12);
            declarations.setChild(details.as(gtk.Widget));
            @import("aqueous_display_editor.zig").For(View).render(view, details, base) catch {
                details.append(w.label("The draft cannot be edited as declarations. Open Aqueous Advanced to correct the draft JSON.", "pearl-secondary").as(gtk.Widget));
            };
            for (outputs) |out| {
                try view.inventory(advanced, out, "actual", "Display information");
                try view.inventory(advanced, out, "configured", "Explicit and inherited settings");
                try view.inventory(advanced, out, "support", "Preview availability");
            }
            try view.inventory(advanced, base, "display_model", "All display declarations and precedence");
            const maintenance = w.flow(3);
            advanced.append(maintenance.as(gtk.Widget));
            for ([_][*:0]const u8{ "Refresh", "Validate", "Rebase draft" }, 0..) |label, i| {
                const button = gtk.Button.newWithLabel(label);
                maintenance.insert(button.as(gtk.Widget), -1);
                const choice = try a.create(Choice);
                choice.* = .{ .form = f, .index = i };
                view.form_signals.add(button.as(object.Object), gtk.Button.signals.clicked.connect(button, *Choice, maintain, choice, .{}));
            }
        }
        fn exactChanged(obj: *object.Object, _: *object.ParamSpec, v: *View) callconv(.c) void {
            v.display_exact = object.ext.cast(gtk.Expander, obj).?.getExpanded() != 0;
        }
        fn moreChanged(obj: *object.Object, _: *object.ParamSpec, v: *View) callconv(.c) void {
            v.display_more = object.ext.cast(gtk.Expander, obj).?.getExpanded() != 0;
        }
        fn maintain(_: *gtk.Button, c: *Choice) callconv(.c) void {
            const v = c.form.view;
            switch (c.index) {
                0 => v.client.begin(.refresh) catch |e| v.fail(e),
                1 => v.client.begin(.validate) catch |e| v.fail(e),
                else => {
                    v.client.rebase() catch |e| v.fail(e);
                    v.update();
                },
            }
        }
        fn identifyClicked(_: *gtk.Button, f: *Form) callconv(.c) void {
            f.view.client.identify() catch |e| f.view.fail(e);
        }
        fn select(_: *gtk.Button, c: *Choice) callconv(.c) void {
            if (!c.form.loading) c.form.choose(c.index);
        }
        fn spun(_: *gtk.SpinButton, b: *Binding) callconv(.c) void {
            edit(b);
        }
        fn toggled(_: *gtk.CheckButton, b: *Binding) callconv(.c) void {
            edit(b);
        }
        fn changed(_: *object.Object, _: *object.ParamSpec, b: *Binding) callconv(.c) void {
            edit(b);
        }
        fn edit(b: *Binding) void {
            if (b.form.loading) return;
            b.form.input_error = null;
            change(b) catch |err| {
                b.form.input_error = switch (err) {
                    error.AmbiguousDisplayDraft => "Multiple staged declarations match this display. Resolve them under More display options.",
                    error.ActiveDisplayProfileNeedsAdvancedEditor => "This display uses a shared or ambiguous profile. Open More display options to edit its declaration.",
                    error.ConflictingEdits => "Advanced file edits overlap this display. Resolve them in Advanced before changing this control.",
                    error.SelectAnotherDisplay => "Choose a different enabled display under Next to.",
                    else => @errorName(err),
                };
            };
            b.form.sync();
        }
        fn change(b: *Binding) !void {
            const f = b.form;
            const old_side = f.side.getSelected();
            const other_index = f.relativeIndex();
            const old_rect = f.heads[f.selected].rect;
            const other_rect = f.heads[other_index].rect;
            const start = if (old_side < 2) old_rect.y else old_rect.x;
            const end = start + (if (old_side < 2) old_rect.height else old_rect.width);
            const ref_start = if (old_side < 2) other_rect.y else other_rect.x;
            const ref_end = ref_start + (if (old_side < 2) other_rect.height else other_rect.width);
            const alignment: ?usize = if (@abs(start - ref_start) < 1) 0 else if (@abs(end - ref_end) < 1) 2 else if (@abs(start + end - ref_start - ref_end) < 2) 1 else null;
            switch (b.key) {
                .enabled => try f.stage("enabled", .{ .bool = f.enabled.getActive() != 0 }),
                .hdr => {
                    try f.stage("hdr", .{ .bool = f.hdr.getActive() != 0 });
                    if (f.hdr.getActive() != 0 and !staged(f, "hdr_level") and m.get(m.get(m.get(f.output(), "configured"), "hdr_level"), "value") == .null) try f.stage("hdr_level", .{ .string = "auto" });
                },
                .scale => try f.stage("scale", .{ .float = f.scales[@min(f.scales.len - 1, f.scale.getSelected())] / 100 }),
                .transform => try f.stage("transform", .{ .string = ([_][]const u8{ "normal", "90", "180", "270", "flipped", "flipped-90", "flipped-180", "flipped-270" })[@min(7, f.transform.getSelected())] }),
                .resolution => {
                    const res = f.resolutions[@min(f.resolutions.len - 1, f.resolution.getSelected())];
                    var selected: []const u8 = res;
                    for (m.list(m.get(f.output(), "modes"))) |mode| {
                        const text = try model.modeText(f.alloc(), mode);
                        if (std.mem.startsWith(u8, text, res) and (text.len == res.len or text[res.len] == '@')) {
                            selected = text;
                            break;
                        }
                    }
                    try f.stage("mode", .{ .string = selected });
                },
                .refresh => try f.stage("mode", .{ .string = f.rates[@min(f.rates.len - 1, f.refresh.getSelected())] }),
                .x, .y => {
                    var r = f.heads[f.selected].rect;
                    r.x = f.x.getValue();
                    r.y = f.y.getValue();
                    try f.position(r);
                },
                .side, .relative => if (f.side.getSelected() < 4) try place(f, 1),
                .mirror => {
                    const i = f.mirror.getSelected();
                    if (i > f.mirror_targets.len) return error.SelectAnotherDisplay;
                    try f.stage("mirror_of", .{ .string = if (i == 0) "" else model.connector(f.heads[f.mirror_targets[i - 1]].output) });
                },
                .hdr_level => try f.stage("hdr_level", .{ .string = ([_][]const u8{ "auto", "100", "400", "1000" })[@min(3, f.hdr_level.getSelected())] }),
                .sdr_white => {
                    const white = f.whites[@min(f.whites.len - 1, f.sdr_white.getSelected())];
                    try f.stage("sdr_white_level", if (white == 0) .null else .{ .float = white });
                },
            }
            if ((b.key == .scale or b.key == .transform or b.key == .resolution or b.key == .refresh) and old_side < 4 and other_index != f.selected and alignment != null) {
                var rect = model.geometry(f.base, f.draft, f.output());
                rect.place(other_rect, old_side, alignment.?);
                try f.position(rect);
            }
        }
        fn place(f: *Form, alignment: usize) !void {
            const other = f.relativeIndex();
            if (other == f.selected) return error.SelectAnotherDisplay;
            var r = f.heads[f.selected].rect;
            r.place(f.heads[other].rect, @min(3, f.side.getSelected()), alignment);
            try f.position(r);
        }
        fn aligned(_: *gtk.Button, c: *Choice) callconv(.c) void {
            place(c.form, c.index) catch |err| c.form.view.fail(err);
            c.form.sync();
        }
        fn automatic(_: *gtk.Button, f: *Form) callconv(.c) void {
            f.stage("hdr_level", .{ .string = "auto" }) catch |e| f.view.fail(e);
            f.stage("sdr_white_level", .null) catch |e| f.view.fail(e);
            f.sync();
        }
        fn arrange(_: *gtk.Button, f: *Form) callconv(.c) void {
            const selected = f.selected;
            var x: f64 = 0;
            for (f.heads, 0..) |h, i| {
                if (!h.enabled) continue;
                f.selected = i;
                var r = h.rect;
                r.x = x;
                r.y = 0;
                f.stage("mirror_of", .{ .string = "" }) catch |e| f.view.fail(e);
                f.position(r) catch |e| f.view.fail(e);
                x += r.width;
            }
            f.selected = selected;
            f.sync();
        }
        fn rounded(cr: *cairo.Context, x: f64, y: f64, width: f64, height: f64) void {
            const r = @min(6, @min(width, height) / 2);
            cr.newSubPath();
            cr.arc(x + width - r, y + r, r, -std.math.pi / 2.0, 0);
            cr.arc(x + width - r, y + height - r, r, 0, std.math.pi / 2.0);
            cr.arc(x + r, y + height - r, r, std.math.pi / 2.0, std.math.pi);
            cr.arc(x + r, y + r, r, std.math.pi, 3 * std.math.pi / 2.0);
            cr.closePath();
        }
        fn centered(cr: *cairo.Context, text: [:0]const u8, x: f64, y: f64) void {
            var extents: cairo.TextExtents = undefined;
            cr.textExtents(text, &extents);
            cr.moveTo(x - extents.width / 2 - extents.x_bearing, y);
            cr.showText(text);
        }
        fn draw(area: *gtk.DrawingArea, cr: *cairo.Context, width: c_int, height: c_int, data: ?*anyopaque) callconv(.c) void {
            const f: *Form = @ptrCast(@alignCast(data.?));
            var color: gdk.RGBA = undefined;
            area.as(gtk.Widget).getColor(&color);
            var left: f64 = 0;
            var top: f64 = 0;
            var right: f64 = 1;
            var bottom: f64 = 1;
            var first = true;
            for (f.heads) |h| {
                if (!h.enabled) continue;
                const r = h.rect;
                if (first) {
                    left = r.x;
                    top = r.y;
                    right = r.x + r.width;
                    bottom = r.y + r.height;
                    first = false;
                } else {
                    left = @min(left, r.x);
                    top = @min(top, r.y);
                    right = @max(right, r.x + r.width);
                    bottom = @max(bottom, r.y + r.height);
                }
            }
            if (!f.dragging) {
                f.ratio = @max(0.00001, @min((@as(f64, @floatFromInt(width)) - 40) / @max(1, right - left), (@as(f64, @floatFromInt(height)) - 32) / @max(1, bottom - top)));
                f.origin_x = (@as(f64, @floatFromInt(width)) - (right - left) * f.ratio) / 2 - left * f.ratio;
                f.origin_y = (@as(f64, @floatFromInt(height)) - (bottom - top) * f.ratio) / 2 - top * f.ratio;
            }
            cr.setSourceRgba(color.f_red, color.f_green, color.f_blue, 0.12);
            var x: f64 = 8;
            while (x < @as(f64, @floatFromInt(width))) : (x += 20) {
                var y: f64 = 8;
                while (y < @as(f64, @floatFromInt(height))) : (y += 20) {
                    cr.rectangle(x, y, 1, 1);
                    cr.fill();
                }
            }
            for (f.heads, 0..) |h, i| {
                if (!h.enabled) continue;
                const r = h.rect;
                const px = f.origin_x + r.x * f.ratio;
                const py = f.origin_y + r.y * f.ratio;
                const rw = @max(12, r.width * f.ratio);
                const rh = @max(12, r.height * f.ratio);
                cr.setSourceRgba(if (i == f.selected) 0.38 else 0.28, if (i == f.selected) 0.29 else 0.26, if (i == f.selected) 0.53 else 0.34, 1);
                rounded(cr, px, py, rw, rh);
                cr.fill();
                cr.setSourceRgba(0.81, 0.74, 1, if (i == f.selected) 1 else 0.45);
                cr.setLineWidth(if (i == f.selected) 2 else 1);
                rounded(cr, px, py, rw, rh);
                cr.stroke();
                cr.setSourceRgba(1, 1, 1, 1);
                cr.setFontSize(26);
                var buffer: [64]u8 = undefined;
                const number = std.fmt.bufPrintZ(&buffer, "{d}", .{h.number}) catch "";
                centered(cr, number, px + rw / 2, py + rh / 2);
                if (rw > 100 and rh > 65) {
                    cr.setFontSize(11);

                    const name = std.fmt.bufPrintZ(&buffer, "{s}", .{model.connector(h.output)}) catch "Display";
                    centered(cr, name, px + rw / 2, py + rh / 2 + 24);
                    if (rh > 100) {
                        cr.setFontSize(10);
                        const resolution = std.fmt.bufPrintZ(&buffer, "{d:.0} × {d:.0}", .{ r.width * model.num(model.value(f.base, f.draft, h.output, "scale"), 1), r.height * model.num(model.value(f.base, f.draft, h.output, "scale"), 1) }) catch "";
                        centered(cr, resolution, px + rw / 2, py + rh / 2 + 40);
                    }
                }
            }
        }
        fn dragBegin(_: *gtk.GestureDrag, x: f64, y: f64, f: *Form) callconv(.c) void {
            for (f.heads, 0..) |h, i| {
                if (!h.enabled) continue;
                const px = f.origin_x + h.rect.x * f.ratio;
                const py = f.origin_y + h.rect.y * f.ratio;
                if (x >= px and x <= px + h.rect.width * f.ratio and y >= py and y <= py + h.rect.height * f.ratio) {
                    f.choose(i);
                    f.start = h.rect;
                    f.dragging = m.str(f.val("mirror_of")).len == 0;
                    _ = f.canvas.as(gtk.Widget).grabFocus();
                    break;
                }
            }
        }
        fn dragUpdate(_: *gtk.GestureDrag, x: f64, y: f64, f: *Form) callconv(.c) void {
            if (!f.dragging) return;
            f.heads[f.selected].rect.x = @round(f.start.x + x / f.ratio);
            f.heads[f.selected].rect.y = @round(f.start.y + y / f.ratio);
            f.canvas.as(gtk.Widget).queueDraw();
        }
        fn dragEnd(_: *gtk.GestureDrag, _: f64, _: f64, f: *Form) callconv(.c) void {
            if (!f.dragging) return;
            f.dragging = false;
            var r = f.heads[f.selected].rect;
            for (f.heads, 0..) |h, i| {
                if (i != f.selected and h.enabled) r.snap(h.rect, 18 / f.ratio);
            }
            f.position(r) catch |e| f.view.fail(e);
            f.sync();
        }
        fn keyPressed(_: *gtk.EventControllerKey, key: c_uint, _: c_uint, mods: gdk.ModifierType, f: *Form) callconv(.c) c_int {
            if (!f.heads[f.selected].enabled or m.str(f.val("mirror_of")).len > 0) return 0;
            var r = f.heads[f.selected].rect;
            const step: f64 = if (mods.shift_mask) 1 else 10;
            switch (key) {
                gdk.KEY_Left => r.x -= step,
                gdk.KEY_Right => r.x += step,
                gdk.KEY_Up => r.y -= step,
                gdk.KEY_Down => r.y += step,
                else => return 0,
            }
            f.position(r) catch |e| f.view.fail(e);
            f.sync();
            return 1;
        }
    };
}
