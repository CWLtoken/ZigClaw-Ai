// safe_path.zig
// SEC-8: 路径遍历防护
// 确保文件路径不超出允许的根目录范围
const mem = @import("std").mem;
const log = @import("std").log;

/// 路径遍历检测结果
pub const PathCheckResult = enum {
    Safe,
    TraversalDetected,
    EmptyPath,
    TooLong,
};

/// 验证路径是否安全（不包含 ../ 等遍历序列）
/// 返回 PathCheckResult 表示检测结果
pub fn validatePath(path: []const u8) PathCheckResult {
    // 空路径检查
    if (path.len == 0) return .EmptyPath;

    // 长度限制（4096，防止超长路径攻击）
    if (path.len > 4096) return .TooLong;

    // 检查路径遍历模式
    var i: usize = 0;
    while (i < path.len - 1) : (i += 1) {
        // 检测 "../" 或 "..\\" 模式
        if (path[i] == '.' and path[i + 1] == '.') {
            if (i + 2 < path.len) {
                const next = path[i + 2];
                if (next == '/' or next == '\\') {
                    log.warn("路径遍历攻击检测: 路径包含 '..' 序列 at index {d}", .{i});
                    return .TraversalDetected;
                }
            } else if (i + 2 == path.len) {
                // 路径以 ".." 结尾
                log.warn("路径遍历攻击检测: 路径以 '..' 结尾", .{});
                return .TraversalDetected;
            }
        }
    }

    return .Safe;
}

/// 将路径限制在指定根目录下
/// 调用者负责释放返回的内存
pub fn joinSafe(allocator: mem.Allocator, root: []const u8, path: []const u8) ![]u8 {
    // 先验证路径
    const result = validatePath(path);
    if (result != .Safe) {
        return error.UnsafePath;
    }

    // 拼接路径
    const joined = try mem.concat(allocator, u8, &[_][]const u8{ root, "/", path });

    // 简单检查：确保拼接后的路径以 root 开头
    if (!mem.startsWith(u8, joined, root)) {
        allocator.free(joined);
        return error.PathEscapesRoot;
    }

    return joined;
}

test "validatePath - safe paths" {
    try std.testing.expectEqual(PathCheckResult.Safe, validatePath("index.html"));
    try std.testing.expectEqual(PathCheckResult.Safe, validatePath("static/css/main.css"));
    try std.testing.expectEqual(PathCheckResult.Safe, validatePath("api/v1/users"));
}

test "validatePath - traversal detected" {
    try std.testing.expectEqual(PathCheckResult.TraversalDetected, validatePath("../etc/passwd"));
    try std.testing.expectEqual(PathCheckResult.TraversalDetected, validatePath("static/../../../etc/shadow"));
    try std.testing.expectEqual(PathCheckResult.TraversalDetected, validatePath("..\\windows\\system32"));
    try std.testing.expectEqual(PathCheckResult.TraversalDetected, validatePath(".."));
}

test "validatePath - edge cases" {
    try std.testing.expectEqual(PathCheckResult.EmptyPath, validatePath(""));

    // 构造超长路径（4097 字符）
    var buf: [4097]u8 = undefined;
    @memset(&buf, 'a');
    try std.testing.expectEqual(PathCheckResult.TooLong, validatePath(&buf));
}

test "validatePath - dots in filenames are safe" {
    // 文件名中包含点但不是遍历
    try std.testing.expectEqual(PathCheckResult.Safe, validatePath("file..txt"));
    try std.testing.expectEqual(PathCheckResult.Safe, validatePath("dir.name/file.txt"));
}
