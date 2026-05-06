// src/context.zig
// 观测层 | Layer: Observability
// 全局请求ID生成器（原子操作，零堆分配）

const std = @import("std");
const builtin = @import("builtin");

/// 全局请求ID计数器（原子操作，无锁）
/// 使用 fetchAdd 保证多线程安全（虽然当前单线程）
var global_request_id: u64 = 0;

/// 请求上下文（贯穿全链路）
pub const RequestContext = struct {
    id: u64,                    // 唯一请求ID
    timestamp_ms: i64,          // 请求到达时间戳
    method: []const u8,         // HTTP方法（切片引用，不拷贝）
    path: []const u8,           // 请求路径（切片引用）
    auth_token_hash: ?u64,      // Authorization token哈希（可选）
    
    /// 生成新的请求上下文（自动分配唯一ID）
    pub fn init(method: []const u8, path: []const u8) RequestContext {
        // 原子递增，返回新值（旧值+1）
        const old_id = @atomicRmw(u64, &global_request_id, .Add, 1, .seq_cst);
        const id = old_id + 1;
        return .{
            .id = id,
            .timestamp_ms = 0, // TODO: implement real timestamp for Zig 0.16
            .method = method,
            .path = path,
            .auth_token_hash = null,
        };
    }
    
    /// 设置鉴权token哈希
    pub fn setAuthToken(self: *RequestContext, token_hash: u64) void {
        self.auth_token_hash = token_hash;
    }
    
    /// 格式化请求ID为字符串（写入给定缓冲区，零分配）
    /// 返回写入的字节数
    pub fn formatId(self: *const RequestContext, buf: []u8) u16 {
        // 缓冲区足够大（32字节），REQUEST-XXXX 最多不超过20字节，所以不会失败
        const result = std.fmt.bufPrint(buf, "REQ-{d}", .{self.id}) catch unreachable;
        return @intCast(result.len);
    }
    
    /// 获取格式化后的请求ID（临时缓冲区版本，调用者需确保生命周期）
    pub fn getFormattedId(self: *const RequestContext) [32]u8 {
        var buf: [32]u8 = undefined;
        const len = self.formatId(&buf);
        var result: [32]u8 = undefined;
        @memcpy(result[0..len], buf[0..len]);
        // 余下部分清零
        if (len < 32) {
            @memset(result[len..], 0);
        }
        return result;
    }
};

/// 重置全局计数器（主要用于测试）
pub fn resetRequestCounter() void {
    _ = @atomicRmw(u64, &global_request_id, .Xchg, 0, .seq_cst);
}

/// 获取当前请求计数（用于/health?verbose=true显示）
pub fn getRequestCount() u64 {
    return @atomicLoad(u64, &global_request_id, .seq_cst);
}

// 单元测试（P47）
const std_debug = std.debug;
const mem = std.mem;

test "P47: RequestContext 初始化和ID唯一性" {
    resetRequestCounter();
    
    const ctx1 = RequestContext.init("POST", "/v1/infer");
    const ctx2 = RequestContext.init("GET", "/health");
    
    std_debug.assert(ctx1.id == 1);
    std_debug.assert(ctx2.id == 2);
    std_debug.assert(ctx1.id != ctx2.id);
    std_debug.print("P47: 请求ID生成测试通过，ctx1={d}, ctx2={d}\n", .{ctx1.id, ctx2.id});
}

test "P47: RequestContext 格式化ID" {
    resetRequestCounter();
    
    const ctx = RequestContext.init("POST", "/v1/infer");
    var buf: [32]u8 = undefined;
    const len = ctx.formatId(&buf);
    
    // 检查格式：REQ-1
    std_debug.assert(len >= 5); // "REQ-1" 至少5字节
    std_debug.assert(mem.eql(u8, buf[0..4], "REQ-"));
    std_debug.print("P47: ID格式化测试通过，formatted={s}\n", .{buf[0..len]});
}

test "P47: RequestContext 鉴权Token设置" {
    resetRequestCounter();
    
    var ctx = RequestContext.init("POST", "/v1/infer");
    std_debug.assert(ctx.auth_token_hash == null);
    
    ctx.setAuthToken(12345);
    std_debug.assert(ctx.auth_token_hash.? == 12345);
    std_debug.print("P47: Token哈希设置测试通过\n", .{});
}

test "P47: 全局计数器递增" {
    resetRequestCounter();
    
    _ = RequestContext.init("GET", "/health");
    _ = RequestContext.init("GET", "/health");
    _ = RequestContext.init("GET", "/health");
    
    const count = getRequestCount();
    std_debug.assert(count == 3);
    std_debug.print("P47: 全局计数器测试通过，count={d}\n", .{count});
}
