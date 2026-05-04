const std = @import("std");
const mem = std.mem;

// 查询 Ollama 推理（简化版）
// 注意：Zig 0.16 的 HTTP 客户端 API 复杂，暂时返回错误
// 当 Ollama 不可用时，返回错误信息
pub fn query_ollama(prompt: []const u8, model: []const u8) ![]const u8 {
    _ = prompt;
    _ = model;

    // 暂时返回错误（Ollama 未运行或 HTTP 客户端不可用）
    // 在实际环境中，Ollama 正在运行时，此函数应调用 API
    return error.OllamaNotAvailable;
}
