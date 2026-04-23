const std = @import("std");
const testing = std.testing;
const core = @import("core.zig");
const storage = @import("storage.zig");
const routing = @import("routing.zig");
const io_uring = @import("io_uring.zig");

test "Integration: Cold Path Data Flow" {
    var ibus = core.IBusControlPlane.zero_init();
    ibus.latency_context_hash = 12345;

    comptime {
        if (@sizeOf(core.IBusControlPlane) != 4096) @compileError("ZC-INTEGRATION-FATAL: IBus size mismatch");
    }

    const router = routing.HashRouter.init();
    const slot = router.get_slot(&ibus);
    try testing.expect(slot < 256);

    var win = storage.StreamWindow.init();
    var hdr = core.TokenStreamHeader.init();
    hdr.set_stream_id(999);
    hdr.set_total_len(4096);
    win.push_header(hdr);

    const res = win.access_header(999);
    try testing.expect(res != null);
    try testing.expectEqual(@as(u32, 4096), res.?.total_len());

    var buf: [10]u8 = undefined;
    const sqe = io_uring.SubmissionEntry{
        .op_code = @intFromEnum(io_uring.IOOp.Read),
        .fd = @as(i32, slot),
        .buf_ptr = &buf,
        .buf_len = @as(u32, buf.len),
        .offset = 0,
        .user_data = 0,
    };

    const TEST_SQ_DEPTH: usize = 2;
    const TEST_SQ_MASK: u32 = TEST_SQ_DEPTH - 1;
    const TestRing = extern struct {
        sq_entries: [TEST_SQ_DEPTH]io_uring.SubmissionEntry,
        sq_head: u32, sq_tail: u32,

        pub fn init() @This() {
            return @This(){ .sq_entries = undefined, .sq_head = 0, .sq_tail = 0 };
        }

        pub fn submit(self: *@This(), e: io_uring.SubmissionEntry) bool {
            const h = self.sq_head;
            const t = self.sq_tail;
            if (t -% h >= TEST_SQ_DEPTH) return false;
            self.sq_entries[t & TEST_SQ_MASK] = e;
            self.sq_tail = t +% 1;
            return true;
        }
    };

    comptime {
        if ((TEST_SQ_DEPTH & (TEST_SQ_DEPTH - 1)) != 0) @compileError("ZC-TEST-FATAL: power of 2");
        if (@offsetOf(TestRing, "sq_entries") != 0) @compileError("ZC-TEST-FATAL: offset 0");
    }

    var tr = TestRing.init();
    try testing.expect(tr.submit(sqe) == true);
    try testing.expect(tr.submit(sqe) == true);
    try testing.expect(tr.submit(sqe) == false);
}