## Class-Level Design: `alpm.zig` + `pacman.zig`

These two modules form a **layered pair** that hides the entire libalpm C boundary. `alpm.zig` is a thin mechanical translation layer (C types → Zig types), while `pacman.zig` is a domain-rich layer that answers questions the rest of the codebase actually asks. This section covers both because they are designed together — the interface of `alpm.zig` is shaped by what `pacman.zig` needs, not by wrapping every libalpm function.

### Why Two Modules, Not One

A single "alpm wrapper" module would mix two distinct concerns:

1. **C interop mechanics**: null-terminated strings, `alpm_list_t` linked list traversal, `[*c]` pointer types, C error code mapping
2. **Domain semantics**: "is this dependency satisfied?", "which repo provides this?", "refresh only the aurpkgs database"

Mixing them creates a module that's hard to test (need real libalpm for domain logic tests) and hard to change (C API changes ripple into domain logic). The two-layer split means:
- `alpm.zig` tests verify C interop works correctly (integration tests with real libalpm)
- `pacman.zig` tests verify domain logic works correctly (unit tests with mock `alpm.Handle`)

### Class Diagram

```mermaid
classDiagram
    class Pacman {
        -allocator: Allocator
        -handle: alpm.Handle
        -local_db: alpm.Database
        -sync_dbs: []alpm.Database
        -aurpkgs_db: ?alpm.Database
        +init(allocator: Allocator) !Pacman
        +deinit() void
        +isInstalled(name: []const u8) bool
        +installedVersion(name: []const u8) ?[]const u8
        +isInSyncDb(name: []const u8) bool
        +syncDbFor(name: []const u8) ?[]const u8
        +satisfies(name: []const u8, constraint: VersionConstraint) bool
        +satisfiesDep(depstring: []const u8) bool
        +findProvider(dep: []const u8) ?ProviderMatch
        +findDbsSatisfier(dbs: DbSet, depstring: []const u8) ?[]const u8
        +refreshAurDb() !void
        +allForeignPackages() ![]InstalledPackage
    }

    class VersionConstraint {
        +op: CmpOp
        +version: []const u8
    }

    class CmpOp {
        <<enumeration>>
        eq
        ge
        le
        gt
        lt
    }

    class ProviderMatch {
        +provider_name: []const u8
        +provider_version: []const u8
        +db_name: []const u8
    }

    class InstalledPackage {
        +name: []const u8
        +version: []const u8
    }

    class DbSet {
        <<enumeration>>
        all_sync
        official_only
        aurpkgs_only
    }

    class "alpm.Handle" as AlpmHandle {
        -raw: *c.alpm_handle_t
        +init(root: []const u8, dbpath: []const u8) !Handle
        +deinit() void
        +getLocalDb() Database
        +registerSyncDb(name: []const u8, siglevel: SigLevel) !Database
        +getSyncDbs() []Database
    }

    class "alpm.Database" as AlpmDatabase {
        -raw: *c.alpm_db_t
        +getName() []const u8
        +getPackage(name: []const u8) ?AlpmPackage
        +getPkgcache() PackageIterator
        +update(handle: Handle, force: bool) !void
    }

    class "alpm.AlpmPackage" as AlpmPkg {
        -raw: *c.alpm_pkg_t
        +getName() []const u8
        +getVersion() []const u8
        +getBase() ?[]const u8
        +getDesc() ?[]const u8
        +getDepends() DepIterator
        +getMakedepends() DepIterator
        +getCheckdepends() DepIterator
        +getOptdepends() DepIterator
        +getProvides() DepIterator
        +getConflicts() DepIterator
    }

    class "alpm.Dependency" as AlpmDep {
        +name: []const u8
        +version: []const u8
        +desc: ?[]const u8
        +mod: DepMod
    }

    class "alpm.DepMod" as DepMod {
        <<enumeration>>
        any
        eq
        ge
        le
        gt
        lt
    }

    Pacman --> AlpmHandle : owns
    Pacman --> AlpmDatabase : queries
    Pacman --> VersionConstraint : uses
    Pacman --> ProviderMatch : returns
    Pacman --> InstalledPackage : returns
    AlpmHandle --> AlpmDatabase : creates
    AlpmDatabase --> AlpmPkg : contains
    AlpmPkg --> AlpmDep : has lists of
    AlpmDep --> DepMod : uses

    Pacman ..> "alpm (module)" : depends on
```

### `alpm.zig` — The C FFI Boundary

This module's job is purely mechanical: make libalpm callable from Zig without any C types leaking out. Every public type and function uses Zig-native types.

#### C Import and Opaque Wrappers

```zig
const c = @cImport({
    @cInclude("alpm.h");
    @cInclude("alpm_list.h");
});

/// Opaque wrapper around alpm_handle_t*.
/// Callers never see the C pointer.
pub const Handle = struct {
    raw: *c.alpm_handle_t,

    pub fn init(root: []const u8, dbpath: []const u8) !Handle {
        var err: c.alpm_errno_t = 0;

        // libalpm requires null-terminated strings
        const c_root = try toCString(root);
        const c_dbpath = try toCString(dbpath);

        const handle = c.alpm_initialize(c_root, c_dbpath, &err);
        if (handle == null) return mapAlpmError(err);

        return .{ .raw = handle.? };
    }

    pub fn deinit(self: *Handle) void {
        _ = c.alpm_release(self.raw);
    }

    pub fn getLocalDb(self: Handle) Database {
        return .{ .raw = c.alpm_get_localdb(self.raw).? };
    }

    pub fn registerSyncDb(self: Handle, name: []const u8, siglevel: SigLevel) !Database {
        const c_name = try toCString(name);
        const db = c.alpm_register_syncdb(self.raw, c_name, @intFromEnum(siglevel));
        if (db == null) return error.DatabaseRegistrationFailed;
        return .{ .raw = db.? };
    }
};
```

#### The `alpm_list_t` Iterator

This is the most important hidden complexity. libalpm uses a custom doubly-linked list (`alpm_list_t`) for every collection. Each node's `data` field is a `void*` that must be cast to the correct type. This is error-prone in C and completely alien to Zig.

The wrapper provides a type-safe Zig iterator:

```zig
/// Generic iterator over alpm_list_t, yielding typed Zig values.
/// Hides linked list traversal and void* casting.
pub fn AlpmListIterator(comptime T: type, comptime extractFn: fn (*c.alpm_list_t) T) type {
    return struct {
        current: ?*c.alpm_list_t,

        pub fn next(self: *@This()) ?T {
            const node = self.current orelse return null;
            self.current = node.next;
            return extractFn(node);
        }
    };
}

// Specialized iterators for common types:

pub const PackageIterator = AlpmListIterator(AlpmPackage, extractPackage);
pub const DepIterator = AlpmListIterator(Dependency, extractDependency);

fn extractPackage(node: *c.alpm_list_t) AlpmPackage {
    const raw: *c.alpm_pkg_t = @ptrCast(@alignCast(node.data));
    return .{ .raw = raw };
}

fn extractDependency(node: *c.alpm_list_t) Dependency {
    const raw: *c.alpm_depend_t = @ptrCast(@alignCast(node.data));
    return .{
        .name = std.mem.span(raw.name),
        .version = if (raw.version) |v| std.mem.span(v) else "",
        .desc = if (raw.desc) |d| std.mem.span(d) else null,
        .mod = @enumFromInt(raw.mod),
    };
}
```

**Why comptime generics here:** libalpm uses `void*` for everything in `alpm_list_t`. In C, you'd cast at every call site. In Zig, the `AlpmListIterator` is parameterized at compile time with the extraction function, so the cast happens once in the extractor and all iteration is type-safe. The compiler generates specialized code for each iterator type — zero runtime cost.

#### Null-Terminated String Conversion

libalpm functions accept `const char*` (null-terminated) but Zig strings are `[]const u8` (length-prefixed). The conversion must allocate a temporary null-terminated copy:

```zig
/// Convert Zig slice to null-terminated C string.
/// Uses a small stack buffer for short strings, heap for long ones.
fn toCString(s: []const u8) ![*:0]const u8 {
    // For strings that are already null-terminated in memory
    // (common with string literals), we can avoid allocation.
    if (s.len > 0 and s.ptr[s.len] == 0) {
        return s.ptr[0..s.len :0];
    }

    // Stack buffer for typical package names (< 128 bytes)
    var buf: [128]u8 = undefined;
    if (s.len < buf.len) {
        @memcpy(buf[0..s.len], s);
        buf[s.len] = 0;
        return buf[0..s.len :0];
    }

    // This path is unusual — package names are short
    @panic("package name exceeds 128 bytes");
}
```

**Note:** In practice, package names and database paths are always short (<128 bytes). The stack buffer avoids heap allocation for every libalpm call. If we needed longer strings (e.g., file paths), we'd use allocator-backed conversion with proper `defer free`.

#### Version Comparison — The Stateless Function

```zig
/// Compare two version strings using libalpm's semantics.
/// Returns: negative if a < b, 0 if equal, positive if a > b.
/// Handles epochs, pkgrel, and alpha/beta suffixes correctly.
pub fn vercmp(a: []const u8, b: []const u8) i32 {
    const c_a = toCString(a) catch return 0;
    const c_b = toCString(b) catch return 0;
    return c.alpm_pkg_vercmp(c_a, c_b);
}
```

This is exposed directly because version comparison is a pure function with no state — no handle needed, no database context. It's the only libalpm function that makes sense as a free function rather than a method.

### `pacman.zig` — The Domain Layer

`pacman.zig` consumes `alpm.zig` and provides the answers that the registry and commands actually need. It hides:
- Which database to check (local vs sync vs aurpkgs)
- How to iterate and filter package lists
- How to map `alpm.DepMod` to version constraint satisfaction
- The pacman.conf parsing needed to register sync databases

#### Initialization — The Hidden Configuration Dance

Initialization is the most complex hidden operation. The caller says `Pacman.init(allocator)`. Internally:

```zig
pub fn init(allocator: Allocator) !Pacman {
    // Step 1: Initialize libalpm with standard Arch paths
    var handle = try alpm.Handle.init("/", "/var/lib/pacman/");

    // Step 2: Register sync databases from pacman.conf
    // Parse [repo] sections to discover database names and servers.
    // This is where /etc/pacman.conf integration happens.
    const sync_dbs = try registerSyncDbs(allocator, &handle);

    // Step 3: Identify the aurpkgs database specifically
    // (needed for selective refresh in refreshAurDb)
    var aurpkgs_db: ?alpm.Database = null;
    for (sync_dbs) |db| {
        if (std.mem.eql(u8, db.getName(), "aurpkgs")) {
            aurpkgs_db = db;
            break;
        }
    }

    return .{
        .allocator = allocator,
        .handle = handle,
        .local_db = handle.getLocalDb(),
        .sync_dbs = sync_dbs,
        .aurpkgs_db = aurpkgs_db,
    };
}

/// Parse pacman.conf and register each [repo] section as a sync database.
/// This is a simplified parser — it handles the common case of:
///   [core]
///   Include = /etc/pacman.d/mirrorlist
///
/// Full pacman.conf parsing (SigLevel, Usage, etc.) is Phase 2+.
fn registerSyncDbs(allocator: Allocator, handle: *alpm.Handle) ![]alpm.Database {
    var dbs = std.ArrayList(alpm.Database).init(allocator);

    const conf = try std.fs.openFileAbsolute("/etc/pacman.conf", .{});
    defer conf.close();

    var buf_reader = std.io.bufferedReader(conf.reader());
    const reader = buf_reader.reader();

    var current_repo: ?[]const u8 = null;
    var line_buf: [1024]u8 = undefined;

    while (reader.readUntilDelimiter(&line_buf, '\n')) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");

        // Skip comments and empty lines
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // Section header: [reponame]
        if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
            const name = trimmed[1 .. trimmed.len - 1];
            if (std.mem.eql(u8, name, "options")) {
                current_repo = null;
                continue;
            }
            current_repo = name;

            // Register with default siglevel
            const db = try handle.registerSyncDb(name, .default);

            // Read Include/Server lines to add mirrors
            // (next iteration handles these)
            try dbs.append(db);
        }

        // Include directive: add mirror servers from file
        if (current_repo != null and std.mem.startsWith(u8, trimmed, "Include")) {
            const eq_pos = std.mem.indexOf(u8, trimmed, "=") orelse continue;
            const path = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");
            try addServersFromMirrorlist(&dbs.items[dbs.items.len - 1], path);
        }

        // Direct Server directive
        if (current_repo != null and std.mem.startsWith(u8, trimmed, "Server")) {
            const eq_pos = std.mem.indexOf(u8, trimmed, "=") orelse continue;
            const url = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");
            try dbs.items[dbs.items.len - 1].addServer(url);
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }

    return dbs.toOwnedSlice();
}
```

**Why parse pacman.conf ourselves instead of using libalpm:** libalpm doesn't provide a pacman.conf parser — that's pacman's job. The `pacman-conf` utility exists but shelling out to it adds a process spawn. A focused parser that handles `[section]`, `Include`, and `Server` covers 99% of real-world configs in ~60 lines. Full parsing (SigLevel per-repo, Usage flags) is deferred to Phase 2.

#### Domain Methods

Each method answers exactly one question. No method returns raw libalpm types.

```zig
/// Is this package installed on the system?
pub fn isInstalled(self: *Pacman, name: []const u8) bool {
    return self.local_db.getPackage(name) != null;
}

/// What version of this package is installed? Null if not installed.
pub fn installedVersion(self: *Pacman, name: []const u8) ?[]const u8 {
    const pkg = self.local_db.getPackage(name) orelse return null;
    return pkg.getVersion();
}

/// Is this package available in any sync database (including aurpkgs)?
pub fn isInSyncDb(self: *Pacman, name: []const u8) bool {
    for (self.sync_dbs) |db| {
        if (db.getPackage(name) != null) return true;
    }
    return false;
}

/// Which sync database provides this package? Returns db name or null.
pub fn syncDbFor(self: *Pacman, name: []const u8) ?[]const u8 {
    for (self.sync_dbs) |db| {
        if (db.getPackage(name) != null) return db.getName();
    }
    return null;
}
```

#### Version Satisfaction — The Core Domain Logic

This is the most nuanced method. It must handle: "is the installed version of package X at least Y?"

```zig
/// Does the installed version of `name` satisfy `constraint`?
/// Returns false if the package is not installed.
pub fn satisfies(self: *Pacman, name: []const u8, constraint: VersionConstraint) bool {
    const installed = self.installedVersion(name) orelse return false;
    return checkVersion(installed, constraint);
}

/// Check if `version` satisfies `constraint` using libalpm's vercmp.
fn checkVersion(version: []const u8, constraint: VersionConstraint) bool {
    const cmp = alpm.vercmp(version, constraint.version);
    return switch (constraint.op) {
        .eq => cmp == 0,
        .ge => cmp >= 0,
        .le => cmp <= 0,
        .gt => cmp > 0,
        .lt => cmp < 0,
    };
}

/// Does any installed or sync-db package satisfy this dependency string?
/// Handles both direct name matches and versioned constraints.
/// Uses libalpm's native satisfier search for provider resolution.
///
/// Example: satisfiesDep("libfoo>=2.0") checks if any package
/// is installed that either IS libfoo>=2.0 or PROVIDES libfoo>=2.0.
pub fn satisfiesDep(self: *Pacman, depstring: []const u8) bool {
    // libalpm's alpm_find_satisfier checks both name and provides
    const local_pkgs = self.local_db.getPkgcache();
    return alpm.findSatisfier(local_pkgs, depstring) != null;
}
```

**Why `satisfiesDep` wraps `alpm_find_satisfier`:** This libalpm function does something we can't easily replicate — it checks both the package name AND the `provides` array of every installed package against a dependency string. Writing this ourselves would mean iterating every installed package, parsing every `provides` entry, and doing version comparisons. libalpm already does this correctly and efficiently.

#### Provider Resolution

```zig
pub const ProviderMatch = struct {
    provider_name: []const u8,
    provider_version: []const u8,
    db_name: []const u8,
};

/// Find a package that provides the given dependency.
/// Checks sync databases (official repos first, then aurpkgs).
/// Returns null if no provider found.
pub fn findProvider(self: *Pacman, dep: []const u8) ?ProviderMatch {
    // Check official repos first (skip aurpkgs)
    for (self.sync_dbs) |db| {
        if (std.mem.eql(u8, db.getName(), "aurpkgs")) continue;

        var it = db.getPkgcache();
        while (it.next()) |pkg| {
            var dep_it = pkg.getProvides();
            while (dep_it.next()) |prov| {
                if (std.mem.eql(u8, prov.name, dep)) {
                    return .{
                        .provider_name = pkg.getName(),
                        .provider_version = pkg.getVersion(),
                        .db_name = db.getName(),
                    };
                }
            }
        }
    }

    // Then check aurpkgs
    if (self.aurpkgs_db) |aurdb| {
        var it = aurdb.getPkgcache();
        while (it.next()) |pkg| {
            var dep_it = pkg.getProvides();
            while (dep_it.next()) |prov| {
                if (std.mem.eql(u8, prov.name, dep)) {
                    return .{
                        .provider_name = pkg.getName(),
                        .provider_version = pkg.getVersion(),
                        .db_name = "aurpkgs",
                    };
                }
            }
        }
    }

    return null;
}
```

**Why official repos before aurpkgs:** The requirements specify "check installed first, then official repos, then AUR" (FR-5). If both `extra` and `aurpkgs` provide `java-runtime`, we prefer the official repo provider — it's more likely to be stable and correctly signed.

#### Selective Database Refresh

This is a critical safety operation. After building an AUR package and `repo-add`ing it, `makepkg -s` for the next package needs to see it. But we must NOT refresh official repo databases — that would be a partial system update (`pacman -Sy` without `-u`), which is dangerous on Arch.

```zig
/// Refresh only the aurpkgs database.
/// This is safe because aurpkgs is our local repo — refreshing it
/// cannot cause a partial system update.
///
/// Called between builds in a multi-package sync workflow so that
/// newly built packages are visible to subsequent makepkg -s calls.
pub fn refreshAurDb(self: *Pacman) !void {
    const db = self.aurpkgs_db orelse return error.AurDbNotConfigured;
    try db.update(self.handle, false); // force=false, normal refresh
}
```

#### Foreign Package Detection (for `outdated` command)

```zig
pub const InstalledPackage = struct {
    name: []const u8,
    version: []const u8,
};

/// List all installed packages that aren't in any official sync database.
/// These are "foreign" packages — typically AUR packages.
/// Used by the `outdated` command to know which packages to check against AUR.
pub fn allForeignPackages(self: *Pacman) ![]InstalledPackage {
    var foreign = std.ArrayList(InstalledPackage).init(self.allocator);

    var it = self.local_db.getPkgcache();
    while (it.next()) |pkg| {
        const name = pkg.getName();
        const in_official = blk: {
            for (self.sync_dbs) |db| {
                // Skip aurpkgs — we want packages NOT in official repos
                if (std.mem.eql(u8, db.getName(), "aurpkgs")) continue;
                if (db.getPackage(name) != null) break :blk true;
            }
            break :blk false;
        };

        if (!in_official) {
            try foreign.append(.{
                .name = name,
                .version = pkg.getVersion(),
            });
        }
    }

    return foreign.toOwnedSlice();
}
```

### Memory Ownership Rules

The two-layer design has a clear memory ownership boundary:

| Data | Owner | Lifetime | Zig Type |
|------|-------|----------|----------|
| `alpm_handle_t*` | `alpm.Handle` | Until `Handle.deinit()` | `*c.alpm_handle_t` (hidden) |
| `alpm_db_t*` | libalpm (via handle) | Until handle released | `*c.alpm_db_t` (hidden) |
| `alpm_pkg_t*` | libalpm (database cache) | Until db invalidated | `*c.alpm_pkg_t` (hidden) |
| Package name strings | libalpm (inside pkg) | Until pkg's db invalidated | `[]const u8` (borrowed) |
| `alpm_depend_t` fields | libalpm (inside pkg) | Until pkg's db invalidated | `[]const u8` (borrowed) |
| `InstalledPackage` list | Caller (via allocator) | Until caller frees | Owned slice |

**Key rule:** All strings returned by `alpm.zig` methods (`getName()`, `getVersion()`, etc.) are **borrowed** from libalpm's internal memory. They are valid as long as the database cache hasn't been invalidated. In practice, this means they're valid for the lifetime of the `Pacman` struct (which owns the `Handle`). The `Pacman` layer documents this: "returned strings are valid until `Pacman.deinit()`."

After `refreshAurDb()`, the aurpkgs database cache is invalidated. Any previously returned strings from aurpkgs packages are now dangling. This is safe because `refreshAurDb` is only called between build iterations in `commands.zig`, and the registry's `invalidate()` method clears its cache entries at the same time — so no stale string pointers persist.

### Testing Strategy

**`alpm.zig` tests** are integration tests — they need real libalpm:

```zig
test "Handle.init with standard Arch paths" {
    // This test only runs on a real Arch system
    if (!isArchLinux()) return error.SkipZigTest;

    var handle = try alpm.Handle.init("/", "/var/lib/pacman/");
    defer handle.deinit();

    const local_db = handle.getLocalDb();
    // Local db should have at least base packages
    const pacman_pkg = local_db.getPackage("pacman");
    try testing.expect(pacman_pkg != null);
}

test "vercmp handles epochs and pkgrel" {
    // Pure function — no libalpm handle needed
    try testing.expect(alpm.vercmp("1:1.0-1", "2.0-1") > 0);  // epoch wins
    try testing.expect(alpm.vercmp("1.0-1", "1.0-2") < 0);     // pkgrel
    try testing.expect(alpm.vercmp("1.0", "1.0") == 0);         // equal
    try testing.expect(alpm.vercmp("1.0alpha", "1.0beta") < 0); // alpha < beta
    try testing.expect(alpm.vercmp("1.0", "1.0.1") < 0);       // more specific
}
```

**`pacman.zig` tests** use a mock `alpm.Handle`:

```zig
test "isInstalled returns true for local package" {
    var mock = MockAlpmHandle.init();
    mock.localDb().addPackage("vim", "9.0.2-1");

    var pac = Pacman.initWithHandle(testing.allocator, mock);
    defer pac.deinit();

    try testing.expect(pac.isInstalled("vim"));
    try testing.expect(!pac.isInstalled("emacs"));
}

test "satisfies checks version constraint" {
    var mock = MockAlpmHandle.init();
    mock.localDb().addPackage("zlib", "1.3.1-1");

    var pac = Pacman.initWithHandle(testing.allocator, mock);
    defer pac.deinit();

    try testing.expect(pac.satisfies("zlib", .{ .op = .ge, .version = "1.3" }));
    try testing.expect(pac.satisfies("zlib", .{ .op = .eq, .version = "1.3.1-1" }));
    try testing.expect(!pac.satisfies("zlib", .{ .op = .ge, .version = "2.0" }));
}

test "syncDbFor returns correct database name" {
    var mock = MockAlpmHandle.init();
    mock.addSyncDb("core").addPackage("linux", "6.7-1");
    mock.addSyncDb("extra").addPackage("vim", "9.0.2-1");

    var pac = Pacman.initWithHandle(testing.allocator, mock);
    defer pac.deinit();

    try testing.expectEqualStrings("core", pac.syncDbFor("linux").?);
    try testing.expectEqualStrings("extra", pac.syncDbFor("vim").?);
    try testing.expect(pac.syncDbFor("nonexistent") == null);
}

test "allForeignPackages excludes official repo packages" {
    var mock = MockAlpmHandle.init();
    mock.addSyncDb("core").addPackage("linux", "6.7-1");
    mock.addSyncDb("extra").addPackage("vim", "9.0.2-1");
    mock.addSyncDb("aurpkgs").addPackage("yay", "12.0-1");

    // Installed packages
    mock.localDb().addPackage("linux", "6.7-1");   // in core → not foreign
    mock.localDb().addPackage("vim", "9.0.2-1");   // in extra → not foreign
    mock.localDb().addPackage("yay", "12.0-1");    // in aurpkgs only → foreign

    var pac = Pacman.initWithHandle(testing.allocator, mock);
    defer pac.deinit();

    const foreign = try pac.allForeignPackages();
    defer testing.allocator.free(foreign);

    try testing.expectEqual(@as(usize, 1), foreign.len);
    try testing.expectEqualStrings("yay", foreign[0].name);
}

test "refreshAurDb errors when aurpkgs not configured" {
    var mock = MockAlpmHandle.init();
    mock.addSyncDb("core"); // no aurpkgs section

    var pac = Pacman.initWithHandle(testing.allocator, mock);
    defer pac.deinit();

    try testing.expectError(error.AurDbNotConfigured, pac.refreshAurDb());
}
```

### Complexity Budget

| Internal concern | Module | Lines (est.) | Justification |
|-----------------|--------|-------------|---------------|
| C import + opaque types | `alpm.zig` | ~30 | `@cImport`, Handle/Database/AlpmPackage structs |
| `Handle` init/deinit/register | `alpm.zig` | ~40 | libalpm lifecycle + error mapping |
| `Database` methods | `alpm.zig` | ~30 | getPackage, getPkgcache, update |
| `AlpmPackage` accessors | `alpm.zig` | ~40 | getName, getVersion, getDepends... |
| `AlpmListIterator` generic | `alpm.zig` | ~35 | Comptime iterator + extractors |
| `Dependency` struct + `DepMod` | `alpm.zig` | ~20 | Mapped from `alpm_depend_t` |
| `toCString` + `vercmp` | `alpm.zig` | ~25 | Null termination + free function |
| Error mapping (`mapAlpmError`) | `alpm.zig` | ~20 | C error codes → Zig error set |
| **alpm.zig total** | | **~240** | Thin wrapper, proportional depth |
| `Pacman.init` + pacman.conf parse | `pacman.zig` | ~80 | Config parsing, db registration |
| Domain query methods | `pacman.zig` | ~60 | isInstalled, installedVersion, isInSyncDb, syncDbFor |
| Version satisfaction | `pacman.zig` | ~30 | satisfies, satisfiesDep, checkVersion |
| Provider resolution | `pacman.zig` | ~45 | findProvider with priority ordering |
| Foreign package detection | `pacman.zig` | ~30 | allForeignPackages |
| `refreshAurDb` | `pacman.zig` | ~10 | Selective db refresh |
| Types (VersionConstraint, etc.) | `pacman.zig` | ~25 | Public types + DbSet enum |
| Tests | `pacman.zig` | ~120 | Mock-based domain tests |
| **pacman.zig total** | | **~400** | Deep domain module |
| **Combined total** | | **~640** | 6 domain methods + 1 free function hide ~640 lines |

