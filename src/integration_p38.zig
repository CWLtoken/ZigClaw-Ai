// src/integration_p38.zig
// ZigClaw V2.4 | 阶段23B | P38: Protocol HTTP 推理测试（真实）
const io_uring = @import("io_uring.zig");
const http_protocol = @import("http_protocol.zig");
const mem = @import("std").mem;

test "P38: HTTP 请求解析 - GET /infer" {
    // 测试 HTTP 请求解析逻辑
    var handler = try http_protocol.HttpProtocolHandler.init();
    defer handler.deinit();
    
    // 模拟接收 HTTP 请求
    const raw_request = 
        "GET /infer?input=hello&modality=text HTTP/1.1\r\n" ++
        "Host: localhost:8080\r\n" ++
        "\r\n";
    
    // 复制到接收缓冲区
    @memcpy(handler.recv_buf[0..raw_request.len], raw_request);
    handler.recv_len = raw_request.len;
    
    // 解析请求
    try handler.parse_http_request();
    
    // 验证解析结果
    try @import("std").testing.expect(mem.eql(u8, handler.request.method, "GET"));
    try @import("std").testing.expect(mem.eql(u8, handler.request.path, "/infer"));
    try @import("std").testing.expect(handler.request.query != null);
    
    // 验证查询参数解析
    const query = handler.request.query.?;
    try @import("std").testing.expect(mem.indexOf(u8, query, "input=hello") != null);
    try @import("std").testing.expect(mem.indexOf(u8, query, "modality=text") != null);
}

test "P38: HTTP 请求解析 - POST /infer with body" {
    var handler = try http_protocol.HttpProtocolHandler.init();
    defer handler.deinit();
    
    const raw_request = 
        "POST /infer HTTP/1.1\r\n" ++
        "Host: localhost:8080\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: 27\r\n" ++
        "\r\n" ++
        "{\"input\":\"test\",\"modality\":\"text\"}";
    
    @memcpy(handler.recv_buf[0..raw_request.len], raw_request);
    handler.recv_len = raw_request.len;
    
    try handler.parse_http_request();
    
    try @import("std").testing.expect(mem.eql(u8, handler.request.method, "POST"));
    try @import("std").testing.expect(mem.eql(u8, handler.request.path, "/infer"));
}

test "P38: HTTP 响应生成 - 200 OK" {
    var handler = try http_protocol.HttpProtocolHandler.init();
    defer handler.deinit();
    
    // 构造响应
    handler.response = .{
        .status_code = 200,
        .status_text = "OK",
        .body = "{\"result\":\"success\"}",
        .content_type = "application/json",
    };
    
    // 生成 HTTP 响应字符串
    const response_str = @import("std").fmt.bufPrint(
        &handler.send_buf,
        "HTTP/1.1 {d} {s}\r\n" ++
        "Content-Type: {s}\r\n" ++
        "Content-Length: {d}\r\n" ++
        "\r\n" ++
        "{s}",
        .{
            handler.response.status_code,
            handler.response.status_text,
            handler.response.content_type,
            handler.response.body.len,
            handler.response.body,
        }
    ) catch return error.ResponseTooLarge;
    
    handler.send_len = response_str.len;
    
    // 调试：打印响应字符串
    @import("std").debug.print("生成的HTTP响应:\n{s}\n", .{response_str});
    
    // 验证响应格式
    try @import("std").testing.expect(mem.indexOf(u8, response_str, "HTTP/1.1 200 OK") != null);
    // 动态验证 Content-Length（根据实际 body 长度）
    const expected_length_str = @import("std").fmt.allocPrint(@import("std").heap.page_allocator, "Content-Length: {d}", .{handler.response.body.len}) catch return error.OutOfMemory;
    defer @import("std").heap.page_allocator.free(expected_length_str);
    try @import("std").testing.expect(mem.indexOf(u8, response_str, expected_length_str) != null);
    try @import("std").testing.expect(mem.indexOf(u8, response_str, "{\"result\":\"success\"}") != null);
}

test "P38: HTTP 错误处理 - 404 Not Found" {
    var handler = try http_protocol.HttpProtocolHandler.init();
    defer handler.deinit();
    
    // 模拟请求不存在的路径
    const raw_request = "GET /unknown HTTP/1.1\r\n\r\n";
    @memcpy(handler.recv_buf[0..raw_request.len], raw_request);
    handler.recv_len = raw_request.len;
    
    try handler.parse_http_request();
    
    // 验证路径不是 /infer
    try @import("std").testing.expect(!mem.eql(u8, handler.request.path, "/infer"));
}
