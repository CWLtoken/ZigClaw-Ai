const std = @import("std");
const testing = std.testing;
const core = @import("core.zig");
const storage = @import("storage.zig");
const io_uring = @import("io_uring.zig");
const reactor = @import("reactor.zig");

test "Integration: Reactor Consumes Storage" {
    // 步骤1：初始化窗口并推入 stream_id=42, total_len=1000
    var window = storage.StreamWindow.init();
    var header = core.TokenStreamHeader.init();
    header.set_stream_id(42);
    header.set_total_len(1000);
    window.push_header(header);

    // 步骤2：初始化反应器并绑定窗口
    var r = reactor.Reactor.init(&window);

    // 步骤3：提交 Read 任务，仅填写关键字段
    const sqe = io_uring.SubmissionEntry{
        .op_code = @intFromEnum(io_uring.IOOp.Read),
        .buf_len = 400,
        .user_data = 42,
    };
    _ = r.ring.submit(sqe);

    // 步骤4：poll 并验证完成事件
    const ev = r.poll();
    try testing.expect(ev == .IoComplete);
    try testing.expectEqual(ev.IoComplete.consumed, 400);
    try testing.expectEqual(ev.IoComplete.user_data, 42);

    // 步骤5：物理级验证剩余长度 = 600
    const opt_header = window.access_header(42);
    try testing.expect(opt_header != null);
    const remaining = std.mem.readInt(u32, opt_header.?.data[8..12], .little);
    try testing.expectEqual(remaining, 600);

    // 步骤6：验证队列已空
    const ev2 = r.poll();
    try testing.expect(ev2 == .Noop);
}