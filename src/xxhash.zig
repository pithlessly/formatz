const std = @import("std");
const readIntLittle = std.mem.readIntLittle;
const rotl = std.math.rotl;

const prime_1 = 0x9e3779b185ebca87;
const prime_2 = 0xc2b2ae3d27d4eb4f;
const prime_3 = 0x165667b19e3779f9;
const prime_4 = 0x85ebca77c2b2ae63;
const prime_5 = 0x27d4eb2f165667c5;

pub fn xxh64(input: []const u8, seed: u64) u64 {
    if (input.len >= 32) {
        var cursor = input.ptr;
        const end = cursor + input.len;
        const limit = @ptrToInt(end - 31);

        var v1 = seed +% prime_1 +% prime_2;
        var v2 = seed +% prime_2;
        var v3 = seed;
        var v4 = seed -% prime_1;

        while (true) {
            v1 = xxh64Round(v1, readIntLittle(u64, cursor[0..8]));
            v2 = xxh64Round(v2, readIntLittle(u64, cursor[8..16]));
            v3 = xxh64Round(v3, readIntLittle(u64, cursor[16..24]));
            v4 = xxh64Round(v4, readIntLittle(u64, cursor[24..32]));
            cursor += 32;
            if (@ptrToInt(cursor) >= limit)
                break;
        }

        var h64 =
            rotl(u64, v1, 1) +% rotl(u64, v2, 7) +%
            rotl(u64, v3, 12) +% rotl(u64, v4, 18);
        h64 = xxh64MergeRound(h64, v1);
        h64 = xxh64MergeRound(h64, v2);
        h64 = xxh64MergeRound(h64, v3);
        h64 = xxh64MergeRound(h64, v4);

        h64 +%= input.len;
        return finalize(h64, cursor[0 .. input.len & 0b11111]);
    } else {
        const h64 = seed +% prime_5 +% input.len;
        return finalize(h64, input);
    }
}

fn xxh64Round(acc: u64, input: u64) u64 {
    return rotl(u64, acc +% (input *% prime_2), 31) *% prime_1;
}

fn xxh64MergeRound(acc: u64, val: u64) u64 {
    return ((acc ^ xxh64Round(0, val)) *% prime_1) +% prime_4;
}

fn finalize(h64: u64, input: []const u8) u64 {
    var hash = h64;
    var cursor = input.ptr;
    var len = input.len;
    while (len >= 8) {
        const k1 = xxh64Round(0, readIntLittle(u64, cursor[0..8]));
        cursor += 8;
        hash ^= k1;
        hash = rotl(u64, hash, 27) *% prime_1 +% prime_4;
        len -= 8;
    }
    if (len >= 4) {
        hash ^= @as(u64, readIntLittle(u32, cursor[0..4])) *% prime_1;
        cursor += 4;
        hash = rotl(u64, hash, 23) *% prime_2 +% prime_3;
        len -= 4;
    }
    while (len > 0) {
        hash ^= @as(u64, cursor[0]) *% prime_5;
        cursor += 1;
        hash = rotl(u64, hash, 11) *% prime_1;
        len -= 1;
    }
    return avalanche(hash);
}

fn avalanche(hash: u64) u64 {
    var res = hash;
    res ^= res >> 33;
    res *%= prime_2;
    res ^= res >> 29;
    res *%= prime_3;
    res ^= res >> 32;
    return res;
}

test "correct output" {
    try std.testing.expect(xxh64("", 0) == 0xef46db3751d8e999);
    try std.testing.expect(xxh64("a", 0) == 0xd24ec4f1a98c6e5b);
    try std.testing.expect(xxh64("ab", 0) == 0x65f708ca92d04a61);
    try std.testing.expect(xxh64("abc", 0) == 0x44bc2cf5ad770999);
    try std.testing.expect(xxh64("abcd", 0) == 0xde0327b0d25d92cc);
    try std.testing.expect(xxh64("abcde", 0) == 0x07e3670c0c8dc7eb);
    try std.testing.expect(xxh64("abcdef", 0) == 0xfa8afd82c423144d);
    try std.testing.expect(xxh64("abcdefg", 0) == 0x1860940e2902822d);
    try std.testing.expect(xxh64("abcdefgh", 0) == 0x3ad351775b4634b7);
    try std.testing.expect(xxh64("abcdefghi", 0) == 0x27f1a34fdbb95e13);
    try std.testing.expect(xxh64("abcdefghij", 0) == 0xd6287a1de5498bb2);
    try std.testing.expect(xxh64("abcdefghijklmnopqrstuvwxyz012345", 0) == 0xbf2cd639b4143b80);
    try std.testing.expect(xxh64("abcdefghijklmnopqrstuvwxyz0123456789", 0) == 0x64f23ecf1609b766);
    try std.testing.expect(xxh64("Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum.", 0) == 0xc5a8b11443765630);
}
