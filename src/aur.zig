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
const RpcResponse = struct {
    version: u32,
    type: []const u8,
    resultcount: u32,
    results: []const RpcPackage,
    @"error": ?[]const u8 = null,
};

/// Raw AUR package as it arrives from the API.
/// PascalCase field names match the JSON keys.
const RpcPackage = struct {
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
            .http_client = .{ .allocator = allocator },
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
        try self.checkError(response);

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

        const response = try self.parseResponse(response_body);
        try self.checkError(response);

        var results: std.ArrayList(*Package) = .empty;
        defer results.deinit(self.allocator);
        try results.ensureTotalCapacity(self.allocator, response.resultcount);

        for (response.results) |rpc_pkg| {
            results.appendAssumeCapacity(try self.mapPackage(rpc_pkg));
        }

        return try results.toOwnedSlice(self.allocator);
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

        const response = try self.parseResponse(response_body);
        try self.checkError(response);

        var results: std.ArrayList(*Package) = .empty;
        defer results.deinit(self.allocator);
        try results.ensureTotalCapacity(self.allocator, response.resultcount);

        for (response.results) |rpc_pkg| {
            results.appendAssumeCapacity(try self.mapPackage(rpc_pkg));
        }

        return try results.toOwnedSlice(self.allocator);
    }

    fn parseResponse(self: *Client, body: []const u8) !RpcResponse {
        return std.json.parseFromSliceLeaky(
            RpcResponse,
            self.arena.allocator(),
            body,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        ) catch return error.MalformedResponse;
    }

    fn checkError(_: *Client, response: RpcResponse) !void {
        if (response.@"error") |err_msg| {
            if (std.mem.indexOf(u8, err_msg, "Too many requests") != null) {
                return error.RateLimited;
            }
            return error.ApiError;
        }
    }

    /// Translate RpcPackage (PascalCase, nullable arrays) to Package (snake_case, non-null arrays).
    fn mapPackage(self: *Client, rpc: RpcPackage) !*Package {
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
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer aw.deinit();

        const result = self.http_client.fetch(.{
            .location = .{ .url = url },
            .response_writer = &aw.writer,
        }) catch return error.NetworkError;

        if (result.status == .too_many_requests) return error.RateLimited;
        if (result.status != .ok) return error.NetworkError;

        return aw.toOwnedSlice() catch return error.NetworkError;
    }

    fn httpPost(self: *Client, url: []const u8, body: []const u8) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer aw.deinit();

        const result = self.http_client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .headers = .{
                .content_type = .{ .override = "application/x-www-form-urlencoded" },
            },
            .response_writer = &aw.writer,
        }) catch return error.NetworkError;

        if (result.status == .too_many_requests) return error.RateLimited;
        if (result.status != .ok) return error.NetworkError;

        return aw.toOwnedSlice() catch return error.NetworkError;
    }
};

/// Percent-encode a string for URL/form use.
fn appendUrlEncoded(buf: *std.ArrayList(u8), allocator: Allocator, input: []const u8) !void {
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

// ── Tests ────────────────────────────────────────────────────────────────

test "parse single info response" {
    const fixture =
        \\{"version":5,"type":"multiinfo","resultcount":1,"results":[{"ID":1000,"Name":"test-pkg","PackageBase":"test-pkg","PackageBaseID":1000,"Version":"1.0-1","Description":"A test package","URL":"https://example.com","URLPath":"/cgit/aur.git/snapshot/test-pkg.tar.gz","Maintainer":"testuser","Submitter":"testuser","NumVotes":42,"Popularity":3.14,"FirstSubmitted":1600000000,"LastModified":1700000000,"OutOfDate":null,"Depends":["dep1","dep2"],"MakeDepends":["makedep1"],"CheckDepends":[],"OptDepends":["opt1: optional feature"],"Provides":["prov1"],"Conflicts":[],"Replaces":[],"Groups":[],"Keywords":["test"],"License":["MIT"],"CoMaintainers":["comaint1"]}]}
    ;

    var client = Client.init(std.testing.allocator);
    defer client.deinit();

    const response = try client.parseResponse(fixture);
    try std.testing.expectEqual(@as(u32, 1), response.resultcount);
    try std.testing.expectEqualStrings("multiinfo", response.type);

    const pkg = try client.mapPackage(response.results[0]);
    try std.testing.expectEqualStrings("test-pkg", pkg.name);
    try std.testing.expectEqualStrings("test-pkg", pkg.pkgbase);
    try std.testing.expectEqualStrings("1.0-1", pkg.version);
    try std.testing.expectEqual(@as(u32, 42), pkg.votes);
    try std.testing.expect(pkg.depends.len == 2);
    try std.testing.expectEqualStrings("dep1", pkg.depends[0]);
    try std.testing.expectEqualStrings("MIT", pkg.licenses[0]);
    try std.testing.expectEqualStrings("comaint1", pkg.comaintainers[0]);
}

test "parse search response has empty dependency arrays" {
    const fixture =
        \\{"version":5,"type":"search","resultcount":1,"results":[{"ID":2000,"Name":"search-pkg","PackageBase":"search-pkg","PackageBaseID":2000,"Version":"2.0-1","Description":"A search result","NumVotes":10,"Popularity":1.5,"FirstSubmitted":1600000000,"LastModified":1700000000,"OutOfDate":null}]}
    ;

    var client = Client.init(std.testing.allocator);
    defer client.deinit();

    const response = try client.parseResponse(fixture);
    const pkg = try client.mapPackage(response.results[0]);

    // Search results have no dependency info — mapped to empty slices
    try std.testing.expectEqual(@as(usize, 0), pkg.depends.len);
    try std.testing.expectEqual(@as(usize, 0), pkg.makedepends.len);
    try std.testing.expectEqual(@as(usize, 0), pkg.provides.len);
}

test "parse error response returns ApiError" {
    const fixture =
        \\{"version":5,"type":"error","resultcount":0,"results":[],"error":"Incorrect request type specified."}
    ;

    var client = Client.init(std.testing.allocator);
    defer client.deinit();

    const response = try client.parseResponse(fixture);
    try std.testing.expectError(error.ApiError, client.checkError(response));
}

test "parse rate limit response returns RateLimited" {
    const fixture =
        \\{"version":5,"type":"error","resultcount":0,"results":[],"error":"Too many requests."}
    ;

    var client = Client.init(std.testing.allocator);
    defer client.deinit();

    const response = try client.parseResponse(fixture);
    try std.testing.expectError(error.RateLimited, client.checkError(response));
}

test "malformed JSON returns MalformedResponse" {
    var client = Client.init(std.testing.allocator);
    defer client.deinit();

    try std.testing.expectError(error.MalformedResponse, client.parseResponse("{invalid"));
}

test "mapPackage normalizes null arrays to empty slices" {
    var client = Client.init(std.testing.allocator);
    defer client.deinit();

    const rpc = RpcPackage{
        .ID = 1,
        .Name = "pkg",
        .PackageBase = "pkg",
        .PackageBaseID = 1,
        .Version = "1.0",
    };

    const pkg = try client.mapPackage(rpc);
    try std.testing.expectEqual(@as(usize, 0), pkg.depends.len);
    try std.testing.expectEqual(@as(usize, 0), pkg.makedepends.len);
    try std.testing.expectEqual(@as(usize, 0), pkg.licenses.len);
    try std.testing.expectEqual(@as(?[]const u8, null), pkg.description);
    try std.testing.expectEqual(@as(?[]const u8, null), pkg.maintainer);
}

test "SearchField roundtrip" {
    const field = SearchField.fromString("name-desc").?;
    try std.testing.expectEqual(SearchField.name_desc, field);
    try std.testing.expectEqualStrings("name-desc", field.toQueryParam());
}

test "SearchField fromString returns null for unknown" {
    try std.testing.expect(SearchField.fromString("nonexistent") == null);
}

test "url encoding" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendUrlEncoded(&buf, std.testing.allocator, "hello world");
    try std.testing.expectEqualStrings("hello+world", buf.items);

    buf.clearRetainingCapacity();
    try appendUrlEncoded(&buf, std.testing.allocator, "a+b&c=d");
    try std.testing.expectEqualStrings("a%2Bb%26c%3Dd", buf.items);
}

test "mapPackage sets non-empty name and version from fixture" {
    var client = Client.init(std.testing.allocator);
    defer client.deinit();

    const fixture =
        \\{"version":5,"type":"multiinfo","resultcount":1,"results":[{"ID":1000,"Name":"test-pkg","PackageBase":"test-pkg","PackageBaseID":1000,"Version":"1.0-1","Description":"A test package","NumVotes":42,"Popularity":3.14,"FirstSubmitted":1600000000,"LastModified":1700000000,"OutOfDate":null}]}
    ;

    const response = try client.parseResponse(fixture);
    const pkg = try client.mapPackage(response.results[0]);
    try std.testing.expect(pkg.name.len > 0);
    try std.testing.expect(pkg.version.len > 0);
    try std.testing.expect(pkg.pkgbase.len > 0);
}

test "cache stores and retrieves packages by name" {
    var client = Client.init(std.testing.allocator);
    defer client.deinit();

    const rpc = RpcPackage{
        .ID = 1,
        .Name = "cached-pkg",
        .PackageBase = "cached-pkg",
        .PackageBaseID = 1,
        .Version = "1.0",
    };

    const pkg = try client.mapPackage(rpc);
    try client.cache.put(client.allocator, pkg.name, pkg);

    // Cache hit should return the same pointer
    const cached = client.cache.get("cached-pkg");
    try std.testing.expect(cached != null);
    try std.testing.expectEqual(pkg, cached.?);
}

test "cache returns null for uncached packages" {
    var client = Client.init(std.testing.allocator);
    defer client.deinit();

    try std.testing.expect(client.cache.get("nonexistent") == null);
}

test "SearchField covers all documented variants" {
    // Verify all search field variants can round-trip through fromString/toQueryParam
    const fields = [_]struct { str: []const u8, val: SearchField }{
        .{ .str = "name", .val = .name },
        .{ .str = "name-desc", .val = .name_desc },
        .{ .str = "depends", .val = .depends },
        .{ .str = "makedepends", .val = .makedepends },
        .{ .str = "checkdepends", .val = .checkdepends },
        .{ .str = "optdepends", .val = .optdepends },
        .{ .str = "maintainer", .val = .maintainer },
        .{ .str = "submitter", .val = .submitter },
        .{ .str = "provides", .val = .provides },
        .{ .str = "conflicts", .val = .conflicts },
        .{ .str = "replaces", .val = .replaces },
        .{ .str = "keywords", .val = .keywords },
        .{ .str = "groups", .val = .groups },
        .{ .str = "comaintainers", .val = .comaintainers },
    };
    for (fields) |f| {
        const parsed = SearchField.fromString(f.str).?;
        try std.testing.expectEqual(f.val, parsed);
        try std.testing.expectEqualStrings(f.str, parsed.toQueryParam());
    }
}

test "url encoding handles special characters" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    // Unreserved chars pass through
    try appendUrlEncoded(&buf, std.testing.allocator, "abc-_.~");
    try std.testing.expectEqualStrings("abc-_.~", buf.items);

    // Empty string
    buf.clearRetainingCapacity();
    try appendUrlEncoded(&buf, std.testing.allocator, "");
    try std.testing.expectEqualStrings("", buf.items);
}

test "checkError passes for successful response" {
    var client = Client.init(std.testing.allocator);
    defer client.deinit();

    const response = RpcResponse{
        .version = 5,
        .type = "multiinfo",
        .resultcount = 0,
        .results = &.{},
        .@"error" = null,
    };

    // Should not return an error
    try client.checkError(response);
}
