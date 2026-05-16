// src/file_store.zig
// 存储层 | Layer: Storage
// 文件版 FileStore — 仅保留 deleteFile（测试清理用）
//
// 设计原则（显性直白）：
//   saveHeatPool / loadHeatPool 已迁移至 heat_snap.zig（双版本头 + CRC32）
//   此处仅保留文件删除辅助函数

const linux = @import("std").os.linux;

pub const FileStore = struct {
    path: [*:0]const u8,

    pub fn init(path: [*:0]const u8) FileStore {
        return .{ .path = path };
    }

    /// 删除持久化文件（测试清理用）
    pub fn deleteFile(self: *const FileStore) void {
        _ = linux.syscall3(
            .unlinkat,
            @as(usize, @bitCast(@as(i64, @as(i32, -100)))),
            @intFromPtr(self.path),
            0,
        );
    }
};
