const core = @import("core.zig");

pub const IOOp = enum(u3) {
    Read = 0, Write = 1, Fsync = 2, Open = 3, Close = 4,
};

pub const SubmissionEntry = extern struct {
    op_code: u8, flags: u8 = 0, ioprio: u16 = 0,
    fd: i32, buf_ptr: ?[*]u8, buf_len: u32,
    offset: u64, user_data: u64,
    __pad: [128 - 40]u8 = [_]u8{0} ** (128 - 40),
};

pub const CompletionEntry = extern struct {
    user_data: u64, result: i32, flags: u32 = 0,
};

pub const SQ_DEPTH: usize = 128;
const SQ_MASK: u32 = SQ_DEPTH - 1;

pub const Ring = extern struct {
    sq_entries: [SQ_DEPTH]SubmissionEntry,
    sq_head: u32, sq_tail: u32,

    pub fn init() Ring {
        return Ring{ .sq_entries = undefined, .sq_head = 0, .sq_tail = 0 };
    }

    pub fn submit(self: *Ring, entry: SubmissionEntry) bool {
        const head = self.sq_head;
        const tail = self.sq_tail;
        const used = tail -% head;
        if (used >= SQ_DEPTH) return false;
        const idx = tail & SQ_MASK;
        self.sq_entries[idx] = entry;
        self.sq_tail = tail +% 1;
        return true;
    }
};

comptime {
    if (@sizeOf(SubmissionEntry) != 128) @compileError("ZC-FATAL: SQE 128 bytes");
    if (@sizeOf(CompletionEntry) != 16) @compileError("ZC-FATAL: CQE 16 bytes");
    if (@offsetOf(SubmissionEntry, "op_code") != 0) @compileError("ZC-FATAL: op_code offset");
    if (@offsetOf(SubmissionEntry, "fd") != 4) @compileError("ZC-FATAL: fd offset");
    if (@offsetOf(SubmissionEntry, "buf_ptr") != 8) @compileError("ZC-FATAL: buf_ptr offset");
    if ((SQ_DEPTH & (SQ_DEPTH - 1)) != 0) @compileError("ZC-FATAL: SQ_DEPTH power of 2");
}