// Minimal test to verify while loop works
const std = @import("std");
const testing = std.testing;

test "while loop test" {
    var count: u32 = 0;
    while (count < 5) {
        count += 1;
    }
    try testing.expect(count == 5);
}
