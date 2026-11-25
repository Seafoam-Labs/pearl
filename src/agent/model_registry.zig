//! Immutable publisher revisions and LFS SHA256 values, verified 2026-11-21.
//! EmbeddingGemma 2 text-backbone profiles verified 2026-11-16 (issue #46).
const std = @import("std");
pub const revision = "cd0c74c575b5c416f3011b5b4c298077f26ca8c2";
pub const base_url = "https://huggingface.co/LiquidAI/LFM3-1.7B-GGUF/resolve/" ++ revision ++ "/";
pub const license_url = "https://huggingface.co/LiquidAI/LFM3-1.7B-GGUF/blob/" ++ revision ++ "/LICENSE";
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
    .{
        .id = "liquid-lfm3-17b-q4km",
        .name = "LFM3-1.7B · Q4_K_M · 1.10 GB",
        .filename = "LFM3-1.7B-Q4_K_M.gguf",
        .bytes = 1099627808,
        .sha256 = "3793e1e6e2266919d6e015287221b41100175a98eddaba92e111aed3b05c93c4",
        .context_tokens = 32768,
        .answer_tokens = 4096,
        .reasoning = true,
        .inference_seconds = 300,
    },
    .{
        .id = "liquid-lfm3-17b-q5km",
        .name = "LFM3-1.7B · Q5_K_M · 1.26 GB",
        .filename = "LFM3-1.7B-Q5_K_M.gguf",
        .bytes = 1258663200,
        .sha256 = "41e51fb0be5f472d323055f2734d986d5a2429570973508fa6322f3f07f6d7f3",
        .context_tokens = 32768,
        .answer_tokens = 4096,
        .reasoning = true,
        .inference_seconds = 300,
    },
    .{
        .id = "liquid-lfm3-17b-q8",
        .name = "LFM3-1.7B · Q8_0 · 1.85 GB",
        .filename = "LFM3-1.7B-Q8_0.gguf",
        .bytes = 1846238496,
        .sha256 = "8f6b24182258205e9e01e21f1f24a1f208c1e8115578825d202ce39976af20b6",
        .context_tokens = 32768,
        .answer_tokens = 4096,
        .reasoning = true,
        .inference_seconds = 300,
    },
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
};
/// Semantic search loads only the text backbone; the multimodal `mmproj`
/// projectors published beside these files are deliberately not downloaded.
pub const embedding_architecture = "gemma-embedding2";
pub const embedding_models = [_]Model{
    .{
        .id = "embeddinggemma-2-q8_0",
        .name = "EmbeddingGemma 2 · Q8_0 · 310 MB",
        .filename = "embeddinggemma-2-Q8_0.gguf",
        .bytes = 309855456,
        .sha256 = "2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135",
        .base_url = "https://huggingface.co/ggml-org/embeddinggemma-2-GGUF/resolve/6ea3e3a309d12a4779cfda98b8c19800d2d5da71/",
        .license_url = "https://www.apache.org/licenses/LICENSE-2.0.txt",
        .context_tokens = 2048,
        .inference_seconds = 60,
    },
    .{
        .id = "embeddinggemma-2-ud-q4_k_xl",
        .name = "EmbeddingGemma 2 · UD-Q4_K_XL · 176 MB",
        .filename = "embeddinggemma-2-UD-Q4_K_XL.gguf",
        .bytes = 175673856,
        .sha256 = "ea905fd08e8061db77a0031cbb5096d459d7cfd2bdd0ad2ba66e483f16719493",
        .base_url = "https://huggingface.co/unsloth/embeddinggemma-2-GGUF/resolve/031f0d4b35536f69ab3509d4893c923264fcf253/",
        .license_url = "https://www.apache.org/licenses/LICENSE-2.0.txt",
        .context_tokens = 2048,
        .inference_seconds = 60,
    },
};
pub fn findEmbedding(id: []const u8) ?Model {
    for (embedding_models) |model| if (std.mem.eql(u8, model.id, id)) return model;
    return null;
}
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

test "embedding profiles are pinned, unique and separate from chat models" {
    for (embedding_models, 0..) |model, i| {
        try std.testing.expect(findEmbedding(model.id) != null);
        try std.testing.expect(find(model.id) == null);
        try std.testing.expect(selection(model.id) == models.len);
        try std.testing.expect(model.bytes > 0 and model.sha256.len == 64);
        for (model.sha256) |ch| try std.testing.expect(std.ascii.isHex(ch));
        const marker = std.mem.indexOf(u8, model.base_url, "/resolve/") orelse return error.UnpinnedModelDownload;
        const pinned = std.mem.trimEnd(u8, model.base_url[marker + 9 ..], "/");
        try std.testing.expectEqual(@as(usize, 40), pinned.len);
        for (pinned) |ch| try std.testing.expect(std.ascii.isHex(ch));
        for (embedding_models[i + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, model.id, other.id));
            try std.testing.expect(!std.mem.eql(u8, model.filename, other.filename));
        }
        for (models) |chat| try std.testing.expect(!std.mem.eql(u8, model.filename, chat.filename));
    }
    try std.testing.expect(findEmbedding("custom") == null);
    try std.testing.expect(findEmbedding(models[0].id) == null);
}
