// src/async_coordinator.zig — 异步推理协调器
// 职责：桥接 HTTP 请求和异步推理结果
// 红线：不导入 reactor/protocol/storage/io_uring（纯逻辑组件）

const mem = @import("std").mem;
const testing = @import("std").testing;

/// 推理完成回调
pub const InferenceCallback = *const fn (result: []const u8, user_data: ?*anyopaque) void;

/// 推理请求
pub const InferenceRequest = struct {
    prompt: []const u8,
    modality: u8,            // 0=text, 1=image
    callback: InferenceCallback,
    user_data: ?*anyopaque,
};

/// 协调器状态
pub const Coordinator = struct {
    pending: ?InferenceRequest,

    pub fn init() Coordinator {
        return .{ .pending = null };
    }

    /// 提交异步推理请求
    pub fn submit(self: *Coordinator, req: InferenceRequest) !void {
        if (self.pending != null) return error.Busy;
        self.pending = req;
    }

    /// 推理完成，调用回调（由事件循环调用）
    pub fn complete(self: *Coordinator, result: []const u8) bool {
        if (self.pending) |req| {
            req.callback(result, req.user_data);
            self.pending = null;
            return true;
        }
        return false;
    }

    /// 检查是否有待处理的请求
    pub fn hasPending(self: *const Coordinator) bool {
        return self.pending != null;
    }
};

// 单元测试：协调器基本功能
test "Coordinator: 提交和完成" {

    // 用结构体封装结果数据
    const Result = struct {
        buf: [4096]u8 = [_]u8{0} ** 4096,
        len: usize = 0,
    };
    var result = Result{};

    var coordinator = Coordinator.init();
    try testing.expect(!coordinator.hasPending());

    const Callback = struct {
        fn callback(result_text: []const u8, user_data: ?*anyopaque) void {
            const r = @as(*Result, @ptrCast(@alignCast(user_data.?)));
            if (result_text.len > r.buf.len) @panic("Callback result_text too large for Result.buf");
            @memcpy(r.buf[0..result_text.len], result_text);
            r.len = result_text.len;
        }
    };

    const req = InferenceRequest{
        .prompt = "测试输入",
        .modality = 0, // text
        .callback = Callback.callback,
        .user_data = @as(?*anyopaque, @ptrCast(&result)),
    };

    // 提交请求
    try coordinator.submit(req);
    try testing.expect(coordinator.hasPending());

    // 模拟推理完成
    const mock_result = "推理结果：Zig是一种系统编程语言";
    _ = coordinator.complete(mock_result);

    try testing.expect(!coordinator.hasPending());
    try testing.expectEqualStrings(mock_result, result.buf[0..result.len]);
}

test "Coordinator: 忙碌时拒绝新请求" {

    var coordinator = Coordinator.init();

    const Callback = struct {
        fn callback(result: []const u8, user_data: ?*anyopaque) void {
            _ = result;
            _ = user_data;
        }
    };

    const req1 = InferenceRequest{
        .prompt = "请求1",
        .modality = 0,
        .callback = Callback.callback,
        .user_data = null,
    };

    const req2 = InferenceRequest{
        .prompt = "请求2",
        .modality = 0,
        .callback = Callback.callback,
        .user_data = null,
    };

    try coordinator.submit(req1);
    try testing.expectError(error.Busy, coordinator.submit(req2));
}

test "Coordinator: 无待处理时 complete 返回 false" {

    var coordinator = Coordinator.init();
    try testing.expect(!coordinator.complete("test"));
}
