const std = @import("std");
const mem = std.mem;
const expect = std.testing.expect;
const ceilPow2 = std.math.ceilPowerOfTwoPromote;
const c = @cImport({ @cInclude("tree_allocator.h"); });

const run_long_tests = false;

var common_buf: [0x1000]u8 = undefined;

fn initMember(min_blocks: usize) c.tral_member_t {
    std.debug.assert(common_buf.len >= c.tral_required_member_buffer_size(min_blocks));
    var res: c.tral_member_t = undefined;
    c.tral_init_member(&res, min_blocks, &common_buf);
    return res;
}

test "init" {
    const min_blocks = 8;
    const buffer_size = c.tral_required_member_buffer_size(min_blocks);
    try expect(buffer_size > 0);
    if (buffer_size > common_buf.len) @panic("");
    var m: c.tral_member_t = undefined;
    c.tral_init_member(&m, min_blocks, &common_buf);
    try expect(c.tral_num_blocks(&m) >= min_blocks);
}

test "mark" {
    var m = initMember(2);
    var adr: u32 = undefined;
    try expect(c.tral_mark(&m, 1, &adr));
    try expect(0 == adr);
    try expect(c.tral_mark(&m, 1, &adr));
    try expect(1 == adr);
}

test "clear" {
    var m = initMember(1);
    var adr: u32 = undefined;
    _ = c.tral_mark(&m, 1, &adr);
    c.tral_clear(&m, adr, 1);
    // cleared block is reused
    try expect(c.tral_mark(&m, 1, &adr));
    try expect(0 == adr);
}

test "mark larger size" {
    var m = initMember(4);
    var adr: u32 = undefined;
    try expect(c.tral_mark(&m, 2, &adr));
    try expect(0 == adr);
    try expect(c.tral_mark(&m, 2, &adr));
    try expect(2 == adr);
}

test "mark increasing size" {
    var m = initMember(3);
    var adr: u32 = undefined;
    _ = c.tral_mark(&m, 1, &adr);
    try expect(c.tral_mark(&m, 2, &adr));
    try expect(2 == adr);
}

test "mark decreasing size" {
    var m = initMember(3);
    var adr: u32 = undefined;
    _ = c.tral_mark(&m, 2, &adr);
    try expect(c.tral_mark(&m, 1, &adr));
    try expect(2 == adr);
}

test "clear previous" {
    var m = initMember(3);
    var adr: u32 = undefined;
    _ = c.tral_mark(&m, 1, &adr);
    _ = c.tral_mark(&m, 1, &adr);
    c.tral_clear(&m, 0, 1);
    _ = c.tral_mark(&m, 1, &adr);
    try expect(c.tral_mark(&m, 1, &adr));
    try expect(2 == adr);
}

const num_blocks_test_list: []u32 = res: {
    const end_threshold = if (run_long_tests) 50e6 else 25e3;
    const phi = std.math.phi;
    var buf: [32]u32 = undefined;
    var len = 0;
    var n: f32 = phi * 10;
    while (n < end_threshold) : (n *= phi) {
        buf[len] = @floatToInt(u32, n);
        len += 1;
    }
    break :res buf[0..len];
};

test "full" {
    var m = initMember(1234);
    var adr: u32 = undefined;
    var num_free_blocks: usize = c.tral_num_blocks(&m);
    while (num_free_blocks > 0) : (num_free_blocks -= 1)
        try expect(c.tral_mark(&m, 1, &adr));
    try expect(!c.tral_mark(&m, 1, &adr));
    // mark succeeds again after clearing
    c.tral_clear(&m, 3, 1);
    try expect(c.tral_mark(&m, 1, &adr));
    try expect(3 == adr);
}

test "pow2 alignment" {
    var m = initMember(0x1000);
    var adr: u32 = undefined;
    var size: u8 = c.TRAL_MARK_MAX_BLOCKS;
    var end_i: u32 = 0;
    while (size > 0) : (size -= 1) {
        try expect(c.tral_mark(&m, size, &adr));
        try expect(end_i == adr);
        end_i += ceilPow2(u8, size);
    }
}

test "capacity" {
    var m = initMember(12345);
    var adr: u32 = undefined;
    var num_blocks_remaining: usize = c.tral_num_blocks(&m);
    const max_blocks = c.TRAL_MARK_MAX_BLOCKS;
    // fill with different sizes until full, keeping track of capacity
    var i: u32 = 0;
    while (true) : (i += 1) {
        const n = i % max_blocks + 1;
        if (!c.tral_mark(&m, n, &adr)) break;
        num_blocks_remaining -= ceilPow2(u8, @intCast(u8, n));
    }
    // fill any remaining space with size 1
    while (num_blocks_remaining > 0) : (num_blocks_remaining -= 1)
        try expect(c.tral_mark(&m, 1, &adr));
    try expect(!c.tral_mark(&m, 1, &adr));
}

test "member buffer size" {
    const min_block_count = 123;
    const req_buf_len = c.tral_required_member_buffer_size(min_block_count);
    const sentinel = common_buf[req_buf_len..][0..4];
    const sentinel_val: u32 = 0xcafe7e57;
    mem.copy(u8, sentinel, &mem.toBytes(sentinel_val));
    var m = initMember(min_block_count);
    var adr: u32 = undefined;
    var i: u32 = 0;
    while (c.tral_mark(&m, i % 8 + 1, &adr)) : (i += 1) {} // fill with different sizes until it fails
    while (c.tral_mark(&m, 1, &adr)) {} // fill any remaining blocks
    // sentinel past the claimed buffer length is untouched
    try expect(sentinel_val == mem.bytesToValue(u32, sentinel));
}

test "end boundary" {
    for (num_blocks_test_list) |n|
        try test_end_boundary(n);
}

test "max block count end boundary" {
    // uses > 600 MB and takes tens of seconds on a desktop machine (debug build)
    if (run_long_tests)
        try test_end_boundary(1 << 32);
}

fn test_end_boundary(min_blocks: usize) !void {
    var tw = TralWrapper.init(std.heap.page_allocator, min_blocks);
    defer tw.deinit();
    const max_mark_len = c.TRAL_MARK_MAX_BLOCKS;
    const num_blocks = c.tral_num_blocks(&tw.m);
    var rem = num_blocks;
    var adr: u32 = undefined;
    // fill with largest size
    while (rem > 0) : (rem -= max_mark_len)
        try expect(c.tral_mark(&tw.m, max_mark_len, &adr));
    try expect(adr == num_blocks - max_mark_len);
    // nothing fits after that
    try expect(!c.tral_mark(&tw.m, max_mark_len, &adr));
    try expect(!c.tral_mark(&tw.m, 1, &adr));
    // successively replace last object with smaller ones
    var mark_len: u32 = max_mark_len;
    while (mark_len > 1) {
        c.tral_clear(&tw.m, adr, mark_len);
        mark_len /= 2;
        try expect(c.tral_mark(&tw.m, mark_len, &adr));
        try expect(c.tral_mark(&tw.m, mark_len, &adr));
        try expect(adr == num_blocks - mark_len);
        try expect(!c.tral_mark(&tw.m, mark_len, &adr));
    }
}

pub const TralWrapper = struct {
    allocator: mem.Allocator,
    m: c.tral_member_t,
    buf: []u8,
    num_blocks: usize,
    const Self = @This();

    pub fn init(allocator: mem.Allocator, min_blocks: usize) Self {
        const buf_len = c.tral_required_member_buffer_size(min_blocks);
        const buf = allocator.alloc(u8, buf_len) catch @panic("alloc() fail");
        var m: c.tral_member_t = undefined;
        c.tral_init_member(&m, min_blocks, buf.ptr);
        return Self{ .allocator = allocator, .m = m, .buf = buf, .num_blocks = c.tral_num_blocks(&m) };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.buf);
    }
};

test "fuzzy tests" {
    const num_fails = if (run_long_tests) 1e6 else 1e3;
    for (num_blocks_test_list) |n|
        try fuzzy_test(n, num_fails);
}

fn fuzzy_test(min_blocks: usize, num_fails_to_end: usize) !void {
    std.debug.assert(num_fails_to_end > 0);
    const clear_search_len = c.TRAL_MARK_MAX_BLOCKS / 2;
    var gen = RandomOpGen.init();
    var pa = std.heap.page_allocator;
    var tw = TralWrapper.init(pa, min_blocks);
    defer tw.deinit();
    var tally = pa.alloc(u8, tw.num_blocks + clear_search_len) catch @panic("alloc() fail");
    mem.set(u8, tally, 0);
    defer pa.free(tally);

    var num_fails: usize = 0;
    var capacity: usize = tw.num_blocks;
    var max_adr: u32 = 0;
    outer: while (num_fails < num_fails_to_end) {
        if (gen.randOp()) |len| {
            var adr: u32 = undefined;
            if (!c.tral_mark(&tw.m, len, &adr)) {
                num_fails += 1;
                continue;
            }
            try expect(0 == tally[adr]);
            tally[adr] = len;
            capacity -= ceilPow2(u8, len);
            max_adr = @max(adr, max_adr);
        } else { // op: clear()
            const search_start = gen.randIndex(max_adr);
            const search_end = search_start + clear_search_len;
            for (search_start..search_end) |i| {
                const len = tally[i];
                if (len != 0) {
                    c.tral_clear(&tw.m, @intCast(u32, i), len);
                    capacity += ceilPow2(u8, len);
                    tally[i] = 0;
                    continue :outer;
                }
            }
        }
    }
    // fill any remaining
    var adr: u32 = undefined;
    while (capacity > 0) : (capacity -= 1) {
        try expect(c.tral_mark(&tw.m, 1, &adr));
        try expect(0 == tally[adr]);
        tally[adr] = 1;
    }
    try expect(!c.tral_mark(&tw.m, 1, &adr));
    // check marked blocks
    var tally_block_count: usize = 0;
    var i: usize = 0;
    const end = tally.len - clear_search_len;
    try expect(0 != tally[0]);
    while (i < end) {
        const marked_len = ceilPow2(u8, tally[i]);
        tally_block_count += marked_len;
        // tally stores length at indices corresponding to start blocks, rest is 0
        for (i + 1 .. i + marked_len) |j|
            try expect(0 == tally[j]);
        i += marked_len;
    }
    try expect(tally_block_count == tw.num_blocks);
}

pub const RandomOpGen = struct {
    // the generator is buffered to reduce overhead during benchmark
    buf: [buf_len]u8 = undefined,
    read_i: u32 = buf_len,
    rng: std.rand.DefaultPrng,

    const buf_len = 0x1000;
    const mark_ratio_u8 = 157; // randOp() BlockCount/null ratio * 256
    const max_len_log2 = @log2(@intToFloat(f32, c.TRAL_MARK_MAX_BLOCKS));
    const limitRange = std.rand.limitRangeBiased;
    const Self = @This();

    pub fn init() Self {
        var rng = std.rand.DefaultPrng.init(@bitCast(u64, std.time.microTimestamp()));
        return Self{ .rng = rng };
    }

    pub fn randOp(self: *Self) ?u8 {
        if (self.read_i >= buf_len) {
            self.rng.fill(&self.buf);
            self.read_i = 0;
        }
        const rv = self.buf[self.read_i];
        self.read_i += 1;
        if (rv >= mark_ratio_u8) return null;

        const len_log2 = limitRange(u8, rv, max_len_log2 + 1);
        const len_pow2 = @as(u8, 1) << @intCast(u3, len_log2);
        return if (len_pow2 < 4) len_pow2 else len_pow2 - limitRange(u8, rv, len_pow2 / 2);
    }

    pub fn randIndex(self: *Self, max: u32) u32 {
        if (self.read_i + 4 > buf_len) {
            self.rng.fill(&self.buf);
            self.read_i = 0;
        }
        const rv = mem.bytesAsValue(u32, self.buf[self.read_i..][0..4]).*;
        self.read_i += 4;
        return limitRange(u32, rv, max + 1);
    }
};
