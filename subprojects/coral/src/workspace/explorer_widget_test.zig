const std = @import("std");
const testing = std.testing;
const u = @import("../c.zig");
const c = u.c;
const explorer = @import("explorer.zig");
const fs = @import("browser_fs.zig");

fn drain() void {
    for (0..256) |_| if (c.g_main_context_iteration(null, 0) == 0) break;
}

test "explorer factory virtualizes 100k model rows and releases viewport widgets" {
    try testing.expect(c.gtk_init_check() != 0);
    var view = explorer.View.init();
    view.connect();
    const window = c.gtk_window_new().?;
    const scroll = c.gtk_scrolled_window_new().?;
    c.gtk_window_set_default_size(u.cast(c.GtkWindow, window), 320, 240);
    c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, scroll), view.widget);
    c.gtk_window_set_child(u.cast(c.GtkWindow, window), scroll);
    for (0..100000) |i| {
        const text = u.fmt("file-{d:0>6}.txt", .{i});
        defer u.a.free(text);
        view.append(text);
    }
    c.gtk_window_present(u.cast(c.GtkWindow, window));
    const deadline = c.g_get_monotonic_time() + 5_000_000;
    while (c.gtk_widget_get_mapped(view.widget) == 0) {
        if (c.g_get_monotonic_time() >= deadline) return error.MappingTimedOut;
        drain();
        c.g_usleep(1000);
    }
    drain();
    try testing.expect(view.live_widgets > 0 and view.peak_widgets < 256);
    const adjustment = c.gtk_scrolled_window_get_vadjustment(u.cast(c.GtkScrolledWindow, scroll));
    c.gtk_adjustment_set_value(adjustment, c.gtk_adjustment_get_upper(adjustment));
    drain();
    try testing.expect(view.peak_widgets < 256);
    c.gtk_window_destroy(u.cast(c.GtkWindow, window));
    drain();
    try testing.expectEqual(@as(usize, 0), view.live_widgets);
}

test "explorer cache evicts pages but preserves path identity and expansion" {
    var tree: explorer.Tree = .{};
    defer tree.deinit();
    const root: @import("model.zig").RootId = @fromBackingInt(1);
    tree.select(root, "dir-0/selected.txt");
    for (0..20) |i| {
        const path = u.fmt("dir-{d}", .{i});
        defer u.a.free(path);
        const index = tree.ensure(root, path).?;
        tree.nodes.items[index].expanded = true;
        var page: fs.Page = .{ .arena = .init(u.a), .entries = &.{}, .continuation = null, .generation = @splat(0), .directory = null, .complete = false, .status = .ready, .processed = 4096 };
        _ = try page.arena.allocator().alloc(u8, 100 * 1024);
        tree.install(index, page);
        try testing.expect(tree.pages() <= explorer.page_limit);
        try testing.expect(tree.bytes() <= explorer.byte_limit);
    }
    try testing.expect(tree.nodes.items[0].expanded);
    try testing.expect(tree.nodes.items[0].page == null);
    try testing.expectEqualStrings("dir-0/selected.txt", tree.selected_path.?);
    try testing.expectEqual(@as(usize, 0), tree.find(root, "dir-0").?);
    try testing.expect(tree.find(@fromBackingInt(2), "dir-0") == null);
    while (tree.nodes.items.len < explorer.node_limit) {
        const path = u.fmt("bounded-{d}", .{tree.nodes.items.len});
        defer u.a.free(path);
        try testing.expect(tree.ensure(root, path) != null);
    }
    try testing.expect(tree.ensure(root, "overflow") == null);
    try testing.expect(tree.ensure(root, "dir-0") != null);
}

test "shared explorer policy survives owner retirement until last worker callback" {
    const policy = explorer.Policy.create(&.{ "*.tmp", "build/" });
    const worker_policy = policy.ref();
    policy.unref();
    try testing.expectEqual(@as(usize, 1), worker_policy.refs);
    try testing.expectEqualStrings("*.tmp", worker_policy.patterns[0]);
    worker_policy.unref();
}
