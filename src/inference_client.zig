const std = @import("std");
const mem = std.mem;

// ============================================================================
// inference_client.zig - Ollama 推理客户端 (WIP - Work In Progress)
// ============================================================================
//
// 当前状态：
//   ⚠️ 本文件是空壳实现，硬编码返回 `error.OllamaNotAvailable`
//   ⚠️ 这是阶段 19 的 WIP 存根，等待 Zig 0.17 HTTP Client API 稳定
//
// 启用前提条件：
//   1. 安装并运行 Ollama 服务：`ollama serve`
//   2. 下载模型（例如）：`ollama pull llama3.2`
//   3. 验证服务：curl http://localhost:11434/api/tags
//
// Zig 0.16 限制：
//   - `std.http.Client` API 复杂，需要 `Io.Threaded` 初始化
//   - 无 `client.open` 方法，需要手动构造 HTTP 请求
//   - 等待 Zig 0.17 标准库稳定后再实现完整客户端
//
// 未来计划：
//   - 实现完整的 Ollama API 调用（/api/generate）
//   - 支持流式响应（stream: true）
//   - 添加错误重试和超时处理
//
// 当前临时方案：
//   - 推理请求通过 `inference.zig` 返回模拟结果
//   - 生产环境建议直接使用 Ollama REST API，或通过反向代理
// ============================================================================

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
