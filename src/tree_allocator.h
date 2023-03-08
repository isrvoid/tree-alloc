#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Fast and deterministic small object allocator.
// mark() and worst case clear() is O(log n)
// The idea is to be fast at the cost of power-of-2 alignment and allocation size.
// This has downsides:
//   - inefficient space usage
//   - fragmentation
// Currenty largest objects are limited to 32 blocks.
// Intended for high turnover and many small objects of varying sizes.
// Sizes above block_size*32 need to be handled by another allocator.

#define TRAL_MARK_MAX_BLOCKS 32

typedef struct {
    void* buf;
    uint32_t num_leaves;
    uint32_t tree_stride;
    uint32_t row_offsets[6];
    uint8_t num_top_branches; // [2, 32]
    uint8_t tree_height;
} tral_member_t;

uint32_t tral_required_member_buffer_size(size_t min_blocks);
void tral_init_member(tral_member_t*, size_t min_blocks, void* buf);
size_t tral_num_blocks(const tral_member_t*);

bool tral_mark(tral_member_t*, uint32_t num_blocks, uint32_t* start_block_out);
// clear() expects num_blocks passed to mark(), otherwise the behavior is undefined
void tral_clear(tral_member_t*, uint32_t start_block, uint32_t num_blocks);

void tral_debug_print(const tral_member_t*);
