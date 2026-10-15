//! Assistant preferences contain no credentials or downloaded-model state.
const std = @import("std");
pub const ProviderKind = enum { google, searxng, brave, google_legacy, bing };
pub const Provider = struct {
    id: []const u8 = "bing",
    name: []const u8 = "Bing",
    kind: ProviderKind = .bing,
    enabled: bool = true,
    endpoint: []const u8 = "",
    engine_id: []const u8 = "",
    language: []const u8 = "en",
    safe_search: bool = true,
    pub fn validate(self: Provider) !void {
        try identifier(self.id);
        try text(self.name, 80);
        try text(self.endpoint, 1024);
        try text(self.engine_id, 128);
        try text(self.language, 16);
        if (self.name.len == 0) return error.ProviderNameRequired;
        if (self.endpoint.len > 0) {
            const uri = try std.Uri.parse(self.endpoint);
            if (!std.mem.eql(u8, uri.scheme, "https") and !std.mem.eql(u8, uri.scheme, "http")) return error.InvalidSearchEndpoint;
            if (uri.host == null or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return error.InvalidSearchEndpoint;
        }
    }
};
pub const default_providers = [_]Provider{.{}};
pub const RuntimeSource = enum { system, packaged, custom };
pub const Backend = enum { auto, vulkan, cuda };
pub const RuntimeConfig = struct { source: RuntimeSource = .system, executable: []const u8 = "" };
pub const Compute = struct {
    mode: enum { cpu, auto, gpu } = .cpu,
    backend: Backend = .auto,
    device_id: []const u8 = "",
    offload_layers: ?u16 = null,
    gpu_memory_target_mib: ?u32 = null,
    allow_cpu_fallback: bool = true,
    pub fn fallback(self: Compute) bool {
        return self.mode == .auto or (self.mode == .gpu and self.allow_cpu_fallback);
    }
};
pub const Config = struct {
    enabled: bool = false,
    runtime: RuntimeConfig = .{},
    compute: Compute = .{},
    model_id: []const u8 = "liquid-lfm25-350m-q4km",
    custom_model: []const u8 = "",
    providers: []const Provider = &default_providers,
    default_provider_id: []const u8 = "bing",
    search_mode: enum { default, all } = .default,
    read_pages: bool = true,
    // Zero selects the model profile or the runtime's CPU thread detection.
    context_tokens: u32 = 0,
    answer_tokens: u32 = 0,
    cpu_threads: u32 = 0,
    idle_unload_seconds: u16 = 60,
    pub fn validate(self: Config) !void {
        try text(self.runtime.executable, 4096);
        if (self.runtime.source == .custom and !std.fs.path.isAbsolute(self.runtime.executable)) return error.AbsoluteRuntimePathRequired;
        try text(self.compute.device_id, 512);
        if (self.compute.mode == .gpu and self.compute.device_id.len == 0) return error.SelectGpuDevice;
        if (self.compute.offload_layers) |n| if (n == 0 or n > 1024) return error.InvalidOffloadLayers;
        if (self.compute.gpu_memory_target_mib) |n| if (n < 128 or n > 1048576) return error.InvalidGpuMemoryTarget;
        try identifier(self.model_id);
        if (!std.mem.eql(u8, self.model_id, "custom") and @import("model_registry.zig").find(self.model_id) == null) return error.UnknownAssistantModel;
        try text(self.custom_model, 4096);
        if (self.custom_model.len > 0 and !std.fs.path.isAbsolute(self.custom_model)) return error.AbsoluteModelPathRequired;
        if (self.providers.len > 8) return error.TooManySearchProviders;
        var active: usize = 0;
        for (self.providers, 0..) |p, i| {
            try p.validate();
            if (p.enabled) active += 1;
            for (self.providers[0..i]) |other| if (std.mem.eql(u8, p.id, other.id)) return error.DuplicateSearchProvider;
        }
        if (self.default_provider_id.len > 0 and self.provider(self.default_provider_id) == null) return error.UnknownSearchProvider;
        if (self.search_mode == .all and active > 3) return error.TooManyEnabledProviders;
        if (self.contextTokens() > std.math.maxInt(c_int) or self.contextTokens() <= @as(u64, self.answerTokens()) + 700) return error.InvalidAssistantContext;
        if (self.cpu_threads > std.math.maxInt(c_int) or self.idle_unload_seconds < 15 or self.idle_unload_seconds > 300) return error.InvalidAssistantBudget;
    }
    pub fn contextTokens(self: Config) u32 {
        if (self.context_tokens != 0) return self.context_tokens;
        return if (@import("model_registry.zig").find(self.model_id)) |m| m.context_tokens else 4096;
    }
    pub fn answerTokens(self: Config) u32 {
        if (self.answer_tokens != 0) return self.answer_tokens;
        return if (@import("model_registry.zig").find(self.model_id)) |m| m.answer_tokens else 384;
    }
    pub fn inferenceSeconds(self: Config) u16 {
        return if (@import("model_registry.zig").find(self.model_id)) |m| m.inference_seconds else 300;
    }
    pub fn threads(self: Config) i32 {
        return if (self.cpu_threads == 0) -1 else @intCast(self.cpu_threads);
    }
    pub fn provider(self: Config, id: []const u8) ?Provider {
        for (self.providers) |p| if (std.mem.eql(u8, id, p.id)) return p;
        return null;
    }
    pub fn selected(self: Config, p: Provider) bool {
        return p.enabled and (self.search_mode == .all or std.mem.eql(u8, p.id, self.default_provider_id));
    }
};
test "runtime selection and compute budgets are explicit" {
    try std.testing.expectError(error.AbsoluteRuntimePathRequired, (Config{ .runtime = .{ .source = .custom, .executable = "llama-server --flag" } }).validate());
    try (Config{ .runtime = .{ .source = .custom, .executable = "/opt/local build/llama-server" } }).validate();
    try std.testing.expectError(error.SelectGpuDevice, (Config{ .compute = .{ .mode = .gpu } }).validate());
    try std.testing.expect((Compute{ .mode = .auto, .allow_cpu_fallback = false }).fallback());
    try std.testing.expect(!(Compute{ .mode = .gpu, .allow_cpu_fallback = false }).fallback());
}
pub fn identifier(value: []const u8) !void {
    if (value.len == 0 or value.len > 64) return error.InvalidAssistantId;
    for (value) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return error.InvalidAssistantId;
}
pub fn text(value: []const u8, max: usize) !void {
    if (value.len > max or !std.unicode.utf8ValidateSlice(value)) return error.InvalidAssistantText;
    for (value) |ch| if (ch < 32 or ch == 127) return error.InvalidAssistantText;
}
test "disabled default selects Bing RSS without requiring provider setup" {
    const cfg: Config = .{};
    try cfg.validate();
    try std.testing.expect(!cfg.enabled);
    try std.testing.expectEqual(ProviderKind.bing, cfg.provider("bing").?.kind);
    try std.testing.expectEqualStrings("", cfg.provider("bing").?.endpoint);
    try std.testing.expect(cfg.selected(cfg.providers[0]));
}
test "provider identity and endpoints are validated without a CPU thread cap" {
    try std.testing.expectError(error.DuplicateSearchProvider, (Config{ .providers = &.{ .{}, .{} } }).validate());
    try (Config{ .cpu_threads = 8 }).validate();
    try (Config{ .cpu_threads = 1024, .context_tokens = 131072, .answer_tokens = 8192 }).validate();
    try std.testing.expectError(error.InvalidSearchEndpoint, (Provider{ .endpoint = "https://user:secret@host" }).validate());
    try std.testing.expectError(error.UnknownSearchProvider, (Config{ .providers = &.{} }).validate());
    try (Config{ .providers = &.{}, .default_provider_id = "" }).validate();
}
test "saved configured providers retain their explicit default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try std.json.parseFromSliceLeaky(Config, arena.allocator(),
        \\{"providers":[{"id":"google","name":"Google","kind":"google","endpoint":"https://search.example.org"}],"default_provider_id":"google"}
    , .{});
    try cfg.validate();
    try std.testing.expect(cfg.selected(cfg.providers[0]));
    try std.testing.expectEqual(ProviderKind.google, cfg.providers[0].kind);
}

test "automatic model profiles and explicit resource choices survive round trips" {
    const registry = @import("model_registry.zig");
    for (registry.models) |model| {
        const automatic: Config = .{ .model_id = model.id };
        try automatic.validate();
        try std.testing.expectEqual(model.context_tokens, automatic.contextTokens());
        try std.testing.expectEqual(model.answer_tokens, automatic.answerTokens());
        try std.testing.expectEqual(@as(i32, -1), automatic.threads());
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = try std.json.parseFromSliceLeaky(Config, a, "{\"cpu_threads\":2,\"context_tokens\":2048,\"answer_tokens\":384}", .{});
    try old.validate();
    try std.testing.expectEqual(@as(i32, 2), old.threads());
    try std.testing.expectEqual(@as(u32, 2048), old.contextTokens());
    const explicit: Config = .{ .cpu_threads = 512, .context_tokens = 131072, .answer_tokens = 8192 };
    const copy = try std.json.parseFromSliceLeaky(Config, a, try std.json.Stringify.valueAlloc(a, explicit, .{}), .{});
    try copy.validate();
    try std.testing.expectEqual(@as(i32, 512), copy.threads());
    try std.testing.expectEqual(@as(u32, 131072), copy.contextTokens());
    try std.testing.expectEqual(@as(u32, 8192), copy.answerTokens());
    try std.testing.expectError(error.InvalidAssistantContext, (Config{ .context_tokens = 2048, .answer_tokens = 4096 }).validate());
}
