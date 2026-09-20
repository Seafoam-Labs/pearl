const std = @import("std");
const u = @import("ui/widgets.zig");
const c = u.c;
const m = @import("core/model.zig");
const linux = @import("collectors/linux.zig");
const io = @import("platform/io.zig");
const Table = @import("ui/table.zig").Table;
const Graph = @import("ui/graph.zig").Graph;
const Services = @import("platform/services.zig").Controller;
const Preferences = @import("platform/preferences.zig").Preferences;
const Target = @import("platform/actions.zig").Target;
const test_hooks = @import("build_options").test_hooks;
const titles = [_][]const u8{ "Overview", "CPU", "Memory", "Disks", "Network", "GPU", "Sensors", "Processes", "Services" };
const symbols = [_][*:0]const u8{ "view-grid-symbolic", "computer-symbolic", "media-flash-symbolic", "drive-harddisk-symbolic", "network-wireless-symbolic", "video-display-symbolic", "weather-clear-symbolic", "view-list-symbolic", "preferences-system-symbolic" };
const Field = enum { cpu, io_wait, frequency, processes, threads, uptime, mem_used, mem_available, mem_cached, swap, disk_read, disk_write, disk_busy, disk_latency, disk_size, net_receive, net_send, net_rx, net_tx, net_speed, gpu_usage, gpu_used, gpu_total, gpu_temp, gpu_power, gpu_encode, gpu_decode, gpu_frequency, sensor, proc_cpu, proc_memory, proc_read, proc_write, proc_threads, proc_pss, proc_command };
const Binding = struct { widget: u.W, field: Field, index: usize = 0 };
pub const App = struct {
    application: *c.GtkApplication,
    window: u.W,
    root: u.W,
    sidebar: u.W,
    popup: u.W,
    nav_toggle: u.W,
    toolbar: u.W,
    title: u.W,
    pause_button: u.W,
    interval: u.W,
    status: u.W,
    body: u.W,
    content: u.W,
    search: u.W,
    nvml: @import("platform/nvml.zig").Provider = .{},
    prefs: Preferences,
    worker: linux.Worker = .{},
    snapshot: ?*m.Snapshot = null,
    closed: bool = false,
    timer: c_uint = 0,
    processes: *Table = undefined,
    services_table: *Table = undefined,
    services: Services = undefined,
    page: u32 = 0,
    paused: bool = false,
    summary: bool = false,
    logical: bool = false,
    building: bool = false,
    narrow: bool = false,
    bindings: std.ArrayList(Binding) = .empty,
    drawings: std.ArrayList(u.W) = .empty,
    histories: std.StringHashMap(*m.History),
    empty_history: m.History = .{},
    device_keys: [3]m.Path = @splat(.{}),
    nav_buttons: [18]u.W = undefined,
    device_combo: ?u.W = null,
    details: ?u.W = null,
    detail_id: m.Identity = .{},
    detail_service: m.Text(256) = .{},
    dialog: ?u.W = null,
    target: ?Target = null,
    force: bool = false,
    service_action: m.Name = .{},
    service_target: m.Text(256) = .{},
    service_generation: u64 = 0,
    notice: m.Text(512) = .{},
    notice_until: i64 = 0,
    last_shape: u64 = 0,
    services_available: bool = false,
    services_note: ?u.W = null,
    top_labels: [3]?u.W = @splat(null),
    top_ids: [3]m.Identity = @splat(.{}),
    last_update_us: i64 = 0,
    fixture_count: usize = 0,
    pref_widgets: [12]?u.W = @splat(null),
    visible_labels: usize = 0,
    pub fn create(application: *c.GtkApplication, prefs: Preferences) *App {
        const self = u.a.create(App) catch unreachable;
        const window = c.gtk_application_window_new(application).?;
        c.gtk_window_set_title(u.cast(c.GtkWindow, window), "Dome");
        c.gtk_window_set_icon_name(u.cast(c.GtkWindow, window), @import("main.zig").identity);
        c.gtk_window_set_default_size(u.cast(c.GtkWindow, window), prefs.width, prefs.height);
        u.class(window, "dome-root");
        const root = u.box(c.GTK_ORIENTATION_VERTICAL, 0, null);
        c.gtk_window_set_child(u.cast(c.GtkWindow, window), root);
        const header = c.gtk_header_bar_new().?;
        const brand = u.box(c.GTK_ORIENTATION_HORIZONTAL, 8, null);
        u.append(brand, u.image("utilities-system-monitor-symbolic", 20));
        u.append(brand, u.label("Dome", "title"));
        c.gtk_header_bar_pack_start(u.cast(c.GtkHeaderBar, header), brand);
        c.gtk_header_bar_set_title_widget(u.cast(c.GtkHeaderBar, header), u.label("System monitor", "secondary"));
        c.gtk_window_set_titlebar(u.cast(c.GtkWindow, window), header);
        const work = u.box(c.GTK_ORIENTATION_HORIZONTAL, 0, null);
        c.gtk_widget_set_vexpand(work, 1);
        u.append(root, work);
        const nav = u.box(c.GTK_ORIENTATION_VERTICAL, 2, "sidebar");
        const sidebar = u.scroll(nav);
        c.gtk_widget_set_size_request(sidebar, 208, -1);
        c.gtk_widget_set_hexpand(sidebar, 0);
        u.append(work, sidebar);
        const main = u.box(c.GTK_ORIENTATION_VERTICAL, 0, null);
        u.expand(main);
        u.append(work, main);
        const toolbar = u.box(c.GTK_ORIENTATION_HORIZONTAL, 8, "toolbar");
        u.append(main, toolbar);
        const nav_toggle = c.gtk_menu_button_new().?;
        c.gtk_menu_button_set_icon_name(u.cast(c.GtkMenuButton, nav_toggle), "sidebar-show-symbolic");
        c.gtk_widget_set_tooltip_text(nav_toggle, "Navigation");
        u.append(toolbar, nav_toggle);
        const popup = c.gtk_popover_new().?;
        const popup_nav = u.box(c.GTK_ORIENTATION_VERTICAL, 2, "sidebar");
        c.gtk_popover_set_child(u.cast(c.GtkPopover, popup), popup_nav);
        c.gtk_menu_button_set_popover(u.cast(c.GtkMenuButton, nav_toggle), popup);
        const title = u.label("Overview", "title");
        u.expand(title);
        u.append(toolbar, title);
        const pause = u.iconButton("media-playback-pause-symbolic", "Pause sampling · Ctrl+P");
        u.append(toolbar, pause);
        const intervals = [_]?[*:0]const u8{ "0.5 s", "1 s", "2 s", "5 s", null };
        const interval = c.gtk_drop_down_new_from_strings(@ptrCast(&intervals)).?;
        u.append(toolbar, interval);
        const search_button = u.iconButton("system-search-symbolic", "Search · Ctrl+F");
        u.append(toolbar, search_button);
        const preferences = u.iconButton("open-menu-symbolic", "Preferences");
        u.append(toolbar, preferences);
        const search = c.gtk_search_entry_new().?;
        c.gtk_search_entry_set_search_delay(u.cast(c.GtkSearchEntry, search), 60);
        c.gtk_search_entry_set_placeholder_text(u.cast(c.GtkSearchEntry, search), "Search name, PID or user ID…");
        u.margin(search, 12);
        u.append(main, search);
        c.gtk_widget_set_visible(search, 0);
        const content = u.box(c.GTK_ORIENTATION_VERTICAL, 16, "content");
        const body = u.scroll(content);
        u.append(main, body);
        const status = u.label("Collecting the first sample…", "status");
        u.ellipsize(status);
        u.append(main, status);
        self.* = .{ .application = application, .window = window, .root = root, .sidebar = sidebar, .popup = popup, .nav_toggle = nav_toggle, .toolbar = toolbar, .title = title, .pause_button = pause, .interval = interval, .status = status, .body = body, .content = content, .search = search, .prefs = prefs, .page = prefs.page, .histories = .init(u.a) };
        for ([_]u.W{ nav, popup_nav }, 0..) |parent, group| {
            u.append(parent, u.label("MONITOR", "eyebrow"));
            for (titles, 0..) |name, index| {
                if (index == 7) u.append(parent, u.label("SYSTEM", "eyebrow"));
                const button = u.button("");
                const row = u.box(c.GTK_ORIENTATION_HORIZONTAL, 12, null);
                u.append(row, u.image(symbols[index], 18));
                u.append(row, u.label(name, null));
                c.gtk_button_set_child(u.cast(c.GtkButton, button), row);
                u.class(button, "nav");
                u.append(parent, button);
                self.bindAction(button, @intCast(index));
                self.nav_buttons[group * 9 + index] = button;
            }
            const spacer = u.box(c.GTK_ORIENTATION_VERTICAL, 0, null);
            c.gtk_widget_set_vexpand(spacer, 1);
            u.append(parent, spacer);
            const host = std.mem.span(c.g_get_host_name());
            const host_label = u.label(host, "secondary");
            u.ellipsize(host_label);
            u.margin(host_label, 10);
            u.append(parent, host_label);
        }
        self.bindAction(pause, 9);
        self.bindAction(preferences, 10);
        self.bindAction(search_button, 11);
        u.connect(interval, "notify::selected", &intervalChanged, self);
        u.connect(search, "search-changed", &searchChanged, self);
        u.connect(window, "close-request", &closeRequested, self);
        const keys = c.gtk_event_controller_key_new().?;
        u.connect(keys, "key-pressed", &keyPressed, self);
        c.gtk_event_controller_set_propagation_phase(keys, c.GTK_PHASE_CAPTURE);
        c.gtk_widget_add_controller(window, keys);
        self.processes = Table.create(false, self, processSelected);
        self.services_table = Table.create(true, self, serviceSelected);
        if (test_hooks) {
            const requested = c.g_getenv("DOME_TEST_PROCESSES");
            if (requested != null) self.fixture_count = @min(32768, std.fmt.parseInt(usize, std.mem.span(requested), 10) catch 0);
        }
        self.services = .{ .changed = servicesChanged, .context = self };
        self.services.init();
        self.narrow = prefs.width < 760;
        if (self.narrow) u.class(self.window, "narrow");
        c.gtk_widget_set_visible(self.nav_toggle, @intFromBool(self.narrow));
        c.gtk_column_view_sort_by_column(u.cast(c.GtkColumnView, self.processes.view), self.processes.columns[prefs.sort_column].widget, if (prefs.sort_descending) c.GTK_SORT_DESCENDING else c.GTK_SORT_ASCENDING);
        self.processes.column_mask = prefs.columns;
        self.processes.narrow(self.narrow);
        self.applyTheme();
        self.worker.interval = prefs.interval;
        self.worker.start() catch self.message("Could not start the system collector");
        self.buildPage();
        self.timer = c.g_timeout_add(200, tick, self);
        c.gtk_window_present(u.cast(c.GtkWindow, window));
        return self;
    }
    pub fn destroy(self: *App) void {
        self.closed = true;
        if (self.timer != 0) {
            _ = c.g_source_remove(self.timer);
            self.timer = 0;
        }
        if (self.target) |t| {
            t.close();
            self.target = null;
        }
        self.worker.stop();
        if (test_hooks) c.g_print("DOME_SHUTDOWN collector stopped\n");
        self.services.deinit();
        if (test_hooks) c.g_print("DOME_SHUTDOWN services stopped\n");
        self.nvml.deinit();
        if (test_hooks) c.g_print("DOME_SHUTDOWN helpers stopped\n");
        self.processes.destroy();
        self.services_table.destroy();
        if (self.snapshot) |s| s.unref();
        var it = self.histories.iterator();
        while (it.next()) |entry| {
            u.a.free(entry.key_ptr.*);
            u.a.destroy(entry.value_ptr.*);
        }
        self.histories.deinit();
        self.bindings.deinit(u.a);
        self.drawings.deinit(u.a);
        u.a.destroy(self);
    }
    fn applyTheme(self: *App) void {
        for ([_][*:0]const u8{ "light", "dark", "compact" }) |name| c.gtk_widget_remove_css_class(self.window, name);
        if (!self.prefs.native) u.class(self.window, if (self.prefs.light) "light" else "dark");
        if (self.prefs.compact) u.class(self.window, "compact");
        const i: u32 = if (self.prefs.interval <= 500000) 0 else if (self.prefs.interval <= 1000000) 1 else if (self.prefs.interval <= 2000000) 2 else 3;
        self.building = true;
        c.gtk_drop_down_set_selected(u.cast(c.GtkDropDown, self.interval), i);
        self.building = false;
    }
    fn bindAction(self: *App, button: u.W, command: u32) void {
        c.g_object_set_data(@ptrCast(button), "dome-action", @ptrFromInt(command + 1));
        u.connect(button, "clicked", &clicked, self);
    }
    fn actionButton(self: *App, text: []const u8, command: u32) u.W {
        const w = u.button(text);
        self.bindAction(w, command);
        return w;
    }
    fn message(self: *App, text: []const u8) void {
        self.notice.set(text);
        self.notice_until = io.monotonic() + 6000000;
        u.setLabel(self.status, self.notice.slice());
    }
    fn history(self: *App, key: []const u8) *m.History {
        if (self.histories.get(key)) |h| return h;
        if (self.histories.count() >= 512) return &self.empty_history;
        const h = u.a.create(m.History) catch unreachable;
        h.* = .{};
        const k = u.a.dupe(u8, key) catch unreachable;
        self.histories.put(k, h) catch unreachable;
        return h;
    }
    fn addHistory(self: *App, key: []const u8, time: i64, value: ?f64, second: ?f64) void {
        const h = self.history(key);
        if (h != &self.empty_history) h.add(time, value, second);
    }
    fn record(self: *App, s: *m.Snapshot) void {
        if (s.reset) {
            var it = self.histories.valueIterator();
            while (it.next()) |h| h.*.add(s.time - 1, null, null);
        }
        for (s.cpus, 0..) |cpu, i| {
            if (i > 128) break;
            const key = io.path("cpu:{d}", .{s.cpu_ids[i]});
            self.addHistory(key.slice(), s.time, cpu.usage, null);
        }
        self.addHistory("memory", s.time, if (s.memory.used()) |v| @floatFromInt(v) else null, null);
        for (s.disks) |d| {
            const key = io.path("disk:{s}", .{d.key.slice()});
            self.addHistory(key.slice(), s.time, d.read_rate, d.write_rate);
        }
        for (s.networks) |n| {
            const key = io.path("net:{s}", .{n.key.slice()});
            self.addHistory(key.slice(), s.time, n.receive, n.send);
        }
        for (s.gpus) |raw| {
            const g = self.nvml.resolve(raw);
            const key = io.path("gpu:{s}", .{g.key.slice()});
            self.addHistory(key.slice(), s.time, g.usage, null);
        }
        for (s.sensors) |sensor| {
            const key = io.path("sensor:{s}", .{sensor.key.slice()});
            self.addHistory(key.slice(), s.time, sensor.value, null);
        }
    }
    fn addBinding(self: *App, parent: u.W, field: Field, index: usize, style: ?[*:0]const u8) u.W {
        const widget = u.label("—", style);
        u.ellipsize(widget);
        u.append(parent, widget);
        self.bindings.append(u.a, .{ .widget = widget, .field = field, .index = index }) catch unreachable;
        return widget;
    }
    fn plot(self: *App, parent: u.W, key: []const u8, accent: usize, height: c_int, maximum: ?f64) void {
        const widget = Graph.create(self.history(key), &self.prefs.duration, &self.prefs.light, &self.prefs.native, accent, height, maximum, key);
        u.append(parent, widget);
        self.drawings.append(u.a, widget) catch unreachable;
    }
    fn metric(self: *App, parent: u.W, title: []const u8, field: Field, index: usize) void {
        const box = u.box(c.GTK_ORIENTATION_VERTICAL, 3, "stat");
        u.expand(box);
        u.append(box, u.label(title, "secondary"));
        _ = self.addBinding(box, field, index, "value");
        u.append(parent, box);
    }
    fn heading(self: *App, title: []const u8, subtitle: []const u8) void {
        const label = u.label(title, "heading");
        u.wrap(label);
        u.append(self.content, label);
        if (subtitle.len > 0) {
            const sub = u.label(subtitle, "secondary");
            u.wrap(sub);
            u.append(self.content, sub);
        }
    }
    fn addNote(self: *App, text: []const u8) void {
        const label = u.label(text, "secondary");
        u.wrap(label);
        u.append(self.content, label);
    }
    fn unavailable(self: *App, title: []const u8, text: []const u8) void {
        const box = u.box(c.GTK_ORIENTATION_VERTICAL, 16, "empty");
        c.gtk_widget_set_vexpand(box, 1);
        c.gtk_widget_set_valign(box, c.GTK_ALIGN_CENTER);
        u.append(box, u.image("dialog-information-symbolic", 40));
        const a = u.label(title, "heading");
        u.wrap(a);
        u.append(box, a);
        const b = u.label(text, "secondary");
        u.wrap(b);
        u.append(box, b);
        u.append(box, self.actionButton("Refresh", 12));
        u.append(self.content, box);
    }
    fn buildPage(self: *App) void {
        self.building = true;
        defer self.building = false;
        // Table widgets own a reference, so removing their old scroller does not destroy their model.
        u.clear(self.content);
        self.services_note = null;
        self.bindings.clearRetainingCapacity();
        self.drawings.clearRetainingCapacity();
        self.device_combo = null;
        self.top_labels = @splat(null);
        self.details = null;
        self.detail_id = .{};
        self.detail_service = .{};
        c.gtk_widget_set_visible(self.search, @intFromBool(self.page >= 7 and !self.summary));
        c.gtk_widget_set_visible(self.sidebar, @intFromBool(!self.narrow and !self.summary));
        c.gtk_widget_set_visible(self.toolbar, @intFromBool(!self.summary));
        for (self.nav_buttons, 0..) |button, i| {
            c.gtk_widget_remove_css_class(button, "active");
            if (i % 9 == self.page) u.class(button, "active");
        }
        u.setLabel(self.title, titles[self.page]);
        const s = self.snapshot orelse {
            self.unavailable("Getting to know your system", "Waiting for the first complete sample…");
            return;
        };
        if (self.summary) {
            self.buildSummary(s);
            self.updateBindings();
            return;
        }
        switch (self.page) {
            0 => self.buildOverview(s),
            1 => self.buildCpu(s),
            2 => self.buildMemory(s),
            3 => self.buildDisks(s),
            4 => self.buildNetwork(s),
            5 => self.buildGpu(s),
            6 => self.buildSensors(s),
            7 => self.buildProcesses(),
            8 => self.buildServices(),
            else => {},
        }
        self.updateBindings();
    }
    fn buildOverview(self: *App, s: *m.Snapshot) void {
        self.heading("Your system, at a glance.", s.cpu_name.slice());
        const flow = c.gtk_flow_box_new().?;
        c.gtk_flow_box_set_selection_mode(u.cast(c.GtkFlowBox, flow), c.GTK_SELECTION_NONE);
        c.gtk_flow_box_set_column_spacing(u.cast(c.GtkFlowBox, flow), 12);
        c.gtk_flow_box_set_row_spacing(u.cast(c.GtkFlowBox, flow), 12);
        c.gtk_flow_box_set_min_children_per_line(u.cast(c.GtkFlowBox, flow), 1);
        c.gtk_flow_box_set_max_children_per_line(u.cast(c.GtkFlowBox, flow), if (self.narrow) 2 else 3);
        c.gtk_flow_box_set_homogeneous(u.cast(c.GtkFlowBox, flow), 1);
        u.append(self.content, flow);
        for ([_]struct { title: []const u8, page: u32, field: Field, accent: usize }{ .{ .title = "CPU", .page = 1, .field = .cpu, .accent = 0 }, .{ .title = "Memory", .page = 2, .field = .mem_used, .accent = 1 }, .{ .title = "GPU", .page = 5, .field = .gpu_usage, .accent = 2 }, .{ .title = "Disk read", .page = 3, .field = .disk_read, .accent = 4 }, .{ .title = "Network receive", .page = 4, .field = .net_receive, .accent = 3 }, .{ .title = "Sensor", .page = 6, .field = .sensor, .accent = 5 } }) |card| {
            const button = self.actionButton("", card.page);
            u.class(button, "card");
            const inner = u.box(c.GTK_ORIENTATION_VERTICAL, 7, null);
            c.gtk_button_set_child(u.cast(c.GtkButton, button), inner);
            c.gtk_widget_set_size_request(button, 180, -1);
            u.expand(button);
            const head = u.box(c.GTK_ORIENTATION_HORIZONTAL, 8, null);
            u.append(head, u.image(symbols[card.page], 18));
            u.append(head, u.label(card.title, null));
            u.append(inner, head);
            _ = self.addBinding(inner, card.field, 0, "value");
            var key = io.path("cpu:{d}", .{std.math.maxInt(u32)});
            switch (card.page) {
                2 => key = io.path("memory", .{}),
                3 => {
                    if (s.disks.len > 0) key = io.path("disk:{s}", .{s.disks[0].key.slice()});
                },
                4 => {
                    if (s.networks.len > 0) key = io.path("net:{s}", .{s.networks[0].key.slice()});
                },
                5 => {
                    if (s.gpus.len > 0) key = io.path("gpu:{s}", .{s.gpus[0].key.slice()});
                },
                6 => {
                    if (s.sensors.len > 0) key = io.path("sensor:{s}", .{s.sensors[0].key.slice()});
                },
                else => {},
            }
            self.plot(inner, key.slice(), card.accent, 56, if (card.page == 1 or card.page == 5) 100 else null);
            c.gtk_flow_box_insert(u.cast(c.GtkFlowBox, flow), button, -1);
        }
        const row = u.box(c.GTK_ORIENTATION_HORIZONTAL, 16, null);
        self.metric(row, "Processes", .processes, 0);
        self.metric(row, "Threads", .threads, 0);
        self.metric(row, "Uptime", .uptime, 0);
        u.append(self.content, row);
        u.append(self.content, u.label("Busiest processes", "title"));
        for (0..3) |i| {
            const button = self.actionButton("", @intCast(100 + i));
            const label = u.label("—", null);
            u.ellipsize(label);
            c.gtk_button_set_child(u.cast(c.GtkButton, button), label);
            self.top_labels[i] = label;
            u.append(self.content, button);
        }
        u.append(self.content, self.actionButton("Inspect processes →", 7));
        self.addNote("Disk and network cards show the first listed device. Open each page to choose a device; stacked interfaces are not summed.");
    }
    fn buildCpu(self: *App, s: *m.Snapshot) void {
        if (s.cpus.len == 0) {
            self.unavailable("CPU counters unavailable", "The kernel did not provide readable CPU counters.");
            return;
        }
        self.heading(s.cpu_name.slice(), "Utilization excludes idle and I/O wait. Each logical processor uses a 0–100% scale.");
        u.append(self.content, self.actionButton(if (self.logical) "Show overall CPU" else "Show logical processors", 13));
        if (self.logical) {
            const flow = c.gtk_flow_box_new().?;
            c.gtk_flow_box_set_selection_mode(u.cast(c.GtkFlowBox, flow), c.GTK_SELECTION_NONE);
            c.gtk_flow_box_set_min_children_per_line(u.cast(c.GtkFlowBox, flow), 1);
            c.gtk_flow_box_set_max_children_per_line(u.cast(c.GtkFlowBox, flow), 4);
            c.gtk_flow_box_set_homogeneous(u.cast(c.GtkFlowBox, flow), 1);
            c.gtk_flow_box_set_column_spacing(u.cast(c.GtkFlowBox, flow), 8);
            c.gtk_flow_box_set_row_spacing(u.cast(c.GtkFlowBox, flow), 8);
            u.append(self.content, flow);
            for (s.cpus[1..], 1..) |_, i| {
                if (i > 128) break;
                const box = u.box(c.GTK_ORIENTATION_VERTICAL, 5, "card");
                c.gtk_widget_set_size_request(box, 140, -1);
                const name = io.path("CPU {d}", .{s.cpu_ids[i]});
                u.append(box, u.label(name.slice(), "secondary"));
                _ = self.addBinding(box, .cpu, i, null);
                const key = io.path("cpu:{d}", .{s.cpu_ids[i]});
                self.plot(box, key.slice(), 0, 65, 100);
                c.gtk_flow_box_insert(u.cast(c.GtkFlowBox, flow), box, -1);
            }
        } else {
            const key = io.path("cpu:{d}", .{std.math.maxInt(u32)});
            self.plot(self.content, key.slice(), 0, 230, 100);
        }
        const row = u.box(c.GTK_ORIENTATION_HORIZONTAL, 12, null);
        self.metric(row, "Utilization", .cpu, 0);
        self.metric(row, "CPU 0 speed", .frequency, 0);
        u.append(self.content, row);
        const stats = u.box(c.GTK_ORIENTATION_HORIZONTAL, 12, null);
        self.metric(stats, "Processes", .processes, 0);
        self.metric(stats, "Threads", .threads, 0);
        self.metric(stats, "Uptime", .uptime, 0);
        u.append(self.content, stats);
        const cores = io.path("{d} physical cores · {d} logical processors · Linux CPU counters", .{ s.core_count, s.cpus.len -| 1 });
        self.addNote(cores.slice());
        const cache_note = io.path("CPU 0 cache instances: {s}", .{s.cache.slice()});
        self.addNote(cache_note.slice());
        self.metric(self.content, "I/O wait", .io_wait, 0);
        if (s.base_frequency) |v| {
            const base = io.path("Base frequency: {d:.2} GHz", .{v});
            self.addNote(base.slice());
        }
    }
    fn buildMemory(self: *App, s: *m.Snapshot) void {
        const capacity = io.path("{s} total physical memory", .{u.bytes(@floatFromInt(s.memory.total)).slice()});
        self.heading("Memory", capacity.slice());
        self.plot(self.content, "memory", 1, 240, @floatFromInt(@max(1, s.memory.total)));
        const first = u.box(c.GTK_ORIENTATION_HORIZONTAL, 12, null);
        self.metric(first, "In use", .mem_used, 0);
        self.metric(first, "Available", .mem_available, 0);
        u.append(self.content, first);
        const second = u.box(c.GTK_ORIENTATION_HORIZONTAL, 12, null);
        self.metric(second, "Cached", .mem_cached, 0);
        self.metric(second, "Swap in use", .swap, 0);
        u.append(self.content, second);
        self.addNote("In use = total − available. Available memory includes reclaimable cache. Process memory is RSS; shared pages can appear in more than one process.");
    }
    fn deviceIndex(self: *App, kind: usize) ?usize {
        const s = self.snapshot orelse return null;
        switch (kind) {
            0 => {
                for (s.disks, 0..) |d, i| if (std.mem.eql(u8, d.key.slice(), self.device_keys[0].slice())) return i;
            },
            1 => {
                for (s.networks, 0..) |d, i| if (std.mem.eql(u8, d.key.slice(), self.device_keys[1].slice())) return i;
            },
            2 => {
                for (s.gpus, 0..) |d, i| if (std.mem.eql(u8, d.key.slice(), self.device_keys[2].slice())) return i;
            },
            else => {},
        }
        return null;
    }
    fn deviceSelector(self: *App, kind: usize) void {
        const s = self.snapshot.?;
        const strings = c.gtk_string_list_new(null).?;
        switch (kind) {
            0 => {
                for (s.disks) |d| c.gtk_string_list_append(strings, d.name.z());
                if (self.device_keys[0].len == 0 and s.disks.len > 0) self.device_keys[0] = s.disks[0].key;
            },
            1 => {
                for (s.networks) |d| c.gtk_string_list_append(strings, d.name.z());
                if (self.device_keys[1].len == 0 and s.networks.len > 0) self.device_keys[1] = s.networks[0].key;
            },
            2 => {
                for (s.gpus) |d| c.gtk_string_list_append(strings, d.name.z());
                if (self.device_keys[2].len == 0 and s.gpus.len > 0) self.device_keys[2] = s.gpus[0].key;
            },
            else => {},
        }
        const combo = c.gtk_drop_down_new(@ptrCast(strings), null).?;
        c.gtk_drop_down_set_selected(u.cast(c.GtkDropDown, combo), if (self.deviceIndex(kind)) |i| @intCast(i) else c.GTK_INVALID_LIST_POSITION);
        u.connect(combo, "notify::selected", &deviceChanged, self);
        self.device_combo = combo;
        u.append(self.content, combo);
    }
    fn buildDisks(self: *App, s: *m.Snapshot) void {
        self.deviceSelector(0);
        const index = self.deviceIndex(0) orelse {
            self.unavailable("No disk selected", "The selected device may have been removed. Choose an available device above.");
            return;
        };
        const d = s.disks[index];
        self.heading(d.model.slice(), d.name.slice());
        const key = io.path("disk:{s}", .{d.key.slice()});
        self.plot(self.content, key.slice(), 4, 220, null);
        const first = u.box(c.GTK_ORIENTATION_HORIZONTAL, 12, null);
        self.metric(first, "Read /s · Solid", .disk_read, index);
        self.metric(first, "Write /s · Dashed", .disk_write, index);
        u.append(self.content, first);
        const second = u.box(c.GTK_ORIENTATION_HORIZONTAL, 12, null);
        self.metric(second, "Active time", .disk_busy, index);
        self.metric(second, "Response time", .disk_latency, index);
        u.append(self.content, second);
        self.metric(self.content, "Device capacity", .disk_size, index);
        self.addNote("Mounted local filesystems (all devices)");
        for (s.mounts) |mount| {
            const info = io.path("{s} · {s} · {s} available / {s}", .{ mount.path.slice(), mount.kind.slice(), u.bytes(@floatFromInt(mount.available)).slice(), u.bytes(@floatFromInt(mount.total)).slice() });
            self.addNote(info.slice());
        }
        self.addNote("Activity describes time with I/O in flight; it is not a measurement of maximum device performance. Partitions are excluded from the device list.");
    }
    fn buildNetwork(self: *App, s: *m.Snapshot) void {
        self.deviceSelector(1);
        const index = self.deviceIndex(1) orelse {
            self.unavailable("No interface selected", "The selected interface is unavailable. Choose another interface above.");
            return;
        };
        const n = s.networks[index];
        self.heading(n.name.slice(), n.state.slice());
        const key = io.path("net:{s}", .{n.key.slice()});
        self.plot(self.content, key.slice(), 3, 220, null);
        const first = u.box(c.GTK_ORIENTATION_HORIZONTAL, 12, null);
        self.metric(first, "Receive · Solid", .net_receive, index);
        self.metric(first, "Send · Dashed", .net_send, index);
        u.append(self.content, first);
        const second = u.box(c.GTK_ORIENTATION_HORIZONTAL, 12, null);
        self.metric(second, "Total received", .net_rx, index);
        self.metric(second, "Total sent", .net_tx, index);
        u.append(self.content, second);
        const addresses = io.path("Addresses: {s}\nHardware address: {s}", .{ n.address.slice(), n.mac.slice() });
        self.addNote(addresses.slice());
        self.metric(self.content, "Link speed", .net_speed, index);
        self.addNote("Traffic is measured per interface using Linux counters. Virtual, bridge and physical interfaces can contain overlapping traffic. Graph scale uses bytes per second.");
    }
    fn buildGpu(self: *App, s: *m.Snapshot) void {
        self.deviceSelector(2);
        const index = self.deviceIndex(2) orelse {
            self.unavailable("No GPU metrics available", "No compatible display adapter was discovered. Other monitoring pages remain available.");
            return;
        };
        const g = self.nvml.resolve(s.gpus[index]);
        self.heading(g.name.slice(), g.driver.slice());
        const key = io.path("gpu:{s}", .{g.key.slice()});
        self.plot(self.content, key.slice(), 2, 220, 100);
        const first = u.box(c.GTK_ORIENTATION_HORIZONTAL, 12, null);
        self.metric(first, "Utilization", .gpu_usage, index);
        self.metric(first, "Device memory", .gpu_used, index);
        u.append(self.content, first);
        const second = u.box(c.GTK_ORIENTATION_HORIZONTAL, 12, null);
        self.metric(second, "Temperature", .gpu_temp, index);
        self.metric(second, "Power", .gpu_power, index);
        u.append(self.content, second);
        const video = u.box(c.GTK_ORIENTATION_HORIZONTAL, 12, null);
        self.metric(video, "Video encode", .gpu_encode, index);
        self.metric(video, "Video decode", .gpu_decode, index);
        u.append(self.content, video);
        const capacity = u.box(c.GTK_ORIENTATION_HORIZONTAL, 12, null);
        self.metric(capacity, "Memory capacity", .gpu_total, index);
        self.metric(capacity, "Clock", .gpu_frequency, index);
        u.append(self.content, capacity);
        self.addNote("A dash means the driver does not expose that metric or permission is unavailable. Visible client usage is never presented as device-wide utilization.");
    }
    fn buildSensors(self: *App, s: *m.Snapshot) void {
        self.heading("Thermals & fans", "Read-only readings exposed by Linux hwmon");
        if (s.sensors.len == 0) {
            self.unavailable("No sensors available", "This system does not expose readable temperature or fan sensors.");
            return;
        }
        for (s.sensors, 0..) |sensor, i| {
            const card = u.box(c.GTK_ORIENTATION_VERTICAL, 8, "card");
            const title = u.label(sensor.name.slice(), null);
            u.wrap(title);
            u.append(card, title);
            _ = self.addBinding(card, .sensor, i, "value");
            const key = io.path("sensor:{s}", .{sensor.key.slice()});
            self.plot(card, key.slice(), if (sensor.fan) 3 else 5, 70, null);
            u.append(self.content, card);
        }
    }
    fn tableHost(self: *App, table: *Table) void {
        const row = u.box(c.GTK_ORIENTATION_HORIZONTAL, 14, null);
        c.gtk_widget_set_vexpand(row, 1);
        const scroll = u.scroll(table.view);
        c.gtk_scrolled_window_set_min_content_height(u.cast(c.GtkScrolledWindow, scroll), 420);
        u.append(row, scroll);
        const details = u.box(c.GTK_ORIENTATION_VERTICAL, 8, "detail");
        c.gtk_widget_set_size_request(details, 224, -1);
        c.gtk_widget_set_valign(details, c.GTK_ALIGN_START);
        c.gtk_widget_set_visible(details, @intFromBool(c.gtk_widget_get_width(self.window) >= 980));
        u.append(row, details);
        self.details = details;
        u.append(self.content, row);
    }
    fn buildProcesses(self: *App) void {
        const toolbar = u.box(c.GTK_ORIENTATION_HORIZONTAL, 8, null);
        u.append(toolbar, self.actionButton(if (self.processes.grouped) "Raw processes" else "Group applications", 14));
        u.append(toolbar, self.actionButton(if (self.processes.mine) "Show all users" else "My processes", 15));
        u.append(toolbar, self.actionButton("Details", 16));
        u.append(self.content, toolbar);
        self.tableHost(self.processes);
        self.updateDetails(false);
        self.addNote("CPU uses total machine capacity by default. Memory is RSS. Application groups use cgroup scopes; uncertain processes stay separate.");
    }
    fn buildServices(self: *App) void {
        const toolbar = u.box(c.GTK_ORIENTATION_HORIZONTAL, 8, null);
        u.append(toolbar, self.actionButton(if (self.services.system) "Switch to user services" else "Switch to system services", 17));
        u.append(toolbar, self.actionButton("Refresh", 18));
        u.append(toolbar, self.actionButton("Details", 16));
        u.append(self.content, toolbar);
        if (!self.services.available) {
            self.unavailable(if (self.services.loading) "Loading services…" else "Services aren’t available", self.services.message.slice());
            return;
        }
        const note = u.label(self.services.message.slice(), "secondary");
        self.services_note = note;
        u.wrap(note);
        u.append(self.content, note);
        self.tableHost(self.services_table);
        self.updateDetails(false);
    }
    fn buildSummary(self: *App, s: *m.Snapshot) void {
        self.heading("Dome", std.mem.span(c.g_get_host_name()));
        const definitions = [_]struct { title: []const u8, field: Field, key: []const u8 }{ .{ .title = "CPU", .field = .cpu, .key = "cpu:4294967295" }, .{ .title = "Memory", .field = .mem_used, .key = "memory" }, .{ .title = "GPU", .field = .gpu_usage, .key = "" }, .{ .title = "Disk read", .field = .disk_read, .key = "" }, .{ .title = "Network receive", .field = .net_receive, .key = "" } };
        _ = s;
        for (definitions) |d| {
            const row = u.box(c.GTK_ORIENTATION_HORIZONTAL, 12, "card");
            const name = u.label(d.title, null);
            u.expand(name);
            u.append(row, name);
            _ = self.addBinding(row, d.field, 0, "title");
            u.append(self.content, row);
        }
        const controls = u.box(c.GTK_ORIENTATION_HORIZONTAL, 8, null);
        u.append(controls, self.actionButton(if (self.paused) "Resume" else "Pause", 9));
        u.append(controls, self.actionButton("Full monitor", 19));
        u.append(self.content, controls);
    }
    fn numberText(value: ?f64, unit: []const u8) m.Text(512) {
        if (value) |v| {
            const text = io.path("{d:.1}{s}", .{ v, unit });
            return m.Text(512).init(text.slice());
        }
        return m.Text(512).init("—");
    }
    fn byteText(value: ?f64, rate: bool) m.Text(512) {
        if (value) |v| {
            const text = io.path("{s}{s}", .{ u.bytes(v).slice(), if (rate) "/s" else "" });
            return m.Text(512).init(text.slice());
        }
        return m.Text(512).init("—");
    }
    fn metricText(self: *App, field: Field, index: usize) m.Text(512) {
        const s = self.snapshot orelse return m.Text(512).init("—");
        switch (field) {
            .io_wait => return numberText(if (index < s.cpus.len) s.cpus[index].io_wait else null, "%"),
            .cpu => return numberText(if (index < s.cpus.len) s.cpus[index].usage else null, "%"),
            .frequency => return numberText(s.frequency, " GHz"),
            .processes => {
                const text = io.path("{d}", .{s.processes.len});
                return m.Text(512).init(text.slice());
            },
            .threads => {
                var total: u64 = 0;
                for (s.processes) |p| total +|= p.threads;
                const text = io.path("{d}", .{total});
                return m.Text(512).init(text.slice());
            },
            .uptime => {
                const seconds: u64 = @intFromFloat(s.uptime);
                const text = io.path("{d} h {d} m", .{ seconds / 3600, seconds % 3600 / 60 });
                return m.Text(512).init(text.slice());
            },
            .mem_used => return byteText(if (s.memory.used()) |v| @floatFromInt(v) else null, false),
            .mem_available => return byteText(if (s.memory.available) |v| @floatFromInt(v) else null, false),
            .mem_cached => return byteText(@floatFromInt(s.memory.cached), false),
            .swap => return byteText(@floatFromInt(s.memory.swap_total -| s.memory.swap_free), false),
            .disk_read, .disk_write, .disk_busy, .disk_latency, .disk_size => {
                if (index >= s.disks.len) return m.Text(512).init("—");
                const d = s.disks[index];
                return switch (field) {
                    .disk_read => byteText(d.read_rate, true),
                    .disk_write => byteText(d.write_rate, true),
                    .disk_busy => numberText(d.activity, "%"),
                    .disk_latency => numberText(d.latency, " ms"),
                    .disk_size => byteText(@floatFromInt(d.size), false),
                    else => unreachable,
                };
            },
            .net_receive, .net_send, .net_rx, .net_tx, .net_speed => {
                if (index >= s.networks.len) return m.Text(512).init("—");
                const n = s.networks[index];
                return switch (field) {
                    .net_receive, .net_send => blk: {
                        const v = if (field == .net_receive) n.receive else n.send;
                        break :blk if (self.prefs.bits) numberText(if (v) |x| x * 8 / 1e6 else null, " Mbit/s") else byteText(v, true);
                    },
                    .net_rx => byteText(@floatFromInt(n.rx), false),
                    .net_tx => byteText(@floatFromInt(n.tx), false),
                    .net_speed => numberText(if (n.speed) |v| v / 1e6 else null, " Mbit/s"),
                    else => unreachable,
                };
            },
            .gpu_usage, .gpu_used, .gpu_total, .gpu_temp, .gpu_power, .gpu_encode, .gpu_decode, .gpu_frequency => {
                if (index >= s.gpus.len) return m.Text(512).init("—");
                const g = self.nvml.resolve(s.gpus[index]);
                return switch (field) {
                    .gpu_usage => numberText(g.usage, "%"),
                    .gpu_used => byteText(g.used, false),
                    .gpu_total => byteText(g.total, false),
                    .gpu_temp => numberText(g.temp, " °C"),
                    .gpu_power => numberText(g.power, " W"),
                    .gpu_encode => numberText(g.encode, "%"),
                    .gpu_decode => numberText(g.decode, "%"),
                    .gpu_frequency => numberText(g.frequency, " MHz"),
                    else => unreachable,
                };
            },
            .sensor => {
                if (index >= s.sensors.len) return m.Text(512).init("—");
                return numberText(s.sensors[index].value, if (s.sensors[index].fan) " RPM" else " °C");
            },
            .proc_cpu, .proc_memory, .proc_read, .proc_write, .proc_threads, .proc_pss, .proc_command => {
                const row = self.processes.selected() orelse return m.Text(512).init("—");
                const p = row.process;
                return switch (field) {
                    .proc_pss => byteText(if (s.detail_id.eql(p.id)) if (s.pss) |v| @floatFromInt(v) else null else null, false),
                    .proc_command => m.Text(512).init(if (s.detail_id.eql(p.id) and s.command.len > 0) s.command.slice() else "Unavailable"),
                    .proc_cpu => numberText(if (p.cpu) |v| v * (if (self.prefs.per_core) @as(f64, @floatFromInt(s.cpus.len -| 1)) else 1) else null, "%"),
                    .proc_memory => byteText(@floatFromInt(p.rss), false),
                    .proc_read => byteText(p.read_rate, true),
                    .proc_write => byteText(p.write_rate, true),
                    .proc_threads => numberText(@floatFromInt(p.threads), ""),
                    else => unreachable,
                };
            },
        }
    }
    fn updateBindings(self: *App) void {
        if (self.page == 0 and !self.summary) {
            if (self.snapshot) |s| {
                var top: [3]?*const m.Process = @splat(null);
                for (s.processes) |*p| {
                    for (0..3) |i| {
                        if (top[i] == null or (p.cpu orelse -1) > (top[i].?.cpu orelse -1)) {
                            var j: usize = 2;
                            while (j > i) : (j -= 1) top[j] = top[j - 1];
                            top[i] = p;
                            break;
                        }
                    }
                }
                for (top, 0..) |p, i| if (self.top_labels[i]) |label| {
                    if (p) |process| {
                        self.top_ids[i] = process.id;
                        const value = io.path("{s} · PID {d} · {d:.1}% CPU · {s}", .{ process.name.slice(), process.id.pid, process.cpu orelse 0, u.bytes(@floatFromInt(process.rss)).slice() });
                        u.setLabel(label, value.slice());
                    } else {
                        self.top_ids[i] = .{};
                        u.setLabel(label, "—");
                    }
                };
            }
        }
        for (self.bindings.items) |b| {
            const text = self.metricText(b.field, b.index);
            u.setLabel(b.widget, text.slice());
        }
        for (self.drawings.items) |w| c.gtk_widget_queue_draw(w);
    }
    fn detailFact(parent: u.W, title: []const u8, value: []const u8) void {
        const row = u.box(c.GTK_ORIENTATION_VERTICAL, 3, "fact");
        u.append(row, u.label(title, "secondary"));
        const label = u.label(value, null);
        u.wrap(label);
        u.append(row, label);
        u.append(parent, row);
    }
    fn updateDetails(self: *App, force: bool) void {
        const box = self.details orelse return;
        // Remove only detail bindings when the selected identity changes.
        if (self.page == 7) {
            const selected = self.processes.selected();
            if (selected == null) {
                if (!force and self.detail_id.pid == 0) return;
                u.clear(box);
                self.removeDetailBindings();
                self.detail_id = .{};
                self.worker.inspect(.{});
                u.append(box, u.label("Select a process", "secondary"));
                return;
            }
            const p = selected.?.process;
            if (!force and self.detail_id.eql(p.id)) return;
            self.detail_id = p.id;
            self.worker.inspect(if (!p.is_group) p.id else .{});
            u.clear(box);
            self.removeDetailBindings();
            const title = u.label(p.name.slice(), "title");
            u.wrap(title);
            u.append(box, title);
            const identity = io.path("PID {d} · User {d}", .{ p.id.pid, p.uid });
            u.append(box, u.label(identity.slice(), "secondary"));
            for ([_]struct { name: []const u8, field: Field }{ .{ .name = "CPU", .field = .proc_cpu }, .{ .name = "Memory (RSS)", .field = .proc_memory }, .{ .name = "Proportional memory (PSS)", .field = .proc_pss }, .{ .name = "Threads", .field = .proc_threads }, .{ .name = "Read /s", .field = .proc_read }, .{ .name = "Write /s", .field = .proc_write } }) |f| {
                u.append(box, u.label(f.name, "secondary"));
                _ = self.addBinding(box, f.field, 0, null);
            }
            if (p.is_group) {
                detailFact(box, "Application scope", p.group.slice());
                if (self.snapshot) |s| {
                    var shown: usize = 0;
                    for (s.processes) |member| {
                        if (std.mem.eql(u8, p.group.slice(), member.group.slice())) {
                            if (shown >= 20) {
                                detailFact(box, "More members", "Open raw processes to inspect the complete group.");
                                break;
                            }
                            const info = io.path("{s} · PID {d}", .{ member.name.slice(), member.id.pid });
                            detailFact(box, "Member", info.slice());
                            shown += 1;
                        }
                    }
                }
            }
            detailFact(box, "Executable", if (p.exe.len > 0) p.exe.slice() else "Unavailable");
            u.append(box, u.label("Command", "secondary"));
            _ = self.addBinding(box, .proc_command, 0, null);
            const end = self.actionButton("End process…", 20);
            const kill = self.actionButton("Force stop…", 21);
            u.class(kill, "error");
            u.append(box, end);
            u.append(box, kill);
            const permitted = self.fixture_count == 0 and p.uid == c.getuid() and p.id.pid > 1 and p.id.pid != c.getpid() and !p.is_group;
            c.gtk_widget_set_sensitive(end, @intFromBool(permitted));
            c.gtk_widget_set_sensitive(kill, @intFromBool(permitted));
            if (!permitted) {
                const label = u.label(if (p.is_group) "Open raw processes to control one group member." else "This process cannot be controlled here.", "secondary");
                u.wrap(label);
                u.append(box, label);
            }
        } else if (self.page == 8) {
            const selected = self.services_table.selected();
            if (selected == null) {
                u.clear(box);
                u.append(box, u.label("Select a service", "secondary"));
                return;
            }
            const service = selected.?.service;
            self.detail_service = service.name;
            u.clear(box);
            const title = u.label(service.name.slice(), "title");
            u.wrap(title);
            u.append(box, title);
            detailFact(box, "Description", service.description.slice());
            detailFact(box, "State", service.state.slice());
            detailFact(box, "Substate", service.substate.slice());
            detailFact(box, "Loaded", service.load.slice());
            u.append(box, self.actionButton("Start service…", 22));
            u.append(box, self.actionButton("Restart service…", 23));
            const stop = self.actionButton("Stop service…", 24);
            u.class(stop, "error");
            u.append(box, stop);
        }
        self.updateBindings();
    }
    fn removeDetailBindings(self: *App) void {
        var i: usize = 0;
        while (i < self.bindings.items.len) {
            if (@intFromEnum(self.bindings.items[i].field) >= @intFromEnum(Field.proc_cpu)) {
                _ = self.bindings.swapRemove(i);
            } else i += 1;
        }
    }
    fn showDetails(self: *App) void {
        if (c.gtk_widget_get_width(self.window) >= 980) {
            self.updateDetails(true);
            return;
        }
        // Narrow details are a standalone modal; selection remains in the table.
        const dialog = self.newDialog("Details");
        const area = c.gtk_dialog_get_content_area(u.cast(c.GtkDialog, dialog)).?;
        const box = u.box(c.GTK_ORIENTATION_VERTICAL, 8, "detail");
        u.append(@ptrCast(area), u.scroll(box));
        c.gtk_window_set_default_size(u.cast(c.GtkWindow, dialog), 420, 640);
        const old = self.details;
        self.details = box;
        self.updateDetails(true);
        self.details = old;
        _ = c.gtk_dialog_add_button(u.cast(c.GtkDialog, dialog), "Close", c.GTK_RESPONSE_CANCEL);
        c.gtk_window_present(u.cast(c.GtkWindow, dialog));
    }
    fn navigate(self: *App, page: u32) void {
        if (self.dialog != null) return;
        self.notice_until = 0;
        self.page = page;
        self.worker.inspect(.{});
        self.prefs.page = page;
        self.processes.query = .{};
        self.services_table.query = .{};
        c.gtk_editable_set_text(u.cast(c.GtkEditable, self.search), "");
        self.processes.filterChanged();
        self.services_table.filterChanged();
        c.gtk_popover_popdown(u.cast(c.GtkPopover, self.popup));
        self.buildPage();
    }
    fn clicked(button: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(App, data);
        const command = @intFromPtr(c.g_object_get_data(@ptrCast(button), "dome-action")) - 1;
        self.handleCommand(@intCast(command));
    }
    fn handleCommand(self: *App, command: u32) void {
        if (command < 9) {
            self.navigate(command);
            return;
        }
        if (command >= 100 and command < 103) {
            const id = self.top_ids[command - 100];
            self.processes.grouped = false;
            self.navigate(7);
            if (self.snapshot) |s| self.processes.updateProcesses(s.processes);
            self.processes.selectIdentity(id);
            self.showDetails();
            return;
        }
        switch (command) {
            9 => {
                self.paused = !self.paused;
                self.worker.configure(self.paused, self.prefs.interval, false);
                c.gtk_button_set_icon_name(u.cast(c.GtkButton, self.pause_button), if (self.paused) "media-playback-start-symbolic" else "media-playback-pause-symbolic");
                self.message(if (self.paused) "Sampling paused" else "Sampling resumed; establishing new counter baselines");
                if (self.summary) self.buildPage();
            },
            10 => self.showPreferences(),
            11 => {
                if (self.page < 7) self.navigate(7);
                _ = c.gtk_widget_grab_focus(self.search);
            },
            12 => {
                self.worker.configure(self.paused, self.prefs.interval, true);
                if (self.page == 8) self.services.refresh();
            },
            13 => {
                self.logical = !self.logical;
                self.buildPage();
            },
            14 => {
                self.processes.grouped = !self.processes.grouped;
                if (self.snapshot) |s| self.processes.updateProcesses(s.processes);
                self.buildPage();
            },
            15 => {
                self.processes.mine = !self.processes.mine;
                self.processes.filterChanged();
                self.buildPage();
            },
            16 => self.showDetails(),
            17 => {
                self.services.open(!self.services.system);
                self.services_table.updateServices(&.{});
                self.buildPage();
            },
            18 => {
                if (self.services.connection == null) self.services.open(self.services.system) else self.services.refresh();
            },
            19 => {
                self.summary = !self.summary;
                c.gtk_window_set_default_size(u.cast(c.GtkWindow, self.window), if (self.summary) 420 else self.prefs.width, if (self.summary) 560 else self.prefs.height);
                self.buildPage();
            },
            20, 21 => self.confirmProcess(command == 21),
            22, 23, 24 => self.confirmService(if (command == 22) "StartUnit" else if (command == 23) "RestartUnit" else "StopUnit"),
            else => {},
        }
    }
    fn intervalChanged(_: ?*c.GObject, _: ?*c.GParamSpec, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(App, data);
        if (self.building) return;
        const index = c.gtk_drop_down_get_selected(u.cast(c.GtkDropDown, self.interval));
        const values = [_]i64{ 500000, 1000000, 2000000, 5000000 };
        if (index < 4) {
            self.prefs.interval = values[index];
            self.worker.configure(self.paused, self.prefs.interval, false);
        }
    }
    fn deviceChanged(_: ?*c.GObject, _: ?*c.GParamSpec, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(App, data);
        if (self.building) return;
        const widget = self.device_combo orelse return;
        const i = c.gtk_drop_down_get_selected(u.cast(c.GtkDropDown, widget));
        const s = self.snapshot orelse return;
        switch (self.page) {
            3 => {
                if (i < s.disks.len) self.device_keys[0] = s.disks[i].key;
            },
            4 => {
                if (i < s.networks.len) self.device_keys[1] = s.networks[i].key;
            },
            5 => {
                if (i < s.gpus.len) self.device_keys[2] = s.gpus[i].key;
            },
            else => return,
        }
        self.buildPage();
    }
    fn searchChanged(_: ?*c.GtkSearchEntry, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(App, data);
        const table = if (self.page == 8) self.services_table else self.processes;
        table.query.set(std.mem.span(c.gtk_editable_get_text(u.cast(c.GtkEditable, self.search))));
        table.filterChanged();
    }
    fn processSelected(data: ?*anyopaque) void {
        const self = u.cast(App, data);
        if (self.closed or self.page != 7) return;
        self.updateDetails(true);
    }
    fn serviceSelected(data: ?*anyopaque) void {
        const self = u.cast(App, data);
        if (self.closed or self.page != 8) return;
        self.updateDetails(true);
    }
    fn servicesChanged(data: ?*anyopaque) void {
        const self = u.cast(App, data);
        if (self.closed) return;
        const availability_changed = self.services_available != self.services.available;
        self.services_available = self.services.available;
        self.services_table.updateServices(self.services.items.items);
        if (self.page == 8) {
            if ((availability_changed or (!self.services.available and !self.services.loading)) and self.dialog == null) self.buildPage() else self.updateDetails(true);
            if (self.services_note) |note| u.setLabel(note, self.services.message.slice());
            self.message(self.services.message.slice());
        }
    }
    fn shape(s: *m.Snapshot) u64 {
        var hash = std.hash.Wyhash.init(0);
        for (s.disks) |d| hash.update(d.key.slice());
        for (s.networks) |d| hash.update(d.key.slice());
        for (s.gpus) |d| hash.update(d.key.slice());
        for (s.sensors) |d| hash.update(d.key.slice());
        hash.update(std.mem.sliceAsBytes(s.cpu_ids));
        return hash.final();
    }
    fn tick(data: ?*anyopaque) callconv(.c) c_int {
        const self = u.cast(App, data);
        if (self.closed) {
            self.timer = 0;
            return 0;
        }
        self.services.tick();
        var nvidia = false;
        if (self.snapshot) |s| {
            for (s.gpus) |g| {
                if (g.vendor == 0x10de) nvidia = true;
            }
        }
        if (test_hooks and c.g_getenv("DOME_TEST_GPU_HANG") != null) nvidia = true;
        self.nvml.tick(nvidia and !self.paused);
        const width = c.gtk_widget_get_width(self.window);
        const narrow = width < 760;
        if (width > 0 and narrow != self.narrow and self.dialog == null) {
            self.narrow = narrow;
            if (narrow) u.class(self.window, "narrow") else c.gtk_widget_remove_css_class(self.window, "narrow");
            c.gtk_widget_set_visible(self.nav_toggle, @intFromBool(narrow));
            self.processes.narrow(narrow);
            self.buildPage();
        }
        if (self.worker.take()) |s| {
            const started = io.monotonic();
            if (test_hooks and self.fixture_count > 0) {
                const fixture = s.arena.allocator().alloc(m.Process, self.fixture_count) catch unreachable;
                for (fixture, 0..) |*p, i| {
                    p.* = .{ .id = .{ .pid = @intCast(100000 + i), .start = 1 }, .uid = c.getuid(), .rss = 1048576 * (i % 100), .cpu = @as(f64, @floatFromInt(i % 100)) / 10 };
                    const name = io.path("Fixture process {d}", .{i});
                    p.name.set(name.slice());
                }
                s.processes = fixture;
            }
            const first = self.snapshot == null;
            const changed_shape = shape(s) != self.last_shape;
            self.last_shape = shape(s);
            const old = self.snapshot;
            self.snapshot = s;
            self.record(s);
            self.processes.cores = @max(1, s.cpus.len -| 1);
            self.processes.per_core = self.prefs.per_core;
            self.processes.updateProcesses(s.processes);
            if (self.dialog == null and (first or changed_shape)) self.buildPage() else {
                self.updateBindings();
                self.updateDetails(false);
            }
            if (old) |p| p.unref();
            self.last_update_us = io.monotonic() - started;
        }
        if (self.notice_until < io.monotonic()) {
            if (self.snapshot) |s| {
                const text = io.path("{s} · {d} processes · {d:.1} ms collection{s}", .{ if (self.fixture_count > 0) "Synthetic test fixture" else if (self.paused) "Paused" else if (io.monotonic() - s.time > @max(5000000, self.prefs.interval * 3)) "Stale — waiting for the collector" else "Live", s.processes.len, @as(f64, @floatFromInt(s.duration)) / 1000, if (s.truncated) " · Collection limit reached" else "" });
                u.setLabel(self.status, text.slice());
            }
        }
        return 1;
    }
    fn closeRequested(_: ?*c.GtkWindow, data: ?*anyopaque) callconv(.c) c_int {
        const self = u.cast(App, data);
        self.closed = true;
        if (self.timer != 0) {
            _ = c.g_source_remove(self.timer);
            self.timer = 0;
        }
        if (test_hooks) c.g_print("DOME_SHUTDOWN close requested\n");
        if (!self.summary) {
            self.prefs.width = c.gtk_widget_get_width(self.window);
            self.prefs.height = c.gtk_widget_get_height(self.window);
        }
        const sorter = u.cast(c.GtkColumnViewSorter, c.gtk_column_view_get_sorter(u.cast(c.GtkColumnView, self.processes.view)));
        const column = c.gtk_column_view_sorter_get_primary_sort_column(sorter);
        for (self.processes.columns, 0..) |col, i| if (col.widget == column) {
            self.prefs.sort_column = @intCast(i);
        };
        self.prefs.sort_descending = c.gtk_column_view_sorter_get_primary_sort_order(sorter) == c.GTK_SORT_DESCENDING;
        if (!self.prefs.save()) c.g_printerr("Dome: could not save preferences\n");
        if (self.dialog) |dialog| {
            c.gtk_window_destroy(u.cast(c.GtkWindow, dialog));
            self.dialog = null;
        }
        return 0;
    }
    fn newDialog(self: *App, title: [*:0]const u8) u.W {
        if (self.dialog) |old| {
            self.removeDetailBindings();
            c.gtk_window_destroy(u.cast(c.GtkWindow, old));
            self.dialog = null;
        }
        const dialog = c.gtk_dialog_new().?;
        self.dialog = dialog;
        c.gtk_window_set_title(u.cast(c.GtkWindow, dialog), title);
        c.gtk_window_set_transient_for(u.cast(c.GtkWindow, dialog), u.cast(c.GtkWindow, self.window));
        c.gtk_window_set_modal(u.cast(c.GtkWindow, dialog), 1);
        c.gtk_window_set_default_size(u.cast(c.GtkWindow, dialog), 420, -1);
        u.class(dialog, "dome-root");
        if (!self.prefs.native) u.class(dialog, if (self.prefs.light) "light" else "dark");
        u.margin(@ptrCast(c.gtk_dialog_get_content_area(u.cast(c.GtkDialog, dialog))), 20);
        u.connect(dialog, "response", &dialogResponse, self);
        return dialog;
    }
    fn confirmProcess(self: *App, force: bool) void {
        const row = self.processes.selected() orelse return;
        const p = row.process;
        if (self.fixture_count > 0 or p.uid != c.getuid() or p.is_group) return;
        if (self.target) |t| t.close();
        self.target = Target.open(p.id) catch |err| {
            self.message(@errorName(err));
            return;
        };
        self.force = force;
        const dialog = self.newDialog(if (force) "Force stop process?" else "End process?");
        const area: u.W = @ptrCast(c.gtk_dialog_get_content_area(u.cast(c.GtkDialog, dialog)));
        const title = io.path("{s} · PID {d} · User {d}", .{ p.name.slice(), p.id.pid, p.uid });
        const label = u.label(title.slice(), "title");
        u.wrap(label);
        u.append(area, label);
        const note = u.label(if (force) "Stop this process immediately? Unsaved work may be lost." else "Ask this process to close? Save any work before continuing.", null);
        u.wrap(note);
        u.append(area, note);
        _ = c.gtk_dialog_add_button(u.cast(c.GtkDialog, dialog), "Cancel", c.GTK_RESPONSE_CANCEL);
        const button = c.gtk_dialog_add_button(u.cast(c.GtkDialog, dialog), if (force) "Force stop" else "End process", c.GTK_RESPONSE_ACCEPT).?;
        u.class(button, "destructive-action");
        c.gtk_dialog_set_default_response(u.cast(c.GtkDialog, dialog), c.GTK_RESPONSE_CANCEL);
        c.gtk_window_present(u.cast(c.GtkWindow, dialog));
    }
    fn confirmService(self: *App, method: [*:0]const u8) void {
        const row = self.services_table.selected() orelse return;
        self.service_target = row.service.name;
        self.service_action.set(std.mem.span(method));
        self.service_generation = self.services.generation;
        const dialog = self.newDialog("Change service state?");
        const area: u.W = @ptrCast(c.gtk_dialog_get_content_area(u.cast(c.GtkDialog, dialog)));
        const title = u.label(row.service.name.slice(), "title");
        u.wrap(title);
        u.append(area, title);
        const label = u.label(if (self.services.system) "This system action may interrupt dependent applications and require authentication." else "This action may interrupt applications using the selected user service.", null);
        u.wrap(label);
        u.append(area, label);
        _ = c.gtk_dialog_add_button(u.cast(c.GtkDialog, dialog), "Cancel", c.GTK_RESPONSE_CANCEL);
        _ = c.gtk_dialog_add_button(u.cast(c.GtkDialog, dialog), method, c.GTK_RESPONSE_APPLY);
        c.gtk_dialog_set_default_response(u.cast(c.GtkDialog, dialog), c.GTK_RESPONSE_CANCEL);
        c.gtk_window_present(u.cast(c.GtkWindow, dialog));
    }
    fn showPreferences(self: *App) void {
        const dialog = self.newDialog("Preferences");
        const area: u.W = @ptrCast(c.gtk_dialog_get_content_area(u.cast(c.GtkDialog, dialog)));
        u.append(area, u.label("Appearance & monitoring", "title"));
        const definitions = [_]struct { text: [*:0]const u8, value: bool }{ .{ .text = "Light appearance", .value = self.prefs.light }, .{ .text = "Use native GTK colors", .value = self.prefs.native }, .{ .text = "Compact process rows", .value = self.prefs.compact }, .{ .text = "Network rates in bits per second", .value = self.prefs.bits }, .{ .text = "Process CPU: one core = 100%", .value = self.prefs.per_core }, .{ .text = "Keep 10 minutes of graph history", .value = self.prefs.duration > 120000000 }, .{ .text = "Show PID column", .value = self.prefs.columns & 2 != 0 }, .{ .text = "Show memory column", .value = self.prefs.columns & 8 != 0 }, .{ .text = "Show disk I/O columns", .value = self.prefs.columns & 48 != 0 } };
        for (definitions, 0..) |d, i| {
            const check = c.gtk_check_button_new_with_label(d.text).?;
            c.gtk_check_button_set_active(u.cast(c.GtkCheckButton, check), @intFromBool(d.value));
            self.pref_widgets[i] = check;
            u.append(area, check);
        }
        _ = c.gtk_dialog_add_button(u.cast(c.GtkDialog, dialog), "Compact summary", 42);
        _ = c.gtk_dialog_add_button(u.cast(c.GtkDialog, dialog), "Cancel", c.GTK_RESPONSE_CANCEL);
        _ = c.gtk_dialog_add_button(u.cast(c.GtkDialog, dialog), "Apply", 43);
        c.gtk_window_present(u.cast(c.GtkWindow, dialog));
    }
    fn dialogResponse(dialog: ?*c.GtkDialog, response: c_int, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(App, data);
        if (response == c.GTK_RESPONSE_ACCEPT) {
            if (self.target) |target| {
                target.signal(self.force) catch |err| {
                    self.message(@errorName(err));
                };
                self.worker.configure(self.paused, self.prefs.interval, true);
            }
        }
        if (response == c.GTK_RESPONSE_APPLY and self.service_generation == self.services.generation) self.services.action(self.service_target.z(), self.service_action.z());
        if (response == 43) {
            self.prefs.light = c.gtk_check_button_get_active(u.cast(c.GtkCheckButton, self.pref_widgets[0].?)) != 0;
            self.prefs.native = c.gtk_check_button_get_active(u.cast(c.GtkCheckButton, self.pref_widgets[1].?)) != 0;
            self.prefs.compact = c.gtk_check_button_get_active(u.cast(c.GtkCheckButton, self.pref_widgets[2].?)) != 0;
            self.prefs.bits = c.gtk_check_button_get_active(u.cast(c.GtkCheckButton, self.pref_widgets[3].?)) != 0;
            self.prefs.per_core = c.gtk_check_button_get_active(u.cast(c.GtkCheckButton, self.pref_widgets[4].?)) != 0;
            self.prefs.duration = if (c.gtk_check_button_get_active(u.cast(c.GtkCheckButton, self.pref_widgets[5].?)) != 0) 600000000 else 120000000;
            self.prefs.columns = 5;
            if (c.gtk_check_button_get_active(u.cast(c.GtkCheckButton, self.pref_widgets[6].?)) != 0) self.prefs.columns |= 2;
            if (c.gtk_check_button_get_active(u.cast(c.GtkCheckButton, self.pref_widgets[7].?)) != 0) self.prefs.columns |= 8;
            if (c.gtk_check_button_get_active(u.cast(c.GtkCheckButton, self.pref_widgets[8].?)) != 0) self.prefs.columns |= 48;
            self.processes.column_mask = self.prefs.columns;
            self.processes.narrow(self.narrow);
            self.applyTheme();
            self.processes.per_core = self.prefs.per_core;
            if (self.snapshot) |s| self.processes.updateProcesses(s.processes);
            _ = self.prefs.save();
        }
        if (self.target) |target| {
            target.close();
            self.target = null;
        }
        self.removeDetailBindings();
        self.dialog = null;
        c.gtk_window_destroy(@ptrCast(dialog));
        if (!self.closed) {
            self.buildPage();
            if (response == 42) self.handleCommand(19);
        }
    }
    fn keyPressed(_: ?*c.GtkEventControllerKey, key: c_uint, _: c_uint, modifiers: c.GdkModifierType, data: ?*anyopaque) callconv(.c) c_int {
        const self = u.cast(App, data);
        const ctrl = modifiers & c.GDK_CONTROL_MASK != 0;
        if (test_hooks and key == c.GDK_KEY_F12) {
            self.probe();
            return 1;
        }
        if (test_hooks and self.dialog == null) {
            switch (key) {
                c.GDK_KEY_F6 => {
                    self.handleCommand(10);
                    return 1;
                },
                c.GDK_KEY_F7 => {
                    self.handleCommand(if (self.page == 8) 23 else 13);
                    return 1;
                },
                c.GDK_KEY_F8 => {
                    self.handleCommand(if (self.page == 8) 24 else 20);
                    return 1;
                },
                c.GDK_KEY_F9 => {
                    self.handleCommand(if (self.page == 8) 22 else 21);
                    return 1;
                },
                c.GDK_KEY_F10 => {
                    self.handleCommand(19);
                    return 1;
                },
                c.GDK_KEY_F11 => {
                    const table = if (self.page == 8) self.services_table else self.processes;
                    c.gtk_single_selection_set_selected(table.selection, 0);
                    return 1;
                },
                else => {},
            }
        }
        if (self.dialog != null) return 0;
        if (modifiers & c.GDK_ALT_MASK != 0 and key >= c.GDK_KEY_1 and key <= c.GDK_KEY_9) {
            self.navigate(@intCast(key - c.GDK_KEY_1));
            return 1;
        }
        if (ctrl and key == c.GDK_KEY_w) {
            c.gtk_window_close(u.cast(c.GtkWindow, self.window));
            return 1;
        }
        if (ctrl and key == c.GDK_KEY_1) {
            self.navigate(0);
            return 1;
        }
        if (ctrl and key == c.GDK_KEY_2) {
            self.navigate(7);
            return 1;
        }
        if (ctrl and key == c.GDK_KEY_f) {
            self.handleCommand(11);
            return 1;
        }
        if (ctrl and key == c.GDK_KEY_p) {
            self.handleCommand(9);
            return 1;
        }
        if (key == c.GDK_KEY_F5) {
            self.handleCommand(12);
            return 1;
        }
        if (modifiers & c.GDK_ALT_MASK != 0 and key == c.GDK_KEY_Return) {
            self.showDetails();
            return 1;
        }
        if (key == c.GDK_KEY_Escape) {
            c.gtk_editable_set_text(u.cast(c.GtkEditable, self.search), "");
            c.gtk_popover_popdown(u.cast(c.GtkPopover, self.popup));
            return 1;
        }
        if (test_hooks and ctrl and key >= c.GDK_KEY_3 and key <= c.GDK_KEY_9) {
            self.navigate(@intCast(key - c.GDK_KEY_1));
            return 1;
        }
        return 0;
    }
    fn probe(self: *App) void {
        const selected = self.processes.selected();
        c.g_print("DOME_PROBE {\"page\":%u,\"sample\":%llu,\"processes\":%zu,\"visible\":%u,\"realized_cells\":%zu,\"paused\":%s,\"sidebar\":%s,\"selected_pid\":%d,\"services\":%zu,\"service_visible\":%u,\"update_us\":%lld,\"width\":%d,\"gpu_provider_count\":%zu,\"gpu_timeouts\":%zu,\"service_error\":%s,\"dialog\":%s}\n", self.page, @as(c_ulonglong, if (self.snapshot) |s| s.sequence else 0), if (self.snapshot) |s| s.processes.len else @as(usize, 0), self.processes.countVisible(), self.processes.realized, @as([*:0]const u8, if (self.paused) "true" else "false"), @as([*:0]const u8, if (c.gtk_widget_get_visible(self.sidebar) != 0) "true" else "false"), @as(c_int, if (selected) |r| r.process.id.pid else 0), self.services.items.items.len, self.services_table.countVisible(), @as(c_longlong, self.last_update_us), c.gtk_widget_get_width(self.window), self.nvml.count, self.nvml.timeouts, @as([*:0]const u8, if (self.services.failure_until > io.monotonic()) "true" else "false"), @as([*:0]const u8, if (self.dialog != null) "true" else "false"));
    }
};
