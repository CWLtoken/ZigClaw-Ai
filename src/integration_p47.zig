// src/integration_p47.zig
// 阶段24（DRD-046）P47 集成测试汇总
// 验证：全局请求ID、零拷贝JSON提取、Bearer鉴权、API路由、上下文注入

const debug = @import("std").debug;
const mem = @import("std").mem;

// 导入所有P47模块
const context = @import("context.zig");
const json_ext = @import("entry/json_extractor.zig");
const middleware = @import("entry/middleware.zig");

// 集成测试1：请求ID连续性
test "P47 Integration: 请求ID连续性" {
    context.resetRequestCounter();
    
    const ctx1 = context.RequestContext.init("POST", "/v1/infer", 0);
    const ctx2 = context.RequestContext.init("GET", "/health", 0);
    const ctx3 = context.RequestContext.init("POST", "/v1/infer", 0);
    
    debug.assert(ctx1.id == 1);
    debug.assert(ctx2.id == 2);
    debug.assert(ctx3.id == 3);
    
    debug.print("P47集成测试：ID连续性通过 (1,2,3)\n", .{});
}

// 集成测试2：JSON提取器 + 鉴权中间件联合
test "P47 Integration: JSON提取 + 鉴权" {
    // 模拟HTTP请求（带Authorization头）
    const headers =
        "POST /v1/infer HTTP/1.1\r\n" ++
        "Authorization: Bearer secret-token-123\r\n" ++
        "Content-Type: application/json\r\n";
    
    // 鉴权应成功
    debug.assert(middleware.checkAuth(headers) == true);
    
    // 模拟JSON body
    const body = "{\"input\": \"hello world\", \"modality\": \"text\"}";
    const loc = json_ext.extractInput(body);
    debug.assert(loc != null);
    const l = loc.?;
    const input = body[l.start..l.end];
    debug.assert(mem.eql(u8, input, "hello world"));
    
    debug.print("P47集成测试：JSON提取+鉴权联合通过\n", .{});
}

// 集成测试3：无效Token应被拒绝
test "P47 Integration: 无效Token拒绝" {
    const headers =
        "POST /v1/infer HTTP/1.1\r\n" ++
        "Authorization: Bearer wrong-token\r\n";
    
    debug.assert(middleware.checkAuth(headers) == false);
    debug.print("P47集成测试：无效Token拒绝通过\n", .{});
}

// 集成测试4：上下文注入到请求处理（模拟）
test "P47 Integration: 上下文注入" {
    const ctx = context.RequestContext.init("POST", "/v1/infer", 0);
    // 检查ID是否递增（依赖全局状态）
    debug.assert(ctx.id >= 1);
    debug.print("P47集成测试：上下文注入通过，ID={d}\n", .{ctx.id});
}
