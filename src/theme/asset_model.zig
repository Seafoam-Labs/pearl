//! Wire/persistence metadata with no decoder or GTK dependency.
pub const Declaration = struct { id: []const u8, path: []const u8 };
pub const Image = struct { id: []const u8, digest: []const u8, size: usize, width: u32, height: u32 };
pub const Blob = struct { digest: []const u8, bytes: []const u8 };
