const std = @import("std");
const print = std.debug.print;
const c = @cImport({ @cInclude("tree_allocator.h"); });
const test_alloc = @import("test.zig");

pub fn main() void {
    print("warmup...\n", .{});
    print("Blocks: ns/call\n", .{});
    _ = fuzzy_benchmark(1e6);

    for (10..27) |i|
        runBenchmark(@as(usize, 1) << @intCast(u5, i));
}

fn runBenchmark(num_blocks: usize) void {
    if (num_blocks < 1 << 20) {
        print("{d:4} K:", .{num_blocks >> 10});
    } else
        print("{d:4} M:", .{num_blocks >> 20});
    const stats = fuzzy_benchmark(num_blocks);
    const ops = stats.mark + stats.clear;
    const ns_per_op = 1e3 * @intToFloat(f64, stats.dur_us) / @intToFloat(f64, ops);
    print("{d:8.1}\n",  .{ns_per_op});
}

// the bnechmark includes overheads: random numbers, bookkeeping tally
fn fuzzy_benchmark(min_blocks: usize) Stats {
    var stats = Stats{};
    const clear_search_len = c.TRAL_MARK_MAX_BLOCKS / 2;
    var gen = test_alloc.RandomOpGen.init();
    var pa = std.heap.page_allocator;
    var tw = test_alloc.TralWrapper.init(pa, min_blocks);
    defer tw.deinit();
    var tally = pa.alloc(u8, tw.num_blocks + clear_search_len) catch @panic("alloc() fail");
    std.mem.set(u8, tally, 0);
    defer pa.free(tally);

    var max_adr: u32 = 0;
    const start_time = std.time.microTimestamp();
    while (true) {
        if (gen.randOp()) |len| {
            var adr: u32 = undefined;
            if (!c.tral_mark(&tw.m, len, &adr))
                break;

            tally[adr] = len;
            max_adr = @max(adr, max_adr);
            stats.mark += 1;
        } else { // op: clear()
            const search_start = gen.randIndex(max_adr);
            const search_end = search_start + clear_search_len;
            for (search_start..search_end) |i| {
                const len = tally[i];
                if (len != 0) {
                    c.tral_clear(&tw.m, @truncate(u32, i), len);
                    tally[i] = 0;
                    stats.clear += 1;
                    break;
                }
            }
        }
    }
    stats.dur_us = @bitCast(u64, std.time.microTimestamp() - start_time);
    return stats;
}

const Stats = struct {
    mark: u64 = 0,
    clear: u64 = 0,
    dur_us: u64 = undefined,
};
