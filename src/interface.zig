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
//
// F3: VTable 升级为编译期签名验证
//   - ContractVerifier 现在检查完整函数签名（参数类型 + 返回类型）
//   - 而不仅仅是 @hasDecl 检查存在性
//   - 签名不匹配在编译期报 @compileError，精确定位错误

// interface.zig: 纯类型锚点，无 std 运行时依赖
const mem = @import("std").mem;
const sub_brain = @import("sub_brain.zig");
const token = @import("token.zig");

// 重新导出，方便引用
pub const Modality = sub_brain.Modality;
pub const TokenSequence = token.TokenSequence;

// ============================================================================
// 执行层契约（Execution Layer）
// ============================================================================

pub const ExecutorInterface = struct {
    pub fn VTable(comptime Self: type) type {
        return struct {
            submit: *const fn(self: Self, op: Op) anyerror!void,
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
            orchestrate: *const fn(self: Self, input: []const u8, modality: Modality, seq: *TokenSequence) anyerror!OrchestrateResult,
        };
    }
};

// ============================================================================
// F3: 编译期签名验证模板
// 各层在公开头末尾通过 @hasDecl + @typeInfo 验证其实现了对应契约
// 用法：在层文件末尾添加 comptime { _ = ContractVerifier.checkStorage(MyImpl); }
//
// 验证内容：
//   1. 方法存在性 (@hasDecl)
//   2. 返回类型匹配 (@typeInfo 比较)
//   3. 参数数量匹配
//   4. 参数类型匹配（Self 参数除外）
// ============================================================================

pub const ContractVerifier = struct {
    /// 验证类型 T 实现了 StorageInterface 契约（get + set）
    pub fn checkStorage(comptime T: type) void {
        comptime {
            if (!@hasDecl(T, "get")) @compileError("StorageInterface: missing 'get' on " ++ @typeName(T));
            if (!@hasDecl(T, "set")) @compileError("StorageInterface: missing 'set' on " ++ @typeName(T));

            // F3: 签名验证
            checkFnSignature(T, "get", ?[]const u8, &.{ u64 });
            checkFnSignature(T, "set", anyerror!void, &.{ u64, []const u8 });
        }
    }

    /// 验证类型 T 实现了 ExecutorInterface 契约（submit + poll + close）
    pub fn checkExecutor(comptime T: type) void {
        comptime {
            if (!@hasDecl(T, "submit")) @compileError("ExecutorInterface: missing 'submit' on " ++ @typeName(T));
            if (!@hasDecl(T, "poll")) @compileError("ExecutorInterface: missing 'poll' on " ++ @typeName(T));
            if (!@hasDecl(T, "close")) @compileError("ExecutorInterface: missing 'close' on " ++ @typeName(T));

            // F3: 签名验证
            checkFnSignature(T, "submit", anyerror!void, &.{ ExecutorInterface.Op });
            checkFnSignature(T, "poll", anyerror!void, &.{ []ExecutorInterface.Event });
            checkFnSignature(T, "close", void, &.{});
        }
    }

    /// 验证类型 T 实现了 OrchestratorInterface 契约（orchestrate）
    pub fn checkOrchestrator(comptime T: type) void {
        comptime {
            if (!@hasDecl(T, "orchestrate")) @compileError("OrchestratorInterface: missing 'orchestrate' on " ++ @typeName(T));

            // F3: 签名验证
            checkFnSignature(T, "orchestrate", anyerror!OrchestrateResult, &.{ []const u8, Modality, *TokenSequence });
        }
    }

    /// 返回类型兼容检查
    /// 规则：
    ///   - 完全相同 → 匹配
    ///   - 期望 anyerror!X，实际 error_set!X → 匹配（更严格的错误集是合理的）
    ///   - 期望 error_set_parent!X，实际 error_set_child!X → 匹配（子集关系）
    ///   - 期望 X，实际 X → 匹配
    ///   - 其他 → 不匹配
    ///
    /// ErrorSet 子集校验：
    ///   如果期望是 error{A,B,C}!X，实际是 error{A,B}!X，则匹配（子集）
    ///   如果期望是 error{A,B}!X，实际是 error{A,B,C}!X，则不匹配（超集）
    ///   如果期望是 anyerror!X，实际是任意 error_set!X，则匹配
    fn retTypeMatches(comptime actual: type, comptime expected: type) bool {
        if (actual == expected) return true;
        // 检查是否是 error union 兼容
        const actual_info = @typeInfo(actual);
        const expected_info = @typeInfo(expected);
        if (actual_info == .@"error_union" and expected_info == .@"error_union") {
            // payload 类型必须匹配
            if (actual_info.@"error_union".payload != expected_info.@"error_union".payload) {
                return false;
            }
            const actual_err_set = actual_info.@"error_union".error_set;
            const expected_err_set = expected_info.@"error_union".error_set;

            // 期望 anyerror!X，实际任意 error_set!X → 匹配
            if (expected_err_set == anyerror) return true;

            // 实际是 anyerror，期望不是 → 不匹配（anyerror 不是任何 error_set 的子集）
            if (actual_err_set == anyerror) return false;

            // ErrorSet 子集关系校验：
            // actual_err_set 和 expected_err_set 都是 type（error set 类型）
            // 用 @typeInfo 获取错误列表
            const actual_errs = @typeInfo(actual_err_set).@"error_set".?;
            const expected_errs = @typeInfo(expected_err_set).@"error_set".?;

            // 如果 actual 的错误数量 > expected，一定不是子集
            if (actual_errs.len > expected_errs.len) return false;

            // 检查 actual 的每个错误是否都在 expected 中
            for (actual_errs) |actual_err| {
                var found = false;
                for (expected_errs) |expected_err| {
                    if (mem.eql(u8, actual_err.name, expected_err.name)) {
                        found = true;
                        break;
                    }
                }
                if (!found) return false;
            }
            return true;
        }
        return false;
    }

    /// 编译期函数签名验证核心
    /// 检查 T 的函数 fn_name 的返回类型和参数类型是否匹配期望
    /// expected_params 是不含 Self 参数的参数类型列表
    fn checkFnSignature(comptime T: type, comptime fn_name: []const u8, comptime expected_return: type, comptime expected_params: []const type) void {
        comptime {
            const fn_type = @TypeOf(@field(T, fn_name));
            const type_info = @typeInfo(fn_type);
            if (type_info != .@"fn") {
                @compileError(@typeName(T) ++ "." ++ fn_name ++ " is not a function (got " ++ @tagName(type_info) ++ ")");
            }
            const fn_info = type_info.@"fn";

            // 验证返回类型（对 error union 做兼容检查）
            // 如果期望是 anyerror!X，实际是 error_set!X 也通过（更严格的错误集是合理的）
            if (fn_info.return_type == null) {
                @compileError(@typeName(T) ++ "." ++ fn_name ++ " has no return type (expected " ++ @typeName(expected_return) ++ ")");
            }
            const actual_ret = fn_info.return_type.?;
            if (!retTypeMatches(actual_ret, expected_return)) {
                @compileError(@typeName(T) ++ "." ++ fn_name ++ " return type mismatch: got " ++ @typeName(actual_ret) ++ ", expected " ++ @typeName(expected_return));
            }

            // 验证参数数量（第一个参数是 Self/Self指针，跳过）
            // 支持 self: T, *T, *const T
            const first_param_type = if (fn_info.params.len > 0) fn_info.params[0].type else null;
            const is_self_param = if (first_param_type) |pt| (pt == T or pt == *T or pt == *const T) else false;
            const self_param_count: usize = if (is_self_param) 1 else 0;
            const actual_param_count = fn_info.params.len - self_param_count;
            if (actual_param_count != expected_params.len) {
                @compileError(@typeName(T) ++ "." ++ fn_name ++ " param count mismatch");
            }

            // 验证每个参数类型
            var i: usize = 0;
            while (i < expected_params.len) : (i += 1) {
                const actual_idx = i + self_param_count;
                const actual_param = fn_info.params[actual_idx].type;
                if (actual_param != expected_params[i]) {
                    @compileError(@typeName(T) ++ "." ++ fn_name ++ " param type mismatch");
                }
            }
        }
    }
};
