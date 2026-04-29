// src/integration_p22.zig
// ZigClaw V2.4 Phase12 | 压力测试 | StreamWindow 64槽位填满
const std = @import("std");
const router = @import("router.zig");
const testing = std.testing;
const mem = std.mem;
const core = @import("core.zig");
const storage = @import("storage.zig");

test "P22-S1: StreamWindow 64槽位填满" {
    var window = storage.StreamWindow.init();
    try testing.expectEqual(@as(u64, 0), window.len);

    // 添加64个 header
    var i: u32 = 0;
    while (i < 64) : (i += 1) {
        var header = core.TokenStreamHeader.init();
        mem.writeInt(u64, header.data[0..8], 1000 + i, .little);
        mem.writeInt(u32, header.data[8..12], 100, .little);
        window.push_header(header);
        try testing.expectEqual(@as(u64, i + 1), window.len);
    }
    try testing.expectEqual(@as(u64, 64), window.len);

    // 尝试添加第65个（应该被静默丢弃）
    var header65 = core.TokenStreamHeader.init();
    mem.writeInt(u64, header65.data[0..8], 1064, .little);
    window.push_header(header65);
    try testing.expectEqual(@as(u64, 64), window.len); // 仍然是64
}

test "P22-S2: 验证所有64个槽位可访问并释放" {
    var window = storage.StreamWindow.init();

    // 添加64个 header
    var i: u32 = 0;
    while (i < 64) : (i += 1) {
        var header = core.TokenStreamHeader.init();
        mem.writeInt(u64, header.data[0..8], 2000 + i, .little);
        window.push_header(header);
    }

    // 验证所有64个槽位可访问
    i = 0;
    while (i < 64) : (i += 1) {
        const stream_id: u64 = 2000 + i;
        const h = window.access_header(stream_id);
        try testing.expect(h != null);
        const id = mem.readInt(u64, h.?.data[0..8], .little);
        try testing.expectEqual(stream_id, id);
    }

    // 释放所有槽位并验证
    i = 0;
    while (i < 64) : (i += 1) {
        window.release_header(2000 + i);
        try testing.expectEqual(@as(u64, 64 - i - 1), window.len);
    }
    try testing.expectEqual(@as(u64, 0), window.len);
}
