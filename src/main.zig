const std = @import("std");
const add = std.math.add;
const mul = std.math.mul;
const Allocator = std.mem.Allocator;

const qoi = @import("qoi.zig");
const zstd = @import("zstd.zig");
const dstat = @import("dstat.zig");

const input_file_max_size = 1024 * 1024 * 1024; // 1 GiB

fn readFile(alloc: Allocator, path: []const u8) ![]align(4) u8 {
    return std.fs.cwd().readFileAllocOptions(
        alloc,
        path,
        input_file_max_size,
        null,
        4,
        null,
    );
}

fn encodeDigits(
    number: u32,
    out_last_digit: [*]u8,
) void {
    var n = number;
    var p = out_last_digit;
    while (true) {
        p[0] = '0' + @intCast(u8, n % 10);
        p -= 1;
        n /= 10;
        if (n == 0) break;
    }
}

// remove every fourth byte from `px_data`
fn removeAlpha(px_data: []u8) void {
    std.debug.assert(px_data.len % 4 == 0);
    var p1 = px_data.ptr;
    var p2 = px_data.ptr;
    var end = px_data.ptr + px_data.len;
    while (p1 != end) {
        p2[0..4].* = p1[0..4].*;
        p1 += 4;
        p2 += 3;
    }
}

fn decodeQoi(
    alloc: Allocator,
    input: []align(4) const u8,
) ![]u8 {
    const metadata = try qoi.Metadata.compute(input);

    // decode QOI and rewrite to PPM.
    // we place enough padding in the PPM header to ensure that:
    // - the pixel data is 4-byte aligned;
    // - the width and height can be any 32-bit values (which is a little excessive)
    const header_size = 32;
    const header_words = @divExact(header_size, 4);
    const res = try alloc.alloc(u32, header_words + metadata.pixels);

    const header = std.mem.sliceAsBytes(res[0..header_words]);
    std.mem.copy(u8, header, "P6\n" ++ " " ** (3 + 10 + 1 + 10 + 1) ++ "255\n");
    encodeDigits(metadata.width, header.ptr + 15);
    encodeDigits(metadata.height, header.ptr + 26);
    try qoi.decode(input, res[header_words..]);

    var res_bytes = std.mem.sliceAsBytes(res);
    removeAlpha(res_bytes[header_size..]);
    res_bytes.len -= metadata.pixels;
    return res_bytes;
}

fn decodeZstd(
    alloc: Allocator,
    input: []const u8,
) ![]u8 {
    var scratch = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = scratch.deinit();

    const reader = std.io.fixedBufferStream(input).reader();
    var out = std.ArrayList(u8).init(alloc);
    errdefer out.deinit();

    try zstd.decode(reader, &out, scratch.allocator());
    return out.toOwnedSlice();
}

fn decode(
    alloc: Allocator,
    in_file: []const u8,
    out_file: []const u8,
    comptime decodeFn: anytype,
) !void {
    const in_data = try readFile(alloc, in_file);
    const out_data = try decodeFn(alloc, in_data);
    try std.fs.cwd().writeFile(out_file, out_data);
}

fn deltaStat(alloc: Allocator, in_file: []const u8) !void {
    const in_data = try readFile(alloc, in_file);
    const report = try dstat.report(alloc, in_data);
    const stdout = std.io.getStdOut().writer();
    inline for (std.meta.fields(@TypeOf(report))) |field|
        if (field.field_type == dstat.MethodReport) {
            const mr = @field(report, field.name);
            try stdout.print("{s:>20}\t{}\t{}\t{}\n", .{
                field.name,
                mr.fit_1byte,
                mr.fit_2byte,
                mr.fallback,
            });
        };
}

fn usage(exe_name: []const u8) noreturn {
    const stderr = std.io.getStdErr().writer();
    stderr.print(
        \\Usage: {s} [format] [infile] [outfile]
        \\Available formats:
        \\  qoi    Convert QOI to PPM
        \\  zstd   Decode zstd files with no dictionary
        \\Additional commands:
        \\  Δstat  Report information about differences in pixels in a PPM file
        \\
    , .{exe_name}) catch {};
    std.process.exit(1);
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var args = std.process.args();
    defer args.deinit();

    const exe_name = try args.next(alloc) orelse usage("formatz");
    const format = try args.next(alloc) orelse usage(exe_name);
    const in_file = try args.next(alloc) orelse usage(exe_name);

    if (std.mem.eql(u8, format, "Δstat")) {
        try deltaStat(alloc, in_file);
    } else {
        const out_file = try args.next(alloc) orelse usage(exe_name);

        if (std.mem.eql(u8, format, "qoi")) {
            try decode(alloc, in_file, out_file, decodeQoi);
        } else if (std.mem.eql(u8, format, "zstd")) {
            try decode(alloc, in_file, out_file, decodeZstd);
        } else usage(exe_name);
    }
}

test {
    std.testing.refAllDecls(@This());
}
