//! Wasmtime owns its values; none of these handles leave the helper process.
const std = @import("std");
const c = @import("wasmtime");
const m = @import("model.zig");
const a = std.heap.c_allocator;
const V = c.wasmtime_component_val_t;
comptime {
    if (c.WASMTIME_VERSION_MAJOR != 48 or c.WASMTIME_VERSION_MINOR != 0 or c.WASMTIME_VERSION_PATCH != 2) @compileError("Wasmtime 48.0.2 is required");
}
fn check(err: ?*c.wasmtime_error_t) !void {
    if (err) |e| {
        defer c.wasmtime_error_delete(e);
        return error.PluginRuntime;
    }
}
fn str(v: V) ![]const u8 {
    const s = switch (v.kind) {
        c.WASMTIME_COMPONENT_STRING => v.of.string,
        c.WASMTIME_COMPONENT_ENUM => v.of.enumeration,
        else => return error.PluginType,
    };
    if (s.size > 4096) return error.PluginValueLimit;
    return s.data[0..s.size];
}
fn field(v: V, key: []const u8) !V {
    if (v.kind != c.WASMTIME_COMPONENT_RECORD or v.of.record.size > 16) return error.PluginType;
    for (v.of.record.data[0..v.of.record.size]) |f| if (std.mem.eql(u8, f.name.data[0..f.name.size], key)) return f.val;
    return error.PluginField;
}
fn string(value: []const u8, kind: u8) V {
    var result = std.mem.zeroes(V);
    result.kind = kind;
    c.wasm_byte_vec_new(&result.of.string, value.len, value.ptr);
    return result;
}
fn record(names: []const []const u8, values: []const V) V {
    var result = std.mem.zeroes(V);
    result.kind = c.WASMTIME_COMPONENT_RECORD;
    c.wasmtime_component_valrecord_new_uninit(&result.of.record, names.len);
    for (names, values, 0..) |name, v, i| {
        c.wasm_byte_vec_new(&result.of.record.data[i].name, name.len, name.ptr);
        result.of.record.data[i].val = v;
    }
    return result;
}
fn eventValue(event: m.Event) V {
    var settings = std.mem.zeroes(V);
    settings.kind = c.WASMTIME_COMPONENT_LIST;
    c.wasmtime_component_vallist_new_uninit(&settings.of.list, event.settings.len);
    for (event.settings, 0..) |s, i| settings.of.list.data[i] = record(&.{ "key", "value" }, &.{ string(s.key, c.WASMTIME_COMPONENT_STRING), string(s.value, c.WASMTIME_COMPONENT_STRING) });
    return record(&.{ "kind", "node", "count", "settings", "reduced-motion" }, &.{ string(@tagName(event.kind), c.WASMTIME_COMPONENT_ENUM), .{ .kind = c.WASMTIME_COMPONENT_U32, .of = .{ .u32 = event.node } }, .{ .kind = c.WASMTIME_COMPONENT_U32, .of = .{ .u32 = event.count } }, settings, .{ .kind = c.WASMTIME_COMPONENT_BOOL, .of = .{ .boolean = event.reduced_motion } } });
}
pub const Runtime = struct {
    engine: *c.wasm_engine_t,
    store: *c.wasmtime_store_t,
    linker: *c.wasmtime_component_linker_t,
    component: *c.wasmtime_component_t,
    function: c.wasmtime_component_func_t,
    manifest: m.Manifest,
    pending: ?[]u8 = null,
    timer_ms: u32 = 0,
    next_timer: u32 = 0,
    published: bool = false,
    calls: usize = 0,
    grants: m.Grants,
    pub fn create(wasm: []const u8, manifest: m.Manifest, grants: m.Grants) !*Runtime {
        const self = try a.create(Runtime);
        errdefer a.destroy(self);
        const cfg = c.wasm_config_new();
        c.wasmtime_config_parallel_compilation_set(cfg, false);
        c.wasmtime_config_wasm_component_model_set(cfg, true);
        c.wasmtime_config_memory_reservation_set(cfg, 32 * 1024 * 1024);
        c.wasmtime_config_memory_guard_size_set(cfg, 65536);
        c.wasmtime_config_memory_reservation_for_growth_set(cfg, 0);
        c.wasmtime_config_consume_fuel_set(cfg, true);
        c.wasmtime_config_max_wasm_stack_set(cfg, 512 * 1024);
        const engine = c.wasm_engine_new_with_config(cfg) orelse return error.PluginEngine;
        errdefer c.wasm_engine_delete(engine);
        const store = c.wasmtime_store_new(engine, null, null) orelse return error.PluginStore;
        errdefer c.wasmtime_store_delete(store);
        c.wasmtime_store_limiter(store, 32 * 1024 * 1024, 4096, 32, 8, 2);
        try check(c.wasmtime_context_set_fuel(c.wasmtime_store_context(store), 1_000_000));
        // WASI is deliberately not linked. SDK guests are freestanding reactors.
        const linker = c.wasmtime_component_linker_new(engine) orelse return error.PluginLinker;
        errdefer c.wasmtime_component_linker_delete(linker);
        {
            const root = c.wasmtime_component_linker_root(linker);
            defer c.wasmtime_component_linker_instance_delete(root);
            var host: ?*c.wasmtime_component_linker_instance_t = null;
            const name = "pearl:plugin/host@0.1.0";
            try check(c.wasmtime_component_linker_instance_add_instance(root, name, name.len, &host));
            defer c.wasmtime_component_linker_instance_delete(host);
            for ([_][]const u8{ "publish", "log", "set-timer", "input-activity" }, [_]c.wasmtime_component_func_callback_t{ publish, log, timer, activity }) |name_, callback| try check(c.wasmtime_component_linker_instance_add_func(host, name_.ptr, name_.len, callback, self, null));
        }
        var component: ?*c.wasmtime_component_t = null;
        try check(c.wasmtime_component_new(engine, wasm.ptr, wasm.len, &component));
        errdefer c.wasmtime_component_delete(component);
        self.* = .{ .engine = engine, .store = store, .linker = linker, .component = component.?, .function = undefined, .manifest = manifest, .grants = grants };
        errdefer if (self.pending) |v| a.free(v);
        var instance: c.wasmtime_component_instance_t = undefined;
        try check(c.wasmtime_component_linker_instantiate(linker, c.wasmtime_store_context(store), component, &instance));
        const parent = c.wasmtime_component_get_export_index(component, null, m.api.ptr, m.api.len) orelse return error.PluginExport;
        defer c.wasmtime_component_export_index_delete(parent);
        const index = c.wasmtime_component_get_export_index(component, parent, "handle-event", 12) orelse return error.PluginExport;
        defer c.wasmtime_component_export_index_delete(index);
        if (!c.wasmtime_component_instance_get_func(&instance, c.wasmtime_store_context(store), index, &self.function)) return error.PluginExport;
        // Reject host effects from component initialization.
        if (self.pending != null or self.calls != 0) return error.PluginInitializationEffect;
        return self;
    }
    pub fn destroy(self: *Runtime) void {
        if (self.pending) |v| a.free(v);
        c.wasmtime_component_delete(self.component);
        c.wasmtime_component_linker_delete(self.linker);
        c.wasmtime_store_delete(self.store);
        c.wasm_engine_delete(self.engine);
        a.destroy(self);
    }
    pub fn handle(self: *Runtime, event: m.Event) !?[]u8 {
        if (self.pending) |v| a.free(v);
        self.pending = null;
        self.calls = 0;
        self.published = false;
        self.next_timer = self.timer_ms;
        var arg = eventValue(event);
        defer c.wasmtime_component_val_delete(&arg);
        var result = std.mem.zeroes(V);
        defer c.wasmtime_component_val_delete(&result);
        const ctx = c.wasmtime_store_context(self.store);
        try check(c.wasmtime_context_set_fuel(ctx, 1_000_000));
        try check(c.wasmtime_component_func_call(&self.function, ctx, &arg, 1, &result, 1));
        if (result.kind != c.WASMTIME_COMPONENT_RESULT or !result.of.result.is_ok or result.of.result.val != null) return error.PluginCallback;
        self.timer_ms = self.next_timer;
        const pending = self.pending;
        self.pending = null;
        return pending;
    }
    fn admit(self: *Runtime) bool {
        self.calls += 1;
        return self.calls <= 64;
    }
    fn failure() ?*c.wasmtime_error_t {
        return c.wasmtime_error_new("invalid or excessive Pearl host call");
    }
    fn success(result: [*c]V) void {
        result[0] = .{ .kind = c.WASMTIME_COMPONENT_RESULT, .of = .{ .result = .{ .is_ok = true, .val = null } } };
    }
    fn publish(data: ?*anyopaque, _: ?*c.wasmtime_context_t, _: ?*const c.wasmtime_component_func_type_t, args: [*c]V, argc: usize, out: [*c]V, outc: usize) callconv(.c) ?*c.wasmtime_error_t {
        const self: *Runtime = @ptrCast(@alignCast(data.?));
        if (!self.admit() or self.published or argc != 1 or outc != 1) return failure();
        self.publishValue(args[0]) catch return failure();
        self.published = true;
        success(out);
        return null;
    }
    fn publishValue(self: *Runtime, value: V) !void {
        const list = try field(value, "nodes");
        if (list.kind != c.WASMTIME_COMPONENT_LIST or list.of.list.size > m.Limits.nodes) return error.PluginType;
        var nodes: [m.Limits.nodes]m.Node = undefined;
        for (list.of.list.data[0..list.of.list.size], 0..) |v, i| {
            const id = try field(v, "id");
            if (id.kind != c.WASMTIME_COMPONENT_U32) return error.PluginType;
            nodes[i] = .{ .id = id.of.u32, .kind = std.meta.stringToEnum(@FieldType(m.Node, "kind"), try str(try field(v, "kind"))) orelse return error.PluginType, .text = try str(try field(v, "text")), .asset = try str(try field(v, "asset")), .clip = try str(try field(v, "clip")) };
        }
        const scene: m.Scene = .{ .nodes = nodes[0..list.of.list.size] };
        try scene.validate(self.manifest);
        const bytes = try std.json.Stringify.valueAlloc(a, scene, .{});
        errdefer a.free(bytes);
        if (bytes.len > 60000) return error.PluginFrameLimit;
        self.pending = bytes;
    }
    fn log(data: ?*anyopaque, _: ?*c.wasmtime_context_t, _: ?*const c.wasmtime_component_func_type_t, args: [*c]V, argc: usize, _: [*c]V, outc: usize) callconv(.c) ?*c.wasmtime_error_t {
        const self: *Runtime = @ptrCast(@alignCast(data.?));
        if (!self.admit() or argc != 1 or outc != 0) return failure();
        const value = str(args[0]) catch return failure();
        m.text(value, 4096) catch return failure();
        // No guest text is written to the shell log by default.
        return null;
    }
    fn timer(data: ?*anyopaque, _: ?*c.wasmtime_context_t, _: ?*const c.wasmtime_component_func_type_t, args: [*c]V, argc: usize, out: [*c]V, outc: usize) callconv(.c) ?*c.wasmtime_error_t {
        const self: *Runtime = @ptrCast(@alignCast(data.?));
        if (!self.admit() or argc != 1 or outc != 1 or args[0].kind != c.WASMTIME_COMPONENT_U32) return failure();
        const ms = args[0].of.u32;
        if (ms != 0 and (ms < 100 or ms > 86400000)) return failure();
        self.next_timer = ms;
        success(out);
        return null;
    }
    fn activity(data: ?*anyopaque, _: ?*c.wasmtime_context_t, _: ?*const c.wasmtime_component_func_type_t, args: [*c]V, argc: usize, out: [*c]V, outc: usize) callconv(.c) ?*c.wasmtime_error_t {
        const self: *Runtime = @ptrCast(@alignCast(data.?));
        if (!self.admit() or argc != 1 or outc != 1 or args[0].kind != c.WASMTIME_COMPONENT_BOOL) return failure();
        out[0] = string(if (self.grants.input_activity) "unsupported" else "permission-denied", c.WASMTIME_COMPONENT_ENUM);
        return null;
    }
};
