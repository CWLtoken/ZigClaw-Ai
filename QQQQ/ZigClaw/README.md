# ZigClaw v3.0 LTS

Based on Zig 0.16 async I/O framework with Linux io_uring syscalls.

## Status

**v6.8.1-lts** — v3.0 LTS Final (144/144 tests green, ReleaseSafe)

- P0: protocol.zig sterile room — eliminated all `.?`/`orelse`/`try`/`catch`
- P0: core.zig — removed unused `const std = @import("std")`
- P0: docs/pitfalls.md — documented directive scope (5 core layers + exempted entry/service layers)
- io_uring: real syscall-based ring (setup, mmap, enter, register_buffers)
- All 13 integration phases passed (p3–p13)

## Build

```
cd src && zig test tests.zig
# or
zig build test
```

## Architecture

- **core.zig** — TokenStreamHeader (13-byte wire layout)
- **storage.zig** — StreamWindow (64 slots) + BodyBufferPool (1024×4096)
- **io_uring.zig** — Raw syscall layer (setup, mmap, enter, register/unregister)
- **reactor.zig** — SPSC reactor with comptime layout/size/SQ_DEPTH guards
- **protocol.zig** — State machine (Idle→HeaderRecv→BodyRecv→BodyDone), sterile room (no std/?.catch/try)

## Directives

- [Pitfalls & Scope](docs/pitfalls.md)

## Environment

- Zig 0.16.0
- Linux x86_64 (WSL2)