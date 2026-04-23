// src/integration_p3.zig
// Phase3 状态机全生命周期集成测试：纯原始物理操作，无任何封装幻觉API
const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const core = @import("core.zig");
const storage = @import("storage.zig");
const io_uring = @import("io_uring.zig");
const protocol = @import("protocol.zig");

test "Integration: Protocol State Machine Lifecycle & Defenses" {
    // ==========================================
    // 1. 初始化：纯原始物理操作构造测试Header
    // ==========================================
    var window = storage.StreamWindow.init();
    var test_header = core.TokenStreamHeader.init();
    // 模板1：原始mem写入，无.set_xxx()幻觉API
    mem.writeInt(u64, test_header.data[0..8], 42, .little);
    mem.writeInt(u32, test_header.data[8..12], 100, .little);
    window.push_header(test_header);

    // 初始化Protocol大脑
    var proto = protocol.Protocol.init(&window);

    // ==========================================
    // 断言0：初始Idle状态验证
    // ==========================================
    const state0 = proto.step();
    try testing.expectEqual(protocol.State.Idle, state0);

    // 触发接收流程
    proto.begin_receive(42);

    // ==========================================
    // 刺探1：流ID劫持攻击，纯原始字段操作提交SQE
    // ==========================================
    // 模板2：无.submit()幻觉API，直接操作ring原始字段
    const idx_hijack = proto.reactor.ring.sq_tail & io_uring.SQ_MASK;
    proto.reactor.ring.sq_entries[idx_hijack] = io_uring.SubmissionEntry{
        .op_code = @intFromEnum(io_uring.IOOp.Read),
        .fd = 0,
        .buf_ptr = null,
        .buf_len = 13,
        .offset = 0,
        .user_data = 99, // 非法流ID，模拟劫持
    };
    proto.reactor.ring.sq_tail += 1; // 原始指针推进

    // 断言1：防篡改雷达生效，触发mismatch错误
    const state1 = proto.step();
    try testing.expectEqual(protocol.State.Error, state1);
    if (state1 == .Error) {
        try testing.expect(mem.indexOf(u8, state1.Error.reason, "mismatch") != null);
    }

    // ==========================================
    // 测试脏手段：复活状态机
    // ==========================================
    proto.state = .Idle;
    proto.begin_receive(42);

    // ==========================================
    // 正常流程：Header接收，原始字段操作
    // ==========================================
    const idx_header = proto.reactor.ring.sq_tail & io_uring.SQ_MASK;
    proto.reactor.ring.sq_entries[idx_header] = io_uring.SubmissionEntry{
        .op_code = @intFromEnum(io_uring.IOOp.Read),
        .fd = 0,
        .buf_ptr = null,
        .buf_len = 13,
        .offset = 0,
        .user_data = 42,
    };
    proto.reactor.ring.sq_tail += 1;

    // 断言2：成功进入Body接收阶段
    const state2 = proto.step();
    try testing.expectEqual(protocol.State.BodyRecv, state2);

    // ==========================================
    // 正常流程：Body碎片1（消费40字节），原始字段操作
    // ==========================================
    const idx_body1 = proto.reactor.ring.sq_tail & io_uring.SQ_MASK;
    proto.reactor.ring.sq_entries[idx_body1] = io_uring.SubmissionEntry{
        .op_code = @intFromEnum(io_uring.IOOp.Read),
        .fd = 0,
        .buf_ptr = null,
        .buf_len = 40,
        .offset = 0,
        .user_data = 42,
    };
    proto.reactor.ring.sq_tail += 1;

    // 断言3：仍在Body接收阶段，剩余60字节
    const state3 = proto.step();
    try testing.expectEqual(protocol.State.BodyRecv, state3);

    // ==========================================
    // 刺探2：长度下溢攻击，原始字段操作
    // ==========================================
    const idx_underflow = proto.reactor.ring.sq_tail & io_uring.SQ_MASK;
    proto.reactor.ring.sq_entries[idx_underflow] = io_uring.SubmissionEntry{
        .op_code = @intFromEnum(io_uring.IOOp.Read),
        .fd = 0,
        .buf_ptr = null,
        .buf_len = 70, // 剩余仅60字节，强行吃70触发溢出
        .offset = 0,
        .user_data = 42,
    };
    proto.reactor.ring.sq_tail += 1;

    // 断言4：ALU溢出捕获生效，触发underflow错误
    const state4 = proto.step();
    try testing.expectEqual(protocol.State.Error, state4);
    if (state4 == .Error) {
        try testing.expect(mem.indexOf(u8, state4.Error.reason, "underflow") != null);
    }

    // ==========================================
    // 复活状态机：此时header的total_len仍为60（非法扣减被拦截，未修改业务内存）
    // ==========================================
    proto.state = .Idle;
    proto.begin_receive(42);

    // ==========================================
    // 正常流程：Body碎片2（消费剩余60字节），原始字段操作
    // ==========================================
    const idx_body2 = proto.reactor.ring.sq_tail & io_uring.SQ_MASK;
    proto.reactor.ring.sq_entries[idx_body2] = io_uring.SubmissionEntry{
        .op_code = @intFromEnum(io_uring.IOOp.Read),
        .fd = 0,
        .buf_ptr = null,
        .buf_len = 60,
        .offset = 0,
        .user_data = 42,
    };
    proto.reactor.ring.sq_tail += 1;

    // 断言5：合法归零，完成接收
    const state5 = proto.step();
    try testing.expectEqual(protocol.State.BodyDone, state5);

    // ==========================================
    // 终态校验：原始mem读取，验证业务内存完整性
    // ==========================================
    // 模板3：无.total_len()幻觉API，直接读取字节数组
    const final_header = window.access_header(42).?;
    const final_len = mem.readInt(u32, final_header.data[8..12], .little);
    try testing.expectEqual(@as(u32, 0), final_len);
}