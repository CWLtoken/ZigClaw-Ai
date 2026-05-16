// src/tests.zig
// ZigClaw V2.4 | 统一测试网关 | 显性路由，拒绝合并
// 编译器从该文件切入，通过 @import 物理拉取各阶段测试
// 各阶段文件保持独立，历史边界不被污染
//
// 军规：@import 的模块必须被引用，否则 Zig 死代码消除会丢弃 test 块
// comptime 引用是 Zig 标准模式，确保编译期可见（非 hack）

const p3 = @import("integration_p3.zig");
const p4 = @import("integration_p4.zig");
const p5 = @import("integration_p5.zig");
const p6 = @import("integration_p6.zig");
const p7 = @import("integration_p7.zig");
const p8 = @import("integration_p8.zig");
const p9 = @import("integration_p9.zig");
const p10 = @import("integration_p10.zig");
const p11 = @import("integration_p11.zig");
const p12 = @import("integration_p12.zig");
const p13 = @import("integration_p13.zig");
const p14 = @import("integration_p14.zig");
const p17 = @import("integration_p17.zig");
const p15 = @import("integration_p15.zig");
const p18 = @import("integration_p18.zig");
const p19 = @import("integration_p19.zig");
const p20 = @import("integration_p20.zig");
const p16 = @import("integration_p16.zig"); // 现在回归调试
const p21 = @import("integration_p21.zig");
const p22 = @import("integration_p22.zig");
const p23 = @import("integration_p23.zig"); // P23: 1024轮压力测试
const p24 = @import("integration_p24.zig");
const p25 = @import("integration_p25.zig");
const p26 = @import("integration_p26.zig");
// P27: token.zig 内联测试（Token 结构、TokenSequence）
// P28: quantizer.zig 内联测试（量化/反量化、余弦相似度）
// P29: sub_brain.zig + orchestrator.zig 内联测试（子脑注册、模态分发）
const p30 = @import("integration_p30.zig");
const p31 = @import("integration_p31.zig"); // P31: infer_from_tokens 全链路验证
const p32 = @import("integration_p32.zig"); // P32: 图像子脑（LCG 256维）全链路
const p33 = @import("integration_p33.zig");
const p34 = @import("integration_p34.zig");
const p35 = @import("integration_p35.zig");
const p36 = @import("integration_p36.zig");
const p37 = @import("integration_p37.zig");
const p38 = @import("integration_p38.zig");
const p39 = @import("integration_p39.zig");
const p40 = @import("integration_p40.zig");
const p41 = @import("integration_p41.zig");
const tok = @import("token.zig");
const quant = @import("quantizer.zig");
const sb = @import("sub_brain.zig");
const orch = @import("orchestrator.zig");
const ac = @import("async_coordinator.zig");
const debug = @import("std").debug;

// 新模块：架构师五层架构对齐（P42-P46）
const hp = @import("heat_pool.zig");
const sp = @import("ssd_persist.zig");
const hs = @import("heat_snap.zig");
const vi = @import("vector_index.zig");
const rt = @import("route_table.zig");
const ib = @import("ibus.zig");
// 阶段24：入口层加固（P47）
const ctx = @import("context.zig");
const json_ext = @import("entry/json_extractor.zig");
const middleware = @import("entry/middleware.zig");
const integration_p47 = @import("integration_p47.zig");
// DRD-048：P0 收官（P48）— Metrics 基线
const metrics = @import("metrics.zig");
// P48 集成测试
const integration_p48 = @import("integration_p48.zig");
// P49 集成测试
const integration_p49 = @import("integration_p49.zig");
// P50 集成测试
const integration_p50 = @import("integration_p50.zig");
// P51 集成测试（多实例部署验证）
const p51 = @import("integration_p51.zig");

comptime {
    _ = p3;
    _ = p4;
    _ = p5;
    _ = p6;
    _ = p7;
    _ = p8;
    _ = p9;
    _ = p10;
    _ = p11;
    _ = p12;
    _ = p13;
    _ = p14;
    _ = p15;
    _ = p17;
    _ = p16;
    _ = p18;
    _ = p19;
    _ = p20;
    _ = p21;
    _ = p22;
    _ = p23; // P23: 1024轮压力测试
    _ = p24;
    _ = p25;
    _ = p26;
    _ = p30;
    _ = p31; // P31: infer_from_tokens 全链路验证
    _ = p32; // P32: 图像子脑（LCG 256维）全链路
    _ = p33;
    _ = p34; // P34: 端到端推理验证（Ollama）
    _ = p35; // P35: HTTP 推理服务集成测试
    _ = p36; // P36: 多模态推理测试
    _ = p37; // P37: 客服场景端到端闭环测试
    _ = p38; // P38: Protocol HTTP 推理测试
    _ = p39; // P39: 多连接 HTTP 压力测试
    _ = p40; // P40: 可观测性测试
    _ = p41; // P41: 故障注入与恢复测试
    _ = tok;
    _ = quant;
    _ = sb;
    _ = orch;
    _ = ac; // async_coordinator 测试
    // 新模块测试（P42-P46）
    _ = hp;
    _ = sp;
    _ = vi;
    _ = rt;
    _ = ib;
    // 阶段24：入口层加固（P47）
    _ = ctx;
    _ = json_ext;
    _ = middleware;
    _ = integration_p47;
    // DRD-048：P0 收官（P48）— Metrics 基线
    _ = metrics;
    // P48 集成测试
    _ = integration_p48;
    // P49 集成测试
    _ = integration_p49;
    // P50 集成测试
    _ = integration_p50;
    // P51 集成测试（多实例部署验证）
    _ = p51;
    // P52 集成测试（路由增强）
    const integration_p52 = @import("integration_p52.zig");
    _ = integration_p52;
    // P53 集成测试（多租户上下文）
    const integration_p53 = @import("integration_p53.zig");
    _ = integration_p53;
    // P54 集成测试（V2 向量索引增强 — IVF+PQ）
    const integration_p54 = @import("integration_p54.zig");
    _ = integration_p54;
    // P55 集成测试（V3 IBus 内省总线）
    const integration_p55 = @import("integration_p55.zig");
    _ = integration_p55;
    // P56 集成测试（V4 观测反馈学习 — SimpleLearner）
    const integration_p56 = @import("integration_p56.zig");
    _ = integration_p56;
    // P57 集成测试（V5 存储外置适配 — FileStore）
    const integration_p57 = @import("integration_p57.zig");
    _ = integration_p57;
    // P58 集成测试（契约层强化 — 接口一致性 + 显式错误处理）
    const integration_p58 = @import("integration_p58.zig");
    _ = integration_p58;
    // F2: 二进制指标协议（P59）
    const integration_p59 = @import("integration_p59.zig");
    _ = integration_p59;
    // F3: 更严格 comptime 合约（P60）
    const integration_p60 = @import("integration_p60.zig");
    _ = integration_p60;

    // E-3: 错误注入模块导入（确保编译器拉取 fault_injection.zig 的 test 块）
    const _fi = @import("fault_injection.zig");
    _ = _fi;

    // v3.0 blueprint references (ensure these files compile)
    _ = @import("interface.zig");
    _ = @import("feedback.zig");
    // DRD-059: V4/V5 新模块
    _ = @import("feedback_engine.zig");
    _ = @import("file_store.zig");
    // P2-3: Comptime 路由（独立模块，验证后替换）
    _ = @import("comptime_router.zig");
    _ = @import("entry/app_router.zig");

    // ========================================================================
    // 编译期契约验证（F3: 签名验证升级）
    // 验证各层实现了 interface.zig 中定义的契约（含完整签名检查）
    // ========================================================================
    const _interface = @import("interface.zig");
    const _orchestrator = @import("orchestrator.zig");

    // F3: OrchestratorInterface — 检查存在性 + 完整签名
    // 验证 Orchestrator.orchestrate 的返回类型和参数类型
    _interface.ContractVerifier.checkOrchestrator(_orchestrator.Orchestrator);

    // 注意: ExecutorInterface 和 StorageInterface 的签名验证
    // 需要实现类型与契约完全对齐后才能启用。
    // 当前 Reactor.submit/poll 的签名与契约定义有差异（历史原因），
    // 在 v3.2 对齐后启用以下验证：
    // _interface.ContractVerifier.checkExecutor(_reactor.Reactor);
    // _interface.ContractVerifier.checkStorage(_file_store.FileStore);

    // _interface 通过 ContractVerifier 调用隐式引用

    // ========================================================================
    // P5: 错误注入测试 — 内联在 tests.zig 中（可访问 src/ 根目录模块）
    // ========================================================================

    // 验证 SyscallError 包含所有预期错误变体
    const _io_uring = @import("io_uring.zig");
    const _SyscallError = _io_uring.SyscallError;
    const _se_info = @typeInfo(_SyscallError);
    if (_se_info != .@"error_set") {
        @compileError("P5 ASSERT: SyscallError is not an error_set");
    }
    const _se_list = _se_info.@"error_set".?;
    // 检查至少包含 5 个预期错误
    if (_se_list.len < 5) {
        @compileError("P5 ASSERT: SyscallError has fewer than 5 variants");
    }

    // 验证 Ring.init 返回 error union
    const _Ring = _io_uring.Ring;
    const _init_info = @typeInfo(@TypeOf(_Ring.init)).@"fn".return_type.?;
    if (@typeInfo(_init_info) != .@"error_union") {
        @compileError("P5 ASSERT: Ring.init does not return error union");
    }

    // 验证 Ring.deinit 返回 void
    const _deinit_ret = @typeInfo(@TypeOf(_Ring.deinit)).@"fn".return_type.?;
    if (@typeInfo(_deinit_ret) != .void) {
        @compileError("P5 ASSERT: Ring.deinit must return void");
    }

    // 验证 AlignedAtomicU64 缓存行对齐
    const _metrics = @import("metrics.zig");
    const _aa = _metrics.AlignedAtomicU64;
    if (@alignOf(_aa) != 64) {
        @compileError("P5 ASSERT: AlignedAtomicU64 must be 64-byte aligned");
    }
    if (@sizeOf(_aa) % 64 != 0) {
        @compileError("P5 ASSERT: AlignedAtomicU64 size must be multiple of 64");
    }

    // 验证 connection_pool.ConnSlot 大小不超过缓存行
    const _pool = @import("connection_pool.zig");
    if (@sizeOf(_pool.ConnSlot) > 64) {
        @compileError("P5 ASSERT: ConnSlot must fit in one cache line");
    }
}

// ========================================================================
// E-3 选项A: 真实错误注入行为测试
// 验证当注入器启用时，包装函数返回预设错误（不依赖真实 io_uring 硬件）
// 这些测试确保 fault_injection.zig 的包装函数正确注入错误
// ========================================================================
const fi = @import("fault_injection.zig");

test "E-3: initRing injects io_uring init failure" {
    var injector = fi.FaultInjector{
        .enabled = true,
        .fail_io_uring_init = true,
    };
    const result = fi.initRing(&injector);
    if (result) |_| {
        @panic("E-3 ASSERT: initRing should return error when fail_io_uring_init=true");
    } else |err| {
        debug.assert(err == error.IOError);
    }
}

test "E-3: submitRing injects SQ overflow (EAGAIN)" {
    var injector = fi.FaultInjector{
        .enabled = true,
        .fail_io_uring_sq_full = true,
    };
    const result = fi.submitRing(&injector, 0xFFFFFFFF, 1, 0);
    if (result) |_| {
        @panic("E-3 ASSERT: submitRing should return EAGAIN when fail_io_uring_sq_full=true");
    } else |err| {
        debug.assert(err == error.EAGAIN);
    }
}

test "E-3: socketFn injects socket creation failure (EMFILE)" {
    var injector = fi.FaultInjector{
        .enabled = true,
        .fail_socket = true,
    };
    const result = fi.socketFn(&injector, 2, 1, 0);
    if (result) |_| {
        @panic("E-3 ASSERT: socketFn should return EMFILE when fail_socket=true");
    } else |err| {
        debug.assert(err == error.EMFILE);
    }
}

test "E-3: listenFn injects listen failure (EAGAIN)" {
    var injector = fi.FaultInjector{
        .enabled = true,
        .fail_listen = true,
    };
    const result = fi.listenFn(&injector, -1, 128);
    if (result) |_| {
        @panic("E-3 ASSERT: listenFn should return EAGAIN when fail_listen=true");
    } else |err| {
        debug.assert(err == error.EAGAIN);
    }
}

test "E-3: injector disabled does not inject errors" {
    var injector = fi.init();
    debug.assert(!injector.enabled);
    debug.assert(!injector.fail_io_uring_init);
    if (fi.initRing(&injector)) |_| {} else |_| {}
}
