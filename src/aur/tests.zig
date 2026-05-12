const std = @import("std");
const testing = std.testing;
const aur = @import("../aur.zig");

const Client = aur.Client;
const RpcPackage = aur.RpcPackage;
const RpcResponse = aur.RpcResponse;

// ── JSON Parsing Tests ───────────────────────────────────────────────────

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
    try std.testing.expectError(error.ApiError, Client.checkError(response));
}

test "parse rate limit response returns RateLimited" {
    const fixture =
        \\{"version":5,"type":"error","resultcount":0,"results":[],"error":"Too many requests."}
    ;

    var client = Client.init(std.testing.allocator);
    defer client.deinit();

    const response = try client.parseResponse(fixture);
    try std.testing.expectError(error.RateLimited, Client.checkError(response));
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
    const field = aur.SearchField.fromString("name-desc").?;
    try std.testing.expectEqual(aur.SearchField.name_desc, field);
    try std.testing.expectEqualStrings("name-desc", field.toQueryParam());
}

test "SearchField fromString returns null for unknown" {
    try std.testing.expect(aur.SearchField.fromString("nonexistent") == null);
}

test "url encoding" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try aur.appendUrlEncoded(&buf, std.testing.allocator, "hello world");
    try std.testing.expectEqualStrings("hello+world", buf.items);

    buf.clearRetainingCapacity();
    try aur.appendUrlEncoded(&buf, std.testing.allocator, "a+b&c=d");
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
    const fields = [_]struct { str: []const u8, val: aur.SearchField }{
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
        const parsed = aur.SearchField.fromString(f.str).?;
        try std.testing.expectEqual(f.val, parsed);
        try std.testing.expectEqualStrings(f.str, parsed.toQueryParam());
    }
}

test "url encoding handles special characters" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    // Unreserved chars pass through
    try aur.appendUrlEncoded(&buf, std.testing.allocator, "abc-_.~");
    try std.testing.expectEqualStrings("abc-_.~", buf.items);

    // Empty string
    buf.clearRetainingCapacity();
    try aur.appendUrlEncoded(&buf, std.testing.allocator, "");
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
    try Client.checkError(response);
}
