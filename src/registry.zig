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

/// Lifetimes: the registry copies no strings. Cache keys are the names
/// parsed from the dependency strings passed to resolve/resolveMany, and
/// Resolution fields point into Pacman (libalpm) and AurClient (its arena)
/// memory. The registry and every Resolution it returns must not outlive
/// the dependency strings, the Pacman instance or the AUR client.
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
        /// Don't count installed AUR (foreign) packages as available: only
        /// their copies in the local repository do. Set for --chroot,
        /// where makepkg installs dependencies inside the chroot from its
        /// repositories and cannot see what is installed on the host.
        ignore_installed_aur: bool = false,

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
        ///
        /// A version constraint (`foo>=2`) must be met by exact-name matches
        /// (installed, sync, AUR); a failing match falls through to the next
        /// tier, so an outdated installed package resolves to a newer sync or
        /// AUR one. Provider matches are not version-checked (provision
        /// versions are not tracked), but a constrained dep never resolves to
        /// a package of its own name through a provider tier.
        pub fn resolve(self: *Self, dep_string: []const u8) !Resolution {
            const spec = dep_spec.parseDep(dep_string);

            // Cache check (by name, not dep string). A cached result that
            // fails this constraint is re-resolved below.
            if (self.cache.get(spec.name)) |cached| {
                if (satisfiesSpec(cached, spec)) return cached;
            }

            // Tier 1: Installed locally? With ignore_installed_aur, AUR
            // packages come from the local repository instead.
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
            if (try self.resolveProvider(spec)) |res| {
                try self.cacheResult(spec.name, res);
                return res;
            }

            // Tier 4: In AUR by exact name?
            if (try self.resolveAur(spec)) |res| {
                try self.cacheResult(spec.name, res);
                return res;
            }

            // Tier 5: Provided by an AUR package?
            if (try self.resolveAurProvider(spec)) |res| {
                try self.cacheResult(spec.name, res);
                return res;
            }

            // Not found anywhere. Only cache the miss for an unconstrained
            // dep: "nothing satisfies foo>=2" says nothing about plain "foo".
            const res: Resolution = .{ .name = spec.name, .source = .unknown };
            if (spec.constraint == null) try self.cacheResult(spec.name, res);
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
                    if (satisfiesSpec(cached, spec)) {
                        results.appendAssumeCapacity(cached);
                    } else {
                        // Rare: a cached result fails a later constraint.
                        // Take the full cascade for this one dep.
                        results.appendAssumeCapacity(try self.resolve(dep_str));
                    }
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

                if (try self.resolveProvider(spec)) |res| {
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

                // Pass 3: fill in placeholders from cache (now populated by
                // flush). An AUR package that fails the dep's constraint
                // stays .unknown; callers fall back to resolve(), which
                // tries the remaining tiers.
                for (dep_strings, results.items) |dep_str, *res| {
                    if (res.source == .unknown) {
                        if (self.cache.get(res.name)) |cached| {
                            if (satisfiesSpec(cached, dep_spec.parseDep(dep_str))) res.* = cached;
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
            if (try self.resolveAur(.{ .name = name })) |res| return res;
            if (try self.resolveAurProvider(.{ .name = name })) |res| return res;
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

                if (self.pacman.isInOfficialSyncDb(name)) return .{
                    .name = name,
                    .source = .satisfied_repos,
                    .version = self.pacman.installedVersion(name),
                };
                if (self.ignore_installed_aur) return self.resolveLocalRepo(name, constraint);
                return .{
                    .name = name,
                    .source = .satisfied_aur,
                    .version = self.pacman.installedVersion(name),
                };
            }

            // Check if an installed package provides this dependency
            // (e.g. nodejs-lts-jod provides nodejs)
            if (self.pacman.findLocalSatisfier(name)) |provider_name| {
                if (constraint) |c| {
                    if (!self.pacman.satisfies(provider_name, c)) return null;
                }

                const official = self.pacman.isInOfficialSyncDb(provider_name);
                if (!official and self.ignore_installed_aur) return self.resolveLocalRepo(name, constraint);
                return .{
                    .name = name,
                    .source = if (official) .satisfied_repos else .satisfied_aur,
                    .version = self.pacman.installedVersion(provider_name),
                    .provider = provider_name,
                };
            }

            if (self.ignore_installed_aur) return self.resolveLocalRepo(name, constraint);
            return null;
        }

        /// `name` in the local repository, by exact name. Only used with
        /// ignore_installed_aur; otherwise the local repository is reached
        /// through the provider tier. Unlike that tier, this one meets a
        /// version constraint with the local repository's copy.
        fn resolveLocalRepo(self: *Self, name: []const u8, constraint: ?pacman_mod.VersionConstraint) ?Resolution {
            const db = self.pacman.syncDbFor(name) orelse return null;
            if (!self.pacman.isAurRepo(db)) return null;
            const version = self.pacman.syncVersion(name) orelse return null;
            if (constraint) |c| {
                if (!pacman_mod.checkVersion(version, c)) return null;
            }
            return .{ .name = name, .source = .repo_aur, .version = version };
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

        fn resolveAur(self: *Self, spec: DepSpec) !?Resolution {
            const pkg = try self.aur_client.info(spec.name) orelse return null;
            if (spec.constraint) |c| {
                if (!pacman_mod.checkVersion(pkg.version, c)) return null;
            }
            return makeAurResolution(pkg, null);
        }

        fn resolveProvider(self: *Self, spec: DepSpec) !?Resolution {
            const name = spec.name;
            // A constrained dep already had its exact-name candidates
            // version-checked by tiers 1 and 2; don't let them back in here.
            const exclude_self = spec.constraint != null;

            // Check cached provider choice
            if (self.provider_choices.get(name)) |chosen_name| {
                if (exclude_self and std.mem.eql(u8, chosen_name, name)) return null;
                return self.resolveProviderByName(name, chosen_name);
            }

            const found = try self.pacman.findAllProviders(self.allocator, name);
            defer self.allocator.free(found);
            const all = if (exclude_self) removeSelf(found, name) else found;

            if (all.len == 0) return null;

            // Auto-select if exactly one is installed
            if (all.len > 1) {
                var installed_idx: ?usize = null;
                var installed_count: usize = 0;
                for (all, 0..) |match, i| {
                    if (self.pacman.isInstalled(match.name)) {
                        installed_idx = i;
                        installed_count += 1;
                    }
                }
                if (installed_count == 1) {
                    const provider = all[installed_idx.?];
                    try self.cacheProviderChoice(name, provider.name);
                    return self.makeProviderResolution(name, provider);
                }
            }

            // Single match or no chooser — use first
            if (all.len == 1 or self.provider_chooser == null) {
                const provider = all[0];
                if (all.len > 1) {
                    try self.cacheProviderChoice(name, provider.name);
                }
                return self.makeProviderResolution(name, provider);
            }

            // Multiple matches + chooser — prompt user
            const idx = self.provider_chooser.?(name, all, self.stderr_color) orelse 0;
            const provider = all[idx];
            try self.cacheProviderChoice(name, provider.name);
            return self.makeProviderResolution(name, provider);
        }

        fn makeProviderResolution(self: *Self, name: []const u8, provider: pacman_mod.ProviderCandidate) Resolution {
            const from_aurpkgs = self.pacman.isAurRepo(provider.db_name);
            const installed = self.pacman.isInstalled(provider.name) and
                !(self.ignore_installed_aur and from_aurpkgs);
            const source: Source = if (installed)
                if (self.pacman.isInOfficialSyncDb(provider.name)) .satisfied_repos else .satisfied_aur
            else if (from_aurpkgs)
                .repo_aur
            else
                .repos;
            return .{
                .name = name,
                .source = source,
                .version = provider.version,
                .provider = provider.name,
            };
        }

        fn resolveProviderByName(self: *Self, dep_name: []const u8, provider_name: []const u8) ?Resolution {
            // Look up the chosen provider in pacman
            const provider = self.pacman.findProvider(dep_name) orelse return null;
            if (std.mem.eql(u8, provider.name, provider_name)) {
                return self.makeProviderResolution(dep_name, provider);
            }
            // If the cached name doesn't match the first provider, scan all
            const all = self.pacman.findAllProviders(self.allocator, dep_name) catch return null;
            defer self.allocator.free(all);
            for (all) |match| {
                if (std.mem.eql(u8, match.name, provider_name)) {
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

        fn resolveAurProvider(self: *Self, spec: DepSpec) !?Resolution {
            const name = spec.name;
            const exclude_self = spec.constraint != null;

            // Check cached provider choice
            if (self.provider_choices.get(name)) |chosen_name| {
                if (exclude_self and std.mem.eql(u8, chosen_name, name)) return null;
                // Try to find the chosen package in AUR
                if (try self.aur_client.info(chosen_name)) |pkg| {
                    return makeAurResolution(pkg, pkg.name);
                }
            }

            const found = self.aur_client.search(name, .provides) catch |err| switch (err) {
                // The AUR rejects some queries (too short, too many results):
                // that means no usable provider, not a failure. Network and
                // rate-limit errors must propagate, or the dependency would be
                // reported as unresolvable.
                error.ApiError => return null,
                else => |e| return e,
            };
            defer self.allocator.free(found);
            // The provides search also matches the package named `name`,
            // which tier 4 already version-checked.
            const results = if (exclude_self) removeSelfAur(found, name) else found;

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

        /// Does a resolution meet the spec's version constraint? Unknown
        /// results, results without a version, and provider matches (whose
        /// provision version is not tracked) are accepted as is.
        fn satisfiesSpec(res: Resolution, spec: DepSpec) bool {
            const c = spec.constraint orelse return true;
            if (res.source == .unknown) return true;
            if (res.provider) |p| {
                if (!std.mem.eql(u8, p, spec.name)) return true;
            }
            const v = res.version orelse return true;
            return pacman_mod.checkVersion(v, c);
        }

        /// Move matches not named `name` to the front of `matches` and
        /// return that prefix (in original order).
        fn removeSelf(matches: []pacman_mod.ProviderCandidate, name: []const u8) []pacman_mod.ProviderCandidate {
            var n: usize = 0;
            for (matches) |m| {
                if (std.mem.eql(u8, m.name, name)) continue;
                matches[n] = m;
                n += 1;
            }
            return matches[0..n];
        }

        fn removeSelfAur(pkgs: []const *aur.Package, name: []const u8) []const *aur.Package {
            const out: []*aur.Package = @constCast(pkgs);
            var n: usize = 0;
            for (pkgs) |p| {
                if (std.mem.eql(u8, p.name, name)) continue;
                out[n] = p;
                n += 1;
            }
            return out[0..n];
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
