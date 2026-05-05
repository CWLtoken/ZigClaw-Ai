const std = @import("std");
const testing = std.testing;

var counter: u32 = 0;

fn might_fail(should_fail: bool) !void {
    counter += 1;
    errdefer { counter += 100; }  // 正常返回应 NOT execute
    if (should_fail) return error.Failed;
}

test "errdefer on success" {
    counter = 0;
    might_fail(false) catch unreachable;
    try testing.expectEqual(@as(u32, 1), counter);  // 为 1 证明 errdefer 未执行
}

test "errdefer on error" {
    counter = 0;
    might_fail(true) catch {}; // 忽略错误，只验证 errdefer 执行
    try testing.expectEqual(@as(u32, 101), counter);  // 为 101 证明 errdefer 执行
}
