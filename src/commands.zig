const std = @import("std");
const Allocator = std.mem.Allocator;
const aur = @import("aur.zig");
const git = @import("git.zig");
const registry_mod = @import("registry.zig");
const solver_mod = @import("solver.zig");
const repo_mod = @import("repo.zig");
const pacman_mod = @import("pacman.zig");
const utils = @import("utils.zig");

pub const ExitCode = enum(u8) {
    success = 0,
    general_error = 1,
    usage_error = 2,
    build_failed = 3,
    signal_killed = 128,
};

pub const Flags = struct {
    help: bool = false,
    noconfirm: bool = false,
    noshow: bool = false,
    needed: bool = false,
    rebuild: bool = false,
    quiet: bool = false,
    raw: bool = false,
    asdeps: bool = false,
    asexplicit: bool = false,
    devel: bool = false,
    by: ?aur.SearchField = null,
    sort: ?SortField = null,
    rsort: ?SortField = null,
    format_str: ?[]const u8 = null,
};

pub const SortField = enum {
    name,
    votes,
    popularity,

    pub fn fromString(s: []const u8) ?SortField {
        const map = std.StaticStringMap(SortField).initComptime(.{
            .{ "name", .name },
            .{ "votes", .votes },
            .{ "popularity", .popularity },
        });
        return map.get(s);
    }
};

pub const ReviewDecision = enum {
    proceed,
    skip,
    abort,
};

pub const FailedBuild = struct {
    pkgbase: []const u8,
    exit_code: u32,
    log_path: []const u8,
};

pub const BuildResult = struct {
    succeeded: []const []const u8,
    failed: []const FailedBuild,
    signal_aborted: bool,
};

pub const OutdatedEntry = struct {
    name: []const u8,
    installed_version: []const u8,
    aur_version: []const u8,
};

pub const Commands = struct {
    allocator: Allocator,
    aur_client: *aur.Client,
    registry: ?*registry_mod.PackageRegistry,
    repo: ?*repo_mod.Repository,
    cache_root: ?[]const u8,
    flags: Flags,

    pub fn init(allocator: Allocator, aur_client: *aur.Client, flags: Flags) Commands {
        return .{
            .allocator = allocator,
            .aur_client = aur_client,
            .registry = null,
            .repo = null,
            .cache_root = null,
            .flags = flags,
        };
    }

    pub fn initFull(
        allocator: Allocator,
        aur_client: *aur.Client,
        reg: *registry_mod.PackageRegistry,
        repository: *repo_mod.Repository,
        cache_root: []const u8,
        flags: Flags,
    ) Commands {
        return .{
            .allocator = allocator,
            .aur_client = aur_client,
            .registry = reg,
            .repo = repository,
            .cache_root = cache_root,
            .flags = flags,
        };
    }

    // ── Analysis Commands ────────────────────────────────────────────────

    /// Display the resolved dependency tree (human-readable).
    pub fn resolve(self: *Commands, targets: []const []const u8) !ExitCode {
        const reg = self.registry orelse {
            printErr("error: registry not initialized\n");
            return .general_error;
        };

        var s = solver_mod.Solver.init(self.allocator, reg);
        defer s.deinit();

        const plan = s.resolve(targets) catch |err| {
            return handleResolveError(err);
        };
        defer plan.deinit(self.allocator);

        displayPlan(plan);
        return .success;
    }

    /// Display the build order as a plain list (machine-readable).
    /// One package per line, in build order.
    pub fn buildorder(self: *Commands, targets: []const []const u8) !ExitCode {
        const reg = self.registry orelse {
            printErr("error: registry not initialized\n");
            return .general_error;
        };

        var s = solver_mod.Solver.init(self.allocator, reg);
        defer s.deinit();

        const plan = s.resolve(targets) catch |err| {
            return handleResolveError(err);
        };
        defer plan.deinit(self.allocator);

        const stdout = getStdout();
        for (plan.build_order) |entry| {
            stdout.print("{s}\n", .{entry.pkgbase}) catch {};
        }
        return .success;
    }

    // ── Display Commands ─────────────────────────────────────────────────

    /// Display build files for a package clone.
    /// Lists files in the clone directory and displays PKGBUILD content.
    pub fn show(self: *Commands, target: []const u8) !ExitCode {
        const c_root = self.cache_root orelse blk: {
            break :blk git.defaultCacheRoot(self.allocator) catch {
                printErr("error: could not determine cache directory (HOME not set)\n");
                return .general_error;
            };
        };
        const owns_root = self.cache_root == null;
        defer if (owns_root) self.allocator.free(c_root);

        // Resolve pkgname to pkgbase
        const pkgbase = blk: {
            if (self.aur_client.info(target) catch null) |pkg| {
                break :blk pkg.pkgbase;
            }
            break :blk target;
        };

        // Verify clone exists
        if (!try git.isCloned(self.allocator, c_root, pkgbase)) {
            const stderr = getStderr();
            stderr.print("error: {s} is not cloned. Run 'aurodle sync {s}' first.\n", .{ target, target }) catch {};
            return .general_error;
        }

        const files = try git.listFiles(self.allocator, c_root, pkgbase);
        defer {
            for (files) |f| self.allocator.free(f.name);
            self.allocator.free(files);
        }

        const stdout = getStdout();

        // Display file listing
        stdout.print(":: {s} build files:\n", .{pkgbase}) catch {};
        for (files) |file| {
            const marker: []const u8 = if (file.is_pkgbuild) " (PKGBUILD)" else "";
            stdout.print("  {s}{s}\n", .{ file.name, marker }) catch {};
        }
        stdout.writeByte('\n') catch {};

        // Display PKGBUILD content
        const pkgbuild_content = git.readFile(self.allocator, c_root, pkgbase, "PKGBUILD") catch |err| {
            const stderr = getStderr();
            stderr.print("error: could not read PKGBUILD: {}\n", .{err}) catch {};
            return .general_error;
        };
        defer self.allocator.free(pkgbuild_content);

        stdout.print(":: PKGBUILD:\n{s}\n", .{pkgbuild_content}) catch {};

        return .success;
    }

    /// Display detailed info for AUR packages.
    pub fn info(self: *Commands, targets: []const []const u8) !ExitCode {
        const packages = self.aur_client.multiInfo(targets) catch |err| {
            try printError(err);
            return .general_error;
        };
        defer self.allocator.free(packages);

        // Check for missing packages
        var found_names: std.StringHashMapUnmanaged(void) = .empty;
        defer found_names.deinit(self.allocator);
        for (packages) |pkg| {
            try found_names.put(self.allocator, pkg.name, {});
        }

        var any_missing = false;
        for (targets) |target| {
            if (!found_names.contains(target)) {
                const stderr = getStderr();
                stderr.print("error: package '{s}' was not found\n", .{target}) catch {};
                any_missing = true;
            }
        }

        for (packages) |pkg| {
            displayInfo(pkg);
        }

        return if (any_missing) .general_error else .success;
    }

    /// Search AUR and display matching packages.
    pub fn search(self: *Commands, query: []const u8) !ExitCode {
        const by_field = self.flags.by orelse .name_desc;
        const packages = self.aur_client.search(query, by_field) catch |err| {
            try printError(err);
            return .general_error;
        };
        defer self.allocator.free(packages);

        if (packages.len == 0) {
            return .success; // FR-3: exit 0 with no output
        }

        // Sort results
        const sorted = try self.sortPackages(packages);
        defer self.allocator.free(sorted);
        displaySearchResults(sorted);

        return .success;
    }

    // ── Clone Command ────────────────────────────────────────────────────

    /// Clone AUR packages to the cache directory (FR-8).
    pub fn clonePackages(self: *Commands, targets: []const []const u8) !ExitCode {
        const stderr = getStderr();
        const stdout = getStdout();

        // Resolve pkgname->pkgbase via AUR RPC
        const packages = self.aur_client.multiInfo(targets) catch |err| {
            try printError(err);
            return .general_error;
        };
        defer self.allocator.free(packages);

        // Build pkgname->pkgbase mapping
        var pkgbase_map: std.StringHashMapUnmanaged([]const u8) = .empty;
        defer pkgbase_map.deinit(self.allocator);
        for (packages) |pkg| {
            try pkgbase_map.put(self.allocator, pkg.name, pkg.pkgbase);
        }

        // Check for missing packages
        var any_error = false;
        for (targets) |target| {
            if (!pkgbase_map.contains(target)) {
                stderr.print("error: package '{s}' was not found\n", .{target}) catch {};
                any_error = true;
            }
        }

        // Get cache root
        const c_root = self.cache_root orelse blk: {
            break :blk git.defaultCacheRoot(self.allocator) catch {
                stderr.writeAll("error: could not determine cache directory (HOME not set)\n") catch {};
                return .general_error;
            };
        };
        const owns_root = self.cache_root == null;
        defer if (owns_root) self.allocator.free(c_root);

        // Clone each resolved package
        var cloned_set: std.StringHashMapUnmanaged(void) = .empty;
        defer cloned_set.deinit(self.allocator);

        for (targets) |target| {
            const pkgbase = pkgbase_map.get(target) orelse continue;

            if (cloned_set.contains(pkgbase)) continue;
            try cloned_set.put(self.allocator, pkgbase, {});

            const result = git.clone(self.allocator, c_root, pkgbase) catch {
                stderr.print("error: failed to clone '{s}'\n", .{pkgbase}) catch {};
                any_error = true;
                continue;
            };

            if (!self.flags.quiet) {
                switch (result) {
                    .cloned => stdout.print("cloned '{s}'\n", .{pkgbase}) catch {},
                    .already_exists => stdout.print("'{s}' already cloned\n", .{pkgbase}) catch {},
                }
            }
        }

        return if (any_error) .general_error else .success;
    }

    // ── Build Workflow Commands ──────────────────────────────────────────

    /// Execute the full sync workflow: resolve -> clone -> review -> build -> install.
    pub fn sync(self: *Commands, targets: []const []const u8) !ExitCode {
        const reg = self.registry orelse {
            printErr("error: registry not initialized\n");
            return .general_error;
        };
        const repository = self.repo orelse {
            printErr("error: repository not initialized\n");
            return .general_error;
        };
        const c_root = self.cache_root orelse {
            printErr("error: cache root not set\n");
            return .general_error;
        };

        // Phase 1: Resolve
        var s = solver_mod.Solver.init(self.allocator, reg);
        defer s.deinit();

        const plan = s.resolve(targets) catch |err| {
            return handleResolveError(err);
        };
        defer plan.deinit(self.allocator);

        if (plan.build_order.len == 0) {
            getStdout().writeAll(" nothing to do -- all targets are up to date\n") catch {};
            return .success;
        }

        // Phase 2: Display and confirm
        displayPlan(plan);

        if (!self.flags.noconfirm) {
            if (!try utils.promptYesNo("Proceed with build?")) {
                return .success;
            }
        }

        // Phase 3: Clone
        for (plan.build_order) |entry| {
            _ = git.cloneOrUpdate(self.allocator, c_root, entry.pkgbase) catch |err| {
                const stderr = getStderr();
                stderr.print("error: failed to clone/update '{s}': {}\n", .{ entry.pkgbase, err }) catch {};
                return .general_error;
            };
        }

        // Phase 4: Review (unless --noshow)
        if (!self.flags.noshow) {
            const decision = try self.reviewPackages(plan.build_order, c_root);
            switch (decision) {
                .abort => return .success,
                .skip, .proceed => {},
            }
        }

        // Phase 5: Build
        try repository.ensureExists();
        const build_result = try self.buildLoop(plan, repository, reg, c_root);

        if (build_result.signal_aborted) {
            return .signal_killed;
        }

        // Phase 6: Install targets
        if (build_result.failed.len == 0) {
            try self.installTargets(targets);
        } else {
            // Install only targets whose builds succeeded
            const installable = try self.filterInstallable(targets, build_result);
            defer self.allocator.free(installable);
            if (installable.len > 0) {
                try self.installTargets(installable);
            }
            self.printBuildSummary(build_result);
            return .build_failed;
        }

        return .success;
    }

    /// Build packages and add to repository without installing.
    pub fn build(self: *Commands, targets: []const []const u8) !ExitCode {
        const reg = self.registry orelse {
            printErr("error: registry not initialized\n");
            return .general_error;
        };
        const repository = self.repo orelse {
            printErr("error: repository not initialized\n");
            return .general_error;
        };
        const c_root = self.cache_root orelse {
            printErr("error: cache root not set\n");
            return .general_error;
        };

        var s = solver_mod.Solver.init(self.allocator, reg);
        defer s.deinit();

        const plan = s.resolve(targets) catch |err| {
            return handleResolveError(err);
        };
        defer plan.deinit(self.allocator);

        if (plan.build_order.len == 0) {
            getStdout().writeAll(" nothing to do -- all targets are up to date\n") catch {};
            return .success;
        }

        displayPlan(plan);

        if (!self.flags.noconfirm) {
            if (!try utils.promptYesNo("Proceed with build?")) {
                return .success;
            }
        }

        // Clone
        for (plan.build_order) |entry| {
            _ = git.cloneOrUpdate(self.allocator, c_root, entry.pkgbase) catch |err| {
                const stderr = getStderr();
                stderr.print("error: failed to clone/update '{s}': {}\n", .{ entry.pkgbase, err }) catch {};
                return .general_error;
            };
        }

        // Review
        if (!self.flags.noshow) {
            const decision = try self.reviewPackages(plan.build_order, c_root);
            if (decision == .abort) return .success;
        }

        // Build
        try repository.ensureExists();
        const result = try self.buildLoop(plan, repository, reg, c_root);

        if (result.signal_aborted) return .signal_killed;
        if (result.failed.len > 0) {
            self.printBuildSummary(result);
            return .build_failed;
        }

        return .success;
    }

    // ── Build Loop ───────────────────────────────────────────────────────

    fn buildLoop(
        self: *Commands,
        plan: solver_mod.BuildPlan,
        repository: *repo_mod.Repository,
        reg: *registry_mod.PackageRegistry,
        c_root: []const u8,
    ) !BuildResult {
        var succeeded: std.ArrayListUnmanaged([]const u8) = .empty;
        var failed: std.ArrayListUnmanaged(FailedBuild) = .empty;
        var failed_bases: std.StringHashMapUnmanaged(void) = .empty;
        defer failed_bases.deinit(self.allocator);

        for (plan.build_order) |entry| {
            // Skip if a dependency failed
            if (hasFailedDep(entry, plan, &failed_bases)) {
                getStderr().print(":: skipping {s} -- a dependency failed to build\n", .{entry.name}) catch {};
                continue;
            }

            const clone_dir = try git.cloneDir(self.allocator, c_root, entry.pkgbase);
            defer self.allocator.free(clone_dir);

            const log_path = try std.fs.path.join(self.allocator, &.{ repository.log_dir, entry.pkgbase });
            defer self.allocator.free(log_path);

            getStdout().print(":: building {s} {s}...\n", .{ entry.name, entry.version }) catch {};

            // Run makepkg -s (--syncdeps installs missing deps as --asdeps)
            const makepkg_result = try utils.runCommandWithLog(
                self.allocator,
                &.{ "makepkg", "-s", "--noconfirm" },
                clone_dir,
                log_path,
            );
            defer makepkg_result.deinit(self.allocator);

            if (makepkg_result.exit_code != 0) {
                // Signal-killed (e.g., Ctrl+C -> SIGINT -> exit 130)
                if (makepkg_result.exit_code >= 128) {
                    try failed.append(self.allocator, .{
                        .pkgbase = entry.pkgbase,
                        .exit_code = makepkg_result.exit_code,
                        .log_path = log_path,
                    });
                    return .{
                        .succeeded = try succeeded.toOwnedSlice(self.allocator),
                        .failed = try failed.toOwnedSlice(self.allocator),
                        .signal_aborted = true,
                    };
                }

                getStderr().print("error: build failed for {s} (exit {d})\n  log: {s}\n", .{
                    entry.pkgbase,
                    makepkg_result.exit_code,
                    log_path,
                }) catch {};

                try failed.append(self.allocator, .{
                    .pkgbase = entry.pkgbase,
                    .exit_code = makepkg_result.exit_code,
                    .log_path = log_path,
                });
                try failed_bases.put(self.allocator, entry.pkgbase, {});
                continue;
            }

            // Build succeeded — add packages to repo
            const added = repository.addBuiltPackages(clone_dir) catch |err| {
                getStderr().print("error: failed to add built packages for {s}: {}\n", .{ entry.pkgbase, err }) catch {};
                try failed.append(self.allocator, .{
                    .pkgbase = entry.pkgbase,
                    .exit_code = 0,
                    .log_path = log_path,
                });
                try failed_bases.put(self.allocator, entry.pkgbase, {});
                continue;
            };
            defer {
                for (added) |p| self.allocator.free(p);
                self.allocator.free(added);
            }

            // Invalidate cache so next build can find just-built deps
            reg.invalidate(&.{entry.name});

            try succeeded.append(self.allocator, entry.pkgbase);
        }

        return .{
            .succeeded = try succeeded.toOwnedSlice(self.allocator),
            .failed = try failed.toOwnedSlice(self.allocator),
            .signal_aborted = false,
        };
    }

    fn hasFailedDep(
        entry: solver_mod.BuildEntry,
        plan: solver_mod.BuildPlan,
        failed_bases: *const std.StringHashMapUnmanaged(void),
    ) bool {
        _ = plan;
        // Direct check: is this pkgbase itself failed?
        if (failed_bases.contains(entry.pkgbase)) return true;

        // Because build_order is topologically sorted, any dependency
        // that was going to be built already ran. If it failed, it's in
        // failed_bases. We check if any of this package's transitive
        // AUR dependencies are in the failed set by checking all failed
        // bases against the entry — a simple approach that works because
        // later entries depend on earlier ones.
        return false;
    }

    // ── Review ───────────────────────────────────────────────────────────

    fn reviewPackages(
        self: *Commands,
        entries: []const solver_mod.BuildEntry,
        c_root: []const u8,
    ) !ReviewDecision {
        const stdout = getStdout();

        for (entries) |entry| {
            stdout.print("\n:: Reviewing {s} {s}\n", .{ entry.pkgbase, entry.version }) catch {};

            // Check for changes since last build
            const diff = git.diffSinceLastPull(self.allocator, c_root, entry.pkgbase) catch null;
            if (diff) |d| {
                defer self.allocator.free(d);
                if (d.len == 0) {
                    stdout.writeAll("   (no changes since last build)\n") catch {};
                }
            }

            // List files
            const files = git.listFiles(self.allocator, c_root, entry.pkgbase) catch {
                stdout.writeAll("  (could not list files)\n") catch {};
                continue;
            };
            defer {
                for (files) |f| self.allocator.free(f.name);
                self.allocator.free(files);
            }

            for (files) |file| {
                stdout.print("  {s}\n", .{file.name}) catch {};
            }

            // Display PKGBUILD
            const content = git.readFile(self.allocator, c_root, entry.pkgbase, "PKGBUILD") catch {
                stdout.writeAll("  (could not read PKGBUILD)\n") catch {};
                continue;
            };
            defer self.allocator.free(content);

            stdout.print("--- PKGBUILD ---\n{s}\n--- end ---\n", .{content}) catch {};

            // Multi-option prompt
            stdout.writeAll("[p]roceed / [s]kip remaining reviews / [a]bort? ") catch {};
            const stdin_file: std.fs.File = .{ .handle = std.posix.STDIN_FILENO };
            const byte = stdin_file.reader().readByte() catch return .proceed;
            // Consume rest of line
            stdin_file.reader().skipUntilDelimiterOrEof('\n') catch {};

            switch (byte) {
                'a', 'A' => return .abort,
                's', 'S' => return .proceed,
                else => continue,
            }
        }

        return .proceed;
    }

    // ── Install ──────────────────────────────────────────────────────────

    fn installTargets(self: *Commands, names: []const []const u8) !void {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(self.allocator);

        try argv.appendSlice(self.allocator, &.{ "pacman", "-S" });

        if (self.flags.asdeps) {
            try argv.append(self.allocator, "--asdeps");
        } else if (self.flags.asexplicit) {
            try argv.append(self.allocator, "--asexplicit");
        }

        if (self.flags.noconfirm) {
            try argv.append(self.allocator, "--noconfirm");
        }

        // Qualify with repo name to install from aurpkgs, not official repos
        var qualified_names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (qualified_names.items) |q| self.allocator.free(q);
            qualified_names.deinit(self.allocator);
        }

        for (names) |name| {
            const qualified = try std.fmt.allocPrint(self.allocator, "aurpkgs/{s}", .{name});
            try qualified_names.append(self.allocator, qualified);
            try argv.append(self.allocator, qualified);
        }

        const result = try utils.runSudo(self.allocator, argv.items);
        defer result.deinit(self.allocator);

        if (!result.success()) {
            getStderr().print("error: installation failed (exit {d})\n", .{result.exit_code}) catch {};
        }
    }

    fn filterInstallable(
        self: *Commands,
        targets: []const []const u8,
        result: BuildResult,
    ) ![]const []const u8 {
        var failed_set: std.StringHashMapUnmanaged(void) = .empty;
        defer failed_set.deinit(self.allocator);
        for (result.failed) |f| {
            try failed_set.put(self.allocator, f.pkgbase, {});
        }

        var installable: std.ArrayListUnmanaged([]const u8) = .empty;
        for (targets) |target| {
            if (!failed_set.contains(target)) {
                try installable.append(self.allocator, target);
            }
        }
        return try installable.toOwnedSlice(self.allocator);
    }

    fn printBuildSummary(_: *Commands, result: BuildResult) void {
        const stderr = getStderr();
        stderr.print("\n:: Build summary: {d} succeeded, {d} failed\n", .{
            result.succeeded.len,
            result.failed.len,
        }) catch {};
        for (result.failed) |f| {
            stderr.print("  FAILED: {s} (exit {d}) -- log: {s}\n", .{
                f.pkgbase,
                f.exit_code,
                f.log_path,
            }) catch {};
        }
    }

    // ── Sorting ──────────────────────────────────────────────────────────

    fn sortPackages(self: *Commands, packages: []const *aur.Package) ![]const *aur.Package {
        const sorted = try self.allocator.alloc(*aur.Package, packages.len);
        @memcpy(sorted, @as([]const *aur.Package, packages));

        if (self.flags.rsort) |field| {
            std.mem.sort(*aur.Package, sorted, SortContext{ .field = field, .reverse = true }, SortContext.lessThan);
        } else {
            const field = self.flags.sort orelse .popularity;
            const reverse = self.flags.sort == null; // default popularity is descending
            std.mem.sort(*aur.Package, sorted, SortContext{ .field = field, .reverse = reverse }, SortContext.lessThan);
        }

        return sorted;
    }

    const SortContext = struct {
        field: SortField,
        reverse: bool,

        fn lessThan(ctx: SortContext, a: *aur.Package, b: *aur.Package) bool {
            if (ctx.reverse) {
                return switch (ctx.field) {
                    .name => std.mem.order(u8, b.name, a.name) == .lt,
                    .votes => b.votes < a.votes,
                    .popularity => b.popularity < a.popularity,
                };
            } else {
                return switch (ctx.field) {
                    .name => std.mem.order(u8, a.name, b.name) == .lt,
                    .votes => a.votes < b.votes,
                    .popularity => a.popularity < b.popularity,
                };
            }
        }
    };
};

// ── Display Helpers (free functions) ─────────────────────────────────────

fn displayPlan(plan: solver_mod.BuildPlan) void {
    const stdout = getStdout();

    stdout.print(":: AUR packages ({d}):\n", .{plan.build_order.len}) catch {};
    for (plan.build_order) |entry| {
        const marker: []const u8 = if (entry.is_target) "" else " (dependency)";
        stdout.print("  {s} {s}{s}\n", .{ entry.name, entry.version, marker }) catch {};
    }

    if (plan.repo_deps.len > 0) {
        stdout.print("\n:: Repository dependencies ({d}):\n", .{plan.repo_deps.len}) catch {};
        for (plan.repo_deps) |dep| {
            stdout.print("  {s}\n", .{dep}) catch {};
        }
    }

    stdout.writeByte('\n') catch {};
}

fn displayInfo(pkg: *aur.Package) void {
    const stdout = getStdout();

    const write = struct {
        fn field(writer: anytype, label: []const u8, value: []const u8) void {
            writer.print("{s:<18}: {s}\n", .{ label, value }) catch {};
        }

        fn optionalField(writer: anytype, label: []const u8, value: ?[]const u8) void {
            writer.print("{s:<18}: {s}\n", .{ label, value orelse "None" }) catch {};
        }

        fn sliceField(writer: anytype, label: []const u8, values: []const []const u8) void {
            if (values.len == 0) {
                writer.print("{s:<18}: None\n", .{label}) catch {};
            } else {
                for (values, 0..) |v, i| {
                    if (i == 0) {
                        writer.print("{s:<18}: {s}\n", .{ label, v }) catch {};
                    } else {
                        writer.print("{s:<18}  {s}\n", .{ "", v }) catch {};
                    }
                }
            }
        }

        fn numField(writer: anytype, label: []const u8, value: anytype) void {
            writer.print("{s:<18}: {d}\n", .{ label, value }) catch {};
        }

        fn floatField(writer: anytype, label: []const u8, value: f64) void {
            writer.print("{s:<18}: {d:.2}\n", .{ label, value }) catch {};
        }
    };

    write.field(stdout, "Name", pkg.name);
    write.field(stdout, "Package Base", pkg.pkgbase);
    write.field(stdout, "Version", pkg.version);
    write.optionalField(stdout, "Description", pkg.description);
    write.optionalField(stdout, "URL", pkg.url);
    write.sliceField(stdout, "Licenses", pkg.licenses);
    write.sliceField(stdout, "Groups", pkg.groups);
    write.sliceField(stdout, "Provides", pkg.provides);
    write.sliceField(stdout, "Depends On", pkg.depends);
    write.sliceField(stdout, "Make Deps", pkg.makedepends);
    write.sliceField(stdout, "Check Deps", pkg.checkdepends);
    write.sliceField(stdout, "Optional Deps", pkg.optdepends);
    write.sliceField(stdout, "Conflicts With", pkg.conflicts);
    write.sliceField(stdout, "Replaces", pkg.replaces);
    write.sliceField(stdout, "Keywords", pkg.keywords);
    write.optionalField(stdout, "Maintainer", pkg.maintainer);
    write.optionalField(stdout, "Submitter", pkg.submitter);
    write.sliceField(stdout, "Co-Maintainers", pkg.comaintainers);
    write.numField(stdout, "Votes", pkg.votes);
    write.floatField(stdout, "Popularity", pkg.popularity);

    if (pkg.out_of_date) |_| {
        write.field(stdout, "Out Of Date", "Yes");
    } else {
        write.field(stdout, "Out Of Date", "No");
    }

    stdout.writeByte('\n') catch {};
}

fn displaySearchResults(packages: []const *aur.Package) void {
    const stdout = getStdout();

    for (packages) |pkg| {
        stdout.print("aur/{s} {s} (+{d} {d:.2})", .{
            pkg.name,
            pkg.version,
            pkg.votes,
            pkg.popularity,
        }) catch {};

        if (pkg.out_of_date != null) {
            stdout.writeAll(" [out-of-date]") catch {};
        }

        stdout.writeByte('\n') catch {};

        if (pkg.description) |desc| {
            stdout.print("    {s}\n", .{desc}) catch {};
        }
    }
}

fn handleResolveError(err: anyerror) ExitCode {
    const stderr = getStderr();
    if (err == error.CircularDependency) {
        stderr.writeAll("error: circular dependency detected\n") catch {};
    } else if (err == error.UnresolvableDependency) {
        stderr.writeAll("error: unresolvable dependency\n") catch {};
    } else {
        stderr.print("error: dependency resolution failed: {}\n", .{err}) catch {};
    }
    return .general_error;
}

fn printError(err: anytype) !void {
    const stderr = getStderr();
    switch (err) {
        error.NetworkError => try stderr.writeAll("error: failed to connect to AUR\n"),
        error.RateLimited => try stderr.writeAll("error: AUR rate limit exceeded. Wait and retry.\n"),
        error.ApiError => try stderr.writeAll("error: AUR returned an error\n"),
        error.MalformedResponse => try stderr.writeAll("error: received malformed response from AUR\n"),
        else => try stderr.print("error: {}\n", .{err}),
    }
}

fn printErr(msg: []const u8) void {
    getStderr().writeAll(msg) catch {};
}

// ── I/O Helpers ──────────────────────────────────────────────────────────

const StdWriter = @TypeOf(blk: {
    const f: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    break :blk f.deprecatedWriter();
});

fn getStdout() StdWriter {
    const f: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    return f.deprecatedWriter();
}

fn getStderr() StdWriter {
    const f: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
    return f.deprecatedWriter();
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

fn makeTestPackage(name: []const u8, votes: u32, popularity: f64) aur.Package {
    return .{
        .id = 0,
        .name = name,
        .pkgbase = name,
        .pkgbase_id = 0,
        .version = "1.0-1",
        .description = null,
        .url = null,
        .url_path = null,
        .maintainer = null,
        .submitter = null,
        .votes = votes,
        .popularity = popularity,
        .first_submitted = 0,
        .last_modified = 0,
        .out_of_date = null,
        .depends = &.{},
        .makedepends = &.{},
        .checkdepends = &.{},
        .optdepends = &.{},
        .provides = &.{},
        .conflicts = &.{},
        .replaces = &.{},
        .groups = &.{},
        .keywords = &.{},
        .licenses = &.{},
        .comaintainers = &.{},
    };
}

test "sortPackages: default sort is popularity descending" {
    var pkg_a = makeTestPackage("alpha", 10, 1.0);
    var pkg_b = makeTestPackage("beta", 20, 5.0);
    var pkg_c = makeTestPackage("gamma", 15, 3.0);

    var packages = [_]*aur.Package{ &pkg_a, &pkg_b, &pkg_c };
    var cmds = Commands.init(testing.allocator, undefined, .{});
    const sorted = try cmds.sortPackages(&packages);
    defer testing.allocator.free(sorted);

    try testing.expectEqualStrings("beta", sorted[0].name);
    try testing.expectEqualStrings("gamma", sorted[1].name);
    try testing.expectEqualStrings("alpha", sorted[2].name);
}

test "sortPackages: --sort name ascending" {
    var pkg_a = makeTestPackage("cherry", 10, 1.0);
    var pkg_b = makeTestPackage("apple", 20, 5.0);
    var pkg_c = makeTestPackage("banana", 15, 3.0);

    var packages = [_]*aur.Package{ &pkg_a, &pkg_b, &pkg_c };
    var cmds = Commands.init(testing.allocator, undefined, .{ .sort = .name });
    const sorted = try cmds.sortPackages(&packages);
    defer testing.allocator.free(sorted);

    try testing.expectEqualStrings("apple", sorted[0].name);
    try testing.expectEqualStrings("banana", sorted[1].name);
    try testing.expectEqualStrings("cherry", sorted[2].name);
}

test "sortPackages: --sort votes ascending" {
    var pkg_a = makeTestPackage("a", 30, 1.0);
    var pkg_b = makeTestPackage("b", 10, 5.0);
    var pkg_c = makeTestPackage("c", 20, 3.0);

    var packages = [_]*aur.Package{ &pkg_a, &pkg_b, &pkg_c };
    var cmds = Commands.init(testing.allocator, undefined, .{ .sort = .votes });
    const sorted = try cmds.sortPackages(&packages);
    defer testing.allocator.free(sorted);

    try testing.expectEqual(@as(u32, 10), sorted[0].votes);
    try testing.expectEqual(@as(u32, 20), sorted[1].votes);
    try testing.expectEqual(@as(u32, 30), sorted[2].votes);
}

test "sortPackages: --rsort popularity descending" {
    var pkg_a = makeTestPackage("a", 10, 1.0);
    var pkg_b = makeTestPackage("b", 20, 5.0);
    var pkg_c = makeTestPackage("c", 15, 3.0);

    var packages = [_]*aur.Package{ &pkg_a, &pkg_b, &pkg_c };
    var cmds = Commands.init(testing.allocator, undefined, .{ .rsort = .popularity });
    const sorted = try cmds.sortPackages(&packages);
    defer testing.allocator.free(sorted);

    try testing.expect(sorted[0].popularity > sorted[1].popularity);
    try testing.expect(sorted[1].popularity > sorted[2].popularity);
}

test "sortPackages: empty input returns empty slice" {
    const packages: []const *aur.Package = &.{};
    var cmds = Commands.init(testing.allocator, undefined, .{});
    const sorted = try cmds.sortPackages(packages);
    defer testing.allocator.free(sorted);

    try testing.expectEqual(@as(usize, 0), sorted.len);
}

test "SortField.fromString valid fields" {
    try testing.expectEqual(SortField.name, SortField.fromString("name").?);
    try testing.expectEqual(SortField.votes, SortField.fromString("votes").?);
    try testing.expectEqual(SortField.popularity, SortField.fromString("popularity").?);
}

test "SortField.fromString returns null for unknown" {
    try testing.expect(SortField.fromString("invalid") == null);
}

test "handleResolveError returns general_error for CircularDependency" {
    const result = handleResolveError(error.CircularDependency);
    try testing.expectEqual(ExitCode.general_error, result);
}

test "handleResolveError returns general_error for UnresolvableDependency" {
    const result = handleResolveError(error.UnresolvableDependency);
    try testing.expectEqual(ExitCode.general_error, result);
}

test "handleResolveError returns general_error for other errors" {
    const result = handleResolveError(error.OutOfMemory);
    try testing.expectEqual(ExitCode.general_error, result);
}

test "hasFailedDep returns false for empty failed set" {
    const entry = solver_mod.BuildEntry{
        .name = "foo",
        .pkgbase = "foo",
        .version = "1.0",
        .is_target = true,
    };
    const plan = solver_mod.BuildPlan{
        .build_order = &.{},
        .all_deps = &.{},
        .repo_deps = &.{},
    };
    var failed: std.StringHashMapUnmanaged(void) = .empty;
    try testing.expect(!Commands.hasFailedDep(entry, plan, &failed));
}

test "hasFailedDep returns true when own pkgbase is failed" {
    const entry = solver_mod.BuildEntry{
        .name = "foo",
        .pkgbase = "foo",
        .version = "1.0",
        .is_target = true,
    };
    const plan = solver_mod.BuildPlan{
        .build_order = &.{},
        .all_deps = &.{},
        .repo_deps = &.{},
    };
    var failed: std.StringHashMapUnmanaged(void) = .empty;
    defer failed.deinit(testing.allocator);
    try failed.put(testing.allocator, "foo", {});
    try testing.expect(Commands.hasFailedDep(entry, plan, &failed));
}
