// src/entry/json_extractor.zig
// 入口层 | Layer: Entry
// 零拷贝 JSON 提取器 — 提取 "input" 字段的位置（不复制字符串）

const std = @import("std");
const mem = std.mem;
const debug = std.debug;

/// 字段在 JSON 缓冲区中的位置（零拷贝引用）
pub const FieldLocation = struct {
    start: usize,     // 字段值的起始偏移（不包括引号）
    end: usize,       // 字段值的结束偏移（不包括结束引号）
    quoted: bool,     // 值是否为字符串（带引号）
};

/// 从 JSON 对象中提取 "input" 字段的位置（零拷贝）
/// 返回 null 如果字段不存在或解析失败
/// 只支持字符串值（带双引号），其他类型返回 null
pub fn extractInput(json: []const u8) ?FieldLocation {
    // 固定搜索模式："input":
    const target = "\"input\":";
    const target_len = target.len;
    
    var i: usize = 0;
    while (i + target_len <= json.len) {
        if (mem.eql(u8, json[i..i+target_len], target)) {
            // 找到字段，跳过空白
            var pos = i + target_len;
            while (pos < json.len and (json[pos] == ' ' or json[pos] == '\t' or json[pos] == '\n' or json[pos] == '\r')) {
                pos += 1;
            }
            if (pos >= json.len) return null;
            
            // 检查是否为字符串（双引号）
            if (json[pos] == '"') {
                const start_quote = pos;
                // 查找结束引号（忽略转义，简单实现）
                var end_quote = pos + 1;
                while (end_quote < json.len and json[end_quote] != '"') {
                    // 跳过转义字符（简单处理：如果看到 \，跳过后一个字符）
                    if (json[end_quote] == '\\' and end_quote + 1 < json.len) {
                        end_quote += 2;
                    } else {
                        end_quote += 1;
                    }
                }
                if (end_quote >= json.len) return null; // 未找到结束引号
                // 返回字符串内容的位置（不包括引号）
                return FieldLocation{
                    .start = start_quote + 1,
                    .end = end_quote,
                    .quoted = true,
                };
            }
            // 非字符串值暂不支持
            return null;
        }
        i += 1;
    }
    return null;
}

// 单元测试（P47）
test "P47: JSON 提取器 - 查找 input 字段" {
    const json = "{\"input\": \"hello world\", \"modality\": \"text\"}";
    const loc = extractInput(json);
    debug.assert(loc != null);
    const l = loc.?;
    debug.assert(l.quoted == true);
    // 检查提取的内容是否为 "hello world"
    const value = json[l.start..l.end];
    debug.assert(mem.eql(u8, value, "hello world"));
    debug.print("P47: JSON 提取器测试通过，input={s}\n", .{value});
}

test "P47: JSON 提取器 - 字段不存在" {
    const json = "{\"modality\": \"text\"}";
    const loc = extractInput(json);
    debug.assert(loc == null);
    debug.print("P47: 字段不存在测试通过\n", .{});
}

test "P47: JSON 提取器 - 空 input" {
    const json = "{\"input\": \"\", \"modality\": \"text\"}";
    const loc = extractInput(json);
    debug.assert(loc != null);
    const l = loc.?;
    debug.assert(l.start == l.end); // 空字符串
    debug.print("P47: 空 input 测试通过\n", .{});
}
