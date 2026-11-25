const coral = @import("coral");
pub const std_options = coral.std_options;

pub fn main(init: @import("std").process.Init) void {
    coral.run(init, true);
}
