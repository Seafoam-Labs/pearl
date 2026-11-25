pub var enabled = false;
pub fn directory() [:0]const u8 {
    return if (enabled) "coral-workspace" else "coral";
}
