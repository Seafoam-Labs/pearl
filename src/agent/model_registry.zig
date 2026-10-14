//! Immutable publisher revisions and LFS SHA256 values, verified 2026-10-14.
const std = @import("std");
pub const revision = "657e078c94084481950a2d555a941481f715536b";
pub const base_url = "https://huggingface.co/LiquidAI/LFM2.5-350M-GGUF/resolve/" ++ revision ++ "/";
pub const license_url = "https://huggingface.co/LiquidAI/LFM2.5-350M-GGUF/blob/" ++ revision ++ "/LICENSE";
pub const Model = struct { id: []const u8, name: [:0]const u8, filename: []const u8, bytes: usize, sha256: []const u8 };
pub const models = [_]Model{
    .{ .id = "liquid-lfm25-350m-q4km", .name = "LFM2.5-350M · Q4_K_M · 229 MB", .filename = "LFM2.5-350M-Q4_K_M.gguf", .bytes = 229312224, .sha256 = "7e6f72643caafc9a68256686638c4d7916f2cec76d1df478d4c3ddcd95a6aed4" },
    .{ .id = "liquid-lfm25-350m-q8", .name = "LFM2.5-350M · Q8_0 · 379 MB", .filename = "LFM2.5-350M-Q8_0.gguf", .bytes = 379217632, .sha256 = "be036a757295e550098b85e13f6af2735d0fa73b41e1156a40c7d8e8e32a5766" },
};
pub fn find(id: []const u8) ?Model {
    for (models) |model| if (std.mem.eql(u8, id, model.id)) return model;
    return null;
}
