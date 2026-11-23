//! This is the render state that is given to a renderer.

const State = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Inspector = @import("../inspector/main.zig").Inspector;
const terminalpkg = @import("../terminal/main.zig");
const inputpkg = @import("../input.zig");
const renderer = @import("../renderer.zig");
const log = std.log.scoped(.renderer_state);
pub const ViewportGlide = @import("ViewportGlide.zig");

test {
    _ = ViewportGlide;
}

/// The mutex that must be held while reading any of the data in the
/// members of this state. Note that the state itself is NOT protected
/// by the mutex and is NOT thread-safe, only the members values of the
/// state (i.e. the terminal, devmode, etc. values).
mutex: *std.Io.Mutex,

/// The terminal data.
terminal: *terminalpkg.Terminal,

/// The terminal inspector, if any. This will be null while the inspector
/// is not active and will be set when it is active.
inspector: ?*Inspector = null,

/// Dead key state. This will render the current dead key preedit text
/// over the cursor. This currently only ever renders a single codepoint.
/// Preedit can in theory be multiple codepoints long but that is left as
/// a future exercise.
preedit: ?Preedit = null,

/// Mouse state. This only contains state relevant to what renderers
/// need about the mouse.
mouse: Mouse = .{},

/// Sub-row viewport scroll offset in pixels from precision (trackpad)
/// scrolling. Positive shifts content down (toward scrollback). Always
/// strictly less than one cell height in magnitude.
scroll_offset_px: f32 = 0,

/// Glided scrolling for keybound scroll actions and cruise; it drives the
/// viewport and `scroll_offset_px` while active. See `ViewportGlide`.
viewport_glide: ViewportGlide = .{},

/// Experimental app-declared smooth scroll regions, keyed by id. See
/// `Smooth` for the escape sequence.
smooth: [Smooth.max_regions]?Smooth = @splat(null),

/// Copy of the displayed smooth scroll offsets for pointer hit testing,
/// readable without `mutex` (callers of `posToViewport` may or may not hold
/// it). Writers hold `mutex` and bump `hit_seq` around updates (seqlock).
hit_seq: std.atomic.Value(u32) = .init(0),
hit: Hit = .{},

/// The number of threads currently waiting to acquire `mutex` via
/// `lockDemand`. This is not protected by the mutex; it is read by
/// hot lock/unlock loops (the IO parse thread) in `yieldToDemand` to
/// decide whether to hand the mutex off before relocking it.
demand: std.atomic.Value(u32) = .init(0),

/// Handoff generation counter. Incremented (with a futex wake) by
/// `unlockDemand` after a demanding waiter releases the mutex, so that
/// `yieldToDemand` knows the waiter had its turn.
handoff_gen: std.atomic.Value(u32) = .init(0),

/// How long `yieldToDemand` sleeps waiting for a demanding waiter to
/// take its turn before giving up. This bounds how long the IO parse
/// thread can stall if a wake is lost or the waiter is descheduled; a
/// demanding critical section (the renderer's frame snapshot) is
/// microseconds, so one millisecond is generous.
const handoff_timeout_ns = 1 * std.time.ns_per_ms;

/// Acquire `mutex` while signaling demand for it. Use this instead of
/// locking the mutex directly on threads that must not be starved by
/// a hot lock/unlock loop (the renderer's frame snapshot). Must be
/// released with `unlockDemand`; releasing with `mutex.unlock` keeps
/// the data safe but makes parked `yieldToDemand` callers wait out
/// their full timeout.
///
/// Both `std.Thread.Mutex` and os_unfair_lock are unfair: a running
/// thread that unlocks and immediately relocks beats a sleeping
/// waiter every time, because the waiter must first be woken and
/// scheduled. Under sustained pty output the IO parse thread is
/// exactly such a loop, so without this signal the renderer can
/// starve for as long as the output lasts.
pub fn lockDemand(self: *State, io: std.Io) void {
    _ = self.demand.fetchAdd(1, .monotonic);
    self.mutex.lockUncancelable(io);
    const prev = self.demand.fetchSub(1, .monotonic);
    assert(prev > 0);
}

/// Release `mutex` acquired via `lockDemand` and notify hot loops
/// parked in `yieldToDemand` that the demanding waiter had its turn.
pub fn unlockDemand(self: *State, io: std.Io) void {
    self.mutex.unlock(io);
    _ = self.handoff_gen.fetchAdd(1, .monotonic);
    io.futexWake(u32, &self.handoff_gen.raw, 1);
}

/// Called by hot lock/unlock loops between critical sections, with
/// `mutex` NOT held: if a `lockDemand` waiter exists, sleep until it
/// has acquired and released the mutex (or the timeout passes). This
/// is the handoff that unfair mutexes never do on their own.
///
/// The orderings here are all monotonic because these atomics are a
/// scheduling heuristic, not a synchronization boundary: the mutex
/// itself orders the protected data, and the timeout bounds any
/// staleness.
pub fn yieldToDemand(self: *State, io: std.Io) void {
    if (self.demand.load(.monotonic) == 0) return;

    // Snapshot the generation before rechecking demand: if the waiter
    // acquires and releases between our check and the wait below, the
    // generation no longer matches and timedWait returns immediately.
    const gen = self.handoff_gen.load(.monotonic);
    if (self.demand.load(.monotonic) == 0) return;
    io.futexWaitTimeout(
        u32,
        &self.handoff_gen.raw,
        gen,
        .{ .duration = .{ .raw = .fromNanoseconds(handoff_timeout_ns), .clock = .awake } },
    ) catch {};
}

pub const Mouse = struct {
    /// The point on the viewport where the mouse currently is. We use
    /// viewport points to avoid the complexity of mapping the mouse to
    /// the renderer state.
    point: ?terminalpkg.point.Coordinate = null,

    /// The mods that are currently active for the last mouse event.
    /// This could really just be mods in general and we probably will
    /// move it out of mouse state at some point.
    mods: inputpkg.Mods = .{},
};

/// The pre-edit state. See Surface.preeditCallback for more information.
pub const Preedit = struct {
    /// The codepoints to render as preedit text.
    codepoints: []const Codepoint = &.{},

    /// A single codepoint to render as preedit text.
    pub const Codepoint = struct {
        codepoint: u21,
        wide: bool = false,
    };

    /// Deinit this preedit that was cre
    pub fn deinit(self: *const Preedit, alloc: Allocator) void {
        alloc.free(self.codepoints);
    }

    /// Allocate a copy of this preedit in the given allocator..
    pub fn clone(self: *const Preedit, alloc: Allocator) !Preedit {
        return .{
            .codepoints = try alloc.dupe(Codepoint, self.codepoints),
        };
    }

    /// The width in cells of all codepoints in the preedit.
    pub fn width(self: *const Preedit) usize {
        var result: usize = 0;
        for (self.codepoints) |cp| {
            result += if (cp.wide) 2 else 1;
        }

        return result;
    }

    /// Range returns the start and end x position of the preedit text
    /// along with any codepoint offset necessary to fit the preedit
    /// into the available space.
    pub fn range(
        self: *const Preedit,
        start: terminalpkg.size.CellCountInt,
        max: terminalpkg.size.CellCountInt,
    ) struct {
        start: terminalpkg.size.CellCountInt,
        end: terminalpkg.size.CellCountInt,
        cp_offset: usize,
    } {
        // If our width is greater than the number of cells we have
        // then we need to adjust our codepoint start to a point where
        // our width would be less than the number of cells we have.
        const w, const cp_offset = width: {
            // max is inclusive, so we need to add 1 to it.
            const max_width = max - start + 1;

            // Rebuild our width in reverse order. This is because we want
            // to offset by the end cells, not the start cells (if we have to).
            var w: terminalpkg.size.CellCountInt = 0;
            for (0..self.codepoints.len) |i| {
                const reverse_i = self.codepoints.len - i - 1;
                const cp = self.codepoints[reverse_i];
                w += if (cp.wide) 2 else 1;
                if (w > max_width) {
                    break :width .{ w, reverse_i };
                }
            }

            // Width fit in the max width so no offset necessary.
            break :width .{ w, 0 };
        };

        // If our preedit goes off the end of the screen, we adjust it so
        // that it shifts left.
        const end = if (w > 0) start + (w - 1) else start;
        const start_offset = if (end > max) end - max else 0;
        return .{
            .start = start -| start_offset,
            .end = end -| start_offset,
            .cp_offset = cp_offset,
        };
    }
};

const test_hangul_ga: u21 = 0xAC00; // U+AC00 HANGUL SYLLABLE GA

test "preedit range covers exact cell width" {
    const testing = std.testing;

    {
        const p: Preedit = .{
            .codepoints = &.{.{ .codepoint = 'a' }},
        };
        const range = p.range(2, 9);
        try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 2), range.start);
        try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 2), range.end);
        try testing.expectEqual(@as(usize, 0), range.cp_offset);
    }

    {
        const p: Preedit = .{
            .codepoints = &.{.{ .codepoint = test_hangul_ga, .wide = true }},
        };
        const range = p.range(2, 9);
        try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 2), range.start);
        try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 3), range.end);
        try testing.expectEqual(@as(usize, 0), range.cp_offset);
    }
}

test "preedit range shifts left at right edge" {
    const testing = std.testing;

    const p: Preedit = .{
        .codepoints = &.{.{ .codepoint = test_hangul_ga, .wide = true }},
    };
    const range = p.range(9, 9);
    try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 8), range.start);
    try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 9), range.end);
    try testing.expectEqual(@as(usize, 0), range.cp_offset);
}

/// A rectangle of viewport cells the app scrolls one row per wheel event.
/// Ghostty accumulates precision scroll input for it and shifts the
/// region up by the sub-row remainder. `bottom` is an overscan row the
/// app fills with the next line of content; it is only revealed as the
/// region shifts.
///
///   ESC _ smooth;ID;top;bottom;left;right;pos;max ESC \   declare/update
///   ESC _ smooth;ID;top;bottom;left;right;pos;max;ox;oy ESC \
///                                                         ...with an app-set
///                                                         shift (see `shift`)
///   ESC _ smooth;top;bottom;pos;max ESC \                 legacy: id 0, full width
///   ESC _ smooth;off[;ID] ESC \                           clear all or one
///   ESC _ smooth;ID;top;bottom;left;right;pos;max;flags ESC \
///                                                         ...with flags (protocol 5);
///                                                         bit 0: no overscan row
///   ESC _ smooth;advance;ID;N[;rate[;flags]] ESC \        content just moved up
///                                                         N rows; glide it in.
///                                                         Negative N (protocol
///                                                         6): moved down.
///                                                         Optional rate in
///                                                         centi-rows/s (protocol
///                                                         7). Optional flags
///                                                         (protocol 8/9): bit 0 =
///                                                         batch glide (up to 128
///                                                         rows, adaptive catch-up),
///                                                         bit 1 = soft bottom fade
///   ESC _ smooth;reveal;ID;top;count;rate[;flags] ESC \   protocol 8/9: animate
///                                                         newly committed rows
///                                                         in region ID (top may
///                                                         be negative in protocol
///                                                         9 for rows already in
///                                                         the glide window;
///                                                         distinct blocks queue
///                                                         FIFO; flags 0: 120 Hz
///                                                         soft ink sweep; flags 1:
///                                                         vertical curtain)
///   ESC _ smooth;? ESC \                                  query; reply smooth;ok;9
///
/// `advance` (protocol 4) is for an app that scrolls a region itself, such
/// as by writing new lines above a pinned editor: sent in the same
/// synchronized update as the rows, it makes Ghostty draw the region N rows
/// lower and glide it back into place on its own frame clock. With no rate
/// hint (or rate 0 from rest), a critically damped spring settles isolated
/// moves crisply. With a positive rate hint (protocol 7, in hundredths of a
/// row per second), a velocity-slewed conveyor cruises at that steady speed
/// across discrete row commits, then coasts smoothly to rest without surging
/// once the stream stops (rate 0 or no further advances). The glide survives
/// re-declarations, including ones that move the region's edges.
/// The region's `bottom` stays an overscan row the glide moves rows behind,
/// unless declared with the no-overscan flag: then `bottom` is drawn like any
/// other row, and rows glided below it are clipped at its lower edge. That
/// suits a region with something else right under it, such as rows an app
/// just added above a status line.
///
/// A negative advance is the same motion downwards: content that just moved
/// down is drawn higher and springs down into place, clipped at the region's
/// top edge, with blank space opening at its bottom. That suits rows an app
/// just removed, with the rows above dropping into their place.
///
/// Rows and columns are 0-based and inclusive.
pub const Smooth = struct {
    pub const max_regions = 8;

    /// Reply to the capability query `ESC _ smooth;? ESC \`: the protocol
    /// version this terminal implements.
    pub const query_reply = "\x1b_smooth;ok;9\x1b\\";

    /// Rows of glide kept at most for legacy/spring glides; a bigger backlog jumps the excess.
    pub const max_glide: f32 = 3;
    /// Rows of glide kept at most for protocol 8/9 paced batch glides.
    pub const max_batch_glide: f32 = 128;
    /// Batch glide pacing bounds and catch-up horizon.
    pub const batch_min_rate: f32 = 5.0;
    pub const batch_max_rate: f32 = 30.0;
    pub const batch_catch_up_s: f32 = 2.5;
    /// Protocol 8 `advance` flags bitmask.
    pub const advance_flag_batch: u32 = 1;
    pub const advance_flag_fade: u32 = 2;
    pub const advance_flags_mask: u32 = advance_flag_batch | advance_flag_fade;
    /// Spring stiffness for isolated/downward glides (critically damped).
    pub const glide_stiffness: f32 = 220;
    /// Maximum accepted rate hint in centi-rows/s (100.00 rows/s).
    pub const max_rate_centi: u32 = 10_000;
    /// Minimum rate hint (rows/s) that engages steady-rate conveyor motion;
    /// slower hints fall back to the spring.
    pub const min_conveyor_rate: f32 = 0.5;
    /// Conveyor velocity ramp-up, braking, and cruise-change time constants.
    /// `4 * brake_gain * tau_brake = 0.98 <= 1`, so braking is critically
    /// damped and approaches rest with zero overshoot.
    pub const tau_ramp: f32 = 0.14;
    pub const tau_brake: f32 = 0.035;
    pub const tau_cruise: f32 = 0.35;
    pub const brake_gain: f32 = 7.0;
    pub const conveyor_substep: f32 = 0.01;

    /// Self-contained glide dynamics, snapshotted by the renderer so draw
    /// wakes evaluate the exact same motion as `State.stepGlides`.
    pub const Glide = struct {
        /// Rows the content is drawn below where it is (negative: above).
        rows: f32 = 0,
        /// Velocity of `rows` in rows per second (negative while gliding up).
        vel: f32 = 0,
        /// Active cruise rate hint in rows/s (>0 while streaming; 0 when
        /// draining or using the spring).
        rate: f32 = 0,
        /// Smoothed cruise speed in rows/s; non-zero while in conveyor mode
        /// (both while streaming and while coasting cleanly to rest).
        cruise: f32 = 0,
        /// Seconds elapsed since the last `advance` (safety timeout so a
        /// vanished stream still drains to rest).
        since: f32 = 0,
        /// True while draining a protocol 8 paced batch commit (larger cap,
        /// adaptive cruise speed, no tight cushion surge).
        batch: bool = false,
        /// True when the renderer should dissolve newly emerging rows softly
        /// at the region's bottom clip edge while gliding.
        fade: bool = false,

        pub fn isActive(self: Glide) bool {
            return self.rows != 0 or self.vel != 0;
        }

        pub fn advance(self: *Glide, delta: f32, rate_hint: f32) void {
            self.advanceFlags(delta, rate_hint, 0);
        }

        pub fn advanceFlags(self: *Glide, delta: f32, rate_hint: f32, flags: u32) void {
            const is_batch = (flags & advance_flag_batch) != 0 and delta > 0;
            const cap = if (is_batch or self.batch) max_batch_glide else max_glide;
            self.rows = std.math.clamp(self.rows + delta, -cap, cap);
            self.since = 0;
            if (self.rows == 0) {
                self.vel = 0;
                self.rate = 0;
                self.cruise = 0;
                self.batch = false;
                self.fade = false;
            } else if (self.rows < 0) {
                self.rate = 0;
                self.cruise = 0;
                self.batch = false;
                self.fade = false;
            } else if (is_batch) {
                self.batch = true;
                if ((flags & advance_flag_fade) != 0) self.fade = true;
                const raw_base = if (rate_hint >= min_conveyor_rate) rate_hint else batch_min_rate;
                const base = std.math.clamp(raw_base, min_conveyor_rate, batch_max_rate);
                const target = std.math.clamp(
                    @max(base, self.rows / batch_catch_up_s),
                    base,
                    batch_max_rate,
                );
                self.rate = target;
                if (self.cruise == 0) self.cruise = target;
            } else if (delta > 0 and rate_hint >= min_conveyor_rate) {
                if ((flags & advance_flag_fade) != 0) self.fade = true;
                self.rate = rate_hint;
                if (self.cruise == 0) self.cruise = rate_hint;
            } else {
                // End of stream (rate 0) or non-positive delta while still
                // gliding up: stop streaming, but keep `cruise` if we were
                // already cruising so we coast smoothly to rest without
                // surging into a stiff spring.
                if ((flags & advance_flag_fade) != 0) self.fade = true;
                if (!self.batch) self.rate = 0;
            }
        }

        /// Step the glide forward by `dt` seconds. Returns whether it is still
        /// moving.
        pub fn step(self: *Glide, dt: f32) bool {
            if (dt <= 0) return self.isActive();
            if (!self.isActive()) {
                self.rate = 0;
                self.cruise = 0;
                self.batch = false;
                self.fade = false;
                return false;
            }
            if (self.cruise == 0 or self.rows <= 0) {
                self.rate = 0;
                self.cruise = 0;
                self.batch = false;
                return self.stepSpring(dt);
            }
            return self.stepConveyor(dt);
        }

        fn stepSpring(self: *Glide, dt: f32) bool {
            const omega = @sqrt(glide_stiffness);
            const x = self.rows;
            const c = self.vel + omega * x;
            const decay = @exp(-omega * dt);
            self.rows = (x + c * dt) * decay;
            self.vel = (self.vel - omega * c * dt) * decay;
            // Never past rest: velocity left over from an advance the other
            // way could otherwise carry it through zero.
            const crossed = x != 0 and (x > 0) != (self.rows > 0);
            if (crossed or (@abs(self.rows) <= 0.001 and @abs(self.vel) < 0.01)) {
                self.rows = 0;
                self.vel = 0;
                self.fade = false;
                return false;
            }
            return true;
        }

        fn stepConveyor(self: *Glide, dt: f32) bool {
            var rem_dt = @min(dt, 10.0);
            while (rem_dt > 0) {
                const h = @min(rem_dt, conveyor_substep);
                rem_dt -= h;
                self.since += h;
                if (!self.batch and self.rate > 0) {
                    const timeout = std.math.clamp(2.0 / self.rate, 0.45, 4.0);
                    if (self.since > timeout) self.rate = 0;
                }
                var v_des: f32 = undefined;
                if (self.batch) {
                    self.cruise += (self.rate - self.cruise) * (1 - @exp(-h / tau_cruise));
                    v_des = self.cruise;
                } else if (self.rate > 0) {
                    self.cruise += (self.rate - self.cruise) * (1 - @exp(-h / tau_cruise));
                    v_des = self.cruise;
                    const cushion_hi = @min(
                        max_glide - 0.65,
                        @max(@as(f32, 1.4), self.cruise * tau_ramp + 1.05),
                    );
                    if (self.rows > cushion_hi) {
                        v_des += 3.0 * (self.rows - cushion_hi);
                    }
                } else {
                    v_des = self.cruise;
                }
                v_des = @min(v_des, brake_gain * self.rows);
                const prev_speed = @max(@as(f32, 0), -self.vel);
                const tau = if (v_des >= prev_speed) tau_ramp else tau_brake;
                const speed = prev_speed + (v_des - prev_speed) * (1 - @exp(-h / tau));
                self.vel = -speed;
                self.rows -= 0.5 * (prev_speed + speed) * h;
                if (self.rows <= 0.001) {
                    self.rows = 0;
                    self.vel = 0;
                    self.rate = 0;
                    self.cruise = 0;
                    self.batch = false;
                    self.fade = false;
                    return false;
                }
            }
            return true;
        }
    };

    /// Self-contained native reveal animation (protocol 8/9): 120 Hz feathered
    /// horizontal ink sweep across prose lines, or vertical curtain dissolve
    /// for code/table/in-place blocks. Protocol 9 adds a FIFO segment queue so
    /// mixed blocks (prose -> code -> prose) transition seamlessly without
    /// client-side stalls. Snapshotted alongside `Glide` for vsync drawing.
    pub const Reveal = struct {
        pub const max_rows: usize = 128;
        pub const max_queued: usize = 32;
        pub const max_rate_param: u32 = 10_000;
        pub const default_sweep_rate: f32 = 280.0;
        pub const max_sweep_rate: f32 = 2400.0;
        pub const sweep_catch_up_s: f32 = 2.0;
        pub const sweep_feather_cols: f32 = 6.0;
        pub const default_curtain_rate: f32 = 10.0;
        pub const max_curtain_rate: f32 = 30.0;
        pub const curtain_catch_up_s: f32 = 1.5;
        pub const curtain_feather_rows: f32 = 1.5;

        pub const Mode = enum(u8) {
            none = 0,
            sweep = 1,
            curtain = 2,
        };

        pub const Span = struct {
            lead: u16 = 0,
            end: u16 = 0,

            pub fn len(self: Span) u16 {
                return self.end -| self.lead;
            }
        };

        pub const Segment = struct {
            mode: Mode = .none,
            start_row: i32 = 0,
            count: u16 = 0,
            base_rate: f32 = 0,
        };

        mode: Mode = .none,
        /// Active-screen row (0-based, may be negative while inside the
        /// gliding scrollback window) of `spans[0]`.
        start_row: i32 = 0,
        /// Number of valid rows in `spans[0..count]` for the active segment.
        count: u16 = 0,
        /// Per-row visible content bounds [lead, end) in grid cells.
        /// `[0..count)` belongs to the active segment; `[count..totalSpans())`
        /// holds queued segments contiguously in FIFO order.
        spans: [max_rows]Span = @splat(.{}),
        /// Pending reveal segments waiting behind the active segment.
        queued: [max_queued]Segment = @splat(.{}),
        queued_len: u8 = 0,
        /// Current row index sweeping (0..count) for `.sweep`.
        active_idx: u16 = 0,
        /// `.sweep`: frontier x in cells on `spans[active_idx]`.
        /// `.curtain`: frontier y in rows relative to `start_row`.
        pos: f32 = 0,
        /// Current speed (cells/s for `.sweep`, rows/s for `.curtain`).
        speed: f32 = 0,
        /// Requested base rate (0 = mode default).
        base_rate: f32 = 0,

        pub fn isActive(self: Reveal) bool {
            return self.mode != .none and self.count > 0;
        }

        pub fn totalSpans(self: Reveal) usize {
            var total: usize = self.count;
            for (0..self.queued_len) |i| total += self.queued[i].count;
            return total;
        }

        /// Highest row index covered by the active or any queued reveal segment,
        /// so pending segments stay masked until their turn.
        pub fn maxEndRow(self: Reveal) i32 {
            var end_row: i32 = self.start_row + @as(i32, self.count) - 1;
            for (0..self.queued_len) |i| {
                const seg = self.queued[i];
                end_row = @max(end_row, seg.start_row + @as(i32, seg.count) - 1);
            }
            return end_row;
        }

        pub fn clear(self: *Reveal) void {
            self.mode = .none;
            self.start_row = 0;
            self.count = 0;
            self.queued_len = 0;
            self.active_idx = 0;
            self.pos = 0;
            self.speed = 0;
            self.base_rate = 0;
        }

        /// Pop the next queued segment into the active slot, or clear if empty.
        fn promoteNext(self: *Reveal) void {
            while (true) {
                const drop: usize = self.count;
                const total = self.totalSpans();
                if (self.queued_len == 0) {
                    self.clear();
                    return;
                }
                const keep_total = total - drop;
                for (0..keep_total) |i| self.spans[i] = self.spans[i + drop];
                const next = self.queued[0];
                for (1..self.queued_len) |i| self.queued[i - 1] = self.queued[i];
                self.queued_len -= 1;
                self.mode = next.mode;
                self.start_row = next.start_row;
                self.count = next.count;
                self.base_rate = next.base_rate;
                self.active_idx = 0;
                self.speed = 0;
                if (self.mode == .sweep) {
                    while (self.active_idx < self.count and self.spans[self.active_idx].len() == 0) {
                        self.active_idx += 1;
                    }
                    if (self.active_idx >= self.count) continue;
                    self.pos = @floatFromInt(self.spans[self.active_idx].lead);
                } else {
                    self.pos = 0;
                }
                self.recomputeSpeed();
                return;
            }
        }

        /// Drop completed leading rows to free buffer room (works for both `.sweep` and `.curtain`).
        fn compact(self: *Reveal) void {
            if (!self.isActive()) return;
            const drop: usize = switch (self.mode) {
                .none => return,
                .sweep => self.active_idx,
                .curtain => blk: {
                    const done = @as(i32, @intFromFloat(@floor(@max(@as(f32, 0), self.pos - curtain_feather_rows))));
                    break :blk @min(@as(usize, @intCast(@max(0, done))), @as(usize, self.count));
                },
            };
            if (drop == 0) return;
            if (drop >= self.count) {
                self.promoteNext();
                return;
            }
            const total = self.totalSpans();
            const keep_total = total - drop;
            for (0..keep_total) |i| self.spans[i] = self.spans[i + drop];
            self.start_row += @intCast(drop);
            self.count -= @intCast(drop);
            if (self.mode == .sweep) {
                self.active_idx = 0;
            } else if (self.mode == .curtain) {
                self.pos = @max(@as(f32, 0), self.pos - @as(f32, @floatFromInt(drop)));
            }
        }

        /// Drop rows that have scrolled past the top of the visible/gliding window
        /// (`< -ceil(max(0, glide_rows))`), promoting queued segments as needed.
        fn pruneAbove(self: *Reveal, glide_rows: f32) void {
            if (!self.isActive()) return;
            const min_row: i32 = -@as(i32, @intFromFloat(@ceil(@max(@as(f32, 0), glide_rows))));
            while (self.isActive()) {
                if (self.start_row + @as(i32, self.count) <= min_row) {
                    self.promoteNext();
                    continue;
                }
                if (self.start_row < min_row) {
                    const drop_i = min_row - self.start_row;
                    if (drop_i >= @as(i32, self.count)) {
                        self.promoteNext();
                        continue;
                    }
                    const drop: usize = @intCast(drop_i);
                    const total = self.totalSpans();
                    const keep_total = total - drop;
                    for (0..keep_total) |i| self.spans[i] = self.spans[i + drop];
                    self.start_row = min_row;
                    self.count -= @intCast(drop);
                    if (self.mode == .sweep) {
                        if (self.active_idx >= drop) {
                            self.active_idx -= @intCast(drop);
                        } else {
                            self.active_idx = 0;
                            self.skipEmpty();
                            if (self.isActive() and self.mode == .sweep) {
                                self.pos = @floatFromInt(self.spans[self.active_idx].lead);
                            }
                        }
                    } else if (self.mode == .curtain) {
                        self.pos = @max(@as(f32, 0), self.pos - @as(f32, @floatFromInt(drop)));
                    }
                }
                break;
            }
        }

        /// Shift active and queued reveal rows up when the terminal scrolls by
        /// `delta > 0`. Rows still inside the gliding scrollback window
        /// (`>= -ceil(glide_rows)`) are kept so `syncSmoothEffects` continues
        /// revealing them via `k_off`.
        pub fn shiftRows(self: *Reveal, delta: i32, glide_rows: f32) void {
            if (!self.isActive() or delta <= 0) return;
            self.start_row -|= delta;
            for (0..self.queued_len) |i| self.queued[i].start_row -|= delta;
            self.pruneAbove(glide_rows);
        }

        fn skipEmpty(self: *Reveal) void {
            while (self.active_idx < self.count and self.spans[self.active_idx].len() == 0) {
                self.active_idx += 1;
            }
            if (self.active_idx >= self.count) {
                self.promoteNext();
            }
        }

        fn recomputeSpeed(self: *Reveal) void {
            switch (self.mode) {
                .none => self.speed = 0,
                .sweep => {
                    var rem_cells: f32 = 0;
                    for (self.active_idx..self.count) |i| {
                        const sp = self.spans[i];
                        if (sp.len() == 0) continue;
                        if (i == self.active_idx) {
                            const end_f = @as(f32, @floatFromInt(sp.end)) + sweep_feather_cols;
                            rem_cells += @max(@as(f32, 0), end_f - self.pos);
                        } else {
                            rem_cells += @as(f32, @floatFromInt(sp.len())) + sweep_feather_cols;
                        }
                    }
                    // Account for queued segments so long mixed bursts catch up smoothly.
                    var off: usize = self.count;
                    for (0..self.queued_len) |q| {
                        const seg = self.queued[q];
                        if (seg.mode == .sweep) {
                            for (off..off + seg.count) |i| {
                                const sp = self.spans[i];
                                if (sp.len() > 0) {
                                    rem_cells += @as(f32, @floatFromInt(sp.len())) + sweep_feather_cols;
                                }
                            }
                        } else {
                            rem_cells += @as(f32, @floatFromInt(seg.count)) * 30.0;
                        }
                        off += seg.count;
                    }
                    const raw_base = if (self.base_rate > 0) self.base_rate else default_sweep_rate;
                    const base = @min(max_sweep_rate, raw_base);
                    self.speed = std.math.clamp(
                        @max(self.speed, @max(base, rem_cells / sweep_catch_up_s)),
                        base,
                        max_sweep_rate,
                    );
                },
                .curtain => {
                    const raw_base = if (self.base_rate > 0) self.base_rate else default_curtain_rate;
                    const base = @min(max_curtain_rate, raw_base);
                    var rem = @max(
                        @as(f32, 0),
                        @as(f32, @floatFromInt(self.count)) + curtain_feather_rows - self.pos,
                    );
                    for (0..self.queued_len) |q| {
                        rem += @as(f32, @floatFromInt(self.queued[q].count));
                    }
                    self.speed = std.math.clamp(
                        @max(self.speed, @max(base, rem / curtain_catch_up_s)),
                        base,
                        max_curtain_rate,
                    );
                },
            }
        }

        pub fn start(
            self: *Reveal,
            mode: Mode,
            top: i32,
            new_spans: []const Span,
            rate_param: u32,
        ) void {
            if (mode == .none or new_spans.len == 0) {
                self.clear();
                return;
            }
            const req_rate: f32 = switch (mode) {
                .none => 0,
                .sweep => @floatFromInt(rate_param),
                .curtain => @as(f32, @floatFromInt(rate_param)) / 100.0,
            };
            if (self.isActive()) {
                self.compact();
            }
            if (self.isActive()) {
                const total = self.totalSpans();
                const room = max_rows - total;
                if (new_spans.len <= room) {
                    if (self.queued_len == 0 and
                        self.mode == mode and
                        top == self.start_row + @as(i32, self.count))
                    {
                        for (new_spans, 0..) |sp, i| self.spans[self.count + i] = sp;
                        self.count += @intCast(new_spans.len);
                        if (req_rate > 0) self.base_rate = req_rate;
                        self.recomputeSpeed();
                        return;
                    }
                    if (self.queued_len > 0) {
                        const tail = &self.queued[self.queued_len - 1];
                        if (tail.mode == mode and
                            top == tail.start_row + @as(i32, tail.count))
                        {
                            for (new_spans, 0..) |sp, i| self.spans[total + i] = sp;
                            tail.count += @intCast(new_spans.len);
                            if (req_rate > 0) tail.base_rate = req_rate;
                            self.recomputeSpeed();
                            return;
                        }
                    }
                    const tail_end: i32 = if (self.queued_len > 0)
                        self.queued[self.queued_len - 1].start_row +
                            @as(i32, self.queued[self.queued_len - 1].count)
                    else
                        self.start_row + @as(i32, self.count);
                    // Only queue strictly adjacent blocks so maxEndRow never masks
                    // unrevealed gap rows between non-adjacent commits.
                    if (top == tail_end and self.queued_len < max_queued) {
                        for (new_spans, 0..) |sp, i| self.spans[total + i] = sp;
                        self.queued[self.queued_len] = .{
                            .mode = mode,
                            .start_row = top,
                            .count = @intCast(new_spans.len),
                            .base_rate = req_rate,
                        };
                        self.queued_len += 1;
                        self.recomputeSpeed();
                        return;
                    }
                }
            }
            // Start fresh when inactive or when the queue/span buffer is full.
            self.clear();
            const n = @min(new_spans.len, max_rows);
            const offset = new_spans.len - n;
            self.mode = mode;
            self.start_row = top + @as(i32, @intCast(offset));
            self.count = @intCast(n);
            for (0..n) |i| self.spans[i] = new_spans[offset + i];
            self.base_rate = req_rate;
            if (mode == .sweep) {
                self.active_idx = 0;
                self.skipEmpty();
                if (!self.isActive()) return;
                self.pos = @floatFromInt(self.spans[self.active_idx].lead);
            } else {
                self.pos = 0;
            }
            self.recomputeSpeed();
        }

        /// Advance the reveal frontier by `dt` seconds. Returns whether it is
        /// still active. When `glide_rows > 0`, both `.sweep` and `.curtain`
        /// stay coupled to the conveyor so rows don't reveal offscreen below
        /// the clip edge, and boost speed if the conveyor pulls ahead.
        pub fn step(
            self: *Reveal,
            dt: f32,
            glide_rows: f32,
            region_bottom: u16,
            overscan: bool,
        ) bool {
            self.pruneAbove(glide_rows);
            if (!self.isActive()) return false;
            if (dt <= 0) return true;
            var rem_dt = @min(dt, 10.0);
            const clip_row: f32 = @floatFromInt(
                if (overscan) @as(u32, region_bottom) else @as(u32, region_bottom) + 1,
            );
            while (rem_dt > 0 and self.isActive()) {
                switch (self.mode) {
                    .none => return false,
                    .curtain => {
                        const end_pos = @as(f32, @floatFromInt(self.count)) + curtain_feather_rows;
                        var eff_speed = self.speed;
                        var target_end = end_pos;
                        if (glide_rows > 0) {
                            const visible_limit = clip_row - glide_rows;
                            const max_pos = @max(
                                @as(f32, 0),
                                visible_limit - @as(f32, @floatFromInt(self.start_row)) + curtain_feather_rows,
                            );
                            if (self.pos >= max_pos and max_pos < end_pos) {
                                // Remaining rows are still below the visible clip edge: hold.
                                return true;
                            }
                            target_end = @min(end_pos, max_pos);
                            const rows_above = visible_limit - (@as(f32, @floatFromInt(self.start_row)) + self.pos);
                            if (rows_above > 2.0) {
                                eff_speed = @min(max_curtain_rate, eff_speed * (1.0 + 0.35 * rows_above));
                            }
                        }
                        const dist = target_end - self.pos;
                        if (dist <= 0 or eff_speed * rem_dt >= dist) {
                            if (dist > 0 and eff_speed > 0) {
                                rem_dt -= dist / eff_speed;
                            }
                            self.pos = target_end;
                            if (self.pos >= end_pos - 0.0001) {
                                self.promoteNext();
                            } else {
                                // Reached the glide clip edge; hold until the next frame.
                                return true;
                            }
                        } else {
                            self.pos += eff_speed * rem_dt;
                            rem_dt = 0;
                        }
                    },
                    .sweep => {
                        const active_row_f: f32 = @floatFromInt(self.start_row + @as(i32, self.active_idx));
                        var eff_speed = self.speed;
                        if (glide_rows > 0) {
                            const visible_limit = clip_row - glide_rows - 0.35;
                            if (active_row_f > visible_limit) {
                                // Row is still below the visible clip edge: hold at its start.
                                return true;
                            }
                            const rows_above = visible_limit - active_row_f;
                            if (rows_above > 1.0) {
                                eff_speed = @min(max_sweep_rate, eff_speed * (1.0 + rows_above));
                            }
                        }
                        const sp = self.spans[self.active_idx];
                        const row_end = @as(f32, @floatFromInt(sp.end)) + sweep_feather_cols;
                        const dist = row_end - self.pos;
                        if (dist <= 0 or eff_speed * rem_dt >= dist) {
                            if (dist > 0 and eff_speed > 0) {
                                rem_dt -= dist / eff_speed;
                            }
                            self.active_idx += 1;
                            self.skipEmpty();
                            if (!self.isActive()) return false;
                            if (self.mode == .sweep) {
                                self.pos = @floatFromInt(self.spans[self.active_idx].lead);
                            }
                        } else {
                            self.pos += eff_speed * rem_dt;
                            rem_dt = 0;
                        }
                    },
                }
            }
            return self.isActive();
        }
    };

    id: u32,
    top: u16,
    bottom: u16,
    left: u16,
    right: u16,

    /// The app's current scroll position (top content row) and maximum.
    pos: u32,
    max: u32,

    /// Accumulated scroll relative to `pos`, in rows. Positive moves
    /// content up (scrolling down).
    acc: f32 = 0,

    /// Rows requested from the app via wheel events that are not yet
    /// reflected in `pos`.
    pending_rows: i32 = 0,

    /// App-set sub-cell shift in thousandths of a cell (x left, y up),
    /// for content the app moves itself, such as a dragged map. When set,
    /// `right` is an overscan column as well, hidden until the region
    /// shifts left into it. The y shift adds to the scroll remainder.
    shift: ?[2]u16 = null,

    /// Active glide motion (spring or steady-rate conveyor; see `advance`).
    glide: Glide = .{},
    /// When `glide` and `reveal` were last brought up to date. An advance or
    /// reveal must land on the motion as it is now, not at the last frame.
    glide_at: std.Io.Timestamp = .zero,
    /// Active native reveal animation (protocol 8; ink sweep or vertical curtain).
    reveal: Reveal = .{},

    /// Whether `bottom` is a hidden overscan row (the default).
    overscan: bool = true,

    pub const Command = union(enum) {
        set: Smooth,
        /// Clear one region, or all of them when null.
        clear: ?u32,
        /// The region's content moved up by `rows`, at `at` (set by the
        /// caller on receipt; parsing leaves it zero), with an optional
        /// cruise `rate` hint in rows per second (0 = spring / end of stream)
        /// and optional protocol 8 `flags`.
        advance: struct {
            id: u32,
            rows: i32,
            rate: f32 = 0,
            flags: u32 = 0,
            at: std.Io.Timestamp = .zero,
        },
        /// Protocol 8/9 reveal animation over newly committed rows
        /// `top .. top + count - 1` (`top` may be negative in protocol 9 for
        /// rows already in the glide scrollback window). `spans` is filled by
        /// the stream handler from the screen; if `has_spans` is false (e.g.
        /// unit tests), default full-width spans `[left, right + 1)` are used.
        reveal: struct {
            id: u32,
            top: i32,
            count: u16,
            rate: u32 = 0,
            mode: Reveal.Mode = .sweep,
            spans: [Reveal.max_rows]Reveal.Span = @splat(.{}),
            has_spans: bool = false,
            at: std.Io.Timestamp = .zero,
        },
    };

    /// Parse the payload after `smooth;`.
    pub fn parse(payload: []const u8) error{Invalid}!Command {
        var v: [9]u32 = undefined;
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, payload, ';');
        if (std.mem.eql(u8, it.peek() orelse "", "off")) {
            _ = it.next();
            const id = it.next() orelse return .{ .clear = null };
            return .{ .clear = std.fmt.parseInt(u32, id, 10) catch return error.Invalid };
        }
        if (std.mem.eql(u8, it.peek() orelse "", "advance")) {
            _ = it.next();
            const id = it.next() orelse return error.Invalid;
            const rows = it.next() orelse return error.Invalid;
            var rate: f32 = 0;
            var flags: u32 = 0;
            if (it.next()) |rate_s| {
                const centi = std.fmt.parseInt(u32, rate_s, 10) catch return error.Invalid;
                if (centi > max_rate_centi) return error.Invalid;
                rate = @as(f32, @floatFromInt(centi)) / 100.0;
                if (it.next()) |flags_s| {
                    if (it.next() != null) return error.Invalid;
                    flags = std.fmt.parseInt(u32, flags_s, 10) catch return error.Invalid;
                    if ((flags & ~advance_flags_mask) != 0) return error.Invalid;
                }
            }
            return .{ .advance = .{
                .id = std.fmt.parseInt(u32, id, 10) catch return error.Invalid,
                .rows = std.fmt.parseInt(i32, rows, 10) catch return error.Invalid,
                .rate = rate,
                .flags = flags,
            } };
        }
        if (std.mem.eql(u8, it.peek() orelse "", "reveal")) {
            _ = it.next();
            const id_s = it.next() orelse return error.Invalid;
            const top_s = it.next() orelse return error.Invalid;
            const count_s = it.next() orelse return error.Invalid;
            const rate_s = it.next() orelse return error.Invalid;
            var flags: u32 = 0;
            if (it.next()) |flags_s| {
                if (it.next() != null) return error.Invalid;
                flags = std.fmt.parseInt(u32, flags_s, 10) catch return error.Invalid;
                if (flags > 1) return error.Invalid;
            }
            const id = std.fmt.parseInt(u32, id_s, 10) catch return error.Invalid;
            const top = std.fmt.parseInt(i32, top_s, 10) catch return error.Invalid;
            const count = std.fmt.parseInt(u16, count_s, 10) catch return error.Invalid;
            const rate = std.fmt.parseInt(u32, rate_s, 10) catch return error.Invalid;
            const min_top: i32 = -@as(i32, @intFromFloat(max_batch_glide));
            if (top < min_top or top > std.math.maxInt(u16) or count == 0 or count > Reveal.max_rows or rate > Reveal.max_rate_param) {
                return error.Invalid;
            }
            return .{ .reveal = .{
                .id = id,
                .top = top,
                .count = count,
                .rate = rate,
                .mode = if (flags == 1) .curtain else .sweep,
            } };
        }
        while (it.next()) |field| {
            if (n == v.len) return error.Invalid;
            v[n] = std.fmt.parseInt(u32, field, 10) catch return error.Invalid;
            n += 1;
        }
        const r: [7]u32 = switch (n) {
            4 => .{ 0, v[0], v[1], 0, std.math.maxInt(u16), v[2], v[3] },
            7, 8, 9 => v[0..7].*,
            else => return error.Invalid,
        };
        if (n == 8 and v[7] > 1) return error.Invalid;
        const max16 = std.math.maxInt(u16);
        if (r[1] >= r[2] or r[2] > max16 or r[3] > r[4] or r[4] > max16)
            return error.Invalid;
        // A shifted region needs a visible column besides its overscan one.
        if (n == 9 and (r[3] >= r[4] or v[7] > 999 or v[8] > 999))
            return error.Invalid;
        return .{ .set = .{
            .id = r[0],
            .top = @intCast(r[1]),
            .bottom = @intCast(r[2]),
            .left = @intCast(r[3]),
            .right = @intCast(r[4]),
            .pos = r[5],
            .max = r[6],
            .shift = if (n == 9) .{ @intCast(v[7]), @intCast(v[8]) } else null,
            .overscan = !(n == 8 and v[7] & 1 == 1),
        } };
    }

    /// Apply a fresh declaration from the app, carrying over accumulated
    /// scroll and acknowledging rows the app has moved since last time.
    pub fn update(self: *Smooth, next: Smooth) void {
        const moved: i64 = @as(i64, next.pos) - @as(i64, self.pos);
        const same = self.top == next.top and self.bottom == next.bottom and
            self.left == next.left and self.right == next.right;

        // Only movement in the direction of our pending wheel requests
        // acknowledges them; moves the app made on its own (keyboard,
        // jumps) leave the accumulated remainder alone.
        var ack: i64 = 0;
        if (moved > 0 and self.pending_rows > 0) ack = @min(moved, self.pending_rows);
        if (moved < 0 and self.pending_rows < 0) ack = @max(moved, self.pending_rows);

        const acc = self.acc - @as(f32, @floatFromInt(ack));
        const pending = self.pending_rows - @as(i32, @intCast(ack));
        const same_width = self.left == next.left and self.right == next.right;
        const glide = self.glide;
        const glide_at = self.glide_at;
        const reveal = if (same_width) self.reveal else Reveal{};
        self.* = next;
        self.glide = glide;
        self.glide_at = glide_at;
        self.reveal = reveal;
        if (same) {
            self.acc = acc;
            self.pending_rows = pending;
        }
    }

    /// Whether precision scrolls over the region are taken over and turned
    /// into smooth scrolling. A region with nothing to scroll (`max` 0),
    /// such as one declared only for its shift, passes them to the app.
    pub fn capturesScroll(self: Smooth) bool {
        return self.max > 0;
    }

    pub fn contains(self: Smooth, x: usize, y: usize) bool {
        return y >= self.top and y <= self.bottom and x >= self.left and x <= self.right;
    }

    /// The vertical offset to render, in rows: the scroll remainder plus
    /// any app-set shift, held between zero and just under one row since
    /// only one overscan row exists.
    pub fn offsetRows(self: Smooth) f32 {
        const app: f32 = if (self.shift) |sh| @as(f32, @floatFromInt(sh[1])) / 1000 else 0;
        return std.math.clamp(std.math.clamp(self.acc, 0, 0.999) + app, 0, 0.999) - self.glide.rows;
    }

    /// Content moved up `rows` at `now` (negative: down): draw it that much
    /// lower (higher), up to `max_glide` (or `max_batch_glide` when batch flag
    /// is set), added to the glide as it stands at `now`.
    pub fn advance(self: *Smooth, rows: i32, rate: f32, now: std.Io.Timestamp) void {
        self.advanceFlags(rows, rate, 0, now);
    }

    pub fn advanceFlags(self: *Smooth, rows: i32, rate: f32, flags: u32, now: std.Io.Timestamp) void {
        _ = self.catchUp(now);
        self.glide.advanceFlags(@floatFromInt(rows), rate, flags);
        if (rows > 0 and self.reveal.isActive()) {
            self.reveal.shiftRows(rows, self.glide.rows);
        }
    }

    pub fn startReveal(
        self: *Smooth,
        mode: Reveal.Mode,
        top: i32,
        count: u16,
        spans: []const Reveal.Span,
        has_spans: bool,
        rate: u32,
        now: std.Io.Timestamp,
    ) void {
        _ = self.catchUp(now);
        const n = @min(@as(usize, count), Reveal.max_rows);
        var fallback: [Reveal.max_rows]Reveal.Span = undefined;
        const slice: []const Reveal.Span = if (has_spans)
            spans[0..n]
        else blk: {
            const end_col: u16 = self.right +| 1;
            for (0..n) |i| fallback[i] = .{ .lead = self.left, .end = end_col };
            break :blk fallback[0..n];
        };
        self.reveal.start(mode, top, slice, rate);
    }

    /// Bring the glide and reveal up to `now`. Returns whether either is moving.
    pub fn catchUp(self: *Smooth, now: std.Io.Timestamp) bool {
        const ns: f32 = @floatFromInt(@max(self.glide_at.durationTo(now).nanoseconds, 0));
        self.glide_at = now;
        const dt = ns / std.time.ns_per_s;
        // Step glide and reveal together in fine substeps whenever both are
        // active so catchUp matches the 120 Hz draw loop across rebuilds.
        if (dt > 0 and self.glide.isActive() and self.reveal.isActive()) {
            var rem_dt = @min(dt, 10.0);
            while (rem_dt > 0) {
                const h = @min(rem_dt, conveyor_substep);
                rem_dt -= h;
                _ = self.glide.step(h);
                _ = self.reveal.step(h, self.glide.rows, self.bottom, self.overscan);
            }
            return self.glide.isActive() or self.reveal.isActive();
        }
        const glide_moving = self.glide.step(dt);
        const reveal_moving = self.reveal.step(dt, self.glide.rows, self.bottom, self.overscan);
        return glide_moving or reveal_moving;
    }

    /// The horizontal offset to render, in columns, or null when the
    /// region has no overscan column.
    pub fn offsetCols(self: Smooth) ?f32 {
        const sh = self.shift orelse return null;
        return @as(f32, @floatFromInt(sh[0])) / 1000;
    }
};

/// Apply a parsed smooth scroll command to the region table. Caller must
/// hold the mutex.
pub fn applySmooth(self: *State, cmd: Smooth.Command) void {
    switch (cmd) {
        .clear => |id| for (&self.smooth) |*slot| {
            const s = slot.* orelse continue;
            if (id == null or s.id == id.?) slot.* = null;
        },
        .set => |next| {
            var free: ?*?Smooth = null;
            for (&self.smooth) |*slot| {
                if (slot.*) |*s| {
                    if (s.id == next.id) {
                        s.update(next);
                        return;
                    }
                } else if (free == null) {
                    free = slot;
                }
            }
            if (free) |slot| {
                slot.* = next;
            } else {
                log.warn("smooth scroll region table full, ignoring id={}", .{next.id});
            }
        },
        .advance => |a| for (&self.smooth) |*slot| {
            if (slot.*) |*s| {
                if (s.id == a.id) s.advanceFlags(a.rows, a.rate, a.flags, a.at);
            }
        },
        .reveal => |r| for (&self.smooth) |*slot| {
            if (slot.*) |*s| {
                if (s.id == r.id) s.startReveal(
                    r.mode,
                    r.top,
                    r.count,
                    &r.spans,
                    r.has_spans,
                    r.rate,
                    r.at,
                );
            }
        },
    }
}

/// Bring every region's glide up to `now`. Returns whether any is still
/// moving, so the renderer keeps waking for frames. Caller must hold the mutex.
pub fn stepGlides(self: *State, now: std.Io.Timestamp) bool {
    var moving = false;
    for (&self.smooth) |*slot| {
        if (slot.*) |*s| {
            if (s.catchUp(now)) moving = true;
        }
    }
    return moving;
}

/// The smooth scroll region containing viewport cell (x, y), if any; where
/// regions nest, the one with the fewest rows, as the renderer draws it.
/// Caller must hold the mutex.
pub fn smoothAt(self: *State, x: usize, y: usize) ?*Smooth {
    var found: ?*Smooth = null;
    for (&self.smooth) |*slot| {
        if (slot.*) |*s| {
            if (!s.contains(x, y)) continue;
            if (found == null or s.bottom - s.top < found.?.bottom - found.?.top) found = s;
        }
    }
    return found;
}

test "smooth: parse an app-set shift" {
    const testing = std.testing;

    const s = (try Smooth.parse("4;0;30;0;99;10;500;250;750")).set;
    try testing.expectEqual(@as(u16, 99), s.right);
    try testing.expectEqual([2]u16{ 250, 750 }, s.shift.?);
    try testing.expectApproxEqAbs(@as(f32, 0.25), s.offsetCols().?, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.75), s.offsetRows(), 0.0001);

    try testing.expect(s.capturesScroll());
    const shift_only = (try Smooth.parse("4;0;30;0;99;0;0;250;750")).set;
    try testing.expect(!shift_only.capturesScroll());

    // No shift: no overscan column, and the plain v2 form still parses.
    const plain = (try Smooth.parse("4;0;30;0;99;10;500")).set;
    try testing.expectEqual(@as(?f32, null), plain.offsetCols());

    // Out of range or a region with no visible column besides the overscan one.
    try testing.expectError(error.Invalid, Smooth.parse("4;0;30;0;99;10;500;1000;0"));
    try testing.expectError(error.Invalid, Smooth.parse("4;0;30;5;5;10;500;0;0"));
    // Eight fields is the flags form (no-overscan test below); a bad flag fails.
    try testing.expectError(error.Invalid, Smooth.parse("4;0;30;0;99;10;500;7"));

    // The y shift adds to the scroll remainder but stays under one row.
    var sum = s;
    sum.acc = 0.5;
    try testing.expectApproxEqAbs(@as(f32, 0.999), sum.offsetRows(), 0.0001);
}

test "smooth: advance glides in and survives re-declaration" {
    const testing = std.testing;
    var state: State = .{ .mutex = undefined, .terminal = undefined };
    state.applySmooth(try Smooth.parse("7;0;20;0;79;0;0;0;0"));
    state.applySmooth(try Smooth.parse("advance;7;1"));
    try testing.expectApproxEqAbs(@as(f32, -1), state.smoothAt(0, 0).?.offsetRows(), 0.0001);
    // A resized live panel moves the edge; the glide carries on.
    state.applySmooth(try Smooth.parse("7;0;18;0;79;0;0;0;0"));
    try testing.expectApproxEqAbs(@as(f32, 1), state.smoothAt(0, 0).?.glide.rows, 0.0001);
    // Capped, then decays to rest.
    state.applySmooth(try Smooth.parse("advance;7;10"));
    try testing.expectApproxEqAbs(Smooth.max_glide, state.smoothAt(0, 0).?.glide.rows, 0.0001);
    var frames: i96 = 0;
    while (state.stepGlides(.fromNanoseconds((frames + 1) * 8_333_333))) frames += 1;
    try testing.expectEqual(@as(f32, 0), state.smoothAt(0, 0).?.glide.rows);
    try testing.expect(frames > 10 and frames < 240);

    // An advance adds to the glide as it is when the advance arrives.
    const s = state.smoothAt(0, 0).?;
    const t0 = s.glide_at;
    var cmd = try Smooth.parse("advance;7;1");
    cmd.advance.at = t0;
    state.applySmooth(cmd);
    cmd.advance.at = t0.addDuration(.fromMilliseconds(100));
    state.applySmooth(cmd);
    var fresh: Smooth = .{ .id = 0, .top = 0, .bottom = 1, .left = 0, .right = 1, .pos = 0, .max = 0 };
    fresh.advance(1, 0, .zero);
    _ = fresh.catchUp(.fromNanoseconds(100 * std.time.ns_per_ms));
    try testing.expectApproxEqAbs(fresh.glide.rows + 1, s.glide.rows, 0.0001);
    // Optional rate hint (centi-rows/s) parses and validates bounds.
    const hinted = (try Smooth.parse("advance;7;1;525")).advance;
    try testing.expectApproxEqAbs(@as(f32, 5.25), hinted.rate, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0), (try Smooth.parse("advance;7;1;0")).advance.rate, 0.0001);
    // Unknown ids are ignored; bad payloads rejected.
    state.applySmooth(try Smooth.parse("advance;9;1"));
    try testing.expectError(error.Invalid, Smooth.parse("advance;7;x"));
    try testing.expectError(error.Invalid, Smooth.parse("advance;7"));
    try testing.expectError(error.Invalid, Smooth.parse("advance;7;1;-5"));
    try testing.expectError(error.Invalid, Smooth.parse("advance;7;1;10001"));
    try testing.expectError(error.Invalid, Smooth.parse("advance;7;1;500;extra"));
    try testing.expectError(error.Invalid, Smooth.parse("advance;7;1;500;4"));
    try testing.expectError(error.Invalid, Smooth.parse("advance;7;1;500;3;extra"));
}

test "smooth: protocol 8 batch glide and soft fade" {
    const testing = std.testing;
    const parsed = (try Smooth.parse("advance;7;16;600;3")).advance;
    try testing.expectEqual(@as(u32, 7), parsed.id);
    try testing.expectEqual(@as(i32, 16), parsed.rows);
    try testing.expectApproxEqAbs(@as(f32, 6.0), parsed.rate, 0.0001);
    try testing.expectEqual(@as(u32, 3), parsed.flags);

    var g: Smooth.Glide = .{};
    const dt: f32 = 1.0 / 120.0;
    g.advanceFlags(16, 6.0, Smooth.advance_flag_batch | Smooth.advance_flag_fade);
    try testing.expectApproxEqAbs(@as(f32, 16.0), g.rows, 0.0001);
    try testing.expect(g.batch);
    try testing.expect(g.fade);
    // 16 / 2.5 = 6.4 rows/s (no tight cushion_hi surge).
    try testing.expectApproxEqAbs(@as(f32, 6.4), g.rate, 0.001);

    var prev = g.rows;
    var peak_speed: f32 = 0;
    var frames: usize = 0;
    while (g.step(dt)) : (frames += 1) {
        try testing.expect(g.rows >= 0 and g.rows <= prev + 0.0001);
        peak_speed = @max(peak_speed, -g.vel);
        prev = g.rows;
        try testing.expect(frames < 600);
    }
    // Cruises smoothly around 6.4 rows/s (~2.5s = ~300 frames) without surging.
    try testing.expect(peak_speed > 6.0 and peak_speed < 6.8);
    try testing.expect(frames > 240 and frames < 420);
    try testing.expectEqual(@as(f32, 0), g.rows);
    try testing.expect(!g.batch);
    try testing.expect(!g.fade);

    // Clamps to max_batch_glide (128) rather than legacy max_glide (3).
    g.advanceFlags(200, 5.0, Smooth.advance_flag_batch);
    try testing.expectApproxEqAbs(Smooth.max_batch_glide, g.rows, 0.0001);
}

test "smooth: protocol 8/9 reveal sweep, chaining, curtain, queue, and glide sync" {
    const testing = std.testing;
    const sw = (try Smooth.parse("reveal;7;10;4;280")).reveal;
    try testing.expectEqual(@as(u32, 7), sw.id);
    try testing.expectEqual(@as(i32, 10), sw.top);
    try testing.expectEqual(@as(u16, 4), sw.count);
    try testing.expectEqual(@as(u32, 280), sw.rate);
    try testing.expectEqual(Smooth.Reveal.Mode.sweep, sw.mode);

    const neg = (try Smooth.parse("reveal;7;-12;4;0")).reveal;
    try testing.expectEqual(@as(i32, -12), neg.top);

    const cu = (try Smooth.parse("reveal;7;10;4;0;1")).reveal;
    try testing.expectEqual(Smooth.Reveal.Mode.curtain, cu.mode);

    try testing.expectError(error.Invalid, Smooth.parse("reveal;7;10;0;280"));
    try testing.expectError(error.Invalid, Smooth.parse("reveal;7;10;129;280"));
    try testing.expectError(error.Invalid, Smooth.parse("reveal;7;-129;4;280"));
    try testing.expectError(error.Invalid, Smooth.parse("reveal;7;10;4;10001"));
    try testing.expectError(error.Invalid, Smooth.parse("reveal;7;10;4;280;2"));
    try testing.expectError(error.Invalid, Smooth.parse("reveal;7;10;4;280;1;extra"));

    // Sweep skips leading blank rows and indentation, and finishes cleanly.
    var rev: Smooth.Reveal = .{};
    const spans = [_]Smooth.Reveal.Span{
        .{ .lead = 0, .end = 0 }, // blank
        .{ .lead = 4, .end = 24 }, // 20 chars indented 4
        .{ .lead = 0, .end = 0 }, // blank
        .{ .lead = 2, .end = 12 }, // 10 chars indented 2
    };
    rev.start(.sweep, 5, &spans, 200);
    try testing.expect(rev.isActive());
    try testing.expectEqual(@as(u16, 1), rev.active_idx);
    try testing.expectApproxEqAbs(@as(f32, 4.0), rev.pos, 0.001);

    // Chaining adjacent rows appends without resetting progress.
    const more = [_]Smooth.Reveal.Span{.{ .lead = 0, .end = 10 }};
    rev.start(.sweep, 9, &more, 200);
    try testing.expectEqual(@as(u16, 4), rev.count); // leading blank compacted away
    try testing.expectEqual(@as(i32, 6), rev.start_row);
    try testing.expectEqual(@as(u16, 0), rev.active_idx);

    // While gliding with rows still below clip edge, sweep holds at lead.
    try testing.expect(rev.step(0.1, 10.0, 12, true));
    try testing.expectApproxEqAbs(@as(f32, 4.0), rev.pos, 0.001);

    // Once visible (glide = 0), sweeps to completion.
    var steps: usize = 0;
    while (rev.step(1.0 / 120.0, 0.0, 12, true)) : (steps += 1) {
        try testing.expect(steps < 400);
    }
    try testing.expect(!rev.isActive());

    // ShiftRows moves reveal upward on subsequent scrolls, keeps rows inside the
    // gliding scrollback window, and clears once past it.
    rev.start(.sweep, 8, &.{ .{ .lead = 0, .end = 20 }, .{ .lead = 0, .end = 20 } }, 280);
    rev.shiftRows(3, 0.0);
    try testing.expectEqual(@as(i32, 5), rev.start_row);
    rev.shiftRows(7, 10.0); // now at -2, still inside 10-row glide window!
    try testing.expect(rev.isActive());
    try testing.expectEqual(@as(i32, -2), rev.start_row);
    rev.shiftRows(12, 0.0); // past window -> cleared
    try testing.expect(!rev.isActive());

    // Curtain mode progresses top-to-bottom and completes.
    rev.start(.curtain, 4, &.{ .{ .lead = 0, .end = 40 }, .{ .lead = 0, .end = 40 } }, 0);
    try testing.expect(rev.isActive());
    var c_steps: usize = 0;
    while (rev.step(1.0 / 120.0, 0.0, 20, true)) : (c_steps += 1) {
        try testing.expect(c_steps < 300);
    }
    try testing.expect(!rev.isActive());

    // Max valid APC rates clamp safely without panicking, and u16 max bottom does not overflow.
    var g_hi: Smooth.Glide = .{};
    g_hi.advanceFlags(10, 100.0, Smooth.advance_flag_batch);
    try testing.expectApproxEqAbs(Smooth.batch_max_rate, g_hi.rate, 0.001);
    rev.start(.sweep, 0, &.{.{ .lead = 0, .end = 20 }}, 10_000);
    try testing.expectApproxEqAbs(Smooth.Reveal.max_sweep_rate, rev.speed, 0.001);
    _ = rev.step(0.01, 1.0, std.math.maxInt(u16), false);
    rev.start(.curtain, 0, &.{.{ .lead = 0, .end = 20 }}, 10_000);
    try testing.expectApproxEqAbs(Smooth.Reveal.max_curtain_rate, rev.speed, 0.001);

    // Substepped catchUp matches 120 Hz incremental stepping when glide and reveal overlap.
    var s_bulk: Smooth = .{ .id = 7, .top = 0, .bottom = 20, .left = 0, .right = 79, .pos = 0, .max = 0 };
    var s_fine = s_bulk;
    const t0: std.Io.Timestamp = .zero;
    s_bulk.advanceFlags(6, 5.0, Smooth.advance_flag_batch | Smooth.advance_flag_fade, t0);
    s_fine.advanceFlags(6, 5.0, Smooth.advance_flag_batch | Smooth.advance_flag_fade, t0);
    const six_spans: [6]Smooth.Reveal.Span = @splat(.{ .lead = 0, .end = 40 });
    s_bulk.startReveal(.sweep, 13, 6, &six_spans, true, 280, t0);
    s_fine.startReveal(.sweep, 13, 6, &six_spans, true, 280, t0);
    _ = s_bulk.catchUp(.fromNanoseconds(250 * std.time.ns_per_ms));
    for (1..31) |f| {
        _ = s_fine.catchUp(.fromNanoseconds(@intCast(f * 250 * std.time.ns_per_ms / 30)));
    }
    try testing.expectEqual(s_fine.reveal.active_idx, s_bulk.reveal.active_idx);
    try testing.expectApproxEqAbs(s_fine.reveal.pos, s_bulk.reveal.pos, 1.5);

    // Width resize clears reveal; vertical-only bottom resize preserves it.
    s_fine.update(.{ .id = 7, .top = 0, .bottom = 18, .left = 0, .right = 79, .pos = 0, .max = 0 });
    try testing.expect(s_fine.reveal.isActive());
    s_fine.update(.{ .id = 7, .top = 0, .bottom = 18, .left = 0, .right = 59, .pos = 0, .max = 0 });
    try testing.expect(!s_fine.reveal.isActive());
}

test "smooth: protocol 9 queued mixed reveals and scroll-coupled curtain" {
    const testing = std.testing;
    var rev: Smooth.Reveal = .{};
    const p1 = [_]Smooth.Reveal.Span{ .{ .lead = 0, .end = 20 }, .{ .lead = 0, .end = 20 } };
    const code = [_]Smooth.Reveal.Span{ .{ .lead = 0, .end = 30 }, .{ .lead = 0, .end = 30 }, .{ .lead = 0, .end = 30 } };
    const p2 = [_]Smooth.Reveal.Span{.{ .lead = 2, .end = 18 }};

    // Queue prose -> curtain -> prose without clobbering the active sweep.
    rev.start(.sweep, 5, &p1, 280);
    rev.start(.curtain, 7, &code, 0);
    rev.start(.sweep, 10, &p2, 280);
    try testing.expectEqual(Smooth.Reveal.Mode.sweep, rev.mode);
    try testing.expectEqual(@as(u8, 2), rev.queued_len);
    try testing.expectEqual(@as(i32, 10), rev.maxEndRow());

    // Shift moves active and queued segments together.
    rev.shiftRows(2, 6.0);
    try testing.expectEqual(@as(i32, 3), rev.start_row);
    try testing.expectEqual(@as(i32, 8), rev.maxEndRow());

    // Stepping transitions sweep -> curtain -> sweep -> done cleanly.
    var saw_curtain = false;
    var saw_second_sweep = false;
    var steps: usize = 0;
    while (rev.step(1.0 / 120.0, 0.0, 20, true)) : (steps += 1) {
        if (rev.mode == .curtain) saw_curtain = true;
        if (saw_curtain and rev.mode == .sweep) saw_second_sweep = true;
        try testing.expect(steps < 600);
    }
    try testing.expect(saw_curtain);
    try testing.expect(saw_second_sweep);
    try testing.expect(!rev.isActive());

    // Curtain holds while its rows are still below the glide clip edge.
    rev.start(.curtain, 14, &code, 0);
    try testing.expect(rev.step(0.2, 10.0, 15, true));
    try testing.expect(rev.pos < 2.0);
    var c_steps: usize = 0;
    while (rev.step(1.0 / 120.0, 0.0, 15, true)) : (c_steps += 1) {
        try testing.expect(c_steps < 400);
    }
    try testing.expect(!rev.isActive());

    // Rows that scroll above -ceil(glide_rows) are pruned inside step() so
    // offscreen rows never stall or blank visible lines.
    rev.start(.sweep, -4, &p1, 280);
    rev.start(.curtain, -2, &code, 0);
    try testing.expect(rev.step(1.0 / 120.0, 0.0, 20, true));
    try testing.expectEqual(Smooth.Reveal.Mode.curtain, rev.mode);
    try testing.expectEqual(@as(i32, 0), rev.start_row);
    try testing.expectEqual(@as(u16, 1), rev.count);

    // Non-adjacent reveal replaces rather than masking unrevealed gap rows.
    rev.start(.sweep, 2, &p1, 280);
    rev.start(.sweep, 8, &p2, 280);
    try testing.expectEqual(@as(u8, 0), rev.queued_len);
    try testing.expectEqual(@as(i32, 8), rev.start_row);
}

test "smooth: rate-hinted conveyor cruises steadily and coasts cleanly to rest" {
    const testing = std.testing;
    var g: Smooth.Glide = .{};
    const dt: f32 = 1.0 / 120.0;

    // Feed 15 rows at a steady 5 rows/s (every 24 frames at 120 fps),
    // with rate=0 on the last row to signal end of stream.
    var min_cruise: f32 = 999;
    var max_cruise: f32 = 0;
    var step_idx: usize = 0;
    while (step_idx < 360) : (step_idx += 1) {
        if (step_idx % 24 == 0) {
            const row_idx = step_idx / 24;
            const rate: f32 = if (row_idx < 14) 5.0 else 0.0;
            g.advance(1, rate);
        }
        _ = g.step(dt);
        // After warm-up (rows 5..13), speed stays nearly flat at 5 rows/s.
        if (step_idx >= 120 and step_idx < 336) {
            const speed = -g.vel;
            min_cruise = @min(min_cruise, speed);
            max_cruise = @max(max_cruise, speed);
        }
    }
    try testing.expect(min_cruise > 4.6 and max_cruise < 5.2);
    try testing.expect(max_cruise / min_cruise < 1.15);

    // After the final row (rate=0), coasts monotonically to rest with no surge or overshoot.
    var prev_rows = g.rows;
    var peak_after_stop: f32 = -g.vel;
    var settle_frames: usize = 0;
    while (g.step(dt)) : (settle_frames += 1) {
        try testing.expect(g.rows >= 0 and g.rows <= prev_rows + 0.0001);
        peak_after_stop = @max(peak_after_stop, -g.vel);
        prev_rows = g.rows;
        try testing.expect(settle_frames < 240);
    }
    try testing.expect(peak_after_stop < 5.2);
    try testing.expectEqual(@as(f32, 0), g.rows);
    try testing.expectEqual(@as(f32, 0), g.vel);
    try testing.expectEqual(@as(f32, 0), g.cruise);

    // If an app hints a rate and then goes silent, the safety timeout drains it to rest.
    g.advance(1, 5.0);
    var silent_frames: usize = 0;
    while (g.step(dt)) : (silent_frames += 1) {
        try testing.expect(silent_frames < 300);
    }
    try testing.expectEqual(@as(f32, 0), g.rows);
    try testing.expectEqual(@as(f32, 0), g.cruise);

    // Slowest conveyor rate (0.5 rows/s) from max_glide settles cleanly on a single large dt.
    g.advance(3, 0.5);
    g.advance(0, 0);
    try testing.expect(!g.step(10.0));
    try testing.expectEqual(@as(f32, 0), g.rows);
    try testing.expectEqual(@as(f32, 0), g.vel);

    // Rate below min_conveyor_rate falls back to spring; cancelling back to 0 clears vel.
    g.advance(1, 0.49);
    try testing.expectEqual(@as(f32, 0), g.cruise);
    _ = g.step(0.05);
    g.advance(-g.rows, 0);
    try testing.expectEqual(@as(f32, 0), g.rows);
    try testing.expectEqual(@as(f32, 0), g.vel);
    try testing.expect(!g.isActive());
}

test "smooth: negative advance glides down into place" {
    const testing = std.testing;
    var state: State = .{ .mutex = undefined, .terminal = undefined };
    state.applySmooth(try Smooth.parse("8;5;9;0;79;0;0;1"));
    state.applySmooth(try Smooth.parse("advance;8;-1"));
    const s = state.smoothAt(0, 5).?;
    // Drawn a row higher: offset up by one.
    try testing.expectApproxEqAbs(@as(f32, 1), s.offsetRows(), 0.0001);
    state.applySmooth(try Smooth.parse("advance;8;-10"));
    try testing.expectApproxEqAbs(-Smooth.max_glide, s.glide.rows, 0.0001);
    var frames: i96 = 0;
    var low: f32 = s.glide.rows;
    while (state.stepGlides(.fromNanoseconds((frames + 1) * 8_333_333))) : (frames += 1) {
        // Rises monotonically to rest, never past it.
        try testing.expect(s.glide.rows >= low and s.glide.rows <= 0);
        low = s.glide.rows;
    }
    try testing.expectEqual(@as(f32, 0), s.glide.rows);
    try testing.expect(frames > 10 and frames < 240);
}

test "smooth: the innermost of nested regions wins" {
    const testing = std.testing;
    var state: State = .{ .mutex = undefined, .terminal = undefined };
    state.applySmooth(try Smooth.parse("9;12;14;0;79;0;0;1"));
    state.applySmooth(try Smooth.parse("7;0;15;0;79;0;0"));
    try testing.expectEqual(@as(u32, 9), state.smoothAt(0, 13).?.id);
    try testing.expectEqual(@as(u32, 7), state.smoothAt(0, 11).?.id);
    try testing.expectEqual(@as(u32, 7), state.smoothAt(0, 15).?.id);
}

test "smooth: no-overscan flag" {
    const testing = std.testing;
    const plain = (try Smooth.parse("8;5;9;0;79;0;0")).set;
    try testing.expect(plain.overscan);
    const flagged = (try Smooth.parse("8;5;9;0;79;0;0;1")).set;
    try testing.expect(!flagged.overscan);
    try testing.expectEqual(@as(u16, 9), flagged.bottom);
    const zero = (try Smooth.parse("8;5;9;0;79;0;0;0")).set;
    try testing.expect(zero.overscan);
    try testing.expectError(error.Invalid, Smooth.parse("8;5;9;0;79;0;0;2"));
}

test "smooth: parse v2, legacy, and clear" {
    const testing = std.testing;

    const v2 = (try Smooth.parse("3;2;20;10;59;5;100")).set;
    try testing.expectEqual(@as(u32, 3), v2.id);
    try testing.expectEqual(@as(u16, 2), v2.top);
    try testing.expectEqual(@as(u16, 20), v2.bottom);
    try testing.expectEqual(@as(u16, 10), v2.left);
    try testing.expectEqual(@as(u16, 59), v2.right);
    try testing.expectEqual(@as(u32, 5), v2.pos);
    try testing.expectEqual(@as(u32, 100), v2.max);

    const legacy = (try Smooth.parse("1;30;0;80")).set;
    try testing.expectEqual(@as(u32, 0), legacy.id);
    try testing.expectEqual(@as(u16, 0), legacy.left);
    try testing.expectEqual(@as(u16, std.math.maxInt(u16)), legacy.right);

    try testing.expectEqual(@as(?u32, null), (try Smooth.parse("off")).clear);
    try testing.expectEqual(@as(?u32, 4), (try Smooth.parse("off;4")).clear);

    try testing.expectError(error.Invalid, Smooth.parse("5;5;0;1")); // top >= bottom
    try testing.expectError(error.Invalid, Smooth.parse("0;1;5;9;4;0;1")); // left > right
    try testing.expectError(error.Invalid, Smooth.parse("1;2;3"));
    try testing.expectError(error.Invalid, Smooth.parse("1;x;3;4"));
}

test "smooth: update acknowledges only requested rows" {
    const testing = std.testing;
    var s = (try Smooth.parse("0;1;10;0;79;5;100")).set;
    s.acc = 2.25;
    s.pending_rows = 2;

    // The app moved the two rows we asked for.
    s.update((try Smooth.parse("0;1;10;0;79;7;100")).set);
    try testing.expectApproxEqAbs(@as(f32, 0.25), s.acc, 0.0001);
    try testing.expectEqual(@as(i32, 0), s.pending_rows);

    // A move the app made on its own leaves the remainder alone.
    s.update((try Smooth.parse("0;1;10;0;79;20;100")).set);
    try testing.expectApproxEqAbs(@as(f32, 0.25), s.acc, 0.0001);

    // Moving the region resets accumulated state.
    s.update((try Smooth.parse("0;2;11;0;79;20;100")).set);
    try testing.expectEqual(@as(f32, 0), s.acc);
}

test "smooth: region table by id and hit testing" {
    const testing = std.testing;
    var state: State = .{ .mutex = undefined, .terminal = undefined };

    state.applySmooth(try Smooth.parse("1;0;10;0;39;0;50"));
    state.applySmooth(try Smooth.parse("2;0;10;40;79;0;50"));
    try testing.expectEqual(@as(u32, 1), state.smoothAt(5, 3).?.id);
    try testing.expectEqual(@as(u32, 2), state.smoothAt(45, 3).?.id);
    try testing.expectEqual(@as(?*Smooth, null), state.smoothAt(45, 11));

    // Re-declaring id 2 updates in place rather than adding a region.
    state.applySmooth(try Smooth.parse("2;0;10;40;79;3;50"));
    var count: usize = 0;
    for (state.smooth) |slot| count += @intFromBool(slot != null);
    try testing.expectEqual(@as(usize, 2), count);

    state.applySmooth(try Smooth.parse("off;1"));
    try testing.expectEqual(@as(?*Smooth, null), state.smoothAt(5, 3));
    state.applySmooth(try Smooth.parse("off"));
    try testing.expectEqual(@as(?*Smooth, null), state.smoothAt(45, 3));
}

/// Displayed pixel-scroll offsets, as used for pointer hit testing.
pub const Hit = struct {
    /// Scrollback shift in pixels; positive moves content down.
    scrollback_px: f32 = 0,
    regions: [Smooth.max_regions]?HitRegion = @splat(null),

    pub const HitRegion = struct {
        top: u16,
        bottom: u16,
        left: u16,
        right: u16,
        /// Rows the region's content is shifted up by.
        offset_rows: f32,
    };
};

/// Refresh the hit-testing copy of the offsets. Caller must hold the mutex.
pub fn publishHit(self: *State) void {
    var next: Hit = .{ .scrollback_px = self.scroll_offset_px };
    // Scrolled into history, regions draw nowhere (see the renderer), so
    // the pointer maps without them.
    const at_active = self.terminal.screens.active.pages.viewport == .active;
    for (self.smooth, 0..) |slot, i| {
        if (!at_active) break;
        const s = slot orelse continue;
        next.regions[i] = .{
            .top = s.top,
            .bottom = s.bottom,
            .left = s.left,
            .right = s.right,
            .offset_rows = s.offsetRows(),
        };
    }
    _ = self.hit_seq.fetchAdd(1, .acq_rel);
    const dst: *volatile Hit = &self.hit;
    dst.* = next;
    _ = self.hit_seq.fetchAdd(1, .acq_rel);
}

/// A consistent copy of the hit-testing offsets. Safe without the mutex.
pub fn readHit(self: *const State) Hit {
    while (true) {
        const before = self.hit_seq.load(.acquire);
        if (before & 1 == 1) {
            std.atomic.spinLoopHint();
            continue;
        }
        const src: *const volatile Hit = &self.hit;
        const copy = src.*;
        if (self.hit_seq.load(.acquire) == before) return copy;
    }
}

test "smooth: hit snapshot mirrors displayed offsets" {
    const testing = std.testing;
    var term = try terminalpkg.Terminal.init(testing.io, testing.allocator, .{ .cols = 40, .rows = 12 });
    defer term.deinit(testing.allocator);
    var state: State = .{ .mutex = undefined, .terminal = &term };
    state.applySmooth(try Smooth.parse("1;2;10;0;39;0;50"));
    state.smoothAt(5, 3).?.acc = 0.4;
    state.scroll_offset_px = 7;
    state.publishHit();

    const hit = state.readHit();
    try testing.expectEqual(@as(f32, 7), hit.scrollback_px);
    const r = hit.regions[0].?;
    try testing.expectEqual(@as(u16, 2), r.top);
    try testing.expectEqual(@as(u16, 10), r.bottom);
    try testing.expectApproxEqAbs(@as(f32, 0.4), r.offset_rows, 0.0001);
    try testing.expectEqual(@as(?Hit.HitRegion, null), hit.regions[1]);
}

test "smooth: hit snapshot has no regions while scrolled into history" {
    const testing = std.testing;
    var term = try terminalpkg.Terminal.init(testing.io, testing.allocator, .{ .cols = 40, .rows = 12 });
    defer term.deinit(testing.allocator);
    for (0..30) |_| try term.printString("line\r\n");
    var state: State = .{ .mutex = undefined, .terminal = &term };
    state.applySmooth(try Smooth.parse("1;2;10;0;39;0;50"));

    term.scrollViewport(.{ .delta = -5 });
    state.publishHit();
    try testing.expectEqual(@as(?Hit.HitRegion, null), state.readHit().regions[0]);

    term.scrollViewport(.bottom);
    state.publishHit();
    try testing.expect(state.readHit().regions[0] != null);
}
