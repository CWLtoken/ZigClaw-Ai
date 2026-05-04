const std = @import("std");
const token = @import("token.zig");
const quantizer = @import("quantizer.zig");
const sub_brain = @import("sub_brain.zig");

pub const Orchestrator = struct {
    sub_brains: [MAX_BRAINS]sub_brain.SubBrain,
    brains_len: u8,
    quantizer: quantizer.Quantizer,
    const MAX_BRAINS = 8;

    // 初始化编排器
    pub fn init() Orchestrator {
        var o = Orchestrator{
            .sub_brains = [_]sub_brain.SubBrain{sub_brain.getTextBrain()} ** MAX_BRAINS,
            .brains_len = 0,
            .quantizer = quantizer.Quantizer.init(),
        };
        // 默认注册文本直通子脑
        _ = o.register_brain(sub_brain.getTextBrain());
        return o;
    }

    // 注册子脑，返回 ID
    pub fn register_brain(self: *Orchestrator, brain: sub_brain.SubBrain) u8 {
        if (self.brains_len >= MAX_BRAINS) return 0; // 0 表示失败
        self.sub_brains[self.brains_len] = brain;
        self.brains_len += 1;
        return self.brains_len - 1;
    }

    // 根据模态查找子脑
    fn find_brain(self: *const Orchestrator, modality: sub_brain.Modality) ?sub_brain.SubBrain {
        var i: u8 = 0;
        while (i < self.brains_len) : (i += 1) {
            if (self.sub_brains[i].input_modality == modality) {
                return self.sub_brains[i];
            }
        }
        return null;
    }

    // 编排主逻辑：选择子脑、提取、量化、输出 Token 序列
    pub fn orchestrate(self: *const Orchestrator, input: []const u8, modality: sub_brain.Modality, seq: *token.TokenSequence) !void {
        if (modality == .Text) {
            // 文本直通策略：不量化，直接拷贝到 token.text
            const token_obj = token.Token.initText(input);
            try seq.append(token_obj);
            return;
        }

        // 其他模态：查找子脑 → 提取向量 → 量化
        const brain = self.find_brain(modality) orelse return error.UnsupportedModality;
        if (brain.dim == 0) return error.InvalidBrainDim;

        var vector: [token.MAX_TOKEN_DIM]f32 = undefined;
        try brain.extract(input, vector[0..brain.dim]);

        var tok = token.Token.initVector(vector[0..brain.dim]);
        try self.quantizer.quantize(vector[0..brain.dim], &tok);
        try seq.append(tok);
    }
};

// 单元测试：子脑注册
test "Orchestrator: 子脑注册" {
    var o = Orchestrator.init();
    try std.testing.expectEqual(@as(u8, 1), o.brains_len); // 默认注册了文本子脑

    const id = o.register_brain(sub_brain.getImageBrain());
    try std.testing.expect(id == 1);
    try std.testing.expectEqual(@as(u8, 2), o.brains_len);
}

test "Orchestrator: 文本直通" {
    var o = Orchestrator.init();
    var seq = token.TokenSequence.init();

    try o.orchestrate("Hello ZigClaw", .Text, &seq);
    try std.testing.expectEqual(@as(u16, 1), seq.len);

    const tok = seq.get(0).?;
    try std.testing.expect(tok.tpe == .Text);
    try std.testing.expectEqualSlices(u8, "Hello ZigClaw", tok.getText());
}

test "Orchestrator: 图像模态（模拟）" {
    var o = Orchestrator.init();
    _ = o.register_brain(sub_brain.getImageBrain());
    var seq = token.TokenSequence.init();

    try o.orchestrate("mock_image_data", .Image, &seq);
    try std.testing.expectEqual(@as(u16, 1), seq.len);

    const tok = seq.get(0).?;
    try std.testing.expect(tok.tpe == .VectorQuantized);
}

test "Orchestrator: 未知模态报错" {
    var o = Orchestrator.init();
    var seq = token.TokenSequence.init();

    try std.testing.expectError(error.UnsupportedModality, o.orchestrate("test", .Unknown, &seq));
}
