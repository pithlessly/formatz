const std = @import("std");
const Allocator = std.mem.Allocator;

fn parseUint(comptime Ty: type, digits: []const u8) error{Invalid}!Ty {
    var res: Ty = 0;
    for (digits) |b| {
        const val = b -% '0';
        if (val >= 10) return error.Invalid;
        if (@mulWithOverflow(Ty, res, 10, &res)) return error.Invalid;
        if (@addWithOverflow(Ty, res, val, &res)) return error.Invalid;
    }
    return res;
}

fn expectOpt(aopt: ?[]const u8, b: []const u8) bool {
    return if (aopt) |a| std.mem.eql(u8, a, b) else false;
}

pub const Image = struct {
    width: u32,
    height: u32,
    pixels: [][4]u8,
};

fn decodePpm255(alloc: Allocator, input: []const u8) error{ OutOfMemory, Invalid }!Image {
    // this ignores the difference between, so it's more permissive than the spec
    var tokens = std.mem.tokenize(u8, input, " \n");

    if (!expectOpt(tokens.next(), "P6")) return error.Invalid;
    var width = if (tokens.next()) |tok| try parseUint(u32, tok) else return error.Invalid;
    var height = if (tokens.next()) |tok| try parseUint(u32, tok) else return error.Invalid;
    if (!expectOpt(tokens.next(), "255")) return error.Invalid;

    var px_size: u32 = undefined;
    if (@mulWithOverflow(u32, width, height, &px_size)) return error.Invalid;
    if (@mulWithOverflow(u32, px_size, 3, &px_size)) return error.Invalid;

    // we can't use `tokens.rest()`, since that seeks to the start of a "token",
    // which will skip any leading 0x0a or 0x20 bytes in the pixel data
    const px_data = input[tokens.index + 1 ..];
    if (px_data.len != px_size) return error.Invalid;

    const pixels = try alloc.alloc([4]u8, width * height);
    // errdefer pixels.deinit(); (not needed; no errors are possible)
    var i: usize = 0;
    while (i < width * height) : (i += 1) {
        var px = px_data[i * 3 ..][0..3];
        const r = px[0];
        const g = px[1];
        const b = px[2];
        const a = 0;
        pixels[i] = .{ r, g, b, a };
    }

    return Image{
        .width = width,
        .height = height,
        .pixels = pixels,
    };
}

pub const MethodReport = struct {
    fit_1byte: u32,
    fit_2byte: u32,
    fallback: u32,

    pub fn summarizeSize(self: MethodReport) u32 {
        return self.fit_1byte + self.fit_2byte * 2 + self.fallback * 5;
    }
};

pub const Report = struct {
    with_perfect_sub: MethodReport,
    with_imperfect_sub: MethodReport,
    with_xor: MethodReport,
    with_xor_fast: MethodReport,
};

const Fit = enum {
    one,
    two,
    fallback,

    const ONE_MASK = ~@as(u32, 0x00_03_03_03);
    const TWO_MASK = ~@as(u32, 0x00_0f_1f_0f);
};

fn reportMethod(img: Image, comptime diffFn: fn ([4]u8, [4]u8) Fit) MethodReport {
    var mr = MethodReport{ .fit_1byte = 0, .fit_2byte = 0, .fallback = 0 };
    var last_pixel = [4]u8{ 0, 0, 0, 0 };
    for (img.pixels) |px| {
        switch (diffFn(last_pixel, px)) {
            .one => mr.fit_1byte += 1,
            .two => mr.fit_2byte += 1,
            .fallback => mr.fallback += 1,
        }
        last_pixel = px;
    }
    return mr;
}

fn perfectSubDiff(a: [4]u8, b: [4]u8) Fit {
    const dr = a[0] -% b[0];
    const dg = a[1] -% b[1];
    const db = a[2] -% b[2];
    if (dr +% 2 < 4 and dg +% 2 < 4 and db +% 2 < 4)
        return .one
    else if (dr +% 8 < 16 and dg +% 16 < 32 and db +% 8 < 16)
        return .two
    else
        return .fallback;
}

fn imperfectSubDiff(a: [4]u8, b: [4]u8) Fit {
    const delta = @bitCast(u32, a) -% @bitCast(u32, b);
    if ((delta +% 0x00_02_02_02) & Fit.ONE_MASK == 0)
        return .one
    else if ((delta +% 0x00_08_10_08) & Fit.TWO_MASK == 0)
        return .two
    else
        return .fallback;
}

fn xorDiff(a: [4]u8, b: [4]u8) Fit {
    const dr = a[0] ^ b[0];
    const dg = a[1] ^ b[1];
    const db = a[2] ^ b[2];
    if (dr < 4 and dg < 4 and db < 4)
        return .one
    else if (dr < 16 and dg < 32 and db < 16)
        return .two
    else
        return .fallback;
}

fn xorDiffFast(a: [4]u8, b: [4]u8) Fit {
    const delta = @bitCast(u32, a) ^ @bitCast(u32, b);
    // std.log.debug("{x:0>8}", .{delta});
    if (delta & Fit.ONE_MASK == 0)
        return .one
    else if (delta & Fit.TWO_MASK == 0)
        return .two
    else
        return .fallback;
}

pub fn report(alloc: Allocator, input: []const u8) !Report {
    const img = try decodePpm255(alloc, input);
    return Report{
        .with_perfect_sub = reportMethod(img, perfectSubDiff),
        .with_imperfect_sub = reportMethod(img, imperfectSubDiff),
        .with_xor = reportMethod(img, xorDiff),
        .with_xor_fast = reportMethod(img, xorDiffFast),
    };
}
