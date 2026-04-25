const std = @import("std");
const Allocator = std.mem.Allocator;
const color_mod = @import("../color.zig");

const MONITOR_URL = "https://status.archlinux.org/api/getMonitorList/vmM5ruWEAB";
const MAX_RESPONSE_SIZE = 512 * 1024;

const circle = "●";
const history_days = 30;

const ratio_green: f64 = 99.0;
const ratio_orange: f64 = 95.0;

const DailyRatio = struct {
    ratio: []const u8 = "0",
};

const RatioEntry = struct {
    ratio: []const u8 = "0",
};

const Monitor = struct {
    name: []const u8 = "",
    statusClass: []const u8 = "",
    @"90dRatio": RatioEntry = .{},
    dailyRatios: []const DailyRatio = &.{},
};

const Psp = struct {
    totalMonitors: u32 = 0,
    monitors: []const Monitor = &.{},
};

const Counts = struct {
    up: u32 = 0,
    down: u32 = 0,
    paused: u32 = 0,
};

const Statistics = struct {
    count_result: []const u8 = "",
    counts: Counts = .{},
};

const MonitorList = struct {
    psp: Psp = .{},
    statistics: Statistics = .{},
};

pub fn run(allocator: Allocator, sty: color_mod.Style) !u8 {
    var http_client = std.http.Client{ .allocator = allocator };
    defer http_client.deinit();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    const fetch_result = http_client.fetch(.{
        .location = .{ .url = MONITOR_URL },
        .method = .GET,
        .response_writer = &aw.writer,
    }) catch {
        writeError("error: failed to fetch Arch Linux status\n");
        return 1;
    };

    if (fetch_result.status != .ok) {
        writeError("error: unexpected HTTP response from status API\n");
        return 1;
    }

    const body = try aw.toOwnedSlice();
    defer allocator.free(body);

    const parsed = std.json.parseFromSlice(
        MonitorList,
        allocator,
        body,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    ) catch {
        writeError("error: failed to parse status API response\n");
        return 1;
    };
    defer parsed.deinit();

    return printStatus(parsed.value, sty);
}

fn writeError(msg: []const u8) void {
    const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
    stderr.writeAll(msg) catch {};
}

fn ratioColor(sty: color_mod.Style, val: f64) []const u8 {
    if (val > ratio_green) return sty.green;
    if (val > ratio_orange) return sty.yellow;
    return sty.red;
}

fn printStatus(data: MonitorList, sty: color_mod.Style) !u8 {
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    const w = stdout.deprecatedWriter();

    const all_clear = std.mem.eql(u8, data.statistics.count_result, "All Clear");
    if (all_clear) {
        try w.print("{s}{s}{s} All systems operational\n\n", .{ sty.green, circle, sty.reset });
    } else if (data.statistics.counts.down > 0) {
        try w.print("{s}{s}{s} {d} monitor(s) down\n\n", .{ sty.red, circle, sty.reset, data.statistics.counts.down });
    } else {
        try w.print("{s}{s}{s} Status unknown\n\n", .{ sty.yellow, circle, sty.reset });
    }

    for (data.psp.monitors) |monitor| {
        const operational = std.mem.eql(u8, monitor.statusClass, "success");
        const down = std.mem.eql(u8, monitor.statusClass, "danger");

        const circ_color = if (operational) sty.green else if (down) sty.red else sty.yellow;
        const status_label: []const u8 = if (operational) "Operational" else if (down) "Down" else "Unknown";
        const status_color = if (operational) sty.green else if (down) sty.red else sty.yellow;

        // Line 1: service name with status indicator
        try w.print("{s}{s}{s}  {s}\n", .{ circ_color, circle, sty.reset, monitor.name });

        // Line 2: history circles, then ratio and right-aligned label flush with circle end
        const ratios = monitor.dailyRatios;
        if (ratios.len > 0) {
            const start = if (ratios.len > history_days) ratios.len - history_days else 0;
            try w.writeAll("   ");
            for (ratios[start..]) |day| {
                const v = std.fmt.parseFloat(f64, day.ratio) catch 0.0;
                try w.print("{s}{s}{s}", .{ ratioColor(sty, v), circle, sty.reset });
            }
        }

        const ratio_val = std.fmt.parseFloat(f64, monitor.@"90dRatio".ratio) catch 0.0;
        try w.print("  {d:.3}%  {s}{s:>11}{s}\n", .{
            ratio_val, status_color, status_label, sty.reset,
        });
    }

    return 0;
}
