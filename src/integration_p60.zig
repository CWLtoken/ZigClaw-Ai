// src/integration_p60.zig
// F3: 更严格 comptime 合约集成测试
// 验证 ContractVerifier 的编译期签名检查功能

const testing = @import("std").testing;
const interface = @import("interface.zig");

// ============================================================================
// 测试用的模拟类型
// ============================================================================

// 正确的 Storage 实现（应该通过验证）
const GoodStorage = struct {
    data: u64 = 0,

    pub fn get(self: *const GoodStorage, key: u64) ?[]const u8 {
        _ = self;
        _ = key;
        return null;
    }

    pub fn set(self: *GoodStorage, key: u64, value: []const u8) anyerror!void {
        _ = self;
        _ = key;
        _ = value;
    }
};

// 缺少 get 的 Storage 实现（应该失败）
const BadStorageNoGet = struct {
    pub fn set(self: *BadStorageNoGet, key: u64, value: []const u8) anyerror!void {
        _ = self;
        _ = key;
        _ = value;
    }
};

// 正确签名的 Orchestrator 实现
const GoodOrchestrator = struct {
    pub fn orchestrate(self: *const GoodOrchestrator, input: []const u8, modality: interface.Modality, seq: *interface.TokenSequence) anyerror!interface.OrchestrateResult {
        _ = self;
        _ = input;
        _ = modality;
        return interface.OrchestrateResult{ .token_seq = seq };
    }
};

// ============================================================================
// 编译期验证测试
// ============================================================================

test "P60-1: GoodStorage 通过 StorageInterface 验证" {
    // 这个测试如果能编译通过，说明 checkStorage 对正确实现不报错
    interface.ContractVerifier.checkStorage(GoodStorage);
}

test "P60-2: GoodOrchestrator 通过 OrchestratorInterface 验证" {
    // 这个测试如果能编译通过，说明 checkOrchestrator 对正确实现不报错
    interface.ContractVerifier.checkOrchestrator(GoodOrchestrator);
}

test "P60-3: VTable 类型定义正确" {
    // 验证 VTable 类型可以实例化
    const ExecutorVTable = interface.ExecutorInterface.VTable(GoodOrchestrator);
    const vtable = ExecutorVTable{
        .submit = undefined,
        .poll = undefined,
        .close = undefined,
    };
    _ = vtable;
}

test "P60-4: OrchestrateResult 类型大小非零" {
    // 验证 OrchestrateResult 是一个有效的结构类型
    try testing.expect(@sizeOf(interface.OrchestrateResult) > 0);
}

test "P60-5: ExecutorInterface Op/Event 类型正确" {
    const op = interface.ExecutorInterface.Op{ .accept = .{ .fd = 42 } };
    const event = interface.ExecutorInterface.Event{ .op = op, .result = 0 };
    try testing.expectEqual(@as(i32, 42), event.op.accept.fd);
}
