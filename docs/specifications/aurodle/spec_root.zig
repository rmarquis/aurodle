// Executable specification root — aggregates all activatable spec files.
//
// Run with: zig build spec

const std = @import("std");

// Contracts (pure function tests)
pub const devel_contract = @import("contracts/devel_contract_spec.zig");

// Properties (invariant tests)
pub const alpm_version_property = @import("properties/alpm_version_property_spec.zig");
pub const devel_property = @import("properties/devel_property_spec.zig");

test {
    std.testing.refAllDecls(@This());
}
