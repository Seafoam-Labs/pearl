//! Immutable publisher revisions and LFS SHA256 values, verified 2026-10-15.
const std = @import("std");
pub const revision = "657e078c94084481950a2d555a941481f715536b";
pub const base_url = "https://huggingface.co/LiquidAI/LFM2.5-350M-GGUF/resolve/" ++ revision ++ "/";
pub const license_url = "https://huggingface.co/LiquidAI/LFM2.5-350M-GGUF/blob/" ++ revision ++ "/LICENSE";
pub const Model = struct {
    id: []const u8,
    name: [:0]const u8,
    filename: []const u8,
    bytes: usize,
    sha256: []const u8,
    base_url: []const u8 = @import("model_registry.zig").base_url,
    license_url: [:0]const u8 = @import("model_registry.zig").license_url,
    context_tokens: u32 = 4096,
    answer_tokens: u32 = 384,
    reasoning: bool = false,
    inference_seconds: u16 = 60,
};
pub const models = [_]Model{
    .{ .id = "liquid-lfm25-350m-q4km", .name = "LFM2.5-350M · Q4_K_M · 229 MB", .filename = "LFM2.5-350M-Q4_K_M.gguf", .bytes = 229312224, .sha256 = "7e6f72643caafc9a68256686638c4d7916f2cec76d1df478d4c3ddcd95a6aed4" },
    .{ .id = "liquid-lfm25-350m-q8", .name = "LFM2.5-350M · Q8_0 · 379 MB", .filename = "LFM2.5-350M-Q8_0.gguf", .bytes = 379217632, .sha256 = "be036a757295e550098b85e13f6af2735d0fa73b41e1156a40c7d8e8e32a5766" },
    .{
        .id = "qwen3-4b-instruct-2507-q4km",
        .name = "Qwen3-4B-Instruct-2507 · Q4_K_M · 2.50 GB",
        .filename = "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
        .bytes = 2497281120,
        .sha256 = "3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597",
        .base_url = "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/a06e946bb6b655725eafa393f4a9745d460374c9/",
        .license_url = "https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507/blob/main/LICENSE",
        .answer_tokens = 512,
        .inference_seconds = 180,
    },
    .{
        .id = "liquid-lfm25-26b-q4km",
        .name = "LFM2.5-2.6B · Q4_K_M · 1.67 GB",
        .filename = "LFM2.5-2.6B-Q4_K_M.gguf",
        .bytes = 1674455040,
        .sha256 = "02a8b7e17487d326e46d68ce0ba24211e1b80a14c4cd0597fa73c1cd697f52ed",
        .base_url = "https://huggingface.co/LiquidAI/LFM2.5-2.6B-GGUF/resolve/e7caca5d835a3901a8e0d63e94009429bafafdfc/",
        .license_url = "https://huggingface.co/LiquidAI/LFM2.5-2.6B-GGUF/blob/e7caca5d835a3901a8e0d63e94009429bafafdfc/LICENSE",
        .context_tokens = 8192,
        .answer_tokens = 4096,
        .reasoning = true,
        .inference_seconds = 300,
    },
    .{
        .id = "liquid-lfm25-12b-instruct-q4km",
        .name = "LFM2.5-1.2B-Instruct · Q4_K_M · 731 MB",
        .filename = "LFM2.5-1.2B-Instruct-Q4_K_M.gguf",
        .bytes = 730895168,
        .sha256 = "b1b3de114215d9507409a662a501a631095a479a419584e8a2ded6304b19b4f5",
        .base_url = "https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct-GGUF/resolve/8ed288026e23958ad9dfa92d53ed773a8eee7125/",
        .license_url = "https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct-GGUF/blob/8ed288026e23958ad9dfa92d53ed773a8eee7125/LICENSE",
        .answer_tokens = 512,
        .inference_seconds = 120,
    },
};
pub fn selection(id: []const u8) u32 {
    for (models, 0..) |model, i| if (std.mem.eql(u8, model.id, id)) return @intCast(i);
    return models.len; // Custom local model is always the final entry.
}
pub fn selected(index: u32) []const u8 {
    return if (index < models.len) models[index].id else "custom";
}
pub fn find(id: []const u8) ?Model {
    for (models) |model| if (std.mem.eql(u8, id, model.id)) return model;
    return null;
}

test "managed models have unique identities and immutable verified downloads" {
    for (models, 0..) |model, i| {
        try std.testing.expectEqualStrings(model.id, selected(selection(model.id)));
        try std.testing.expect(model.bytes > 0 and model.sha256.len == 64);
        for (model.sha256) |ch| try std.testing.expect(std.ascii.isHex(ch));
        const marker = std.mem.indexOf(u8, model.base_url, "/resolve/") orelse return error.UnpinnedModelDownload;
        const pinned = std.mem.trimEnd(u8, model.base_url[marker + 9 ..], "/");
        try std.testing.expectEqual(@as(usize, 40), pinned.len);
        for (pinned) |ch| try std.testing.expect(std.ascii.isHex(ch));
        for (models[i + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, model.id, other.id));
            try std.testing.expect(!std.mem.eql(u8, model.filename, other.filename));
        }
    }
    try std.testing.expectEqualStrings("custom", selected(selection("custom")));
}
