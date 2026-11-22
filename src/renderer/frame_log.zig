//! Frame-gap log for smooth region animations, for benchmarking pacing.
//!
//! Off unless `GHOSTTY_SMOOTH_FRAME_LOG` names a file. While a smooth glide or
//! reveal animates, each draw records the gap since the previous animated draw.
//! When the animation settles, after a gap of 250 ms or more (a pause, not a
//! frame, so a longer stall is not counted either), and every 512 frames, one
//! JSON line summarising those gaps is appended:
//!
//!   {"frames":412,"p50_ms":8.50,"p99_ms":12.75,"max_ms":33.00,
//!    "over_12_5ms":3,"over_20_8ms":1,"hist":"33:398,34:11,50:2,132:1"}
//!
//! Gaps are timed when the renderer draws, so they show how evenly the render
//! thread produces frames, not when the compositor presents them. Percentiles
//! are the upper edge of a 0.25 ms bucket, so they read up to 0.25 ms high.
//! At 120 Hz a frame is 8.3 ms: a gap of at least 12.5 ms (1.5 frames) missed
//! at least one vsync, and one of at least 20.8 ms (2.5 frames) missed two.
//! `hist` lists the non-empty buckets as `index:count` (index × 0.25 ms is the
//! bucket's lower edge; the last index collects everything longer) so a
//! reader can pool several lines into true percentiles.
const FrameLog = @This();

const std = @import("std");
const builtin = @import("builtin");

pub const env_var = "GHOSTTY_SMOOTH_FRAME_LOG";

/// Gaps are bucketed at this resolution up to `buckets * resolution_ms`.
const resolution_ms = 0.25;
const buckets = 256;

/// The path, copied at first use so a later `setenv` cannot move it.
path_buf: [1024]u8 = undefined,
path_len: usize = 0,
checked: bool = false,
last_ns: ?i96 = null,
hist: [buckets + 1]u32 = @splat(0),
count: u32 = 0,
max_ms: f64 = 0,

fn enabled(self: *FrameLog) bool {
    if (!self.checked) {
        self.checked = true;
        if (comptime builtin.link_libc) {
            if (std.c.getenv(env_var)) |p| {
                const path = std.mem.span(p);
                if (path.len > 0 and path.len < self.path_buf.len) {
                    @memcpy(self.path_buf[0..path.len], path);
                    self.path_buf[path.len] = 0;
                    self.path_len = path.len;
                }
            }
        }
    }
    return self.path_len > 0;
}

/// A gap this long is a pause between animations, not a slow frame.
const pause_ms = 250;
/// Lines are also written every this many frames, so an animation that
/// never reports settled still shows up.
const flush_frames = 512;

/// An animated draw at monotonic time `now_ns`.
pub fn frame(self: *FrameLog, now_ns: i96) void {
    if (!self.enabled()) return;
    defer self.last_ns = now_ns;
    const last = self.last_ns orelse return;
    const ms = @as(f64, @floatFromInt(@max(now_ns - last, 0))) / std.time.ns_per_ms;
    if (ms >= pause_ms) {
        self.settle();
        return;
    }
    self.record(ms);
    if (self.count >= flush_frames) self.write();
}

fn bucket(ms: f64) usize {
    return @intFromFloat(@min(@max(ms / resolution_ms, 0), buckets));
}

fn record(self: *FrameLog, ms: f64) void {
    self.hist[bucket(ms)] += 1;
    self.count += 1;
    self.max_ms = @max(self.max_ms, ms);
}

/// The animation settled: write the summary and start over.
pub fn settle(self: *FrameLog) void {
    self.last_ns = null;
    self.write();
}

fn write(self: *FrameLog) void {
    if (self.count == 0) return;
    defer self.reset();
    if (self.path_len == 0) return;
    var buf: [4096]u8 = undefined;
    const line = self.summary(&buf) catch return;
    if (comptime builtin.link_libc) {
        const path: [*:0]const u8 = @ptrCast(&self.path_buf);
        const flags: std.c.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true };
        const fd = std.c.open(path, flags, @as(std.c.mode_t, 0o644));
        if (fd < 0) return;
        defer _ = std.c.close(fd);
        _ = std.c.write(fd, line.ptr, line.len);
    }
}

fn reset(self: *FrameLog) void {
    self.hist = @splat(0);
    self.count = 0;
    self.max_ms = 0;
}

fn percentile(self: *const FrameLog, q: f64) f64 {
    const want: u32 = @max(1, @as(u32, @intFromFloat(@ceil(@as(f64, @floatFromInt(self.count)) * q))));
    var seen: u32 = 0;
    for (self.hist, 0..) |n, i| {
        seen += n;
        if (seen >= want) {
            if (i == buckets) return self.max_ms;
            return @as(f64, @floatFromInt(i + 1)) * resolution_ms;
        }
    }
    return self.max_ms;
}

/// Gaps of at least `ms`.
fn atLeast(self: *const FrameLog, ms: f64) u32 {
    var n: u32 = 0;
    for (self.hist[bucket(ms)..]) |c| n += c;
    return n;
}

fn summary(self: *const FrameLog, buf: []u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try w.print(
        "{{\"frames\":{d},\"p50_ms\":{d:.2},\"p99_ms\":{d:.2},\"max_ms\":{d:.2}," ++
            "\"over_12_5ms\":{d},\"over_20_8ms\":{d},\"hist\":\"",
        .{
            self.count,
            self.percentile(0.5),
            self.percentile(0.99),
            self.max_ms,
            self.atLeast(12.5),
            self.atLeast(20.75),
        },
    );
    var first = true;
    for (self.hist, 0..) |n, i| {
        if (n == 0) continue;
        if (!first) try w.writeByte(',');
        first = false;
        try w.print("{d}:{d}", .{ i, n });
    }
    try w.writeAll("\"}\n");
    return w.buffered();
}

test "smooth frame log summarises gaps" {
    var log: FrameLog = .{ .checked = true };
    for (0..98) |_| log.record(8.3);
    log.record(13);
    log.record(30);
    var buf: [4096]u8 = undefined;
    const line = try log.summary(&buf);
    try std.testing.expectEqualStrings(
        "{\"frames\":100,\"p50_ms\":8.50,\"p99_ms\":13.25,\"max_ms\":30.00," ++
            "\"over_12_5ms\":2,\"over_20_8ms\":1,\"hist\":\"33:98,52:1,120:1\"}\n",
        line,
    );
}

test "smooth frame log clamps long gaps into the last bucket" {
    var log: FrameLog = .{ .checked = true };
    log.record(1e30);
    try std.testing.expectEqual(@as(u32, 1), log.hist[buckets]);
    try std.testing.expectEqual(@as(f64, 1e30), log.percentile(0.5));
}

test "smooth frame log ignores the gap before the first animated draw" {
    var log: FrameLog = .{ .checked = true };
    @memcpy(log.path_buf[0..10], "/dev/null\x00");
    log.path_len = 9;
    log.frame(1_000_000_000);
    try std.testing.expectEqual(@as(u32, 0), log.count);
    log.frame(1_008_000_000);
    try std.testing.expectEqual(@as(u32, 1), log.count);
    log.settle();
    try std.testing.expectEqual(@as(u32, 0), log.count);
    try std.testing.expectEqual(@as(?i96, null), log.last_ns);
}

test "smooth frame log treats a long gap as a pause and flushes long animations" {
    var log: FrameLog = .{ .checked = true };
    @memcpy(log.path_buf[0..10], "/dev/null\x00");
    log.path_len = 9;
    var t: i96 = 0;
    log.frame(t);
    t += 8_000_000;
    log.frame(t);
    try std.testing.expectEqual(@as(u32, 1), log.count);
    t += 400_000_000; // a pause: not recorded, and the stretch is written
    log.frame(t);
    try std.testing.expectEqual(@as(u32, 0), log.count);
    for (0..flush_frames + 3) |_| {
        t += 8_000_000;
        log.frame(t);
    }
    // 512 recorded and written, then 3 more.
    try std.testing.expectEqual(@as(u32, 3), log.count);
}
