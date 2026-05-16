# 存储层技术文档

## 概述

存储层（L5 Storage）由 `storage_arena.zig` 单一文件实现，统一管理热池（Heat Pool）、SSD 快照和文件存储。

## 架构

```
┌─────────────────────────────────────────────────────────┐
│  StorageArena (struct)                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │ ArenaAllocator│  │  Heat Pool   │  │  SSD Snap    │  │
│  │ (单一所有权)  │  │  align(64)   │  │  dual-version│  │
│  └──────────────┘  └──────────────┘  └──────────────┘  │
│  ┌──────────────┐                                       │
│  │  Mutex(64)   │  ← 并发安全锁，独立缓存行              │
│  └──────────────┘                                       │
└─────────────────────────────────────────────────────────┘
```

## 核心设计

### 1. 单一所有权生命周期

- 一个 `ArenaAllocator` 管理所有堆分配
- `init()` 初始化，`deinit()` 一次调用释放全部资源
- snap_path 由 Arena 动态分配（`dupeZ`），无需手动释放

### 2. 缓存行对齐（M-1）

```zig
heats: [SLOT_COUNT]u16 align(64),
last_touch_ns: [SLOT_COUNT]u64 align(64),
mu: atomic.Mutex align(64) = .unlocked,
```

三个热点字段各自独占 64 字节缓存行，消除多核伪共享。

### 3. 锁粒度与 I/O 分离

`saveHeatPool` 四阶段流水线：

```
阶段1: 加锁 → 递增版本号 → 复制热池数据 → 解锁
阶段2: 构造 SSD Header（无锁）
阶段3: io_uring 异步写入（无锁）
```

**铁律：持有锁时不做任何 I/O。**

### 4. 内省快照（A-4）

```zig
pub fn getSnapshot(self: *const StorageArena) struct { heats, last_touch_ns }
```

返回热池数据的完整副本，I-Bus 客户端只能读取快照，无法修改内部状态。

### 5. SSD 双版本快照

- 文件布局：Header0(64B) + Header1(64B) + Padding(64B) + Body(8128B) = 8320B
- 版本号 0/1 交替写入（`snap_version ^ 1`）
- CRC32 校验 + magic 验证
- 启动时自动从 SSD 恢复 + 时间衰减补偿

## 军规合规

| 军规 | 状态 |
|------|------|
| S-1 显性直白 | ✅ |
| S-2 精确导入 | ✅ |
| S-3 无菌室 | ✅ |
| S-4 零依赖 | ✅ |
| A-1 六层隔离 | ✅ |
| A-4 IBus 内省 | ✅ |
| P-1 纯状态机 | ✅ |
| P-2 显式清理 | ✅ |
| P-4 缓存行隔离 | ✅ |
| M-1 结构体对齐 | ✅ |

## 文件清单

| 文件 | 行数 | 职责 |
|------|------|------|
| `src/storage_arena.zig` | ~392 | 统一存储层（热池+SSD+文件） |
| `src/storage.zig` | ~141 | StreamWindow + BodyBufferPool |

## Git 历史

- `ce03759` — M-1 缓存行对齐 + 清理冗余导入
- `1f324eb` — ArenaAllocator + deinit 单一所有权
- `f62f7eb` — saveToFile 无锁日志 + snap_version 原子性
- `05bd02b` — 存储层合并 + io_uring 竞态修复 + I-Bus 数据竞争修复
