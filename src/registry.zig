const std = @import("std");
const Allocator = std.mem.Allocator;
const aur = @import("aur.zig");
const alpm = @import("alpm.zig");
const color = @import("color.zig");
const devel = @import("devel.zig");
const pacman_mod = @import("pacman.zig");
const provider_types = @import("provider.zig");
const source_mod = @import("source.zig");
const dep_spec = @import("dep_spec.zig");

pub const ProviderCandidate = provider_types.ProviderCandidate;
pub const ProviderChooserFn = provider_types.ProviderChooserFn;
pub const ProviderSelection = provider_types.ProviderSelection;

// ── Public Types ─────────────────────────────────────────────────────────

pub const Source = source_mod.Source;

pub const Resolution = struct {
    name: []const u8,
    source: Source,
    version: ?[]const u8 = null,
    aur_pkg: ?*aur.Package = null,
    provider: ?[]const u8 = null,
};

pub const DepSpec = dep_spec.DepSpec;
pub const parseDep = dep_spec.parseDep;

// ── Production Type Alias ────────────────────────────────────────────────

pub const PackageRegistry = RegistryImpl(pacman_mod.Pacman, aur.Client);

// ── Generic Registry Implementation ──────────────────────────────────────

pub fn RegistryImpl(comptime PacmanT: type, comptime AurClientT: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        pacman: *PacmanT,
        aur_client: *AurClientT,
        cache: std.StringHashMapUnmanaged(Resolution),
        pending_aur: std.StringArrayHashMapUnmanaged(void),
        provider_chooser: ?ProviderChooserFn = null,
        stderr_color: color.Style = color.Style.disabled,
        provider_choices: std.StringHashMapUnmanaged([]const u8) = .empty,
        provider_selections: std.ArrayListUnmanaged(ProviderSelection) = .empty,

        pub fn init(allocator: Allocator, pm: *PacmanT, ac: *AurClientT) Self {
            return .{
                .allocator = allocator,
                .pacman = pm,
                .aur_client = ac,
                .cache = .empty,
                .pending_aur = .empty,
            };
        }

        pub fn deinit(self: *Self) void {
            self.cache.deinit(self.allocator);
            self.pending_aur.deinit(self.allocator);
            self.provider_choices.deinit(self.allocator);
            self.provider_selections.deinit(self.allocator);
        }

        /// Resolve a single dependency string through the cascade:
        /// cache → installed → sync → pacman provider → AUR → AUR provider → unknown
        pub fn resolve(self: *Self, dep_string: []const u8) !Resolution {
            const spec = dep_spec.parseDep(dep_string);

            // Cache check (by name, not dep string)
            if (self.cache.get(spec.name)) |cached| {
                // Re-verify constraint for cached result
                if (spec.constraint) |c| {
                    if (cached.version) |v| {
                        if (!pacman_mod.checkVersion(v, c)) {
                            // Cached version doesn't satisfy this constraint
                            return .{
                                .name = spec.name,
                                .source = .unknown,
                                .version = cached.version,
                                .aur_pkg = cached.aur_pkg,
                            };
                        }
                    }
                }
                return cached;
            }

            // Tier 1: Installed locally?
            if (self.resolveLocal(spec.name, spec.constraint)) |res| {
                try self.cacheResult(spec.name, res);
                return res;
            }

            // Tier 2: In sync databases?
            if (self.resolveSync(spec.name, spec.constraint)) |res| {
                try self.cacheResult(spec.name, res);
                return res;
            }

            // Tier 3: Provided by installed/sync package?
            if (try self.resolveProvider(spec.name)) |res| {
                try self.cacheResult(spec.name, res);
                return res;
            }

            // Tier 4: In AUR by exact name?
            if (try self.resolveAur(spec.name)) |res| {
                try self.cacheResult(spec.name, res);
                return res;
            }

            // Tier 5: Provided by an AUR package?
            if (try self.resolveAurProvider(spec.name)) |res| {
                try self.cacheResult(spec.name, res);
                return res;
            }

            // Not found anywhere
            const res: Resolution = .{ .name = spec.name, .source = .unknown };
            try self.cacheResult(spec.name, res);
            return res;
        }

        /// Batch resolve with deferred AUR batching.
        /// Local + sync lookups run first (cheap), then all remaining names
        /// are flushed as a single AUR multiInfo call.
        pub fn resolveMany(self: *Self, dep_strings: []const []const u8) ![]Resolution {
            var results: std.ArrayList(Resolution) = .empty;
            errdefer results.deinit(self.allocator);
            try results.ensureTotalCapacity(self.allocator, dep_strings.len);

            // Pass 1: resolve locally + sync, defer AUR
            for (dep_strings) |dep_str| {
                const spec = dep_spec.parseDep(dep_str);

                if (self.cache.get(spec.name)) |cached| {
                    results.appendAssumeCapacity(cached);
                    continue;
                }

                if (self.resolveLocal(spec.name, spec.constraint)) |res| {
                    try self.cacheResult(spec.name, res);
                    results.appendAssumeCapacity(res);
                    continue;
                }

                if (self.resolveSync(spec.name, spec.constraint)) |res| {
                    try self.cacheResult(spec.name, res);
                    results.appendAssumeCapacity(res);
                    continue;
                }

                if (try self.resolveProvider(spec.name)) |res| {
                    try self.cacheResult(spec.name, res);
                    results.appendAssumeCapacity(res);
                    continue;
                }

                // Defer to AUR batch
                try self.pending_aur.put(self.allocator, spec.name, {});
                results.appendAssumeCapacity(.{ .name = spec.name, .source = .unknown });
            }

            // Pass 2: flush all pending AUR lookups in one batch
            if (self.pending_aur.count() > 0) {
                try self.flushPendingAur();

                // Pass 3: fill in placeholders from cache (now populated by flush)
                for (results.items) |*res| {
                    if (res.source == .unknown) {
                        if (self.cache.get(res.name)) |cached| {
                            res.* = cached;
                        }
                    }
                }
            }

            return try results.toOwnedSlice(self.allocator);
        }

        /// Invalidate specific cache entries.
        /// Called between builds in a multi-package sync workflow
        /// after repo-add makes a package available in aurpkgs.
        pub fn invalidate(self: *Self, names: []const []const u8) void {
            for (names) |name| {
                _ = self.cache.remove(name);
            }
        }

        /// Warm the AUR client cache for the given names via a single
        /// batched multiInfo call. Subsequent info() calls for these
        /// names become cache hits with no HTTP round-trip.
        pub fn prefetchAur(self: *Self, names: []const []const u8) !void {
            if (names.len == 0) return;
            const results = try self.aur_client.multiInfo(names);
            self.allocator.free(results);
        }

        /// Resolve a package directly from AUR, bypassing local/sync tiers.
        /// Used by the solver for target packages that need dependency info
        /// even when the package is already installed or in sync repos.
        pub fn resolveFromAur(self: *Self, name: []const u8) !?Resolution {
            if (try self.resolveAur(name)) |res| return res;
            if (try self.resolveAurProvider(name)) |res| return res;
            return null;
        }

        /// Version comparison using the same algorithm as libalpm/pacman.
        pub fn vercmp(a: []const u8, b: []const u8) i32 {
            return alpm.vercmp(a, b);
        }

        /// True for packages with a VCS-based name (-git, -svn, -hg, -bzr, -cvs).
        pub fn isVcsPackage(name: []const u8) bool {
            return devel.isVcsPackage(name);
        }

        // ── Private Resolution Tiers ────────────────────────────────────

        fn resolveLocal(self: *Self, name: []const u8, constraint: ?pacman_mod.VersionConstraint) ?Resolution {
            if (self.pacman.isInstalled(name)) {
                if (constraint) |c| {
                    if (!self.pacman.satisfies(name, c)) return null;
                }

                return .{
                    .name = name,
                    .source = if (self.pacman.isInOfficialSyncDb(name)) .satisfied_repos else .satisfied_aur,
                    .version = self.pacman.installedVersion(name),
                };
            }

            // Check if an installed package provides this dependency
            // (e.g. nodejs-lts-jod provides nodejs)
            if (self.pacman.findLocalSatisfier(name)) |provider_name| {
                if (constraint) |c| {
                    if (!self.pacman.satisfies(provider_name, c)) return null;
                }

                return .{
                    .name = name,
                    .source = if (self.pacman.isInOfficialSyncDb(provider_name)) .satisfied_repos else .satisfied_aur,
                    .version = self.pacman.installedVersion(provider_name),
                    .provider = provider_name,
                };
            }

            return null;
        }

        fn resolveSync(self: *Self, name: []const u8, constraint: ?pacman_mod.VersionConstraint) ?Resolution {
            const version = self.pacman.officialSyncVersion(name) orelse return null;

            if (constraint) |c| {
                if (!pacman_mod.checkVersion(version, c)) return null;
            }

            return .{
                .name = name,
                .source = .repos,
                .version = version,
            };
        }

        fn resolveAur(self: *Self, name: []const u8) !?Resolution {
            const pkg = try self.aur_client.info(name) orelse return null;
            return makeAurResolution(pkg, null);
        }

        fn resolveProvider(self: *Self, name: []const u8) !?Resolution {
            // Check cached provider choice
            if (self.provider_choices.get(name)) |chosen_name| {
                return self.resolveProviderByName(name, chosen_name);
            }

            const all = try self.pacman.findAllProviders(self.allocator, name);
            defer self.allocator.free(all);

            if (all.len == 0) return null;

            // Auto-select if exactly one is installed
            if (all.len > 1) {
                var installed_idx: ?usize = null;
                var installed_count: usize = 0;
                for (all, 0..) |match, i| {
                    if (self.pacman.isInstalled(match.provider_name)) {
                        installed_idx = i;
                        installed_count += 1;
                    }
                }
                if (installed_count == 1) {
                    const provider = all[installed_idx.?];
                    try self.cacheProviderChoice(name, provider.provider_name);
                    return self.makeProviderResolution(name, provider);
                }
            }

            // Single match or no chooser — use first
            if (all.len == 1 or self.provider_chooser == null) {
                const provider = all[0];
                if (all.len > 1) {
                    try self.cacheProviderChoice(name, provider.provider_name);
                }
                return self.makeProviderResolution(name, provider);
            }

            // Multiple matches + chooser — prompt user
            var candidates: std.ArrayListUnmanaged(ProviderCandidate) = .empty;
            defer candidates.deinit(self.allocator);
            for (all) |match| {
                try candidates.append(self.allocator, .{
                    .name = match.provider_name,
                    .version = match.provider_version,
                    .db_name = match.db_name,
                });
            }

            const idx = self.provider_chooser.?(name, candidates.items, self.stderr_color) orelse 0;
            const provider = all[idx];
            try self.cacheProviderChoice(name, provider.provider_name);
            return self.makeProviderResolution(name, provider);
        }

        fn makeProviderResolution(self: *Self, name: []const u8, provider: pacman_mod.ProviderMatch) Resolution {
            const from_aurpkgs = self.pacman.isAurRepo(provider.db_name);
            const source: Source = if (self.pacman.isInstalled(provider.provider_name))
                if (self.pacman.isInOfficialSyncDb(provider.provider_name)) .satisfied_repos else .satisfied_aur
            else if (from_aurpkgs)
                .repo_aur
            else
                .repos;
            return .{
                .name = name,
                .source = source,
                .version = provider.provider_version,
                .provider = provider.provider_name,
            };
        }

        fn resolveProviderByName(self: *Self, dep_name: []const u8, provider_name: []const u8) ?Resolution {
            // Look up the chosen provider in pacman
            const provider = self.pacman.findProvider(dep_name) orelse return null;
            if (std.mem.eql(u8, provider.provider_name, provider_name)) {
                return self.makeProviderResolution(dep_name, provider);
            }
            // If the cached name doesn't match the first provider, scan all
            const all = self.pacman.findAllProviders(self.allocator, dep_name) catch return null;
            defer self.allocator.free(all);
            for (all) |match| {
                if (std.mem.eql(u8, match.provider_name, provider_name)) {
                    return self.makeProviderResolution(dep_name, match);
                }
            }
            return null;
        }

        fn cacheProviderChoice(self: *Self, dep_name: []const u8, chosen: []const u8) !void {
            try self.provider_choices.put(self.allocator, dep_name, chosen);
            try self.provider_selections.append(self.allocator, .{
                .dep_name = dep_name,
                .chosen = chosen,
            });
        }

        fn resolveAurProvider(self: *Self, name: []const u8) !?Resolution {
            // Check cached provider choice
            if (self.provider_choices.get(name)) |chosen_name| {
                // Try to find the chosen package in AUR
                if (try self.aur_client.info(chosen_name)) |pkg| {
                    return makeAurResolution(pkg, pkg.name);
                }
            }

            const results = self.aur_client.search(name, .provides) catch return null;
            defer self.allocator.free(results);

            if (results.len == 0) return null;

            if (results.len == 1 or self.provider_chooser == null) {
                const provider_pkg = results[0];
                if (results.len > 1) {
                    try self.cacheProviderChoice(name, provider_pkg.name);
                }
                return makeAurResolution(provider_pkg, provider_pkg.name);
            }

            // Multiple AUR providers — prompt user
            var candidates: std.ArrayListUnmanaged(ProviderCandidate) = .empty;
            defer candidates.deinit(self.allocator);
            for (results) |pkg| {
                try candidates.append(self.allocator, .{
                    .name = pkg.name,
                    .version = pkg.version,
                    .db_name = "aur",
                });
            }

            const idx = self.provider_chooser.?(name, candidates.items, self.stderr_color) orelse 0;
            const provider_pkg = results[idx];
            try self.cacheProviderChoice(name, provider_pkg.name);
            return makeAurResolution(provider_pkg, provider_pkg.name);
        }

        fn flushPendingAur(self: *Self) !void {
            const names = self.pending_aur.keys();
            if (names.len == 0) return;

            const packages = try self.aur_client.multiInfo(names);
            defer self.allocator.free(packages);

            for (packages) |pkg| {
                try self.cacheResult(pkg.name, makeAurResolution(pkg, null));
            }

            self.pending_aur.clearRetainingCapacity();
        }

        fn makeAurResolution(pkg: *aur.Package, provider_name: ?[]const u8) Resolution {
            return .{
                .name = pkg.name,
                .source = .aur,
                .version = pkg.version,
                .aur_pkg = pkg,
                .provider = provider_name,
            };
        }

        fn cacheResult(self: *Self, name: []const u8, res: Resolution) !void {
            try self.cache.put(self.allocator, name, res);
        }
    };
}

// ── Pure Functions ───────────────────────────────────────────────────────

// ── Tests ────────────────────────────────────────────────────────────────

test {
    _ = @import("registry/tests.zig");
}
