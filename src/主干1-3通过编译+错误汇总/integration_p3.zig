// Phase3 状态机全生命周期集成测试 | 泥泞物理操作 | 防御性刺探
const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const core = @import("core.zig");
const storage = @import("storage.zig");
const io_uring = @import("io_uring.zig");
const protocol = @import("protocol.zig");

test "Integration: Protocol State Machine Lifecycle & Defenses" {
    var window = storage.StreamWindow.init();
    var test_header = core.TokenStreamHeader.init();
    mem.writeInt(u64, test_header.data[0..8], 42, .little);
    mem.writeInt(u32, test_header.data[8..12], 100, .little);
    window.push_header(test_header);

    var proto = protocol.Protocol.init(&window);

    try testing.expectEqual(protocol.State.Idle, proto.step());
    proto.begin_receive(42);

    {
        const idx = proto.reactor.ring.sq_tail & io_uring.SQ_MASK;
        proto.reactor.ring.sq_entries[idx] = .{ .op_code = @intFromEnum(io_uring.IOOp.Read), .fd = 0, .buf_ptr = null, .buf_len = 13, .offset = 0, .user_data = 99 };
        proto.reactor.ring.sq_tail += 1;
    }
    const s1 = proto.step();
    try testing.expectEqual(protocol.State.Error, s1);
    if (s1 == .Error) try testing.expect(mem.indexOf(u8, s1.Error.reason, "mismatch") != null);

    proto.state = .Idle;
    proto.begin_receive(42);

    {
        const idx = proto.reactor.ring.sq_tail & io_uring.SQ_MASK;
        proto.reactor.ring.sq_entries[idx] = .{ .op_code = @intFromEnum(io_uring.IOOp.Read), .fd = 0, .buf_ptr = null, .buf_len = 13, .offset = 0, .user_data = 42 };
        proto.reactor.ring.sq_tail += 1;
    }
    try testing.expectEqual(protocol.State.BodyRecv, proto.step());

    {
        const idx = proto.reactor.ring.sq_tail & io_uring.SQ_MASK;
        proto.reactor.ring.sq_entries[idx] = .{ .op_code = @intFromEnum(io_uring.IOOp.Read), .fd = 0, .buf_ptr = null, .buf_len = 40, .offset = 0, .user_data = 42 };
        proto.reactor.ring.sq_tail += 1;
    }
    try testing.expectEqual(protocol.State.BodyRecv, proto.step());

    {
        const idx = proto.reactor.ring.sq_tail & io_uring.SQ_MASK;
        proto.reactor.ring.sq_entries[idx] = .{ .op_code = @intFromEnum(io_uring.IOOp.Read), .fd = 0, .buf_ptr = null, .buf_len = 70, .offset = 0, .user_data = 42 };
        proto.reactor.ring.sq_tail += 1;
    }
    const s4 = proto.step();
    try testing.expectEqual(protocol.State.Error, s4);
    if (s4 == .Error) try testing.expect(mem.indexOf(u8, s4.Error.reason, "underflow") != null);

    proto.state = .Idle;
    proto.begin_receive(42);
    {
        // 【架构师裁决：修复笔误，补齐 .ring】
        const idx = proto.reactor.ring.sq_tail & io_uring.SQ_MASK;
        proto.reactor.ring.sq_entries[idx] = .{ .op_code = @intFromEnum(io_uring.IOOp.Read), .fd = 0, .buf_ptr = null, .buf_len = 60, .offset = 0, .user_data = 42 };
        proto.reactor.ring.sq_tail += 1;
    }
    try testing.expectEqual(protocol.State.BodyDone, proto.step());

    const final_header = window.access_header(42).?;
    const final_len = mem.readInt(u32, final_header.data[8..12], .little);
    try testing.expectEqual(@as(u32, 0), final_len);
}