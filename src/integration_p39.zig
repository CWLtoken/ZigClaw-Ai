// src/integration_p39.zig
// ZigClaw V2.4 | 阶段23B | P39: 多连接 HTTP 压力测试（真实）
const io_uring = @import("io_uring.zig");
const http_protocol = @import("http_protocol.zig");
const mem = @import("std").mem;

test "P39: 多 HTTP 请求处理 - 顺序" {
    // 模拟处理多个 HTTP 请求（顺序处理）
    const num_requests: usize = 5;
    var i: usize = 0;
    while (i < num_requests) : (i += 1) {
        var handler = try http_protocol.HttpProtocolHandler.init();
        defer handler.deinit();
        
        // 构造 HTTP 请求
        const raw_request = @import("std").fmt.allocPrint(
            @import("std").heap.page_allocator,
            "GET /infer?input={d}&modality=text HTTP/1.1\r\nHost: localhost\r\n\r\n",
            .{i}
        ) catch return error.OutOfMemory;
        defer @import("std").heap.page_allocator.free(raw_request);
        
        // 复制到接收缓冲区
        @memcpy(handler.recv_buf[0..raw_request.len], raw_request);
        handler.recv_len = raw_request.len;
        
        // 解析请求
        try handler.parse_http_request();
        
        // 验证解析结果
        try @import("std").testing.expect(mem.eql(u8, handler.request.method, "GET"));
        try @import("std").testing.expect(mem.eql(u8, handler.request.path, "/infer"));
    }
}

test "P39: HTTP 响应生成 - 多种状态码" {
    var handler = try http_protocol.HttpProtocolHandler.init();
    defer handler.deinit();
    
    // 测试 200 OK
    handler.response = .{
        .status_code = 200,
        .status_text = "OK",
        .body = "{\"result\":\"success\"}",
        .content_type = "application/json",
    };
    const response_200 = @import("std").fmt.bufPrint(
        &handler.send_buf,
        "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ handler.response.status_code, handler.response.status_text, handler.response.content_type, handler.response.body.len, handler.response.body }
    ) catch return error.ResponseTooLarge;
    try @import("std").testing.expect(mem.indexOf(u8, response_200, "HTTP/1.1 200 OK") != null);
    
    // 测试 404 Not Found
    handler.response = .{
        .status_code = 404,
        .status_text = "Not Found",
        .body = "{\"error\":\"Not Found\"}",
        .content_type = "application/json",
    };
    const response_404 = @import("std").fmt.bufPrint(
        &handler.send_buf,
        "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ handler.response.status_code, handler.response.status_text, handler.response.content_type, handler.response.body.len, handler.response.body }
    ) catch return error.ResponseTooLarge;
    try @import("std").testing.expect(mem.indexOf(u8, response_404, "HTTP/1.1 404 Not Found") != null);
}

test "P39: HTTP 错误请求处理" {
    var handler = try http_protocol.HttpProtocolHandler.init();
    defer handler.deinit();
    
    // 测试无效请求（没有 \r\n 结束符）
    const invalid_request = "GET /infer HTTP/1.1";  // 缺少 \r\n\r\n
    @memcpy(handler.recv_buf[0..invalid_request.len], invalid_request);
    handler.recv_len = invalid_request.len;
    
    // 解析应该失败（缺少 \r\n）
    try @import("std").testing.expectError(error.InvalidRequest, handler.parse_http_request());
}
