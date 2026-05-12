const std = @import("std");
const Allocator = std.mem.Allocator;

/// Max response size from AUR. Typical responses are <100KB.
/// 10MB handles extreme multi-info batches.
const MAX_RESPONSE_SIZE = 10 * 1024 * 1024;

/// Max packages per multi-info request.
const MAX_BATCH_SIZE = 100;

pub const AurError = error{
    NetworkError,
    RateLimited,
    ApiError,
    MalformedResponse,
};

pub const SearchField = enum {
    name,
    name_desc,
    depends,
    makedepends,
    checkdepends,
    optdepends,
    maintainer,
    submitter,
    provides,
    conflicts,
    replaces,
    keywords,
    groups,
    comaintainers,

    pub fn toQueryParam(self: SearchField) []const u8 {
        return switch (self) {
            .name => "name",
            .name_desc => "name-desc",
            .depends => "depends",
            .makedepends => "makedepends",
            .checkdepends => "checkdepends",
            .optdepends => "optdepends",
            .maintainer => "maintainer",
            .submitter => "submitter",
            .provides => "provides",
            .conflicts => "conflicts",
            .replaces => "replaces",
            .keywords => "keywords",
            .groups => "groups",
            .comaintainers => "comaintainers",
        };
    }

    pub fn fromString(s: []const u8) ?SearchField {
        const map = std.StaticStringMap(SearchField).initComptime(.{
            .{ "name", .name },
            .{ "name-desc", .name_desc },
            .{ "depends", .depends },
            .{ "makedepends", .makedepends },
            .{ "checkdepends", .checkdepends },
            .{ "optdepends", .optdepends },
            .{ "maintainer", .maintainer },
            .{ "submitter", .submitter },
            .{ "provides", .provides },
            .{ "conflicts", .conflicts },
            .{ "replaces", .replaces },
            .{ "keywords", .keywords },
            .{ "groups", .groups },
            .{ "comaintainers", .comaintainers },
        });
        return map.get(s);
    }
};

pub const Package = struct {
    id: u32,
    name: []const u8,
    pkgbase: []const u8,
    pkgbase_id: u32,
    version: []const u8,
    description: ?[]const u8,
    url: ?[]const u8,
    url_path: ?[]const u8,
    maintainer: ?[]const u8,
    submitter: ?[]const u8,
    votes: u32,
    popularity: f64,
    first_submitted: i64,
    last_modified: i64,
    out_of_date: ?i64,
    depends: []const []const u8,
    makedepends: []const []const u8,
    checkdepends: []const []const u8,
    optdepends: []const []const u8,
    provides: []const []const u8,
    conflicts: []const []const u8,
    replaces: []const []const u8,
    groups: []const []const u8,
    keywords: []const []const u8,
    licenses: []const []const u8,
    comaintainers: []const []const u8,
};

/// Raw AUR RPC response structure — matches the JSON exactly.
pub const RpcResponse = struct {
    version: u32,
    type: []const u8,
    resultcount: u32,
    results: []const RpcPackage,
    @"error": ?[]const u8 = null,
};

/// Raw AUR package as it arrives from the API.
/// PascalCase field names match the JSON keys.
pub const RpcPackage = struct {
    ID: u32,
    Name: []const u8,
    PackageBase: []const u8,
    PackageBaseID: u32,
    Version: []const u8,
    Description: ?[]const u8 = null,
    URL: ?[]const u8 = null,
    URLPath: ?[]const u8 = null,
    Maintainer: ?[]const u8 = null,
    Submitter: ?[]const u8 = null,
    NumVotes: u32 = 0,
    Popularity: f64 = 0.0,
    FirstSubmitted: i64 = 0,
    LastModified: i64 = 0,
    OutOfDate: ?i64 = null,
    Depends: ?[]const []const u8 = null,
    MakeDepends: ?[]const []const u8 = null,
    CheckDepends: ?[]const []const u8 = null,
    OptDepends: ?[]const []const u8 = null,
    Provides: ?[]const []const u8 = null,
    Conflicts: ?[]const []const u8 = null,
    Replaces: ?[]const []const u8 = null,
    Groups: ?[]const []const u8 = null,
    Keywords: ?[]const []const u8 = null,
    License: ?[]const []const u8 = null,
    CoMaintainers: ?[]const []const u8 = null,
};

pub const Client = struct {
    allocator: Allocator,
    /// All Package data lives here. Freed in bulk on deinit().
    arena: std.heap.ArenaAllocator,
    http_client: std.http.Client,
    cache: std.StringHashMapUnmanaged(*Package),

    pub fn init(allocator: Allocator) Client {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .http_client = .{ .allocator = allocator, .io = std.Options.debug_io },
            .cache = .empty,
        };
    }

    pub fn deinit(self: *Client) void {
        self.http_client.deinit();
        self.cache.deinit(self.allocator);
        self.arena.deinit();
    }

    /// Single-package lookup. Checks cache first, then issues an HTTP request.
    pub fn info(self: *Client, name: []const u8) !?*Package {
        // Cache hit
        if (self.cache.get(name)) |pkg| return pkg;

        // HTTP request
        const url = try std.fmt.allocPrint(
            self.allocator,
            "https://aur.archlinux.org/rpc/v5/info/{s}",
            .{name},
        );
        defer self.allocator.free(url);

        const response_body = try self.httpGet(url);
        defer self.allocator.free(response_body);

        const response = try self.parseResponse(response_body);
        try Client.checkError(response);

        if (response.resultcount == 0) return null;

        const pkg = try self.mapPackage(response.results[0]);
        try self.cache.put(self.allocator, pkg.name, pkg);
        return pkg;
    }

    /// Batch multi-info. Fetches uncached in chunks of MAX_BATCH_SIZE.
    pub fn multiInfo(self: *Client, names: []const []const u8) ![]const *Package {
        var results: std.ArrayList(*Package) = .empty;
        defer results.deinit(self.allocator);

        var uncached: std.ArrayList([]const u8) = .empty;
        defer uncached.deinit(self.allocator);

        for (names) |name| {
            if (self.cache.get(name)) |pkg| {
                try results.append(self.allocator, pkg);
            } else {
                try uncached.append(self.allocator, name);
            }
        }

        // Batch uncached in chunks
        var i: usize = 0;
        while (i < uncached.items.len) {
            const end = @min(i + MAX_BATCH_SIZE, uncached.items.len);
            const batch = uncached.items[i..end];

            const batch_results = try self.fetchMultiInfo(batch);
            defer self.allocator.free(batch_results);
            for (batch_results) |pkg| {
                try self.cache.put(self.allocator, pkg.name, pkg);
                try results.append(self.allocator, pkg);
            }

            i = end;
        }

        return try results.toOwnedSlice(self.allocator);
    }

    /// Search AUR packages. NOT cached (search results lack dependency arrays).
    pub fn search(
        self: *Client,
        query: []const u8,
        by: SearchField,
    ) ![]const *Package {
        // URL-encode the query
        var encoded_query: std.ArrayList(u8) = .empty;
        defer encoded_query.deinit(self.allocator);
        try appendUrlEncoded(&encoded_query, self.allocator, query);

        const url = try std.fmt.allocPrint(
            self.allocator,
            "https://aur.archlinux.org/rpc/v5/search/{s}?by={s}",
            .{ encoded_query.items, by.toQueryParam() },
        );
        defer self.allocator.free(url);

        const response_body = try self.httpGet(url);
        defer self.allocator.free(response_body);

        return self.parseAndMapResults(response_body);
    }

    /// Issues a single multi-info request for a batch of names.
    /// Uses POST with form-encoded body to avoid URL length limits.
    fn fetchMultiInfo(self: *Client, names: []const []const u8) ![]*Package {
        // Build form body: "arg[]=name1&arg[]=name2&..."
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.allocator);

        for (names, 0..) |name, idx| {
            if (idx > 0) try body.append(self.allocator, '&');
            try body.appendSlice(self.allocator, "arg[]=");
            try appendUrlEncoded(&body, self.allocator, name);
        }

        const response_body = try self.httpPost(
            "https://aur.archlinux.org/rpc/v5/info",
            body.items,
        );
        defer self.allocator.free(response_body);

        return self.parseAndMapResults(response_body);
    }

    pub fn parseResponse(self: *Client, body: []const u8) !RpcResponse {
        return std.json.parseFromSliceLeaky(
            RpcResponse,
            self.arena.allocator(),
            body,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        ) catch return error.MalformedResponse;
    }

    /// Parse a response body and map all results to Package pointers.
    fn parseAndMapResults(self: *Client, response_body: []const u8) ![]*Package {
        const response = try self.parseResponse(response_body);
        try Client.checkError(response);

        var results: std.ArrayList(*Package) = .empty;
        defer results.deinit(self.allocator);
        try results.ensureTotalCapacity(self.allocator, response.resultcount);

        for (response.results) |rpc_pkg| {
            results.appendAssumeCapacity(try self.mapPackage(rpc_pkg));
        }

        return try results.toOwnedSlice(self.allocator);
    }

    pub fn checkError(response: RpcResponse) !void {
        if (response.@"error") |err_msg| {
            if (std.mem.indexOf(u8, err_msg, "Too many requests") != null) {
                return error.RateLimited;
            }
            return error.ApiError;
        }
    }

    /// Translate RpcPackage (PascalCase, nullable arrays) to Package (snake_case, non-null arrays).
    pub fn mapPackage(self: *Client, rpc: RpcPackage) !*Package {
        const arena_alloc = self.arena.allocator();
        const pkg = try arena_alloc.create(Package);
        pkg.* = .{
            .id = rpc.ID,
            .name = rpc.Name,
            .pkgbase = rpc.PackageBase,
            .pkgbase_id = rpc.PackageBaseID,
            .version = rpc.Version,
            .description = rpc.Description,
            .url = rpc.URL,
            .url_path = rpc.URLPath,
            .maintainer = rpc.Maintainer,
            .submitter = rpc.Submitter,
            .votes = rpc.NumVotes,
            .popularity = rpc.Popularity,
            .first_submitted = rpc.FirstSubmitted,
            .last_modified = rpc.LastModified,
            .out_of_date = rpc.OutOfDate,
            .depends = rpc.Depends orelse &.{},
            .makedepends = rpc.MakeDepends orelse &.{},
            .checkdepends = rpc.CheckDepends orelse &.{},
            .optdepends = rpc.OptDepends orelse &.{},
            .provides = rpc.Provides orelse &.{},
            .conflicts = rpc.Conflicts orelse &.{},
            .replaces = rpc.Replaces orelse &.{},
            .groups = rpc.Groups orelse &.{},
            .keywords = rpc.Keywords orelse &.{},
            .licenses = rpc.License orelse &.{},
            .comaintainers = rpc.CoMaintainers orelse &.{},
        };
        return pkg;
    }

    fn httpGet(self: *Client, url: []const u8) ![]u8 {
        return self.httpFetch(url, null);
    }

    fn httpPost(self: *Client, url: []const u8, payload: []const u8) ![]u8 {
        return self.httpFetch(url, payload);
    }

    fn httpFetch(self: *Client, url: []const u8, payload: ?[]const u8) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer aw.deinit();

        var headers: std.http.Client.Request.Headers = .{};
        if (payload != null) {
            headers.content_type = .{ .override = "application/x-www-form-urlencoded" };
        }

        const result = self.http_client.fetch(.{
            .location = .{ .url = url },
            .method = if (payload != null) .POST else .GET,
            .payload = payload,
            .headers = headers,
            .response_writer = &aw.writer,
        }) catch return error.NetworkError;

        if (result.status == .too_many_requests) return error.RateLimited;
        if (result.status != .ok) return error.NetworkError;

        return aw.toOwnedSlice() catch return error.NetworkError;
    }
};

/// Percent-encode a string for URL/form use.
pub fn appendUrlEncoded(buf: *std.ArrayList(u8), allocator: Allocator, input: []const u8) !void {
    for (input) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try buf.append(allocator, c);
        } else if (c == ' ') {
            try buf.append(allocator, '+');
        } else {
            try buf.appendSlice(allocator, &.{ '%', hexDigit(@truncate(c >> 4)), hexDigit(@truncate(c & 0xf)) });
        }
    }
}

fn hexDigit(v: u4) u8 {
    return "0123456789ABCDEF"[v];
}
