//! Release identity injected by the build system (-Dversion or PEARL_VERSION);
//! not tracked in source. Packaging and CI supply the tag/pkgver.
const injected = @import("pearl_version").string;
pub const string: [:0]const u8 = injected[0..injected.len :0];
