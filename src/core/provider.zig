pub const ProviderCandidate = struct {
    name: []const u8,
    version: []const u8,
    db_name: []const u8, // repo name or "aur"
};

/// Asks the frontend which of several providers satisfies `dep_name`.
/// `ctx` is passed back to `choose_fn` unchanged, so the frontend can
/// carry its own state (terminal style, input source…) without the core
/// knowing about it. Returning null selects the first candidate.
pub const ProviderChooser = struct {
    ctx: ?*anyopaque = null,
    choose_fn: *const fn (
        ctx: ?*anyopaque,
        dep_name: []const u8,
        candidates: []const ProviderCandidate,
    ) ?usize,

    pub fn choose(self: ProviderChooser, dep_name: []const u8, candidates: []const ProviderCandidate) ?usize {
        return self.choose_fn(self.ctx, dep_name, candidates);
    }
};

pub const ProviderSelection = struct {
    dep_name: []const u8,
    chosen: []const u8,
};
