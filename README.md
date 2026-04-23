# ZigClaw v2.4

Based on Zig 0.16 async I/O framework with Linux io_uring syscalls.

## Status

**v2.4-p6-mmap-real** - Phase 1 Closure, Ring real.

- Pure syscall3/syscall6 for io_uring_setup + mmap
- Kernel fd acquired, physical memory mapped, pointers aligned
- All 3 tests passed

## Build

```
rm -rf zig-cache && zig build test
```

## Environment

- Zig 0.16.0
- Linux x86_64 (WSL2, kernel 6.18.18-gentoo-microsoft-standard)
