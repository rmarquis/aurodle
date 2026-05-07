const std = @import("std");
const plan_mod = @import("../plan.zig");
const pacman_mod = @import("../pacman.zig");
const devel = @import("../devel.zig");
const color = @import("../color.zig");
const types = @import("types.zig");

const getStdout = types.getStdout;

// ── Constants ────────────────────────────────────────────────────────

const hdr_pkg = "Package ()";
const hdr_old_ver = "Old Version";
const hdr_new_ver = "New Version";
const hdr_net_change = "Net Change";
const hdr_dl_size = "Download Size";

/// Column widths for the verbose package table.
/// Seeded from header labels, grown by `widenRepoPkg`, and consumed by
/// `emitTableHeader` / `emitRepoPkgRow`.
const ColWidths = struct {
    name: usize,
    old: usize,
    ver: usize,
    nc: usize,
    dl: usize,
    has_old: bool = false,
    show_sizes: bool,

    fn initFromHeaders(total: usize, show_sizes: bool) ColWidths {
        return .{
            .name = hdr_pkg.len + countDigits(total),
            .old = hdr_old_ver.len,
            .ver = hdr_new_ver.len,
            .nc = hdr_net_change.len,
            .dl = hdr_dl_size.len,
            .show_sizes = show_sizes,
        };
    }

    fn widenRepoPkg(self: *ColWidths, pm: ?*pacman_mod.Pacman, name: []const u8) void {
        const repo = if (pm) |p| p.syncDbFor(name) else null;
        const w = if (repo) |r| r.len + 1 + name.len else name.len;
        if (w > self.name) self.name = w;
        const p = pm orelse return;
        if (p.installedVersion(name)) |v| {
            self.has_old = true;
            if (v.len > self.old) self.old = v.len;
        }
        if (p.syncVersion(name)) |v| {
            if (v.len > self.ver) self.ver = v.len;
        }
        if (self.show_sizes) {
            if (p.repoPkgSizeInfo(name)) |si| {
                var b1: [32]u8 = undefined;
                const nc = fmtSize(si.net_change, &b1);
                if (nc.len > self.nc) self.nc = nc.len;
                var b2: [32]u8 = undefined;
                const dl = fmtSize(si.download, &b2);
                if (dl.len > self.dl) self.dl = dl.len;
            }
        }
    }
};

// ── Public API ───────────────────────────────────────────────────────

pub fn displayPlan(plan: plan_mod.BuildPlan, repo_deps_full: []const []const u8, pm: ?*pacman_mod.Pacman, removals: []const []const u8, err_writer: types.ErrWriter, c: color.Style, ec: color.Style, hint: *const std.StringHashMapUnmanaged([]const u8)) void {
    const stdout = getStdout();
    const verbose = if (pm) |p| p.verbose_pkg_lists else false;

    // Warn about AUR packages: out-of-date flag + reinstall detection (single pass)
    for (plan.build_order) |entry| {
        if (entry.out_of_date) |ts| {
            const es = std.time.epoch.EpochSeconds{ .secs = @intCast(ts) };
            const ed = es.getEpochDay();
            const yd = ed.calculateYearDay();
            const md = yd.calculateMonthDay();
            const ds = es.getDaySeconds();
            err_writer.print(
                "{s}warning:{s} {s} has been flagged {s}out of date{s} on {s}{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z{s}\n",
                .{
                    ec.yellow,
                    ec.reset,
                    entry.name,
                    ec.red,
                    ec.reset,
                    ec.yellow,
                    yd.year,
                    md.month.numeric(),
                    md.day_index + 1,
                    ds.getHoursIntoDay(),
                    ds.getMinutesIntoHour(),
                    ds.getSecondsIntoMinute(),
                    ec.reset,
                },
            ) catch {};
        }
        if (pm) |p| {
            for (entry.target_names) |tname| {
                if (devel.isVcsPackage(tname)) continue;
                if (p.installedVersion(tname)) |old| {
                    if (std.mem.eql(u8, old, entry.version)) {
                        err_writer.print("{s}warning:{s} {s}-{s} is up to date -- reinstalling\n", .{ ec.yellow, ec.reset, tname, old }) catch {};
                    }
                }
            }
        }
    }
    if (pm) |p| {
        for (plan.repo_targets) |name| {
            if (p.installedVersion(name)) |old| {
                const new = p.syncVersion(name) orelse continue;
                if (std.mem.eql(u8, old, new)) {
                    err_writer.print("{s}warning:{s} {s}-{s} is up to date -- reinstalling\n", .{ ec.yellow, ec.reset, name, old }) catch {};
                }
            }
        }
    }

    // Warn about detected conflicts (informational for resolve/buildorder commands;
    // sync/build handle these interactively before reaching displayPlan)
    for (plan.conflicts) |conflict| {
        switch (conflict.kind) {
            .aur_aur => err_writer.print(
                "{s}warning:{s} {s} and {s} are in conflict\n",
                .{ ec.yellow, ec.reset, conflict.package, conflict.conflicts_with },
            ) catch {},
            .aur_installed => err_writer.print(
                "{s}warning:{s} {s} conflicts with installed package {s}\n",
                .{ ec.yellow, ec.reset, conflict.package, conflict.conflicts_with },
            ) catch {},
            .repo_installed => err_writer.print(
                "{s}warning:{s} new dependency {s} conflicts with installed package {s}\n",
                .{ ec.yellow, ec.reset, conflict.package, conflict.conflicts_with },
            ) catch {},
            .aur_replaces => err_writer.print(
                "{s}warning:{s} aur/{s} replaces installed package {s}\n",
                .{ ec.yellow, ec.reset, conflict.package, conflict.conflicts_with },
            ) catch {},
            .repo_replaces => err_writer.print(
                "{s}warning:{s} {s} replaces installed package {s}\n",
                .{ ec.yellow, ec.reset, conflict.package, conflict.conflicts_with },
            ) catch {},
        }
    }

    // Display provider selections (informational)
    for (plan.provider_selections) |sel| {
        err_writer.print("{s}::{s} {s} provider: {s}\n", .{ ec.blue, ec.reset, sel.dep_name, sel.chosen }) catch {};
    }

    stdout.writeAll("resolving dependencies...\n") catch {};

    if (verbose) {
        displayPlanVerbose(plan, repo_deps_full, pm, removals, stdout, c, hint);
    } else {
        displayPlanCompact(plan, repo_deps_full, pm, stdout, c, hint);
    }

    if (pm) |p| {
        if (repo_deps_full.len > 0 or plan.repo_targets.len > 0) {
            var sizes = p.repoDepSizes(repo_deps_full);
            const target_sizes = p.repoDepSizes(plan.repo_targets);
            sizes.download += target_sizes.download;
            sizes.install += target_sizes.install;
            sizes.net_upgrade += target_sizes.net_upgrade;
            if (target_sizes.has_upgrades) sizes.has_upgrades = true;

            stdout.writeByte('\n') catch {};
            if (sizes.download > 0) {
                printSize(stdout, "Total Download Size:  ", sizes.download);
            }
            printSize(stdout, "Total Installed Size: ", sizes.install);
            if (sizes.has_upgrades) {
                printSize(stdout, "Net Upgrade Size:     ", sizes.net_upgrade);
            }
        }
    }

    stdout.writeByte('\n') catch {};
}

/// Display an install-only package list (all packages from sync dbs),
/// respecting VerbosePkgLists from pacman.conf.
pub fn displayInstallList(names: []const []const u8, pm: ?*pacman_mod.Pacman, err_writer: types.ErrWriter, c: color.Style, ec: color.Style) void {
    if (names.len == 0) return;
    const stdout = getStdout();
    const verbose = if (pm) |p| p.verbose_pkg_lists else false;

    // Warn about reinstalls (matches displayPlan behaviour)
    if (pm) |p| {
        for (names) |name| {
            if (p.installedVersion(name)) |old| {
                const new = p.syncVersion(name) orelse continue;
                if (std.mem.eql(u8, old, new)) {
                    err_writer.print("{s}warning:{s} {s}-{s} is up to date -- reinstalling\n", .{ ec.yellow, ec.reset, name, old }) catch {};
                }
            }
        }
    }

    if (verbose) {
        var widths = ColWidths.initFromHeaders(names.len, pm != null);
        for (names) |name| widths.widenRepoPkg(pm, name);
        emitTableHeader(stdout, widths, names.len);
        for (names) |name| emitRepoPkgRow(stdout, pm, name, widths, c);
    } else {
        stdout.print("\nPackages ({d})", .{names.len}) catch {};
        for (names) |name| {
            printCompactRepoPkg(pm, name, stdout, c);
        }
        stdout.writeByte('\n') catch {};
    }

    stdout.writeByte('\n') catch {};
}

// ── Private Helpers ───────────────────────────────────────────────────

fn displayPlanCompact(
    plan: plan_mod.BuildPlan,
    repo_deps_full: []const []const u8,
    pm: ?*pacman_mod.Pacman,
    stdout: anytype,
    c: color.Style,
    hint: *const std.StringHashMapUnmanaged([]const u8),
) void {
    var aur_count: usize = 0;
    for (plan.build_order) |entry| {
        aur_count += if (entry.target_names.len > 0) entry.target_names.len else 1;
    }
    const total = aur_count + repo_deps_full.len + plan.repo_targets.len;
    if (total == 0) return;

    stdout.print("\nPackages ({d})", .{total}) catch {};
    for (plan.build_order) |entry| {
        const display_names: []const []const u8 = if (entry.target_names.len > 0) entry.target_names else &.{entry.name};
        for (display_names) |tname| {
            stdout.print(" {s}aur/{s}{s}-{s}", .{ c.magenta, c.reset, tname, displayVersion(entry, hint) }) catch {};
        }
    }
    for (plan.repo_targets) |name| {
        printCompactRepoPkg(pm, name, stdout, c);
    }
    for (repo_deps_full) |dep| {
        printCompactRepoPkg(pm, dep, stdout, c);
    }
    stdout.writeByte('\n') catch {};
}

fn printCompactRepoPkg(pm: ?*pacman_mod.Pacman, name: []const u8, stdout: anytype, c: color.Style) void {
    const repo = if (pm) |p| p.syncDbFor(name) else null;
    const ver = if (pm) |p| p.syncVersion(name) orelse "?" else "?";
    if (repo) |r| {
        stdout.print(" {s}{s}/{s}{s}-{s}", .{ c.magenta, r, c.reset, name, ver }) catch {};
    } else {
        stdout.print(" {s}-{s}", .{ name, ver }) catch {};
    }
}

fn emitTableHeader(writer: anytype, widths: ColWidths, total: usize) void {
    writer.writeByte('\n') catch {};
    writer.print(hdr_pkg[0 .. hdr_pkg.len - 1] ++ "{d})", .{total}) catch {};
    pad(writer, countDigits(total) + hdr_pkg.len, widths.name);
    if (widths.has_old) {
        writer.writeAll(hdr_old_ver) catch {};
        pad(writer, hdr_old_ver.len, widths.old);
    }
    writer.writeAll(hdr_new_ver) catch {};
    if (widths.show_sizes) {
        pad(writer, hdr_new_ver.len, widths.ver);
        rightAlign(writer, hdr_net_change, widths.nc);
        rightAlign(writer, hdr_dl_size, widths.dl);
    }
    writer.writeAll("\n\n") catch {};
}

fn emitRepoPkgRow(writer: anytype, pm: ?*pacman_mod.Pacman, name: []const u8, widths: ColWidths, c: color.Style) void {
    const repo = if (pm) |p| p.syncDbFor(name) else null;
    const ver = if (pm) |p| p.syncVersion(name) orelse "?" else "?";
    const w = if (repo) |r| blk: {
        writer.print("{s}{s}/{s}{s}", .{ c.magenta, r, c.reset, name }) catch {};
        break :blk r.len + 1 + name.len;
    } else blk: {
        writer.writeAll(name) catch {};
        break :blk name.len;
    };
    pad(writer, w, widths.name);
    if (widths.has_old) {
        const old_ver = if (pm) |p| p.installedVersion(name) orelse "-" else "-";
        if (!std.mem.eql(u8, old_ver, "-")) {
            writer.print("{s}{s}{s}", .{ c.red, old_ver, c.reset }) catch {};
        } else {
            writer.writeAll(old_ver) catch {};
        }
        pad(writer, old_ver.len, widths.old);
    }
    writer.print("{s}{s}{s}", .{ c.green, ver, c.reset }) catch {};
    if (widths.show_sizes) {
        pad(writer, ver.len, widths.ver);
        if (pm.?.repoPkgSizeInfo(name)) |si| {
            var b1: [32]u8 = undefined;
            rightAlign(writer, fmtSize(si.net_change, &b1), widths.nc);
            var b2: [32]u8 = undefined;
            rightAlign(writer, fmtSize(si.download, &b2), widths.dl);
        }
    }
    writer.writeByte('\n') catch {};
}

fn displayPlanVerbose(
    plan: plan_mod.BuildPlan,
    repo_deps_full: []const []const u8,
    pm: ?*pacman_mod.Pacman,
    removals: []const []const u8,
    stdout: anytype,
    c: color.Style,
    hint: *const std.StringHashMapUnmanaged([]const u8),
) void {
    var aur_count: usize = 0;
    for (plan.build_order) |entry| {
        aur_count += if (entry.target_names.len > 0) entry.target_names.len else 1;
    }
    const total = aur_count + removals.len + repo_deps_full.len + plan.repo_targets.len;
    if (total == 0) return;

    const has_repo_pkgs = repo_deps_full.len > 0 or plan.repo_targets.len > 0;
    const show_sizes = pm != null and has_repo_pkgs;

    var widths = ColWidths.initFromHeaders(total, show_sizes);

    const aur_prefix = "aur/";
    for (plan.build_order) |entry| {
        const display_names: []const []const u8 = if (entry.target_names.len > 0) entry.target_names else &.{entry.name};
        for (display_names) |tname| {
            if (aur_prefix.len + tname.len > widths.name) widths.name = aur_prefix.len + tname.len;
            const ver = displayVersion(entry, hint);
            if (ver.len > widths.ver) widths.ver = ver.len;
            if (pm) |p| {
                if (p.installedVersion(tname)) |v| {
                    widths.has_old = true;
                    if (v.len > widths.old) widths.old = v.len;
                }
            }
        }
    }
    for (removals) |name| {
        if (name.len > widths.name) widths.name = name.len;
        if (pm) |p| {
            if (p.installedVersion(name)) |v| {
                if (v.len > widths.old) widths.old = v.len;
            }
        }
    }
    if (removals.len > 0) widths.has_old = true;

    const repo_lists = [_][]const []const u8{ plan.repo_targets, repo_deps_full };
    for (repo_lists) |list| {
        for (list) |name| widths.widenRepoPkg(pm, name);
    }

    emitTableHeader(stdout, widths, total);

    for (removals) |name| {
        stdout.writeAll(name) catch {};
        pad(stdout, name.len, widths.name);
        if (widths.has_old) {
            const old_ver = if (pm) |p| p.installedVersion(name) orelse "?" else "?";
            stdout.print("{s}{s}{s}", .{ c.red, old_ver, c.reset }) catch {};
            pad(stdout, old_ver.len, widths.old);
        }
        stdout.writeByte('\n') catch {};
    }

    for (plan.build_order) |entry| {
        const display_names: []const []const u8 = if (entry.target_names.len > 0) entry.target_names else &.{entry.name};
        for (display_names) |tname| {
            stdout.print("{s}{s}{s}{s}", .{ c.magenta, aur_prefix, c.reset, tname }) catch {};
            pad(stdout, aur_prefix.len + tname.len, widths.name);
            if (widths.has_old) {
                const old_ver = if (pm) |p| p.installedVersion(tname) orelse "" else "";
                if (old_ver.len > 0) {
                    stdout.print("{s}{s}{s}", .{ c.red, old_ver, c.reset }) catch {};
                    pad(stdout, old_ver.len, widths.old);
                } else {
                    pad(stdout, 0, widths.old);
                }
            }
            stdout.print("{s}{s}{s}\n", .{ c.green, displayVersion(entry, hint), c.reset }) catch {};
        }
    }

    for (repo_lists) |list| {
        for (list) |name| emitRepoPkgRow(stdout, pm, name, widths, c);
    }
}

fn displayVersion(entry: plan_mod.BuildEntry, hint: *const std.StringHashMapUnmanaged([]const u8)) []const u8 {
    if (hint.get(entry.name)) |v| return v;
    return if (devel.isVcsPackage(entry.name)) "latest" else entry.version;
}

fn pad(writer: anytype, current: usize, col: usize) void {
    const spaces = (col + 2) -| current;
    writer.writeByteNTimes(' ', if (spaces < 2) 2 else spaces) catch {};
}

fn fmtSize(bytes: i64, buf: *[32]u8) []const u8 {
    const abs = if (bytes < 0) -bytes else bytes;
    const sign: []const u8 = if (bytes < 0) "-" else "";
    return if (abs >= 1024 * 1024)
        std.fmt.bufPrint(buf, "{s}{d:.2} MiB", .{ sign, @as(f64, @floatFromInt(abs)) / (1024.0 * 1024.0) }) catch ""
    else if (abs >= 1024)
        std.fmt.bufPrint(buf, "{s}{d:.2} KiB", .{ sign, @as(f64, @floatFromInt(abs)) / 1024.0 }) catch ""
    else
        std.fmt.bufPrint(buf, "{s}{d} B", .{ sign, abs }) catch "";
}

fn rightAlign(writer: anytype, str: []const u8, col: usize) void {
    const spaces = (col + 2) -| str.len;
    writer.writeByteNTimes(' ', if (spaces < 2) 2 else spaces) catch {};
    writer.writeAll(str) catch {};
}

fn countDigits(n: usize) usize {
    var digits: usize = 1;
    var v = n;
    while (v >= 10) {
        v /= 10;
        digits += 1;
    }
    return digits;
}

fn printSize(writer: anytype, label: []const u8, bytes: i64) void {
    const abs = if (bytes < 0) -bytes else bytes;
    const sign: []const u8 = if (bytes < 0) "-" else "";
    if (abs >= 1024 * 1024) {
        writer.print("{s}{s}{d:.2} MiB\n", .{ label, sign, @as(f64, @floatFromInt(abs)) / (1024.0 * 1024.0) }) catch {};
    } else if (abs >= 1024) {
        writer.print("{s}{s}{d:.2} KiB\n", .{ label, sign, @as(f64, @floatFromInt(abs)) / 1024.0 }) catch {};
    } else {
        writer.print("{s}{s}{d} B\n", .{ label, sign, abs }) catch {};
    }
}
