//! Test root for the candid module. It sits here rather than in candid/ so
//! that the module root is src/, which lets candid reach principal.zig.

test {
    _ = @import("candid/candid.zig");
}
