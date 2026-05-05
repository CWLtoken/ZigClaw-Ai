# ZigClaw v2.4 架构文档

## 六层架构全景图

```
┌─────────────────────────────────────────────────────────┐
│                    编排层 (Orchestration)               │
│  token.zig → quantizer.zig → orchestrator.zig          │
│  多模态Token量化 + 子脑路由 + 推理协调                   │
└─────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────┐
│                    推理引擎层 (Inference)                │
│  inference.zig / sub_brain.zig                         │
│  Ollama集成 + 图像子脑(LCG) + 文本子脑                  │
└─────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────┐
│                    Protocol 大脑层                       │
│  protocol.zig / http_protocol.zig                      │
│  二进制协议状态机 + HTTP协议解析                         │
│  ⚠️ 军规：状态机内无try/catch/orelse/?                 │
└─────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────┐
│                    Reactor 盲盒层                        │
│  reactor.zig                                           │
│  事件循环 + 异步I/O调度                                 │
│  ⚠️ 军规：无菌室，无std/storage导入、无mem.writeInt     │
└─────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────┐
│                   io_uring 泥泞层                        │
│  io_uring.zig                                          │
│  系统调用封装 (ACCEPT/SEND/RECV/READ/WRITE)             │
│  批量提交 + 完成事件收割                                 │
└─────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────┐
│                    Ring 真实化层                         │
│  io_uring Ring 数据结构                                 │
│  SQ/CQ 环形队列 + SQE/CQE 操作                          │
└─────────────────────────────────────────────────────────┘
```

## 模块依赖拓扑

```
http_server.zig
    ↓
http_protocol.zig / protocol.zig
    ↓
reactor.zig
    ↓
io_uring.zig
    ↓
(libc / Linux kernel)

orchestrator.zig
    ↓
token.zig + quantizer.zig
    ↓
sub_brain.zig / inference.zig
    ↓
(Ollama HTTP API)
```

## 数据流向

### HTTP 请求处理流程
```
Client → http_server.zig (accept)
    → http_protocol.zig (parse HTTP)
    → reactor.zig (event loop)
    → orchestrator.zig (route to sub-brain)
    → inference.zig (call Ollama)
    → Response flows back
```

### 二进制协议流程
```
Client → protocol.zig (parse header/body)
    → reactor.zig (state machine)
    → business_logic
    → Response via io_uring SEND
```

## 关键数据结构

### ServerMetrics (可观测性)
```zig
pub const ServerMetrics = struct {
    uptime_start: i64,
    total_requests: std.atomic.Value(u64),
    active_connections: std.atomic.Value(u32),
    error_count: std.atomic.Value(u64),
}
```

### HttpServer
```zig
pub const HttpServer = struct {
    ring: io_uring.Ring,
    listen_fd: i32,
    port: u16,
    metrics: *ServerMetrics,
    running: std.atomic.Value(bool),
}
```

## 军规检查清单

| 规则 | 适用文件 | 检查项 |
|------|----------|--------|
| 第一诫 | 所有非测试文件 | 禁止 `const std = @import("std")`，仅允许精确导入如 `const mem = @import("std").mem` |
| 无菌室 | reactor.zig | 无std/storage导入、无mem.writeInt |
| 状态机纯净 | protocol.zig | 无try/catch/orelse/? |
| 服务器隔离 | server.zig / http_server.zig | 不导入Protocol/Reactor、不持有Storage指针、不使用std.Thread |

## 版本信息

- **当前版本**: v2.4
- **最新Tag**: v5.4-p41-observability
- **测试基线**: 76/76 全绿
- **Zig版本**: 0.16.0
- **核心依赖**: io_uring (Linux 5.1+), Ollama (可选，推理服务)
