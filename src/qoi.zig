const std = @import("std");
const Vector = std.meta.Vector;

const InputBuf = []align(@alignOf(u32)) const u8;

pub const Metadata = struct {
    width: u32,
    height: u32,
    pixels: usize,
    channels: enum { rgb, rgba },
    colorspace: enum { srgb, linear },
    pixels_start: [*]const u8,
    pixels_end: [*]const u8,

    pub fn compute(input: InputBuf) error{Invalid}!Metadata {
        // length of header + end marker
        if (input.len < 22) return error.Invalid;
        // magic number
        if (std.mem.readIntBig(u32, input[0..4]) != 0x716f6966)
            return error.Invalid;
        const w = std.mem.readIntBig(u32, input[4..8]);
        const h = std.mem.readIntBig(u32, input[8..12]);
        // verify that this doesn't overflow
        const pixels = std.math.mul(usize, w, h) catch
            return error.Invalid;
        // check the last 8 bytes
        const end = input[input.len - 8 ..];
        if (std.mem.readIntBig(u64, end[0..8]) != 0x01)
            return error.Invalid;
        return Metadata{
            .width = w,
            .height = h,
            .pixels = pixels,
            .channels = switch (input[12]) {
                3 => .rgb,
                4 => .rgba,
                else => return error.Invalid,
            },
            .colorspace = switch (input[13]) {
                0 => .srgb,
                1 => .linear,
                else => return error.Invalid,
            },
            .pixels_start = input[14..].ptr,
            .pixels_end = end.ptr,
        };
    }
};

const Color = Vector(4, u8);

fn hash(col: Color) u6 {
    const r = col[0];
    const g = col[1];
    const b = col[2];
    const a = col[3];
    return @truncate(u6, (r *% 3) +% (g *% 5) +% (b *% 7) +% (a *% 11));
}

pub fn decode(input: InputBuf, output: []u32) error{ Invalid, OutputTooSmall }!void {
    const metadata = try Metadata.compute(input);
    const input_end = @ptrToInt(metadata.pixels_end);
    if (output.len < metadata.pixels)
        return error.OutputTooSmall;
    var prev_pixels = std.mem.zeroes([64]Vector(4, u8));
    var col: Vector(4, u8) = .{ 0, 0, 0, 255 };
    var ptr = metadata.pixels_start;
    var out: usize = 0;
    while (@ptrToInt(ptr) < input_end and out < output.len) {
        const byte = ptr[0];
        if (byte == 0xfe) {
            // QOI_OP_RGB
            col[0] = ptr[1];
            col[1] = ptr[2];
            col[2] = ptr[3];
            prev_pixels[hash(col)] = col;
            ptr += 4;
            output[out] = @bitCast(u32, col);
            out += 1;
        } else if (byte == 0xff) {
            // QOI_OP_RGBA
            col[0] = ptr[1];
            col[1] = ptr[2];
            col[2] = ptr[3];
            col[3] = ptr[4];
            prev_pixels[hash(col)] = col;
            ptr += 5;
            output[out] = @bitCast(u32, col);
            out += 1;
        } else switch (@intCast(u2, byte >> 6)) {
            0b00 => {
                // QOI_OP_INDEX
                col = prev_pixels[@truncate(u6, byte)];
                ptr += 1;
                output[out] = @bitCast(u32, col);
                out += 1;
            },
            0b01 => {
                // QOI_OP_DIFF
                col[0] +%= @as(u8, @truncate(u2, byte >> 4)) -% 2;
                col[1] +%= @as(u8, @truncate(u2, byte >> 2)) -% 2;
                col[2] +%= @as(u8, @truncate(u2, byte >> 0)) -% 2;
                prev_pixels[hash(col)] = col;
                ptr += 1;
                output[out] = @bitCast(u32, col);
                out += 1;
            },
            0b10 => {
                // QOI_OP_LUMA
                const more_deltas = ptr[1];
                const dg = @as(u8, @truncate(u6, byte)) -% 32;
                const dr = dg +% @truncate(u4, more_deltas >> 4) -% 8;
                const db = dg +% @truncate(u4, more_deltas >> 0) -% 8;
                col[0] +%= @bitCast(u8, dr);
                col[1] +%= @bitCast(u8, dg);
                col[2] +%= @bitCast(u8, db);
                prev_pixels[hash(col)] = col;
                ptr += 2;
                output[out] = @bitCast(u32, col);
                out += 1;
            },
            0b11 => {
                // QOI_OP_RUN
                const repetitions = @as(u8, @truncate(u6, byte)) + 1;
                if (out + repetitions > output.len)
                    return error.Invalid;
                ptr += 1;
                std.mem.set(u32, output[out..][0..repetitions], @bitCast(u32, col));
                out += repetitions;
            },
        }
    }
    if (@ptrToInt(ptr) != input_end)
        return error.Invalid;
    if (out != output.len)
        return error.Invalid;
}

test {
    std.testing.refAllDecls(@This());
}
