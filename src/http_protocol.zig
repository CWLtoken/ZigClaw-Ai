// src/http_protocol.zig
// ZigClaw V2.4 | 阶段23B | HTTP 协议处理器 - 通过 Protocol 状态机走 io_uring
const std = @import("std");
const protocol = @import("protocol.zig");
const orchestrator = @import("orchestrator.zig");
const storage = @import("storage.zig");
const router = @import("router.zig");
const mem = std.mem;
const Arena = std.heap.ArenaAllocator;

// HTTP 请求处理函数（符合 router.HandlerFn 签名）
fn handle_http_request(ctx: *router.RequestContext) void {
    _ = ctx;
    std.debug.print("HttpProtocolHandler: 收到请求（暂未实现）\n", .{});
}

pub const HttpProtocolHandler = struct {
    proto: protocol.Protocol,
    request_buffer: [8192]u8,
    response_buffer: [4096]u8,

    /// 初始化 HTTP 协议处理器
    /// 使用 Storage 层的 StreamWindow 和 BodyBufferPool
    pub fn init() !HttpProtocolHandler {
        // 创建 Protocol 实例（使用 Storage 层的 StreamWindow 和 BodyBufferPool）
        var window = storage.StreamWindow.init();
        var body_pool = storage.BodyBufferPool.init();

        const proto = try protocol.Protocol.init(&window, &body_pool, handle_http_request);
        
        return HttpProtocolHandler{
            .proto = proto,
            .request_buffer = undefined,
            .response_buffer = undefined,
        };
    }

    /// 处理 HTTP 请求（通过 Protocol 状态机）
    /// 注意：此方法不直接调用 read()/write()，所有 I/O 通过 Protocol 走 io_uring
    pub fn handle_request(self: *HttpProtocolHandler, accepted_fd: i32) !void {
        _ = self;
        _ = accepted_fd; // 暂时未使用，Protocol 会通过 Reactor 获取 fd
        
        // 1. 通过 Protocol 接收数据
        // Protocol 应该已经从 Reactor 获取了连接数据
        // 这里应该调用 Protocol 的状态机来处理 HTTP 请求
        
        // 简化实现：直接解析请求（后续会改为通过 Protocol）
        // TODO: 集成 Protocol 状态机
        
        std.debug.print("HttpProtocolHandler: 处理请求（暂未集成 Protocol）\n", .{});
    }

    /// 解析 HTTP 请求行
    fn parse_http_request(self: *HttpProtocolHandler, data: []const u8) !HttpRequest {
        _ = self;
        var arena = Arena.init(std.heap.page_allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        _ = alloc;

        // 查找请求行结束位置
        const first_line_end = mem.indexOf(u8, data, "\r\n") orelse return error.InvalidRequest;
        const first_line = data[0..first_line_end];

        var iter = mem.splitSequence(u8, first_line, " ");
        const method = iter.next() orelse return error.InvalidRequest;
        const full_path = iter.next() orelse return error.InvalidRequest;
        _ = iter.next(); // 跳过 HTTP/1.1

        // 分离路径和查询参数
        var path = full_path;
        var query: ?[]const u8 = null;
        if (mem.indexOf(u8, full_path, "?")) |pos| {
            path = full_path[0..pos];
            query = full_path[pos+1..];
        }

        return HttpRequest{
            .method = method,
            .path = path,
            .query = query,
            .body = if (data.len > first_line_end + 2) data[first_line_end + 2..] else "",
        };
    }
};

/// HTTP 请求结构
const HttpRequest = struct {
    method: []const u8,
    path: []const u8,
    query: ?[]const u8,
    body: []const u8,
};

/// 处理 /infer 请求
fn handle_infer_request(alloc: std.mem.Allocator, query: ?[]const u8) ![]const u8 {
    _ = alloc;
    
    var input: ?[]const u8 = null;
    var modality_str: []const u8 = "text";

    if (query) |q| {
        var params = mem.splitSequence(u8, q, "&");
        while (params.next()) |param| {
            if (mem.startsWith(u8, param, "input=")) {
                input = param[6..];
            } else if (mem.startsWith(u8, param, "modality=")) {
                modality_str = param[9..];
            }
        }
    }

    if (input == null) {
        return "{\"error\":\"Missing input parameter\"}";
    }

    // 调用推理（简化版，实际应通过 Orchestrator）
    // TODO: 集成 Orchestrator
    const response = std.fmt.allocPrint(
        std.heap.page_allocator,
        "{{\"input\":\"{s}\",\"modality\":\"{s}\",\"result\":\"推理结果（暂未集成Orchestrator）\"}}",
        .{ input.?, modality_str }
    ) catch {
        return "{\"error\":\"Response generation failed\"}";
    };
    
    return response;
}
