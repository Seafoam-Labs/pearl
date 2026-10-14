//! Assistant preferences contain no credentials or downloaded-model state.
const std = @import("std");
pub const ProviderKind = enum { google, searxng, brave, google_legacy };
pub const Provider = struct {
    id: []const u8 = "google",
    name: []const u8 = "Google",
    kind: ProviderKind = .google,
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
pub const Config = struct {
    enabled: bool = false,
    model_id: []const u8 = "liquid-lfm25-350m-q4km",
    custom_model: []const u8 = "",
    providers: []const Provider = &default_providers,
    default_provider_id: []const u8 = "google",
    search_mode: enum { default, all } = .default,
    read_pages: bool = true,
    context_tokens: u16 = 4096,
    answer_tokens: u16 = 384,
    cpu_threads: u8 = 2,
    idle_unload_seconds: u16 = 60,
    pub fn validate(self: Config) !void {
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
        if (self.context_tokens != 2048 and self.context_tokens != 4096) return error.InvalidAssistantContext;
        if (self.answer_tokens < 64 or self.answer_tokens > 512 or self.cpu_threads < 1 or self.cpu_threads > 2 or self.idle_unload_seconds < 15 or self.idle_unload_seconds > 300) return error.InvalidAssistantBudget;
    }
    pub fn provider(self: Config, id: []const u8) ?Provider {
        for (self.providers) |p| if (std.mem.eql(u8, id, p.id)) return p;
        return null;
    }
    pub fn selected(self: Config, p: Provider) bool {
        return p.enabled and (self.search_mode == .all or std.mem.eql(u8, p.id, self.default_provider_id));
    }
};
pub fn identifier(value: []const u8) !void {
    if (value.len == 0 or value.len > 64) return error.InvalidAssistantId;
    for (value) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return error.InvalidAssistantId;
}
pub fn text(value: []const u8, max: usize) !void {
    if (value.len > max or !std.unicode.utf8ValidateSlice(value)) return error.InvalidAssistantText;
    for (value) |ch| if (ch < 32 or ch == 127) return error.InvalidAssistantText;
}
test "disabled default selects Google without configuring or contacting a service" {
    const cfg: Config = .{};
    try cfg.validate();
    try std.testing.expect(!cfg.enabled);
    try std.testing.expectEqual(ProviderKind.google, cfg.provider("google").?.kind);
    try std.testing.expectEqualStrings("", cfg.provider("google").?.endpoint);
}
test "provider identity, endpoint and CPU budgets are strict" {
    try std.testing.expectError(error.DuplicateSearchProvider, (Config{ .providers = &.{ .{}, .{} } }).validate());
    try std.testing.expectError(error.InvalidAssistantBudget, (Config{ .cpu_threads = 8 }).validate());
    try std.testing.expectError(error.InvalidSearchEndpoint, (Provider{ .endpoint = "https://user:secret@host" }).validate());
    try std.testing.expectError(error.UnknownSearchProvider, (Config{ .providers = &.{} }).validate());
    try (Config{ .providers = &.{}, .default_provider_id = "" }).validate();
}
