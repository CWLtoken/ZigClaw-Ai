const mem = @import("std").mem;
const math = @import("std").math;
const testing = @import("std").testing;

// Token 维度上限（架构师设计）
pub const MAX_TOKEN_DIM = 64;

// Token 类型枚举
pub const TokenType = enum(u8) {
    Text,            // 文本 Token（UTF-8 序列）
    VectorQuantized, // 向量量化 Token（用于图像/语音）
};

// 统一 Token 定义（必须 ≤ 512 字节）
pub const Token = struct {
    tpe: TokenType,
    dim: u16,                        // 有效维度，≤ MAX_TOKEN_DIM
    data: [MAX_TOKEN_DIM]f32,        // 当 tpe == .VectorQuantized 时存放原始向量的码本索引或归一化值
    text: [64]u8,                   // 当 tpe == .Text 时存放 UTF-8 字符串
    text_len: u8,

    // 编译期尺寸守卫：Token 必须 ≤ 512 字节
    comptime {
        if (@sizeOf(Token) > 512) {
            @compileError("Token size exceeds 512 bytes! Consider reducing MAX_TOKEN_DIM.");
        }
    }

    // 初始化文本 Token（零开销直通）
    pub fn initText(text_str: []const u8) Token {
        var token = Token{
            .tpe = .Text,
            .dim = 0,
            .data = undefined,
            .text = [_]u8{0} ** 64,
            .text_len = 0,
        };

        const copy_len = if (text_str.len > 63) 63 else text_str.len;
        mem.copyForwards(u8, token.text[0..], text_str[0..copy_len]);
        token.text_len = @intCast(copy_len);
        return token;
    }

    // 初始化向量量化 Token
    pub fn initVector(vec: []const f32) Token {
        var token = Token{
            .tpe = .VectorQuantized,
            .dim = @intCast(if (vec.len > MAX_TOKEN_DIM) MAX_TOKEN_DIM else vec.len),
            .data = [_]f32{0} ** MAX_TOKEN_DIM,
            .text = [_]u8{0} ** 64,
            .text_len = 0,
        };

        const copy_len = if (vec.len > MAX_TOKEN_DIM) MAX_TOKEN_DIM else vec.len;
        mem.copyForwards(f32, token.data[0..], vec[0..copy_len]);
        return token;
    }

    // 获取文本（仅当 tpe == .Text）
    pub fn getText(self: *const Token) []const u8 {
        if (self.tpe != .Text) return "";
        return self.text[0..self.text_len];
    }
};

// Token 序列（静态固定容量，避免堆分配）
pub const TokenSequence = struct {
    tokens: [MAX_SEQ_LEN]Token,
    len: u16,

    pub const MAX_SEQ_LEN = 256;

    // 编译期尺寸守卫
    comptime {
        if (@sizeOf(TokenSequence) > 512 * 256) { // 约128KB，合理
            @compileError("TokenSequence too large!");
        }
    }

    // 初始化空序列
    pub fn init() TokenSequence {
        return TokenSequence{
            .tokens = [_]Token{Token.initText("")} ** MAX_SEQ_LEN,
            .len = 0,
        };
    }

    // 添加 Token（返回错误如果序列已满）
    pub fn append(self: *TokenSequence, token: Token) !void {
        if (self.len >= MAX_SEQ_LEN) return error.SequenceFull;
        self.tokens[self.len] = token;
        self.len += 1;
    }

    // 获取 Token（边界检查）
    pub fn get(self: *const TokenSequence, index: u16) ?Token {
        if (index >= self.len) return null;
        return self.tokens[index];
    }
};

// 单元测试：Token 尺寸验证
test "Token: 尺寸 ≤ 512 字节" {
    const size = @sizeOf(Token);
    try testing.expect(size <= 512);
}

test "Token: 初始化文本 Token" {
    const token = Token.initText("Hello ZigClaw");
    try testing.expect(token.tpe == .Text);
    try testing.expectEqualSlices(u8, "Hello ZigClaw", token.getText());
}

test "TokenSequence: 容量 256，溢出保护" {
    var seq = TokenSequence.init();
    try testing.expectEqual(@as(u16, 0), seq.len);

    // 添加一个 Token
    try seq.append(Token.initText("test"));
    try testing.expectEqual(@as(u16, 1), seq.len);

    // 测试溢出
    var i: u32 = 0;
    while (i < 256) : (i += 1) {
        seq.append(Token.initText("x")) catch |err| {
            try testing.expect(err == error.SequenceFull);
            break;
        };
    }
}
