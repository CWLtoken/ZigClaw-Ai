// src/interface.zig
// Design blueprint for v3.0 – compile-time interface contracts
// 零运行时开销，所有绑定在编译期解析。不包含可执行代码。
//
// 使用方式：
//   const interface = @import("interface.zig");
//   const Executor = interface.ExecutorInterface;
//   // 具体实现类型通过 comptime 参数传入
//
// 本文件仅为类型锚点，不实现任何逻辑。
// 所有 VTable 函数指针均为编译期确定，无运行时间接调用开销。

const std = @import("std");
const sub_brain = @import("sub_brain.zig");
const token = @import("token.zig");

// 重新导出，方便引用
pub const Modality = sub_brain.Modality;
pub const TokenSequence = token.TokenSequence;

// ============================================================================
// 执行层契约（Execution Layer）
// ============================================================================

pub const ExecutorInterface = struct {
    /// VTable 类型：由实现者在编译期生成
    pub fn VTable(comptime Self: type) type {
        return struct {
            submit: *const fn(self: Self, op: anytype) anyerror!void,
            poll:   *const fn(self: Self, events: []Event) anyerror!void,
            close:  *const fn(self: Self) void,
        };
    }

    /// 异步操作类型
    pub const Op = union(enum) {
        accept: struct { fd: i32 },
        recv:   struct { fd: i32, buf: []u8 },
        send:   struct { fd: i32, data: []const u8 },
        close:  struct { fd: i32 },
    };

    /// 完成事件
    pub const Event = struct {
        op: Op,
        result: i32,
    };

    /// 错误类型（显式，不依赖 errno 隐式转换）
    pub const Error = error{
        WouldBlock,
        ConnectionRefused,
        TimedOut,
        BufferExhausted,
        IoUringSetupFailed,
        MmapFailed,
    };
};

// ============================================================================
// 存储层契约（Storage Layer）
// ============================================================================

pub const StorageInterface = struct {
    pub fn VTable(comptime Self: type) type {
        return struct {
            get: *const fn(self: Self, key: u64) ?[]const u8,
            set: *const fn(self: Self, key: u64, value: []const u8) anyerror!void,
        };
    }
};

// ============================================================================
// 编排层契约（Orchestration Layer）
// ============================================================================

/// 编排结果：调用方直接可见所有字段，无需猜测实现细节
pub const OrchestrateResult = struct {
    token_seq: *const TokenSequence,
};

pub const OrchestratorInterface = struct {
    pub fn VTable(comptime Self: type) type {
        return struct {
            /// 显式枚举 + 具体返回类型，替代 anytype/anyopaque
            orchestrate: *const fn(self: Self, input: []const u8, modality: Modality) anyerror!OrchestrateResult,
        };
    }
};

// ============================================================================
// 编译期契约验证模板
// 各层在公开头末尾通过 @hasDecl 验证其实现了对应契约
// 用法：在层文件末尾添加 comptime { _ = ContractVerifier.checkStorage(MyImpl); }
// ============================================================================

pub const ContractVerifier = struct {
    /// 验证类型 T 实现了 StorageInterface 契约（get + set）
    pub fn checkStorage(comptime T: type) void {
        comptime {
            if (!@hasDecl(T, "get")) @compileError("StorageInterface: missing 'get' on " ++ @typeName(T));
            if (!@hasDecl(T, "set")) @compileError("StorageInterface: missing 'set' on " ++ @typeName(T));
        }
    }

    /// 验证类型 T 实现了 ExecutorInterface 契约（submit + poll + close）
    pub fn checkExecutor(comptime T: type) void {
        comptime {
            if (!@hasDecl(T, "submit")) @compileError("ExecutorInterface: missing 'submit' on " ++ @typeName(T));
            if (!@hasDecl(T, "poll")) @compileError("ExecutorInterface: missing 'poll' on " ++ @typeName(T));
            if (!@hasDecl(T, "close")) @compileError("ExecutorInterface: missing 'close' on " ++ @typeName(T));
        }
    }

    /// 验证类型 T 实现了 OrchestratorInterface 契约（orchestrate）
    pub fn checkOrchestrator(comptime T: type) void {
        comptime {
            if (!@hasDecl(T, "orchestrate")) @compileError("OrchestratorInterface: missing 'orchestrate' on " ++ @typeName(T));
        }
    }
};
