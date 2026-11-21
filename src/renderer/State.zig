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
///   ESC _ smooth;advance;ID;N ESC \                       content just moved up
///                                                         N rows; glide it in.
///                                                         Negative N (protocol
///                                                         6): moved down
///   ESC _ smooth;? ESC \                                  query; reply smooth;ok;5
///
/// `advance` (protocol 4) is for an app that scrolls a region itself, such
/// as by writing new lines above a pinned editor: sent in the same
/// synchronized update as the rows, it makes Ghostty draw the region N rows
/// lower and spring it back into place on its own frame clock. The glide
/// survives re-declarations, including ones that move the region's edges.
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
    pub const query_reply = "\x1b_smooth;ok;6\x1b\\";

    /// Rows of glide kept at most; a bigger backlog jumps the excess.
    pub const max_glide: f32 = 3;
    /// Spring stiffness for the glide (critically damped, so no overshoot).
    pub const glide_stiffness: f32 = 220;

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

    /// Rows the content is drawn below where it is (negative: above),
    /// springing back to zero, and that spring's velocity in rows per
    /// second (see `advance`).
    glide: f32 = 0,
    glide_vel: f32 = 0,
    /// When `glide` and `glide_vel` were last brought up to date. An
    /// advance must land on the glide as it is now, not as it was at the
    /// last frame update, or the motion jumps.
    glide_at: std.Io.Timestamp = .zero,

    /// Whether `bottom` is a hidden overscan row (the default).
    overscan: bool = true,

    pub const Command = union(enum) {
        set: Smooth,
        /// Clear one region, or all of them when null.
        clear: ?u32,
        /// The region's content moved up by `rows`, at `at` (set by the
        /// caller on receipt; parsing leaves it zero).
        advance: struct { id: u32, rows: i32, at: std.Io.Timestamp = .zero },
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
            if (it.next() != null) return error.Invalid;
            return .{ .advance = .{
                .id = std.fmt.parseInt(u32, id, 10) catch return error.Invalid,
                .rows = std.fmt.parseInt(i32, rows, 10) catch return error.Invalid,
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
        const glide = self.glide;
        const glide_vel = self.glide_vel;
        const glide_at = self.glide_at;
        self.* = next;
        self.glide = glide;
        self.glide_vel = glide_vel;
        self.glide_at = glide_at;
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
        return std.math.clamp(std.math.clamp(self.acc, 0, 0.999) + app, 0, 0.999) - self.glide;
    }

    /// Content moved up `rows` at `now` (negative: down): draw it that much
    /// lower (higher), up to `max_glide` either way, added to the glide as it
    /// stands at `now`.
    pub fn advance(self: *Smooth, rows: i32, now: std.Io.Timestamp) void {
        _ = self.catchUp(now);
        const next = self.glide + @as(f32, @floatFromInt(rows));
        self.glide = std.math.clamp(next, -max_glide, max_glide);
    }

    /// Bring the glide spring up to `now`. Returns whether it is moving.
    pub fn catchUp(self: *Smooth, now: std.Io.Timestamp) bool {
        const ns: f32 = @floatFromInt(@max(self.glide_at.durationTo(now).nanoseconds, 0));
        self.glide_at = now;
        return self.stepGlide(ns / std.time.ns_per_s);
    }

    /// Step the glide spring by `dt` seconds (closed form, exact at any
    /// frame rate). Returns whether it is still moving.
    pub fn stepGlide(self: *Smooth, dt: f32) bool {
        if (self.glide == 0 and self.glide_vel == 0) return false;
        const omega = @sqrt(glide_stiffness);
        const x = self.glide;
        const c = self.glide_vel + omega * x;
        const decay = @exp(-omega * dt);
        self.glide = (x + c * dt) * decay;
        self.glide_vel = (self.glide_vel - omega * c * dt) * decay;
        // Never past rest: velocity left over from an advance the other way
        // could otherwise carry it through zero.
        const crossed = x != 0 and (x > 0) != (self.glide > 0);
        if (crossed or (@abs(self.glide) <= 0.001 and @abs(self.glide_vel) < 0.01)) {
            self.glide = 0;
            self.glide_vel = 0;
            return false;
        }
        return true;
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
                if (s.id == a.id) s.advance(a.rows, a.at);
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
    try testing.expectApproxEqAbs(@as(f32, 1), state.smoothAt(0, 0).?.glide, 0.0001);
    // Capped, then decays to rest.
    state.applySmooth(try Smooth.parse("advance;7;10"));
    try testing.expectApproxEqAbs(Smooth.max_glide, state.smoothAt(0, 0).?.glide, 0.0001);
    var frames: i96 = 0;
    while (state.stepGlides(.fromNanoseconds((frames + 1) * 8_333_333))) frames += 1;
    try testing.expectEqual(@as(f32, 0), state.smoothAt(0, 0).?.glide);
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
    fresh.advance(1, .zero);
    _ = fresh.catchUp(.fromNanoseconds(100 * std.time.ns_per_ms));
    try testing.expectApproxEqAbs(fresh.glide + 1, s.glide, 0.0001);
    // Unknown ids are ignored; bad payloads rejected.
    state.applySmooth(try Smooth.parse("advance;9;1"));
    try testing.expectError(error.Invalid, Smooth.parse("advance;7;x"));
    try testing.expectError(error.Invalid, Smooth.parse("advance;7"));
    try testing.expectError(error.Invalid, Smooth.parse("advance;7;1;2"));
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
    try testing.expectApproxEqAbs(-Smooth.max_glide, s.glide, 0.0001);
    var frames: i96 = 0;
    var low: f32 = s.glide;
    while (state.stepGlides(.fromNanoseconds((frames + 1) * 8_333_333))) : (frames += 1) {
        // Rises monotonically to rest, never past it.
        try testing.expect(s.glide >= low and s.glide <= 0);
        low = s.glide;
    }
    try testing.expectEqual(@as(f32, 0), s.glide);
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
    for (self.smooth, 0..) |slot, i| {
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
    var state: State = .{ .mutex = undefined, .terminal = undefined };
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
