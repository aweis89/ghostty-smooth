//! Glided viewport scrolling for keybound scroll actions and cruise.
//!
//! The viewport still moves in whole rows (`Terminal.scrollViewport`), so
//! history, selection, links and search behave as they always do. The glide
//! keeps a visual position `v` that moves smoothly, scrolls the viewport to
//! the row at or just below it, and leaves the remainder as a sub-row pixel
//! offset (`State.scroll_offset_px`), the same one precision trackpad
//! scrolling uses. Nothing else in the renderer has to know.
//!
//! Two motions add together:
//!
//!   - A critically damped spring towards a target, for `j`, `Space`, `gg`
//!     and the other scroll actions. Repeated presses add to the target.
//!   - Cruise: a constant speed, like a teleprompter, until the end of the
//!     scrollback in its direction.
//!
//! Rows and directions follow the terminal: positive is down, towards the
//! active area. Caller holds the renderer state mutex for every call.
const ViewportGlide = @This();

const std = @import("std");
const terminalpkg = @import("../terminal/main.zig");
const Terminal = terminalpkg.Terminal;

/// Spring stiffness; settles a page in about a quarter of a second.
pub const stiffness: f32 = 400;
/// Rows of spring kept at most: a longer jump (`gg` through a long
/// history) jumps the excess at once and glides the last stretch.
pub const max_spring_rows: f32 = 96;
/// Cruise speed bounds and default, in rows per second.
pub const min_cruise: f32 = 0.25;
pub const max_cruise: f32 = 60;
pub const default_cruise: f32 = 2;
/// Speed factor per `cruise_speed` step.
pub const cruise_step: f32 = 1.25;

/// Rows still to travel to the spring's target (signed).
remaining: f32 = 0,
/// Spring velocity, rows/s, towards decreasing `remaining`.
velocity: f32 = 0,
/// Rows the viewport is below the visual position, in [0, 1): the grid is
/// drawn this far down (towards scrollback) to show the visual position.
lag: f32 = 0,
/// Cruise direction: 1 down, -1 up, 0 off.
cruise_dir: f32 = 0,
/// Cruise speed, rows/s; kept between cruises.
cruise_speed: f32 = default_cruise,

pub fn isActive(self: *const ViewportGlide) bool {
    return self.remaining != 0 or self.velocity != 0 or self.cruise_dir != 0 or self.lag != 0;
}

/// Stop where the viewport is now. Rounds to the nearest row so a glide
/// interrupted mid-row does not leave a half-row offset behind.
pub fn cancel(self: *ViewportGlide, term: *Terminal) void {
    if (self.lag >= 0.5) term.scrollViewport(.{ .delta = -1 });
    self.remaining = 0;
    self.velocity = 0;
    self.lag = 0;
    self.cruise_dir = 0;
}

/// The viewport's visual row offset from the top of the scrollable area,
/// and the largest it can be.
fn position(self: *const ViewportGlide, term: *Terminal) struct { v: f32, max: f32 } {
    const sb = term.screens.active.pages.scrollbar();
    const offset: f32 = @floatFromInt(sb.offset);
    const max: f32 = @floatFromInt(sb.total -| sb.len);
    return .{ .v = offset - self.lag, .max = max };
}

/// Glide `rows` further (negative: up), clamped to the scrollback.
pub fn scrollBy(self: *ViewportGlide, term: *Terminal, rows: f32) void {
    const p = self.position(term);
    const target = std.math.clamp(p.v + self.remaining + rows, 0, p.max);
    self.setRemaining(term, target - p.v);
}

/// Glide to the top (`.top`) or bottom (`.bottom`) of the scrollback.
pub fn scrollToEnd(self: *ViewportGlide, term: *Terminal, end: enum { top, bottom }) void {
    const p = self.position(term);
    self.cruise_dir = 0;
    self.setRemaining(term, switch (end) {
        .top => -p.v,
        .bottom => p.max - p.v,
    });
}

fn setRemaining(self: *ViewportGlide, term: *Terminal, remaining: f32) void {
    var r = remaining;
    // Jump all but the last stretch of a long glide.
    const excess = @abs(r) - max_spring_rows;
    if (excess >= 1) {
        const jump: f32 = @trunc(excess) * std.math.sign(r);
        term.scrollViewport(.{ .delta = @intFromFloat(jump) });
        r -= jump;
    }
    self.remaining = r;
    if (r == 0 and self.lag == 0) self.velocity = 0;
}

/// Start cruising in `dir` (1 down, -1 up), or stop if already cruising
/// that way.
pub fn toggleCruise(self: *ViewportGlide, dir: f32) void {
    self.cruise_dir = if (self.cruise_dir == dir) 0 else dir;
}

/// Change the cruise speed by `steps` factors of `cruise_step`.
pub fn adjustCruise(self: *ViewportGlide, steps: f32) void {
    self.cruise_speed = std.math.clamp(
        self.cruise_speed * std.math.pow(f32, cruise_step, steps),
        min_cruise,
        max_cruise,
    );
}

/// Advance by `dt` seconds: scroll the viewport and return the sub-row
/// offset to draw it at, in rows (multiply by the cell height).
pub fn step(self: *ViewportGlide, term: *Terminal, dt: f32) f32 {
    if (!self.isActive() or dt <= 0) return self.lag;

    // Spring: closed-form critically damped step of `remaining`.
    var moved: f32 = 0;
    if (self.remaining != 0 or self.velocity != 0) {
        const omega = @sqrt(stiffness);
        const x = self.remaining;
        const c = self.velocity + omega * x;
        const decay = @exp(-omega * dt);
        var nx = (x + c * dt) * decay;
        var nv = (self.velocity - omega * c * dt) * decay;
        const crossed = x != 0 and (x > 0) != (nx > 0);
        if (crossed or (@abs(nx) < 0.002 and @abs(nv) < 0.02)) {
            nx = 0;
            nv = 0;
        }
        moved += x - nx;
        self.remaining = nx;
        self.velocity = nv;
    }
    moved += self.cruise_dir * self.cruise_speed * dt;

    // The viewport sits at the row at or below the visual position:
    // `lag` in [0, 1).
    var lag = self.lag - moved;
    const rows = @floor(lag);
    lag -= rows;
    if (rows != 0) {
        const before = term.screens.active.pages.scrollbar().offset;
        const delta: isize = @intFromFloat(-rows);
        term.scrollViewport(.{ .delta = delta });
        const after = term.screens.active.pages.scrollbar().offset;
        const actual: isize = @as(isize, @intCast(after)) - @as(isize, @intCast(before));
        if (actual != delta) {
            // Hit the top or bottom of the scrollback: settle there.
            self.remaining = 0;
            self.velocity = 0;
            self.cruise_dir = 0;
            lag = 0;
        }
    }
    // A finished spring with no cruise lands exactly on a row.
    if (self.remaining == 0 and self.velocity == 0 and self.cruise_dir == 0) {
        if (lag >= 0.5) term.scrollViewport(.{ .delta = -1 });
        lag = 0;
    }
    self.lag = lag;
    return lag;
}

fn testTerminal(rows: usize) !Terminal {
    const testing = std.testing;
    var term = try Terminal.init(testing.io, testing.allocator, .{ .cols = 20, .rows = 10 });
    for (0..rows) |_| try term.printString("line\r\n");
    return term;
}

fn viewportOffset(term: *Terminal) usize {
    return term.screens.active.pages.scrollbar().offset;
}

fn settle(g: *ViewportGlide, term: *Terminal) !void {
    var steps: usize = 0;
    while (g.isActive()) : (steps += 1) {
        try std.testing.expect(steps < 2000);
        const lag = g.step(term, 1.0 / 120.0);
        try std.testing.expect(lag >= 0 and lag < 1);
    }
}

test "viewport glide: scrolls up gradually and lands on the row" {
    const testing = std.testing;
    var term = try testTerminal(100);
    defer term.deinit(testing.allocator);
    const start = viewportOffset(&term);

    var g: ViewportGlide = .{};
    g.scrollBy(&term, -20);
    // Nothing jumps up front.
    try testing.expectEqual(start, viewportOffset(&term));
    _ = g.step(&term, 0.05);
    const first = viewportOffset(&term);
    try testing.expect(first < start and first > start - 20);

    try settle(&g, &term);
    try testing.expectEqual(start - 20, viewportOffset(&term));
}

test "viewport glide: repeated presses add up and clamp at the top" {
    const testing = std.testing;
    var term = try testTerminal(30);
    defer term.deinit(testing.allocator);

    var g: ViewportGlide = .{};
    for (0..10) |_| g.scrollBy(&term, -10);
    try settle(&g, &term);
    try testing.expectEqual(@as(usize, 0), viewportOffset(&term));
}

test "viewport glide: long jump to the top jumps the excess" {
    const testing = std.testing;
    var term = try testTerminal(500);
    defer term.deinit(testing.allocator);

    var g: ViewportGlide = .{};
    g.scrollToEnd(&term, .top);
    try testing.expect(@abs(g.remaining) <= max_spring_rows);
    try settle(&g, &term);
    try testing.expectEqual(@as(usize, 0), viewportOffset(&term));

    g.scrollToEnd(&term, .bottom);
    try settle(&g, &term);
    try testing.expect(term.screens.active.pages.viewport == .active);
}

test "viewport glide: cruise runs at its speed and stops at the bottom" {
    const testing = std.testing;
    var term = try testTerminal(100);
    defer term.deinit(testing.allocator);

    var g: ViewportGlide = .{};
    g.scrollToEnd(&term, .top);
    try settle(&g, &term);

    g.toggleCruise(1);
    for (0..240) |_| _ = g.step(&term, 1.0 / 120.0);
    // Two seconds at the default speed: four rows, give or take the
    // row the viewport rounds to.
    const cruised = viewportOffset(&term);
    try testing.expect(cruised == 4 or cruised == 5);

    g.adjustCruise(100);
    try testing.expectEqual(max_cruise, g.cruise_speed);
    try settle(&g, &term);
    try testing.expect(term.screens.active.pages.viewport == .active);
    try testing.expectEqual(@as(f32, 0), g.cruise_dir);
}

test "viewport glide: cancel rounds to the nearest row" {
    const testing = std.testing;
    var term = try testTerminal(100);
    defer term.deinit(testing.allocator);
    const start = viewportOffset(&term);

    var g: ViewportGlide = .{};
    g.scrollBy(&term, -10);
    _ = g.step(&term, 0.03);
    g.cancel(&term);
    try testing.expect(!g.isActive());
    try testing.expect(viewportOffset(&term) < start);
}
