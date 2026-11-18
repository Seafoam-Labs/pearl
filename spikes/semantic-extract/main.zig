//! Manual spike: verifies the sandboxed pdftotext boundary and chunker against
//! the semantic fixture corpus. Not part of the default build; compile with:
//!   zig build-exe -lc --dep extract --dep chunk \
//!     -Mroot=spikes/semantic-extract/main.zig \
//!     -Mextract=src/search/extract.zig -Mchunk=src/search/chunk.zig \
//!     --name semantic-extract-check -femit-bin=.cache/semantic-extract-check
//! and run from the repository root. Requires bubblewrap and Poppler.
const std = @import("std");
const extract = @import("extract");
const chunk = @import("chunk");
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    std.debug.print("pdf sandbox available: {}\n", .{extract.pdfAvailable()});
    const pdf_text = try extract.pdf(a, "tests/fixtures/semantic/lease.pdf");
    std.debug.print("pdf extracted {d} bytes:\n{s}\n", .{ pdf_text.len, pdf_text });
    const passages = try chunk.chunk(a, pdf_text);
    std.debug.print("pdf passages: {d}\n", .{passages.len});
    const md = try extract.text(a, "tests/fixtures/semantic/notes.md");
    const md_passages = try chunk.chunk(a, md);
    std.debug.print("md extracted {d} bytes, {d} passages\n", .{ md.len, md_passages.len });
    for (md_passages) |p| std.debug.print("md passage: {s}\n", .{p});
}
