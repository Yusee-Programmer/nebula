// examples/uefi_demo/boot_interactive.zig — bring-up WITH input.
//
// boot.zig finds memory and a framebuffer, calls Tauraro once, and halts.
// This one adds the two things that turn a rendered picture into an
// interface: a pointer, a keyboard, and a frame loop to poll them.
//
// The turnkey `--target uefi-x64` path CANNOT be used here. It auto-generates
// glue that passes exactly (framebuffer, width, height, pitch) -- enough to
// paint, but it never locates an input protocol, and there is no way to ask
// it to. Reaching any protocol beyond GOP is precisely what the hand-written
// stub is for, which is why boot.zig was kept around after the turnkey target
// landed. Build with scripts/build-uefi.ps1 -Stub this-file.
//
// ## The division of labour
//
// Zig owns the platform: protocols, the event loop, and turning firmware
// input into plain integers. Tauraro owns everything above the pixel. That
// split is the same Canvas + input-source contract every other backend
// follows -- SDL2's backend does exactly this shape, just with SDL_PollEvent
// instead of UEFI protocols -- and it is why no toolkit code changes to run
// here.

const std = @import("std");
const uefi = std.os.uefi;

extern fn tauraro_heap_init(base: [*]u8, size: usize) void;

// One call per frame. Everything the UI needs to know about the outside
// world, flattened to integers so the boundary stays trivial:
//   mouse_x/y  cursor position in PIXELS, already scaled to the framebuffer
//   buttons    bit 0 = primary pressed
//   key        a printable ASCII codepoint, or 0 for none this frame
// Returns non-zero to ask for shutdown (the app decides when it is done).
extern fn tauraro_ui_frame(
    fb: [*]u32,
    width: c_longlong,
    height: c_longlong,
    pitch: c_longlong,
    mouse_x: c_longlong,
    mouse_y: c_longlong,
    buttons: c_longlong,
    key: c_longlong,
) c_longlong;

// 16 MiB, same reasoning as boot.zig: the arena has no error channel back to
// its caller, so it is sized well above one frame's cost rather than tuned
// tight. With per-frame release (toolkit/platform/arena.tr) steady-state
// usage is now constant, so this no longer has to cover N frames of leak.
const HEAP_SIZE: usize = 16 * 1024 * 1024;

pub fn main() void {
    const st = uefi.system_table;
    const bs = st.boot_services.?;

    const heap_bytes = bs.allocatePool(.loader_data, HEAP_SIZE) catch return;
    tauraro_heap_init(heap_bytes.ptr, HEAP_SIZE);

    const gop = (bs.locateProtocol(uefi.protocol.GraphicsOutput, null) catch return) orelse return;
    const mode = gop.mode;
    const fb: [*]u32 = @ptrFromInt(mode.frame_buffer_base);
    const w: i64 = @intCast(mode.info.horizontal_resolution);
    const h: i64 = @intCast(mode.info.vertical_resolution);

    // Pointer. AbsolutePointer is tried FIRST and is the one that actually
    // works under QEMU with `-device usb-tablet` (which scripts/run-uefi.ps1
    // now passes): it reports a position directly, in its own coordinate
    // space, which scales to pixels with one multiply.
    //
    // SimplePointer is the fallback for a plain PS/2 mouse. It reports
    // RELATIVE motion, so the cursor position has to be accumulated here and
    // clamped to the screen -- the firmware has no concept of a cursor, and
    // nothing else in the stack is going to keep that state either.
    const abs_ptr = bs.locateProtocol(uefi.protocol.AbsolutePointer, null) catch null;
    const simple_ptr = if (abs_ptr == null)
        bs.locateProtocol(uefi.protocol.SimplePointer, null) catch null
    else
        null;

    var mx: i64 = @divTrunc(w, 2);
    var my: i64 = @divTrunc(h, 2);

    while (true) {
        var buttons: i64 = 0;

        if (abs_ptr) |ap| {
            if (ap.getState()) |s| {
                const m = ap.mode;
                // Scale device units to pixels. Guard the span: a broken
                // device reporting min == max would divide by zero, and a
                // firmware bug should not be able to fault the loop.
                const span_x = m.absolute_max_x -| m.absolute_min_x;
                const span_y = m.absolute_max_y -| m.absolute_min_y;
                if (span_x > 0 and span_y > 0) {
                    const rel_x = s.current_x -| m.absolute_min_x;
                    const rel_y = s.current_y -| m.absolute_min_y;
                    mx = @intCast(@divTrunc(rel_x * @as(u64, @intCast(w)), span_x));
                    my = @intCast(@divTrunc(rel_y * @as(u64, @intCast(h)), span_y));
                }
                if (s.active_buttons.touch_active) buttons = 1;
            } else |_| {}
        } else if (simple_ptr) |sp| {
            if (sp.getState()) |s| {
                // Relative motion, accumulated and clamped. The raw deltas
                // are in the device's own resolution units; dividing by a
                // constant is a crude sensitivity that keeps a PS/2 mouse
                // from flying across a 1280px screen in one poll.
                mx += @divTrunc(s.relative_movement_x, 8);
                my += @divTrunc(s.relative_movement_y, 8);
                if (mx < 0) mx = 0;
                if (my < 0) my = 0;
                if (mx >= w) mx = w - 1;
                if (my >= h) my = h - 1;
                if (s.left_button or s.right_button) buttons = 1;
            } else |_| {}
        }

        // Keyboard. readKeyStroke returns NotReady when nothing is queued,
        // which is the common case every frame, so the error is expected
        // control flow rather than a failure.
        var key: i64 = 0;
        if (st.con_in) |con_in| {
            if (con_in.readKeyStroke()) |k| {
                if (k.unicode_char != 0) key = @intCast(k.unicode_char);
            } else |_| {}
        }

        const want_exit = tauraro_ui_frame(
            fb,
            w,
            h,
            @intCast(mode.info.pixels_per_scan_line),
            mx,
            my,
            buttons,
            key,
        );
        if (want_exit != 0) break;

        // ~60Hz. stall() is microseconds. Without this the loop spins as
        // fast as the firmware allows and the pointer reads are wasted work.
        _ = bs.stall(16_000) catch {};
    }

    while (true) {
        asm volatile ("hlt");
    }
}
