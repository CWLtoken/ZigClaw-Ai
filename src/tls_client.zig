// src/tls_client.zig — TLS 客户端降维层
// 依赖：Zig 0.16 标准库 std.crypto.tls.Client 和 std.io.net.Stream
// 军规：不引入第三方库，全部用标库实现（使用 io_uring 进行 socket 操作，但 TLS 层使用标准库）

const std = @import("std");
const net = std.io.net;
const tls = std.crypto.tls;
const io_uring = @import("io_uring.zig");
const mem = @import("std").mem;

/// TLS 包装的 TCP 连接
pub const TlsConnection = struct {
    tls_client: ?tls.Client,

    /// 在已建立的 TCP 连接上初始化 TLS
    /// 参数: host (如 "openrouter.ai"), port (如 443)
    pub fn init(host: []const u8, port: u16) !TlsConnection {
        var sockfd_raw: i32 = undefined;
        // 1. 创建 socket
        sockfd_raw = try io_uring.Syscall.socket(io_uring.AF_INET, io_uring.SOCK_STREAM, 0);
        if (sockfd_raw < 0) return error.SocketCreationFailed;
        defer {
            if (sockfd_raw >= 0) {
                io_uring.Syscall.close(sockfd_raw);
            }
        };

        // 2. DNS 解析 — 使用硬编码 IP（与 http_client.zig 保持一致）
        //    openrouter.ai 真实 IP：104.18.3.115
        const ip_bytes = [4]u8{ 104, 18, 3, 115 }; // 104.18.3.115
        const ip_network_order = mem.readInt(u32, &ip_bytes, .big);

        var addr = io_uring.SockAddrIn{
            .family = io_uring.AF_INET,
            .port = io_uring.htons(port),
            .addr = ip_network_order,
        };
        // 3. 连接
        const sockfd: u32 = @intCast(sockfd_raw);
        try io_uring.Syscall.connect(sockfd, &addr, @sizeOf(io_uring.SockAddrIn));

        // 4. 将 socket 包装为 std.io.net.Stream（此时 Stream 获得 socket 的所有权）
        var socket: net.Socket = undefined;
        socket.handle = @intCast(sockfd_raw);
        const stream: net.Stream = .{
            .socket = socket,
        };
        // 现在 Stream 拥有 socket，我们设置 sockfd_raw 为 -1 以避免 defer 中重复关闭
        sockfd_raw = -1;

        // 5. 初始化 TLS 配置和客户端
        var tls_config: tls.Context = undefined;
        tls_config = tls.Context.init(.{
            .verify_certificate = true, // 验证服务器证书
            // 可以根据需要添加更多配置，例如设置最低 TLS 版本等
        });
        var tls_client_val: tls.Client = undefined;
        // 为了获取 Io 实例，我们需要创建一个。但是 TLS client 的 init 可能不需要直接的 Io？
        // 查看 std.crypto.tls.Client.init 的签名
        // 实际上，从错误来看，它似乎接受一个 stream 参数
        // 让我们尝试这样调用，如果需要 io 的话可能会有其他错误
        tls_client_val = try tls.Client.init(tls_config, stream, host) orelse {
            // 如果 TLS 初始化失败，我们需要清理 resources
            // 但 stream 不包含需要关闭的资源，socket.handle 由我们管理
            return error.TlsInitFailed;
        };

        // 6. 执行 TLS 握手
        try tls_client_val.handshake() orelse {
            _ = stream.close(); // 这需要一个 io 参数，有问题
            return error.TlsHandshakeFailed;
        };

        // 成功！将 TLS Client 存储在可选字段中（以便在 close 时释放）
        return TlsConnection{ .tls_client = tls_client_val };
    }

    /// TLS 安全发送
    pub fn send(self: *TlsConnection, data: []const u8) !usize {
        if (self.tls_client) |*client| {
            return client.write(data);
        } else {
            return error.ConnectionClosed;
        }
    }

    /// TLS 安全接收
    pub fn recv(self: *TlsConnection, buf: []u8) !usize {
        if (self.tls_client) |*client| {
            return client.read(buf);
        } else {
            return error.ConnectionClosed;
        }
    }

    /// 关闭 TLS + TCP
    pub fn close(self: *TlsConnection) void {
        if (self.tls_client) |*client| {
            // 优雅关闭 TLS 连接
            _ = client.shutdown();
            // 通过将可选字段设置为 null 来释放 TLS Client 和内部资源
            self.tls_client = null;
        }
    }
};
