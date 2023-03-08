#include "tree_allocator.h"

#include <assert.h>
#include <string.h>

// Anything with 'leaves' in the name refers to the continuous block bitmap.
// A leaf is an uint32_t representing 32 blocks.
// Top tree node has at least 2 branches, other nodes have 32.
#define NUM_BRANCHES_LOG2 5
#define NUM_BRANCHES (1 << NUM_BRANCHES_LOG2)
#define BRANCH_INDEX_MASK (NUM_BRANCHES - 1)
#define NUM_TREES (NUM_BRANCHES_LOG2 + 1)
#define CEIL_LOG2_SMALL(x) ((x > 1) + (x > 2) + (x > 4) + (x > 8) + (x > 16))

// implementation assumes at least 32-bit ints
static_assert(sizeof 1 >= 4, "int size < 32-bit");
static_assert(TRAL_MARK_MAX_BLOCKS == 1 << NUM_BRANCHES_LOG2, "MARK_MAX_BLOCKS out of sync");

// The trees share leaves that are stored separately.
// Because of this, the trees are 1 shorter than a single tree would be.
static int treeHeight(size_t min_blocks) {
    int h = 1;
    uint32_t capacity = NUM_BRANCHES;
    for (; capacity; capacity <<= NUM_BRANCHES_LOG2)
        h += min_blocks > capacity;

    assert(h > 1);
    return h - 1;
}

static int numTopNodeBranches(size_t min_blocks) {
    const int h = treeHeight(min_blocks);
    const uint32_t num_top_branch_blocks = 1u << NUM_BRANCHES_LOG2 * h;
    return min_blocks / num_top_branch_blocks + !!(min_blocks % num_top_branch_blocks);
}

static uint32_t numLeaves(size_t min_blocks) {
    const uint32_t num_top_branches = numTopNodeBranches(min_blocks);
    const int h = treeHeight(min_blocks);
    return num_top_branches << NUM_BRANCHES_LOG2 * (h - 1);
}

static uint32_t numTreeNodes(size_t min_blocks) {
    const int h = treeHeight(min_blocks);
    uint32_t row_width = numTopNodeBranches(min_blocks);
    uint32_t res = 1; // top node
    for (int i = 1; i < h; ++i, row_width <<= NUM_BRANCHES_LOG2)
        res += row_width;
    return res;
}

static void rowOffsets(int num_top_branches, int tree_height, uint32_t* offsets_out) {
    offsets_out[0] = 0;
    uint32_t offset = 1;
    uint32_t row_width = num_top_branches;
    for (int row_i = 1; row_i < tree_height; ++row_i, offset += row_width, row_width <<= NUM_BRANCHES_LOG2)
        offsets_out[row_i] = offset;
}

static size_t checkMinBlocks(size_t min_blocks) {
    assert(min_blocks > 0 && min_blocks <= UINT64_C(1) << 32);
    const size_t lower_cap = NUM_BRANCHES * 2; // ensures tree height > 0
    return min_blocks < lower_cap ? lower_cap : min_blocks;
}

static uint32_t requiredBufferSize(uint32_t num_leaves, uint32_t num_tree_nodes) {
    return (num_leaves + num_tree_nodes * NUM_TREES) * 4;
}

uint32_t tral_required_member_buffer_size(size_t min_blocks) {
    min_blocks = checkMinBlocks(min_blocks);
    const uint32_t num_leaves = numLeaves(min_blocks);
    const uint32_t num_tree_nodes = numTreeNodes(min_blocks);
    return requiredBufferSize(num_leaves, num_tree_nodes);
}

static void initTopNodes(tral_member_t* m) {
    uint32_t* p = (uint32_t*)m->buf + m->num_leaves;
    uint32_t* const end = p + m->tree_stride * NUM_TREES;
    const uint32_t non_existent_marked = m->num_top_branches < NUM_BRANCHES ? ~((1u << m->num_top_branches) - 1) : 0;
    for (; p < end; p += m->tree_stride)
        *p = non_existent_marked;
}

void tral_init_member(tral_member_t* m, size_t min_blocks, void* buf) {
    min_blocks = checkMinBlocks(min_blocks);
    memset(m, 0, sizeof(tral_member_t));
    m->tree_height = treeHeight(min_blocks);
    m->num_top_branches = numTopNodeBranches(min_blocks);
    m->num_leaves = numLeaves(min_blocks);
    m->tree_stride = numTreeNodes(min_blocks);
    rowOffsets(m->num_top_branches, m->tree_height, m->row_offsets);
    const uint32_t buf_size = requiredBufferSize(m->num_leaves, m->tree_stride);
    memset(buf, 0, buf_size);
    m->buf = buf;
    initTopNodes(m);
}

size_t tral_num_blocks(const tral_member_t* m) {
    assert(sizeof(size_t) > 4 || m->num_leaves < 1 << (32 - NUM_BRANCHES_LOG2));
    return (size_t)m->num_leaves << NUM_BRANCHES_LOG2;
}

static inline int countTrailingZeros(uint32_t x) {
    x = x & -x;
    return !!(x & 0xffff0000) << 4 | !!(x & 0xff00ff00) << 3 | !!(x & 0xf0f0f0f0) << 2 | !!(x & 0xcccccccc) << 1 | !!(x & 0xaaaaaaaa);
}

static inline int indexOfFirstZero(uint32_t x) {
    return countTrailingZeros(~x);
}

static inline uint32_t leafWithSpaceIndex(const uint32_t* tree, const uint32_t* row_offsets, int tree_height) {
    uint32_t node_i = indexOfFirstZero(*tree);
    for (int i = 1; i < tree_height; ++i) {
        const uint32_t node = tree[row_offsets[i] + node_i];
        const int branch_i = indexOfFirstZero(node);
        node_i = (node_i << NUM_BRANCHES_LOG2) + branch_i;
    }
    return node_i;
}

static inline int leafBlocksOffset(uint32_t x, int num_blocks_log2) {
    switch (num_blocks_log2) {
        case 5:
            return 0;
        case 4:
            return !!(x & 0xffff) << 4;
        case 3:
            x = x >> 1 | x | 0xaaaaaaaa;
            x = x >> 2 | x | 0xeeeeeeee;
            x = x >> 4 | x | 0xfefefefe;
            x = ~x & -~x;
            return !!(x & 0xffff0000) << 4 | !!(x & 0xff00ff00) << 3;
        case 2:
            x = x >> 1 | x | 0xaaaaaaaa;
            x = x >> 2 | x | 0xeeeeeeee;
            x = ~x & -~x;
            return !!(x & 0xffff0000) << 4 | !!(x & 0xff00ff00) << 3 | !!(x & 0xf0f0f0f0) << 2;
        case 1:
            x = x >> 1 | x | 0xaaaaaaaa;
            // fallthrough
        case 0:
            return indexOfFirstZero(x);
    }
    assert(0);
}

static inline int leafHasSpaceEnd(uint32_t leaf) {
    uint32_t free_blocks = ~leaf;
    int n = !!free_blocks + !leaf;
    const uint32_t fold_mask[4] = { 0x55555555, 0x11111111, 0x01010101, 0x00010001 };
    for (int i = 0; i < 4; ++i) {
        free_blocks = free_blocks >> (1 << i) & free_blocks & fold_mask[i];
        n += !!free_blocks;
    }
    return n;
}

static inline void updateTreeLeafFull(uint32_t* tree, uint32_t leaf_i, const uint32_t* row_offsets, int tree_height) {
    int branch_i = leaf_i & BRANCH_INDEX_MASK;
    uint32_t node_i = leaf_i >> NUM_BRANCHES_LOG2;
    for (int row_i = tree_height - 1; ; --row_i, branch_i = node_i & BRANCH_INDEX_MASK, node_i >>= NUM_BRANCHES_LOG2) {
        uint32_t* const node = tree + row_offsets[row_i] + node_i;
        *node |= 1u << branch_i;
        const bool node_has_space_left = ~*node;
        if (row_i == 0 || node_has_space_left) return;
    }
}

static inline uint32_t leafBlocksMask(int num_blocks_log2, int offset) {
    const int w = 1 << num_blocks_log2;
    const uint32_t width_mask = ((w != NUM_BRANCHES) << (w & BRANCH_INDEX_MASK)) - 1;
    return width_mask << offset;
}

bool tral_mark(tral_member_t* m, uint32_t num_blocks, uint32_t* adr_out) {
    assert(num_blocks && num_blocks <= TRAL_MARK_MAX_BLOCKS);
    const int num_blocks_log2 = CEIL_LOG2_SMALL(num_blocks);
    uint32_t* const leaves = (uint32_t*)m->buf;
    uint32_t* const tree0 = leaves + m->num_leaves;
    uint32_t* const tree = tree0 + num_blocks_log2 * m->tree_stride;
    if (*tree == UINT32_MAX) return false;

    const uint32_t leaf_i = leafWithSpaceIndex(tree, m->row_offsets, m->tree_height);
    uint32_t* const leaf = leaves + leaf_i;
    const int blocks_offset = leafBlocksOffset(*leaf, num_blocks_log2);
    *leaf |= leafBlocksMask(num_blocks_log2, blocks_offset);
    *adr_out = (leaf_i << NUM_BRANCHES_LOG2) + blocks_offset;

    const int update_start_i = leafHasSpaceEnd(*leaf);
    uint32_t* tree_it = tree0 + m->tree_stride * update_start_i;
    for (int i = update_start_i; i < NUM_TREES; ++i, tree_it += m->tree_stride)
        updateTreeLeafFull(tree_it, leaf_i, m->row_offsets, m->tree_height);
    return true;
}

static inline void updateTreeLeafHasSpace(uint32_t* tree, uint32_t leaf_i, const uint32_t* row_offsets, int tree_height) {
    int branch_i = leaf_i & BRANCH_INDEX_MASK;
    uint32_t node_i = leaf_i >> NUM_BRANCHES_LOG2;
    for (int row_i = tree_height - 1; ; --row_i, branch_i = node_i & BRANCH_INDEX_MASK, node_i >>= NUM_BRANCHES_LOG2) {
        uint32_t* const node = tree + row_offsets[row_i] + node_i;
        const bool node_had_space = ~*node;
        *node &= ~(1u << branch_i);
        if (row_i == 0 || node_had_space) return;
    }
}

void tral_clear(tral_member_t* m, uint32_t adr, uint32_t num_blocks) {
    assert(num_blocks && num_blocks <= TRAL_MARK_MAX_BLOCKS);
    assert(adr <= (m->num_leaves << NUM_BRANCHES_LOG2) - 1);
    const int num_blocks_log2 = CEIL_LOG2_SMALL(num_blocks);
    uint32_t* const leaves = (uint32_t*)m->buf;
    const uint32_t leaf_i = adr >> NUM_BRANCHES_LOG2;
    uint32_t* const leaf = leaves + leaf_i;
    const int blocks_offset = adr & BRANCH_INDEX_MASK;
    *leaf &= ~leafBlocksMask(num_blocks_log2, blocks_offset);
    uint32_t* tree_it = leaves + m->num_leaves;
    const int update_end_i = leafHasSpaceEnd(*leaf);
    for (int i = 0; i < update_end_i; ++i, tree_it += m->tree_stride)
        updateTreeLeafHasSpace(tree_it, leaf_i, m->row_offsets, m->tree_height);
}
