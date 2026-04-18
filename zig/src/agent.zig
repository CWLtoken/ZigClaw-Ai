const std = @import("std");

export fn execute_agent_default(precision: u32, entry: *anyopaque) u32 {
    _ = precision;
    _ = entry;
    return 0;
}

export fn execute_agent_explicit(precision: u32, entry: *anyopaque, temp_store: *anyopaque) u32 {
    _ = precision;
    _ = entry;
    _ = temp_store;
    return 0;
}
