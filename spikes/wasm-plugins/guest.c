__attribute__((import_module("pearl"), import_name("increment")))
extern unsigned increment(unsigned value);

unsigned run(unsigned value) { return increment(value) + 1; }
