extern "pearl" fn increment(value: u32) u32;

export fn run(value: u32) u32 {
    return increment(value) + 1;
}
