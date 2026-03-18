const std = @import("std");

/// Raw C bindings for libalpm. Never exposed outside this module.
const c = @cImport({
    @cInclude("alpm.h");
    @cInclude("alpm_list.h");
});

// ── Public Types ─────────────────────────────────────────────────────────

/// Signature verification level for database registration.
pub const SigLevel = enum(c_int) {
    use_default = 1 << 30,
    package = 1 << 0,
    package_optional = (1 << 0) | (1 << 1),
    database = 1 << 10,
    database_optional = (1 << 10) | (1 << 11),
};

/// Dependency version constraint operator.
pub const DepMod = enum(c_uint) {
    any = 1,
    eq = 2,
    ge = 3,
    le = 4,
    gt = 5,
    lt = 6,
};

/// A resolved dependency with Zig-native types.
/// All string fields are borrowed from libalpm — valid until the
/// owning database cache is invalidated.
pub const Dependency = struct {
    name: []const u8,
    version: []const u8,
    desc: ?[]const u8,
    name_hash: c_ulong,
    mod: DepMod,
};

/// Errors that can come from libalpm operations.
pub const AlpmError = error{
    HandleInitFailed,
    DatabaseRegistrationFailed,
    DatabaseUpdateFailed,
    InvalidArgument,
};

// ── Generic List Iterator ────────────────────────────────────────────────

/// Type-safe iterator over alpm_list_t, yielding typed Zig values.
/// Hides linked-list traversal and void* casting.
pub fn AlpmListIterator(comptime T: type, comptime extractFn: fn (?*c.alpm_list_t) T) type {
    return struct {
        current: ?*c.alpm_list_t,

        pub fn next(self: *@This()) ?T {
            const node = self.current orelse return null;
            self.current = node.next;
            return extractFn(node);
        }
    };
}

fn extractPackage(node: ?*c.alpm_list_t) AlpmPackage {
    const n = node.?;
    const raw: *c.alpm_pkg_t = @ptrCast(@alignCast(n.data));
    return .{ .raw = raw };
}

fn extractDependency(node: ?*c.alpm_list_t) Dependency {
    const n = node.?;
    const raw: *c.alpm_depend_t = @ptrCast(@alignCast(n.data));
    return .{
        .name = sliceFromCStr(raw.name),
        .version = if (raw.version) |v| sliceFromCStr(v) else "",
        .desc = if (raw.desc) |d| sliceFromCStr(d) else null,
        .name_hash = raw.name_hash,
        .mod = @enumFromInt(raw.mod),
    };
}

pub const PackageIterator = AlpmListIterator(AlpmPackage, extractPackage);
pub const DepIterator = AlpmListIterator(Dependency, extractDependency);

// ── Handle ───────────────────────────────────────────────────────────────

/// Opaque wrapper around alpm_handle_t*.
/// Callers never see the C pointer.
pub const Handle = struct {
    raw: *c.alpm_handle_t,

    /// Initialize libalpm with root filesystem path and database path.
    /// Standard Arch Linux values: root="/", dbpath="/var/lib/pacman/".
    pub fn init(root: []const u8, dbpath: []const u8) AlpmError!Handle {
        var err: c.alpm_errno_t = 0;

        const c_root = toCString(root);
        const c_dbpath = toCString(dbpath);

        const handle = c.alpm_initialize(c_root.ptr(), c_dbpath.ptr(), &err);
        if (handle == null) return error.HandleInitFailed;

        return .{ .raw = handle.? };
    }

    pub fn deinit(self: Handle) void {
        _ = c.alpm_release(self.raw);
    }

    /// Get the local (installed) package database.
    pub fn getLocalDb(self: Handle) Database {
        return .{ .raw = c.alpm_get_localdb(self.raw).? };
    }

    /// Register a sync database by name (e.g., "core", "extra", "aurpkgs").
    pub fn registerSyncDb(self: Handle, name: []const u8, siglevel: SigLevel) AlpmError!Database {
        const c_name = toCString(name);
        const db = c.alpm_register_syncdb(self.raw, c_name.ptr(), @intFromEnum(siglevel));
        if (db == null) return error.DatabaseRegistrationFailed;
        return .{ .raw = db.? };
    }

    /// Refresh (update) a list of databases.
    /// For selective refresh of a single db, pass a one-element slice.
    pub fn dbUpdate(self: Handle, dbs: []const Database, force: bool) AlpmError!void {
        // Build an alpm_list_t from the slice
        var list: ?*c.alpm_list_t = null;
        for (dbs) |db| {
            list = c.alpm_list_add(list, db.raw);
        }
        defer c.alpm_list_free(list);

        const ret = c.alpm_db_update(self.raw, list, if (force) 1 else 0);
        if (ret < 0) return error.DatabaseUpdateFailed;
    }
};

// ── Database ─────────────────────────────────────────────────────────────

/// Opaque wrapper around alpm_db_t*.
pub const Database = struct {
    raw: *c.alpm_db_t,

    /// Get the database name (e.g., "core", "extra", "local").
    pub fn getName(self: Database) []const u8 {
        return sliceFromCStr(c.alpm_db_get_name(self.raw).?);
    }

    /// Look up a package by exact name. Returns null if not found.
    pub fn getPackage(self: Database, name: []const u8) ?AlpmPackage {
        const c_name = toCString(name);
        const pkg = c.alpm_db_get_pkg(self.raw, c_name.ptr());
        if (pkg == null) return null;
        return .{ .raw = pkg.? };
    }

    /// Iterate over all packages in this database.
    pub fn getPkgcache(self: Database) PackageIterator {
        return .{ .current = c.alpm_db_get_pkgcache(self.raw) };
    }

    /// Add a mirror server URL to this database.
    /// Required before dbUpdate() can download database files.
    pub fn addServer(self: Database, url: []const u8) AlpmError!void {
        const c_url = toCString(url);
        const ret = c.alpm_db_add_server(self.raw, c_url.ptr());
        if (ret != 0) return error.InvalidArgument;
    }
};

// ── Package ──────────────────────────────────────────────────────────────

/// Opaque wrapper around alpm_pkg_t*.
/// All returned strings are borrowed from libalpm's internal memory —
/// valid until the owning database cache is invalidated.
pub const AlpmPackage = struct {
    raw: *c.alpm_pkg_t,

    pub fn getName(self: AlpmPackage) []const u8 {
        return sliceFromCStr(c.alpm_pkg_get_name(self.raw).?);
    }

    pub fn getVersion(self: AlpmPackage) []const u8 {
        return sliceFromCStr(c.alpm_pkg_get_version(self.raw).?);
    }

    pub fn getBase(self: AlpmPackage) ?[]const u8 {
        const raw = c.alpm_pkg_get_base(self.raw) orelse return null;
        return sliceFromCStr(raw);
    }

    pub fn getDesc(self: AlpmPackage) ?[]const u8 {
        const raw = c.alpm_pkg_get_desc(self.raw) orelse return null;
        return sliceFromCStr(raw);
    }

    pub fn getDepends(self: AlpmPackage) DepIterator {
        return .{ .current = c.alpm_pkg_get_depends(self.raw) };
    }

    pub fn getMakedepends(self: AlpmPackage) DepIterator {
        return .{ .current = c.alpm_pkg_get_makedepends(self.raw) };
    }

    pub fn getCheckdepends(self: AlpmPackage) DepIterator {
        return .{ .current = c.alpm_pkg_get_checkdepends(self.raw) };
    }

    pub fn getOptdepends(self: AlpmPackage) DepIterator {
        return .{ .current = c.alpm_pkg_get_optdepends(self.raw) };
    }

    pub fn getProvides(self: AlpmPackage) DepIterator {
        return .{ .current = c.alpm_pkg_get_provides(self.raw) };
    }

    pub fn getConflicts(self: AlpmPackage) DepIterator {
        return .{ .current = c.alpm_pkg_get_conflicts(self.raw) };
    }

    pub fn getReplaces(self: AlpmPackage) DepIterator {
        return .{ .current = c.alpm_pkg_get_replaces(self.raw) };
    }

    /// Download size in bytes (sync db packages only; 0 for local).
    pub fn getSize(self: AlpmPackage) i64 {
        return c.alpm_pkg_get_size(self.raw);
    }

    /// Installed size in bytes.
    pub fn getIsize(self: AlpmPackage) i64 {
        return c.alpm_pkg_get_isize(self.raw);
    }
};

// ── Free Functions ───────────────────────────────────────────────────────

/// Compare two version strings using libalpm's semantics.
/// Returns: negative if a < b, 0 if equal, positive if a > b.
/// Handles epochs, pkgrel, and alpha/beta suffixes correctly.
/// Pure function — no handle needed.
pub fn vercmp(a: []const u8, b: []const u8) i32 {
    const c_a = toCString(a);
    const c_b = toCString(b);
    return c.alpm_pkg_vercmp(c_a.ptr(), c_b.ptr());
}

/// Find a package that satisfies a dependency string in a package list.
/// Uses libalpm's native satisfier which checks both name and provides.
/// Returns null if no satisfier found.
pub fn findSatisfier(pkgcache: PackageIterator, depstring: []const u8) ?AlpmPackage {
    const c_dep = toCString(depstring);
    const pkg = c.alpm_find_satisfier(pkgcache.current, c_dep.ptr());
    if (pkg == null) return null;
    return .{ .raw = pkg.? };
}

// ── Internal Helpers ─────────────────────────────────────────────────────

/// Null-terminated buffer for C string conversion.
/// Package names and paths in the alpm API are always short (< 256 bytes).
const CStringBuf = struct {
    buf: [256]u8 = .{0} ** 256,

    fn init(s: []const u8) CStringBuf {
        var result = CStringBuf{};
        if (s.len >= result.buf.len) {
            @panic("string exceeds alpm toCString buffer (256 bytes)");
        }
        @memcpy(result.buf[0..s.len], s);
        // buf is zero-initialized, so buf[s.len] is already 0
        return result;
    }

    fn ptr(self: *const CStringBuf) [*:0]const u8 {
        // Find the sentinel position (first zero byte)
        var len: usize = 0;
        while (len < self.buf.len and self.buf[len] != 0) : (len += 1) {}
        return @ptrCast(self.buf[0..len :0]);
    }
};

fn toCString(s: []const u8) CStringBuf {
    return CStringBuf.init(s);
}

/// Convert a C null-terminated string to a Zig slice.
fn sliceFromCStr(ptr: [*:0]const u8) []const u8 {
    return std.mem.span(ptr);
}

// ── Tests ────────────────────────────────────────────────────────────────
// These are integration tests — they require libalpm.so and a real
// pacman database on an Arch Linux system.

fn isArchLinux() bool {
    std.fs.accessAbsolute("/var/lib/pacman/local", .{}) catch return false;
    return true;
}

test "Handle.init succeeds with standard Arch paths" {
    if (!isArchLinux()) return error.SkipZigTest;

    const handle = try Handle.init("/", "/var/lib/pacman/");
    defer handle.deinit();
}

test "Handle.init fails with invalid dbpath" {
    const result = Handle.init("/", "/nonexistent/path/db/");
    try std.testing.expectError(error.HandleInitFailed, result);
}

test "getLocalDb returns valid database" {
    if (!isArchLinux()) return error.SkipZigTest;

    const handle = try Handle.init("/", "/var/lib/pacman/");
    defer handle.deinit();

    const local_db = handle.getLocalDb();
    const name = local_db.getName();
    try std.testing.expectEqualStrings("local", name);
}

test "Database.getPackage finds installed pacman" {
    if (!isArchLinux()) return error.SkipZigTest;

    const handle = try Handle.init("/", "/var/lib/pacman/");
    defer handle.deinit();

    const local_db = handle.getLocalDb();
    const pkg = local_db.getPackage("pacman") orelse return error.SkipZigTest;

    try std.testing.expectEqualStrings("pacman", pkg.getName());
    try std.testing.expect(pkg.getVersion().len > 0);
}

test "Database.getPackage returns null for nonexistent package" {
    if (!isArchLinux()) return error.SkipZigTest;

    const handle = try Handle.init("/", "/var/lib/pacman/");
    defer handle.deinit();

    const local_db = handle.getLocalDb();
    try std.testing.expect(local_db.getPackage("definitely-not-installed-zzz") == null);
}

test "AlpmPackage accessors return Zig slices" {
    if (!isArchLinux()) return error.SkipZigTest;

    const handle = try Handle.init("/", "/var/lib/pacman/");
    defer handle.deinit();

    const local_db = handle.getLocalDb();
    const pkg = local_db.getPackage("pacman") orelse return error.SkipZigTest;

    // getName returns []const u8
    const name = pkg.getName();
    try std.testing.expect(name.len > 0);

    // getVersion returns []const u8
    const version = pkg.getVersion();
    try std.testing.expect(version.len > 0);

    // getDesc returns ?[]const u8
    const desc = pkg.getDesc();
    try std.testing.expect(desc != null);

    // getIsize returns positive installed size for local packages
    try std.testing.expect(pkg.getIsize() > 0);
}

test "AlpmPackage size accessors return valid values for sync packages" {
    if (!isArchLinux()) return error.SkipZigTest;

    const handle = try Handle.init("/", "/var/lib/pacman/");
    defer handle.deinit();

    const db = handle.registerSyncDb("core", .use_default) catch return error.SkipZigTest;
    const pkg = db.getPackage("glibc") orelse return error.SkipZigTest;

    // Sync packages have both download size and installed size
    try std.testing.expect(pkg.getSize() > 0);
    try std.testing.expect(pkg.getIsize() > 0);
    // Installed size is always >= download size (compressed)
    try std.testing.expect(pkg.getIsize() >= pkg.getSize());
}

test "AlpmPackage.getDepends returns iterable dependencies" {
    if (!isArchLinux()) return error.SkipZigTest;

    const handle = try Handle.init("/", "/var/lib/pacman/");
    defer handle.deinit();

    const local_db = handle.getLocalDb();
    const pkg = local_db.getPackage("pacman") orelse return error.SkipZigTest;

    var it = pkg.getDepends();
    var count: usize = 0;
    while (it.next()) |dep| {
        try std.testing.expect(dep.name.len > 0);
        count += 1;
    }
    // pacman has dependencies
    try std.testing.expect(count > 0);
}

test "PackageIterator iterates local database" {
    if (!isArchLinux()) return error.SkipZigTest;

    const handle = try Handle.init("/", "/var/lib/pacman/");
    defer handle.deinit();

    const local_db = handle.getLocalDb();
    var it = local_db.getPkgcache();

    var count: usize = 0;
    while (it.next()) |pkg| {
        try std.testing.expect(pkg.getName().len > 0);
        count += 1;
        if (count >= 5) break; // Don't iterate everything
    }
    // A real system has packages installed
    try std.testing.expect(count >= 5);
}

test "registerSyncDb succeeds for core" {
    if (!isArchLinux()) return error.SkipZigTest;

    const handle = try Handle.init("/", "/var/lib/pacman/");
    defer handle.deinit();

    const db = try handle.registerSyncDb("core", .use_default);
    try std.testing.expectEqualStrings("core", db.getName());
}

test "registerSyncDb fails for duplicate name" {
    if (!isArchLinux()) return error.SkipZigTest;

    const handle = try Handle.init("/", "/var/lib/pacman/");
    defer handle.deinit();

    _ = try handle.registerSyncDb("core", .use_default);
    const result = handle.registerSyncDb("core", .use_default);
    try std.testing.expectError(error.DatabaseRegistrationFailed, result);
}

// ── Version Comparison Tests ─────────────────────────────────────────────
// vercmp is a pure function — no system dependencies needed.

test "vercmp: equal versions return 0" {
    try std.testing.expectEqual(@as(i32, 0), vercmp("1.0.0", "1.0.0"));
    try std.testing.expectEqual(@as(i32, 0), vercmp("1.0.0-1", "1.0.0-1"));
}

test "vercmp: newer version returns positive" {
    try std.testing.expect(vercmp("2.0.0", "1.0.0") > 0);
    try std.testing.expect(vercmp("1.1.0", "1.0.0") > 0);
    try std.testing.expect(vercmp("1.0.1", "1.0.0") > 0);
}

test "vercmp: older version returns negative" {
    try std.testing.expect(vercmp("1.0.0", "2.0.0") < 0);
    try std.testing.expect(vercmp("1.0.0", "1.1.0") < 0);
}

test "vercmp: epoch takes precedence" {
    try std.testing.expect(vercmp("1:1.0", "2.0") > 0);
    try std.testing.expect(vercmp("2:1.0", "1:99.99") > 0);
}

test "vercmp: pkgrel is secondary to version" {
    try std.testing.expect(vercmp("1.0-2", "1.0-1") > 0);
    try std.testing.expect(vercmp("1.0-999", "2.0-1") < 0);
}

test "vercmp: antisymmetry property" {
    const pairs = [_][2][]const u8{
        .{ "1.0", "2.0" },
        .{ "1.0-1", "1.0-2" },
        .{ "1:1.0", "2:1.0" },
        .{ "0.9.9", "1.0" },
    };

    for (pairs) |p| {
        const ab = vercmp(p[0], p[1]);
        const ba = vercmp(p[1], p[0]);
        if (ab > 0) try std.testing.expect(ba < 0) else if (ab < 0) try std.testing.expect(ba > 0) else try std.testing.expectEqual(@as(i32, 0), ba);
    }
}

test "vercmp: reflexivity property" {
    const versions = [_][]const u8{
        "1.0", "2.3.4-5", "1:3.0-1", "0.0.1",
    };
    for (versions) |v| {
        try std.testing.expectEqual(@as(i32, 0), vercmp(v, v));
    }
}

test "vercmp: transitivity property" {
    const triples = [_][3][]const u8{
        .{ "1.0", "2.0", "3.0" },
        .{ "1.0-1", "1.0-2", "1.0-3" },
        .{ "1:1.0", "1:2.0", "2:0.1" },
        .{ "0.9", "1.0", "1.0.1" },
    };

    for (triples) |t| {
        const ab = vercmp(t[0], t[1]);
        const bc = vercmp(t[1], t[2]);
        const ac = vercmp(t[0], t[2]);
        try std.testing.expect(ab < 0);
        try std.testing.expect(bc < 0);
        try std.testing.expect(ac < 0);
    }
}

test "toCString roundtrip preserves content" {
    const input = "test-package";
    const cstr = toCString(input);
    const back = sliceFromCStr(cstr.ptr());
    try std.testing.expectEqualStrings(input, back);
}

test "toCString handles empty string" {
    const cstr = toCString("");
    const back = sliceFromCStr(cstr.ptr());
    try std.testing.expectEqualStrings("", back);
}

test "findSatisfier finds package by name in local db" {
    if (!isArchLinux()) return error.SkipZigTest;

    const handle = try Handle.init("/", "/var/lib/pacman/");
    defer handle.deinit();

    const local_db = handle.getLocalDb();
    const pkgcache = local_db.getPkgcache();

    const result = findSatisfier(pkgcache, "pacman");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("pacman", result.?.getName());
}

test "findSatisfier returns null for nonexistent dep" {
    if (!isArchLinux()) return error.SkipZigTest;

    const handle = try Handle.init("/", "/var/lib/pacman/");
    defer handle.deinit();

    const local_db = handle.getLocalDb();
    const pkgcache = local_db.getPkgcache();

    try std.testing.expect(findSatisfier(pkgcache, "definitely-not-a-real-pkg-zzz") == null);
}
