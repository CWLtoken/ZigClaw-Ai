// src/integration_p53.zig
// P53: 多租户上下文测试

const context = @import("context.zig");
const middleware = @import("entry/middleware.zig");
const mem = @import("std").mem;

test "P53: X-Tenant-ID 头正确解析为 tenant_id" {
    const headers =
        "POST /v1/infer HTTP/1.1\r\n" ++
        "Authorization: Bearer secret-token-123\r\n" ++
        "X-Tenant-ID: 42\r\n" ++
        "Content-Type: application/json\r\n";

    const result = middleware.checkAuthWithTenant(headers);
    @import("std").debug.assert(result.allowed == true);
    @import("std").debug.assert(result.tenant_id == 42);
    @import("std").debug.print("P53: X-Tenant-ID 解析测试通过, tenant_id={d}\n", .{result.tenant_id});
}

test "P53: 无 X-Tenant-ID 头时默认 tenant_id = 0" {
    const headers =
        "POST /v1/infer HTTP/1.1\r\n" ++
        "Authorization: Bearer secret-token-123\r\n" ++
        "Content-Type: application/json\r\n";

    const result = middleware.checkAuthWithTenant(headers);
    @import("std").debug.assert(result.allowed == true);
    @import("std").debug.assert(result.tenant_id == 0);
    @import("std").debug.print("P53: 默认 tenant_id 测试通过, tenant_id={d}\n", .{result.tenant_id});
}

test "P53: context.init 正确存储 tenant_id" {
    context.resetRequestCounter();

    const ctx = context.RequestContext.init("POST", "/v1/infer", 99);
    @import("std").debug.assert(ctx.tenant_id == 99);
    @import("std").debug.assert(ctx.id == 1);
    @import("std").debug.assert(mem.eql(u8, ctx.method, "POST"));
    @import("std").debug.assert(mem.eql(u8, ctx.path, "/v1/infer"));
    @import("std").debug.print("P53: context.init tenant_id 测试通过, tenant_id={d}\n", .{ctx.tenant_id});
}
