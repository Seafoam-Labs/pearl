//! Feasibility probe only: no GTK, shell, filesystem or WASI guest capabilities.
const std = @import("std");
const c = @import("wasmtime");

comptime {
    if (c.WASMTIME_VERSION_MAJOR != 48 or c.WASMTIME_VERSION_MINOR != 0 or c.WASMTIME_VERSION_PATCH != 2)
        @compileError("This probe is pinned to Wasmtime 48.0.2 headers and library");
}

fn check(err: ?*c.wasmtime_error_t) !void {
    if (err) |e| {
        defer c.wasmtime_error_delete(e);
        var message: c.wasm_byte_vec_t = undefined;
        c.wasmtime_error_message(e, &message);
        defer c.wasm_byte_vec_delete(&message);
        std.debug.print("Wasmtime error: {s}\n", .{message.data[0..message.size]});
        return error.Wasmtime;
    }
}

fn increment(_: ?*anyopaque, _: ?*c.wasmtime_context_t, _: ?*const c.wasmtime_component_func_type_t, args: [*c]c.wasmtime_component_val_t, argc: usize, results: [*c]c.wasmtime_component_val_t, resultc: usize) callconv(.c) ?*c.wasmtime_error_t {
    if (argc != 1 or resultc != 1 or args[0].kind != c.WASMTIME_COMPONENT_U32)
        return c.wasmtime_error_new("invalid probe callback signature");
    results[0] = .{ .kind = c.WASMTIME_COMPONENT_U32, .of = .{ .u32 = args[0].of.u32 +% 1 } };
    return null;
}

fn probe(engine: *c.wasm_engine_t, label: []const u8, wat: []const u8, mode: enum { arithmetic, string, memory, fuel, missing_import }) !void {
    var bytes: c.wasm_byte_vec_t = undefined;
    try check(c.wasmtime_wat2wasm(wat.ptr, wat.len, &bytes));
    defer c.wasm_byte_vec_delete(&bytes);
    var component: ?*c.wasmtime_component_t = null;
    try check(c.wasmtime_component_new(engine, @ptrCast(bytes.data), bytes.size, &component));
    defer c.wasmtime_component_delete(component);
    const store = c.wasmtime_store_new(engine, null, null) orelse return error.Store;
    defer c.wasmtime_store_delete(store);
    c.wasmtime_store_limiter(store, 1024 * 1024, 1024, 8, 8, 2);
    const context = c.wasmtime_store_context(store);
    try check(c.wasmtime_context_set_fuel(context, 100_000));
    const linker = c.wasmtime_component_linker_new(engine);
    defer c.wasmtime_component_linker_delete(linker);
    if (mode != .missing_import) {
        const root = c.wasmtime_component_linker_root(linker);
        defer c.wasmtime_component_linker_instance_delete(root);
        try check(c.wasmtime_component_linker_instance_add_func(root, "increment", 9, increment, null, null));
    }
    var instance: c.wasmtime_component_instance_t = undefined;
    const instance_error = c.wasmtime_component_linker_instantiate(linker, context, component, &instance);
    if (mode == .missing_import) {
        if (instance_error) |e| c.wasmtime_error_delete(e) else return error.UnexpectedImportAccepted;
        std.debug.print("PASS {s}: undeclared host import rejected\n", .{label});
        return;
    }
    try check(instance_error);
    const index = c.wasmtime_component_get_export_index(component, null, "run", 3) orelse return error.Export;
    defer c.wasmtime_component_export_index_delete(index);
    var func: c.wasmtime_component_func_t = undefined;
    if (!c.wasmtime_component_instance_get_func(&instance, context, index, &func)) return error.Function;
    const arg: c.wasmtime_component_val_t = .{ .kind = c.WASMTIME_COMPONENT_U32, .of = .{ .u32 = 40 } };
    // 48.0.2 replaces/drops the previous result value; always initialize it.
    var result: c.wasmtime_component_val_t = std.mem.zeroes(c.wasmtime_component_val_t);
    const err = c.wasmtime_component_func_call(&func, context, if (mode == .arithmetic) &arg else null, if (mode == .arithmetic) 1 else 0, &result, 1);
    if (mode == .fuel) {
        const e = err orelse return error.InfiniteLoopDidNotTrap;
        defer c.wasmtime_error_delete(e);
        var message: c.wasm_byte_vec_t = undefined;
        c.wasmtime_error_message(e, &message);
        defer c.wasm_byte_vec_delete(&message);
        if (std.mem.indexOf(u8, message.data[0..message.size], "fuel") == null) return error.UnexpectedTrap;
        std.debug.print("PASS {s}: infinite loop stopped by fuel\n", .{label});
        return;
    }
    try check(err);
    defer c.wasmtime_component_val_delete(&result);
    switch (mode) {
        .arithmetic => if (result.kind != c.WASMTIME_COMPONENT_U32 or result.of.u32 != 42) return error.BadArithmetic,
        .string => if (result.kind != c.WASMTIME_COMPONENT_STRING or !std.mem.eql(u8, result.of.string.data[0..result.of.string.size], "hello")) return error.BadString,
        .memory => if (result.kind != c.WASMTIME_COMPONENT_S32 or result.of.s32 != -1) return error.MemoryLimitFailed,
        else => unreachable,
    }
    std.debug.print("PASS {s}\n", .{label});
}

pub fn main() !void {
    const config = c.wasm_config_new();
    c.wasmtime_config_wasm_component_model_set(config, true);
    c.wasmtime_config_consume_fuel_set(config, true);
    const engine = c.wasm_engine_new_with_config(config) orelse return error.Engine;
    defer c.wasm_engine_delete(engine);
    try probe(engine, "C guest -> Zig callback -> 42", @embedFile("c.component.wat"), .arithmetic);
    try probe(engine, "Zig guest -> Zig callback -> 42", @embedFile("zig.component.wat"), .arithmetic);
    try probe(engine, "missing import", @embedFile("c.component.wat"), .missing_import);
    try probe(engine, "canonical string result and cleanup",
        \\(component
        \\ (core module $m
        \\  (memory (export "memory") 1)
        \\  (data (i32.const 0) "\08\00\00\00\05\00\00\00hello")
        \\  (func (export "run") (result i32) i32.const 0))
        \\ (core instance $i (instantiate $m))
        \\ (func (export "run") (result string) (canon lift (core func $i "run") (memory $i "memory"))))
    , .string);
    try probe(engine, "linear memory growth capped at 1 MiB",
        \\(component
        \\ (core module $m
        \\  (memory 1)
        \\  (func (export "run") (result i32) i32.const 32 memory.grow))
        \\ (core instance $i (instantiate $m))
        \\ (func (export "run") (result s32) (canon lift (core func $i "run"))))
    , .memory);
    try probe(engine, "execution budget",
        \\(component
        \\ (core module $m
        \\  (func (export "run") (result i32) (loop $forever br $forever) i32.const 0))
        \\ (core instance $i (instantiate $m))
        \\ (func (export "run") (result u32) (canon lift (core func $i "run"))))
    , .fuel);
}
