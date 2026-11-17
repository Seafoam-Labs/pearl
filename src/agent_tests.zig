test {
    _ = @import("agent/config.zig");
    _ = @import("agent/intent.zig");
    _ = @import("agent/providers.zig");
    _ = @import("agent/extract.zig");
    _ = @import("agent/fetch.zig");
    _ = @import("agent/controller.zig");
    _ = @import("agent/protocol.zig");
    _ = @import("agent/sse.zig");
    _ = @import("agent/runtime_probe.zig");
    _ = @import("agent/runtime_install.zig");
    _ = @import("agent/compute.zig");
    _ = @import("agent/memory.zig");
    _ = @import("agent/model_registry.zig");
    _ = @import("agent/downloads.zig");
    _ = @import("agent/benchmark.zig");
    _ = @import("agent/telemetry.zig");
    _ = @import("agent/embed.zig");
    _ = @import("search/chunk.zig");
    _ = @import("search/store.zig");
    _ = @import("search/extract.zig");
    _ = @import("search/sandbox.zig");
    _ = @import("search/indexer.zig");
    _ = @import("search/service.zig");
    _ = @import("search/schedule.zig");
    _ = @import("search/watch.zig");
}
