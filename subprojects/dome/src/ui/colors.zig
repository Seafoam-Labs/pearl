//! Owned rendering values: never retain a borrowed Pearl snapshot in a graph.
pub const RGB = [3]f64;
pub const Colors = struct {
    native: bool = true,
    text: RGB = .{ 0.9, 0.9, 0.9 },
    series: [6]RGB = dark,

    pub const dark = [6]RGB{ .{ 0.816, 0.737, 1 }, .{ 0.93, 0.737, 0.627 }, .{ 0.65, 0.84, 0.71 }, .{ 0.655, 0.784, 0.98 }, .{ 0.91, 0.71, 0.83 }, .{ 0.86, 0.81, 0.58 } };
    pub const light = [6]RGB{ .{ 0.404, 0.314, 0.643 }, .{ 0.58, 0.33, 0.18 }, .{ 0.2, 0.44, 0.3 }, .{ 0.22, 0.38, 0.59 }, .{ 0.58, 0.32, 0.47 }, .{ 0.46, 0.4, 0.12 } };
};
