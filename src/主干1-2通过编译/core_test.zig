const std = @import("std");
const core = @import("core.zig");
const expect = std.testing.expect;

test "IBusControlPlane struct size check" {
    try expect(@sizeOf(core.IBusControlPlane) == 4096);
}

test "TokenStreamHeader read/write round-trip" {
    var hdr = core.TokenStreamHeader{ .raw = [_]u8{0} ** 13 };
    hdr.set_stream_id(0x123456789ABCDEF0);
    try expect(hdr.stream_id() == 0x123456789ABCDEF0);

    hdr.set_total_len(0x11223344);
    try expect(hdr.total_len() == 0x11223344);

    hdr.set_is_final(true);
    try expect(hdr.is_final() == true);
}

test "Heat update function" {
    try expect(core.update_heat(0, false) == 0);
    try expect(core.update_heat(255, true) == 255);
}