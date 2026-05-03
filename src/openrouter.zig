// src/openrouter.zig
// ZigClaw V2.4 Phase16 | OpenRouter 客户端 | Zig 0.16 std.http.Client
const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const http = std.http;
const Io = std.Io;

pub const Error = error{
    MissingApiKey,
    RequestFailed,
    ResponseFailed,
};

/// OpenRouter 聊天响应（简化版）
pub const ChatResponse = struct {
    text: [4096]u8,
    len: u32,
};

/// 最小 OpenRouter 客户端
pub const Client = struct {
    allocator: std.mem.Allocator,
    http: http.Client,
    api_key: []const u8,

    /// 初始化客户端（API Key 由调用者传入）
    pub fn init(allocator: std.mem.Allocator, api_key: []const u8) Error!Client {
        // 1. 复制 API Key
        const key_dup = allocator.dupe(u8, api_key) catch return Error.RequestFailed;

        // 2. 初始化 Io 实例
        const io_instance = Io{};

        // 3. 初始化 HTTP 客户端
        const http_client: http.Client = .{
            .allocator = allocator,
            .io = io_instance,
        };

        return Client{
            .allocator = allocator,
            .http = http_client,
            .api_key = key_dup,
        };
    }

    pub fn deinit(self: *Client) void {
        self.allocator.free(self.api_key);
        self.http.deinit();
        self.* = undefined;
    }

    /// 发送聊天请求，返回响应文本
    pub fn chat(self: *Client, model: []const u8, prompt: []const u8) Error!ChatResponse {
        const allocator = self.allocator;

        // 1. 构建 URL
        const url = fmt.allocPrint(allocator, "https://openrouter.ai/api/v1/chat/completions", .{}) catch return Error.RequestFailed;
        defer allocator.free(url);

        // 2. 构建请求体
        const body = fmt.allocPrint(allocator,
            \\{"model":"{s}","messages":[{"role":"user","content":"{s}"}]}
        , .{ model, prompt }) catch return Error.RequestFailed;
        defer allocator.free(body);

        // 3. 构建 Authorization header
        const auth_header = fmt.allocPrint(allocator, "Bearer {s}", .{self.api_key}) catch return Error.RequestFailed;
        defer allocator.free(auth_header);

        // 4. 准备响应体缓冲区
        var response_body = std.ArrayList(u8).init(allocator);
        defer response_body.deinit();

        // 5. 发送请求（使用 fetch）
        _ = self.http.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .headers = .{
                .authorization = .{ .override = auth_header },
                .content_type = .{ .override = "application/json" },
            },
            .response_writer = null, // 暂时不捕获响应体
        }) catch return Error.RequestFailed;

        // 暂时返回空响应（需要修复 response_writer）
        var result: ChatResponse = undefined;
        result.text = [_]u8{0} ** 4096;
        result.len = 0;
        return result;
    }
};
