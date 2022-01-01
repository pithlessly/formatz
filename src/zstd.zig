const std = @import("std");
const Allocator = std.mem.Allocator;

const xxh64 = @import("xxhash.zig").xxh64;

const log = std.log.scoped(.zstd);

pub fn Error(comptime Reader: type) type {
    return Reader.Error || error{ BadChecksum, BadMagicNumber, InvalidFormat, EndOfStream, OutOfMemory };
}

pub const OutputBuf = *std.ArrayList(u8);

pub fn decode(
    reader: anytype,
    output: OutputBuf,
    scratch_alloc: Allocator,
) Error(@TypeOf(reader))!void {
    while (try decodeMagicNumber(reader)) |frame_type| {
        switch (frame_type) {
            .skippable => {
                // Frame_Size
                const size = try reader.readIntLittle(u32);
                log.debug("skipping frame of {} bytes", .{size});
                // TODO: This has to explicitly read & discard the skipped bytes.
                // It might be better to use a seekable stream to represent this.
                try reader.skipBytes(size, .{});
            },

            .zstd => {
                const frame = try decodeFrameHeader(reader);
                // don't use the output buffer's allocator for this,
                // because it could be an arena allocator, in which case
                // we would break the FIFO allocation pattern that makes
                // it possible to avoid most copies
                const window = try scratch_alloc.alloc(u8, frame.window_size);
                defer scratch_alloc.free(window);
                log.debug("decoded frame: {}", .{frame});
                const starting_length = output.items.len;
                while (try decodeBlock(reader, frame, output, window, scratch_alloc)) {}
                if (frame.has_checksum) {
                    // all bytes of the output added since the start of the frame
                    const decodedData = output.items[starting_length..];
                    const declaredChecksum = try reader.readIntLittle(u32);
                    const computedChecksum = @truncate(u32, xxh64(decodedData, 0));
                    if (declaredChecksum != computedChecksum)
                        return error.BadChecksum;
                }
            },
        }
    }
}

const FrameType = enum { zstd, skippable };

fn decodeMagicNumber(reader: anytype) !?FrameType {
    // Magic_Number
    var magic_bytes: [4]u8 = undefined;
    switch (try reader.readAll(&magic_bytes)) {
        0 => return null,
        4 => {},
        else => return error.EndOfStream,
    }
    switch (std.mem.readIntLittle(u32, &magic_bytes)) {
        0xfd2fb528 => return .zstd,
        0x184d2a50...0x184d2a5f => return .skippable,
        else => return error.BadMagicNumber,
    }
}

const FrameHeaderInfo = struct {
    content_size: usize,
    window_size: usize,
    content_size_known: bool,
    single_segment: bool,
    has_checksum: bool,
    dict_id: u32,
};

// Check the magic number and decode the frame header
fn decodeFrameHeader(reader: anytype) !FrameHeaderInfo {
    // Frame_Header_Descriptor
    const frame_desc = try reader.readByte();
    // DID_Field_Size
    const dict_id_size = switch (@truncate(u2, frame_desc)) {
        0 => @as(usize, 0),
        1 => 1,
        2 => 2,
        3 => 4,
    };
    // Content_Checksum_flag
    const has_checksum = @truncate(u1, frame_desc >> 2) == 1;
    // Reserved_bit
    if (@truncate(u1, frame_desc >> 3) != 0) return error.InvalidFormat;
    // Unused_bit
    _ = @truncate(u1, frame_desc >> 4);
    // Single_Segment_flag
    const single_segment = @truncate(u1, frame_desc >> 5) == 1;
    // FCS_Field_Size
    const content_size_size = switch (@truncate(u2, frame_desc >> 6)) {
        0 => @as(usize, @boolToInt(single_segment)),
        1 => 2,
        2 => 4,
        3 => 8,
    };

    // Window_Size
    var window_size: usize = undefined;
    if (!single_segment) {
        // Window_Descriptor
        const win_desc = try reader.readByte();
        const mantissa = @truncate(u3, win_desc);
        const base: u64 = @as(u64, 1) << (10 + @intCast(u6, win_desc >> 3));
        const size: u64 = base + (base >> 3) * mantissa;
        window_size = std.math.cast(usize, size) catch |e| switch (e) {
            error.Overflow => return error.OutOfMemory,
        };
    }

    // Dictionary_ID
    const dict_id = try reader.readVarInt(u32, .Little, dict_id_size);

    // Frame_Content_Size
    var content_size_u64 = try reader.readVarInt(u64, .Little, content_size_size);
    if (content_size_size == 2) content_size_u64 += 256;
    const content_size = std.math.cast(usize, content_size_u64) catch |e| switch (e) {
        error.Overflow => return error.OutOfMemory,
    };
    if (single_segment) window_size = content_size;

    return FrameHeaderInfo{
        .content_size = content_size,
        .window_size = if (single_segment) content_size else window_size,
        .content_size_known = content_size_size != 0,
        .single_segment = single_segment,
        .has_checksum = has_checksum,
        .dict_id = dict_id,
    };
}

const BlockHeader = struct {
    last_block: bool, // Last_Block
    block_type: BlockType, // Block_Type
    block_size: u21, // Block_Size

    const BlockType = enum(u2) {
        raw = 0, // Raw_Block
        rle = 1, // RLE_Block
        comp = 2, // Compressed_Block
        res = 3, // Reserved_Block
    };

    fn unpack(int: u24) BlockHeader {
        return .{
            .last_block = @truncate(u1, int) == 1,
            .block_type = @intToEnum(BlockType, @truncate(u2, int >> 1)),
            .block_size = @intCast(u21, int >> 3),
        };
    }
};

fn decodeBlock(
    reader: anytype,
    frame: FrameHeaderInfo,
    output: OutputBuf,
    window: []u8,
    scratch_alloc: Allocator,
) !bool {
    std.debug.assert(window.len == frame.window_size);
    const header = BlockHeader.unpack(try reader.readIntLittle(u24));
    // Block_Maximum_Size
    // TODO: perhaps precompute and save as a field in `FrameHeaderInfo` to save a comparison?
    if (header.block_size > window.len or header.block_size > (1 << 17))
        return error.InvalidFormat; // block is too large
    log.debug("got block: {}", .{header});
    switch (header.block_type) {
        .raw => try readBytesToArrayList(reader, header.block_size, output),
        .rle => try output.appendNTimes(try reader.readByte(), header.block_size),
        .comp => {
            // NOTE: while the parameter to this function is called the "window" and its allocation
            // is the size of the window, we don't actually use it the same way the window is used
            // according to the ZSTD spec. Instead, this is just used to pre-read the content of the
            // compressed block, because the reader API wouldn't be appropriate for it.
            const block = window[0..header.block_size];
            try reader.readNoEof(block);
            try decompressCompressedBlockContent(block, output, scratch_alloc);
        },
        .res => return error.InvalidFormat,
    }
    return !header.last_block;
}

fn readBytesToArrayList(
    reader: anytype,
    n: usize,
    output: OutputBuf,
) (@TypeOf(reader).Error || error{ OutOfMemory, EndOfStream })!void {
    try output.ensureUnusedCapacity(n);
    try reader.readNoEof(output.unusedCapacitySlice()[0..n]);
    output.items.len += n;
}

fn decompressCompressedBlockContent(block: []const u8, output: OutputBuf, scratch_alloc: Allocator) !void {
    var literals_data_len: usize = undefined;
    const literals_data = try decodeLiteralsSection(block, &literals_data_len, scratch_alloc);
    defer scratch_alloc.free(literals_data);
    _ = literals_data;
    _ = block;
    _ = output;
    unreachable; // TODO
}

fn decodeLiteralsSection(
    block: []const u8,
    section_size_out: *usize,
    scratch_alloc: Allocator,
) ![]u8 {
    if (block.len < 1) return error.InvalidFormat;
    // Literals_Section_Header
    const literals_section_header_first_byte = block[0];
    // Literals_Block_Type
    const ty = @intToEnum(enum(u2) {
        raw = 0, // Raw_Literals_Block
        rle = 1, // RLE_Literals_Block
        compressed = 2, // Compressed_Literals_Block,
        treeless = 3, // Treeless_Literals_Block,
    }, @truncate(u2, literals_section_header_first_byte));

    var regenerated_size: u20 = undefined; // Regenerated_Size
    var compressed_size: u18 = undefined; // Compressed_Size
    var num_streams: enum(u3) { one, four } = undefined;

    // Size_Format
    const size_format = @truncate(u2, literals_section_header_first_byte >> 2);

    var offset: usize = 0;

    // decode Literals_Section_Header
    switch (ty) {
        .raw, .rle => switch (size_format) {
            0b00, 0b10 => {
                regenerated_size = literals_section_header_first_byte >> 3;
                offset += 1;
            },
            0b01 => {
                if (block.len < 2) return error.InvalidFormat;
                regenerated_size = @intCast(u12, std.mem.readIntLittle(u16, block[0..2]) >> 4);
                offset += 2;
            },
            0b11 => {
                if (block.len < 3) return error.InvalidFormat;
                regenerated_size = @intCast(u20, std.mem.readIntLittle(u24, block[0..3]) >> 4);
                offset += 3;
            },
        },

        .compressed, .treeless => switch (size_format) {
            0b00 => {
                num_streams = .one;
                if (block.len < 3) return error.InvalidFormat;
                const literals_section_header = std.mem.readIntLittle(u24, block[0..3]);
                regenerated_size = @truncate(u10, literals_section_header >> 4);
                compressed_size = @truncate(u10, literals_section_header >> (4 + 10));
                offset += 3;
            },
            0b01 => {
                num_streams = .four;
                if (block.len < 3) return error.InvalidFormat;
                const literals_section_header = std.mem.readIntLittle(u24, block[0..3]);
                regenerated_size = @truncate(u10, literals_section_header >> 4);
                compressed_size = @truncate(u10, literals_section_header >> (4 + 10));
                offset += 3;
            },
            0b10 => {
                num_streams = .four;
                if (block.len < 4) return error.InvalidFormat;
                const literals_section_header = std.mem.readIntLittle(u32, block[0..4]);
                regenerated_size = @truncate(u14, literals_section_header >> 4);
                compressed_size = @truncate(u14, literals_section_header >> (4 + 14));
                offset += 4;
            },
            0b11 => {
                num_streams = .four;
                if (block.len < 5) return error.InvalidFormat;
                const literals_section_header = std.mem.readIntLittle(u40, block[0..5]);
                regenerated_size = @truncate(u18, literals_section_header >> 4);
                compressed_size = @truncate(u18, literals_section_header >> (4 + 18));
                offset += 5;
            },
        },
    }

    const literals_data = try scratch_alloc.alloc(u8, regenerated_size);
    errdefer scratch_alloc.free(literals_data);

    switch (ty) {
        .raw => {
            if (block[offset..].len < regenerated_size) return error.InvalidFormat;
            std.mem.copy(u8, literals_data, block[offset..][0..regenerated_size]);
            offset += regenerated_size;
        },
        .rle => {
            if (block[offset..].len < 1) return error.InvalidFormat;
            std.mem.set(u8, literals_data, block[offset]);
            offset += 1;
        },
        .compressed, .treeless => {
            // Total_Streams_Size
            var total_streams_size: usize = compressed_size;
            // Huffman_Tree_Description
            if (ty == .compressed) {
                // Huffman_Tree_Description_Size
                const huffman_tree_description_size = try decodeNewHuffmanTree(block[offset..]);
                offset += huffman_tree_description_size;
                total_streams_size -= huffman_tree_description_size;
                offset += try decodeNewHuffmanTree(block[offset..]);
            }
            switch (num_streams) {
                .one => unreachable, // TODO
                .four => {
                    const jump_table = try decodeJumpTable(block[offset..], total_streams_size);
                    offset += 6;
                    _ = jump_table;
                    unreachable; // TODO
                },
            }
        },
    }

    section_size_out.* = offset;
    return literals_data;
}

fn decodeNewHuffmanTree(stream: []const u8) !usize {
    var offset: usize = 0;
    _ = stream;
    _ = offset;
    unreachable; // TODO
}

fn decodeJumpTable(stream: []const u8, total_streams_size: usize) ![4]u16 {
    if (stream.len < 6) return error.InvalidFormat;
    const stream1_size = std.mem.readIntLittle(u16, stream[0..2]);
    const stream2_size = std.mem.readIntLittle(u16, stream[2..4]);
    const stream3_size = std.mem.readIntLittle(u16, stream[4..6]);
    const stream123_size =
        @as(usize, stream1_size) + @as(usize, stream2_size) + @as(usize, stream3_size);

    const stream4_size_usize = std.math.sub(
        usize,
        total_streams_size - 6,
        stream123_size,
    ) catch return error.InvalidFormat;

    return [4]u16{
        stream1_size,
        stream2_size,
        stream3_size,
        std.math.cast(u16, stream4_size_usize) catch return error.InvalidFormat,
    };
}
