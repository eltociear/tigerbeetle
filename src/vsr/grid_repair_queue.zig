//! Track corrupt/missing grid blocks.
//!
//! - The GridRepairQueue is LSM-aware: it can repair entire tables.
//! - The GridRepairQueue is shared by all Trees.
//! - The GridRepairQueue is "coherent" – that is, all of the blocks in the queue belong in the
//!   replica's current checkpoint:
//!   - The GridRepairQueue will not repair freed blocks.
//!   - The GridRepairQueue will repair released blocks, until they are freed at the checkpoint.
//! - GridRepairQueue.enqueue_table() is called immediately after superblock sync.
//! - GridRepairQueue.enqueue_block() is called by the grid when non-repair reads encounter corrupt
//!   blocks.
const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.grid_repair_queue);
const maybe = stdx.maybe;

const stdx = @import("../stdx.zig");
const constants = @import("../constants.zig");
const schema = @import("../lsm/schema.zig");
const vsr = @import("../vsr.zig");

const GridType = @import("./grid.zig").GridType;
const FIFO = @import("../fifo.zig").FIFO;
const IOPS = @import("../iops.zig").IOPS;
const BlockPtrConst = *align(constants.sector_size) const [constants.block_size]u8;

pub const GridRepairQueue = struct {
    const TableContentBlocksSet = std.StaticBitSet(constants.lsm_table_content_blocks_max);

    /// A block is removed from the collection when:
    /// - the block's write completes, or
    /// - the block is released and the release is checkpointed, or
    /// - the grid is canceled.
    ///
    /// The map is keyed by block address.
    const FaultyBlocks = std.AutoArrayHashMapUnmanaged(u64, FaultyBlock);

    const FaultyBlock = struct {
        checksum: u128,
        progress: FaultProgress,
        /// Transitions:
        /// - Initial state is `waiting`.
        /// - `waiting → writing` when the block arrives and begins to repair.
        /// - `writing → aborting` when the (writing) block is released by the checkpoint.
        state: enum { waiting, writing, aborting } = .waiting,
    };

    const FaultProgress = union(enum) {
        /// Repair a single block.
        block,
        /// Repair the table and all of its content. Awaiting table index block.
        table_index: TableIndex,
        /// Repair the table and all of its content. Awaiting table content blocks.
        table_content: TableContent,

        const TableIndex = struct { table: *RepairTable };
        const TableContent = struct { table: *RepairTable, index: u32 };
    };

    pub const RepairTableResult = enum {
        /// The table is synced: its index and content blocks are all written.
        repaired,
        /// The table no longer needs to be synced because the Grid was canceled.
        canceled,
        /// The table no longer needs to be synced because it was released at the checkpoint.
        released,
    };

    pub const RepairTable = struct {
        index_address: u64,
        index_checksum: u128,
        /// Invariants:
        /// - content_blocks_received.count < table_blocks_total
        /// TODO(Congestion control): This bitset is currently used only for extra validation.
        /// Eventually we should request tables using this + EWAH encoding, instead of
        /// block-by-block.
        content_blocks_received: TableContentBlocksSet = TableContentBlocksSet.initEmpty(),
        /// This count includes the index block.
        /// Invariants:
        /// - table_blocks_written ≤ table_blocks_total
        table_blocks_written: u32 = 0,
        /// When null, the table is awaiting an index block.
        /// When non-null, the table is awaiting content blocks.
        /// This count includes the index block.
        table_blocks_total: ?u32 = null,

        /// Invoked when the table index block and all content blocks have been written.
        callback: *const fn (*RepairTable, RepairTableResult) void,
        /// "next" belongs to the `faulty_tables` FIFO.
        next: ?*RepairTable = null,
    };

    pub const Options = struct {
        /// Lower-bound for the limit of concurrent enqueue_block()'s available.
        blocks_max: usize,
        /// Maximum number of concurrent enqueue_table()'s.
        tables_max: usize,
    };

    options: Options,

    /// Invariants:
    /// - For every block address in faulty_blocks, ¬free_set.is_free(address).
    faulty_blocks: FaultyBlocks,
    /// Index within `faulty_blocks`, used to cycle through block-repair requests.
    ///
    /// Invariants:
    /// - faulty_blocks.count() > 0 implies faulty_blocks_repair_index < faulty_blocks.count()
    /// - faulty_blocks.count() = 0 implies faulty_blocks_repair_index = faulty_blocks.count()
    faulty_blocks_repair_index: usize = 0,

    /// Invariants:
    /// - enqueued_blocks_table + enqueued_blocks_single = faulty_blocks.count()
    /// - enqueued_blocks_table ≤ options.tables_max * lsm_table_content_blocks_max
    enqueued_blocks_single: usize = 0,
    enqueued_blocks_table: usize = 0,

    /// Invariants:
    /// - For every index address in faulty_tables: ¬free_set.is_free(address).
    faulty_tables: FIFO(RepairTable) = .{ .name = "grid_repair_queue_tables" },

    checkpointing: ?struct {
        /// The number of faulty_blocks with state=aborting.
        aborting: usize,
    } = null,

    /// Guard against new block/table repairs queueing within RepairTable callbacks.
    canceling: bool = false,

    pub fn init(allocator: std.mem.Allocator, options: Options) error{OutOfMemory}!GridRepairQueue {
        var faulty_blocks = FaultyBlocks{};
        errdefer faulty_blocks.deinit(allocator);

        try faulty_blocks.ensureTotalCapacity(
            allocator,
            options.blocks_max + options.tables_max * constants.lsm_table_content_blocks_max,
        );

        return GridRepairQueue{
            .options = options,
            .faulty_blocks = faulty_blocks,
        };
    }

    pub fn deinit(queue: *GridRepairQueue, allocator: std.mem.Allocator) void {
        assert(!queue.canceling);

        queue.faulty_blocks.deinit(allocator);

        queue.* = undefined;
    }

    /// When the queue wants more blocks than fit in a single request message, successive calls
    /// to this function cycle through the pending BlockRequests.
    pub fn next_batch_of_block_requests(
        queue: *GridRepairQueue,
        requests: []vsr.BlockRequest,
    ) usize {
        assert(!queue.canceling);
        assert(requests.len > 0);

        const faults_total = queue.faulty_blocks.count();
        if (faults_total == 0) return 0;
        assert(queue.faulty_blocks_repair_index < faults_total);

        const fault_addresses = queue.faulty_blocks.entries.items(.key);
        const fault_data = queue.faulty_blocks.entries.items(.value);

        var requests_count: usize = 0;
        var fault_offset: usize = 0;
        while (fault_offset < faults_total) : (fault_offset += 1) {
            const fault_index =
                (queue.faulty_blocks_repair_index + fault_offset) % faults_total;

            switch (fault_data[fault_index].state) {
                .waiting => {
                    requests[requests_count] = .{
                        .block_address = fault_addresses[fault_index],
                        .block_checksum = fault_data[fault_index].checksum,
                    };
                    requests_count += 1;

                    if (requests_count == requests.len) break;
                },
                .writing => {},
                .aborting => assert(queue.checkpointing.?.aborting > 0),
            }
        }

        queue.faulty_blocks_repair_index =
            (queue.faulty_blocks_repair_index + fault_offset) % faults_total;

        assert(requests_count <= requests.len);
        assert(requests_count <= faults_total);
        return requests_count;
    }

    /// Count the number of *non-table* block repairs available.
    pub fn enqueue_blocks_available(queue: *const GridRepairQueue) usize {
        assert(!queue.canceling);
        assert(queue.faulty_tables.count <= queue.options.tables_max);
        assert(queue.faulty_blocks.count() ==
            queue.enqueued_blocks_single + queue.enqueued_blocks_table);
        assert(queue.enqueued_blocks_table <=
            queue.options.tables_max * constants.lsm_table_content_blocks_max);

        const faulty_blocks_free =
            queue.faulty_blocks.capacity() -
            queue.enqueued_blocks_single -
            queue.options.tables_max * constants.lsm_table_content_blocks_max;
        return faulty_blocks_free;
    }

    /// Queue a faulty block to request from the cluster and repair.
    pub fn enqueue_block(queue: *GridRepairQueue, address: u64, checksum: u128) void {
        assert(!queue.canceling);
        assert(queue.enqueue_blocks_available() > 0);
        assert(queue.faulty_tables.count <= queue.options.tables_max);
        assert(queue.faulty_blocks.count() ==
            queue.enqueued_blocks_single + queue.enqueued_blocks_table);

        const enqueue = queue.enqueue_faulty_block(address, checksum, .block);
        assert(enqueue == .insert or enqueue == .duplicate);
    }

    pub fn enqueued_table(queue: *GridRepairQueue, address: u64, checksum: u128) bool {
        assert(!queue.canceling);
        maybe(queue.enqueue_blocks_available() == 0);
        assert(queue.faulty_tables.count <= queue.options.tables_max);

        var tables = queue.faulty_tables.peek();
        while (tables) |queue_table| : (tables = queue_table.next) {
            if (queue_table.index_address == address) {
                assert(queue_table.index_checksum == checksum);
                return true;
            }
        }
        return false;
    }

    pub fn enqueue_table(
        queue: *GridRepairQueue,
        callback: *const fn (*RepairTable, RepairTableResult) void,
        table: *RepairTable,
        address: u64,
        checksum: u128,
    ) void {
        assert(!queue.canceling);
        assert(queue.faulty_tables.count < queue.options.tables_max);
        assert(!queue.enqueued_table(address, checksum));
        assert(queue.faulty_blocks.count() ==
            queue.enqueued_blocks_single + queue.enqueued_blocks_table);

        var tables = queue.faulty_tables.peek();
        while (tables) |queue_table| : (tables = queue_table.next) assert(queue_table != table);

        table.* = .{
            .callback = callback,
            .index_address = address,
            .index_checksum = checksum,
        };
        queue.faulty_tables.push(table);

        const enqueue =
            queue.enqueue_faulty_block(address, checksum, .{ .table_index = .{ .table = table } });
        assert(enqueue == .insert or enqueue == .replace);
    }

    fn enqueue_faulty_block(
        queue: *GridRepairQueue,
        address: u64,
        checksum: u128,
        progress: FaultProgress,
    ) union(enum) {
        insert,
        replace: *FaultyBlock,
        duplicate,
    } {
        assert(!queue.canceling);
        assert(queue.faulty_tables.count <= queue.options.tables_max);
        assert(queue.faulty_blocks.count() ==
            queue.enqueued_blocks_single + queue.enqueued_blocks_table);

        defer {
            assert(queue.faulty_blocks.count() ==
                queue.enqueued_blocks_single + queue.enqueued_blocks_table);
        }

        const fault_result = queue.faulty_blocks.getOrPutAssumeCapacity(address);
        if (fault_result.found_existing) {
            const fault = fault_result.value_ptr;
            assert(fault.checksum == checksum);
            assert(fault.state != .aborting);

            switch (progress) {
                .block => return .duplicate,
                .table_index,
                .table_content,
                => {
                    // The content block may already have been queued by either the scrubber or a
                    // commit/compaction grid read.
                    assert(fault.progress == .block);

                    queue.enqueued_blocks_single -= 1;
                    queue.enqueued_blocks_table += 1;
                    fault.progress = progress;
                    return .{ .replace = fault };
                },
            }
        } else {
            switch (progress) {
                .block => queue.enqueued_blocks_single += 1,
                .table_index => queue.enqueued_blocks_table += 1,
                .table_content => queue.enqueued_blocks_table += 1,
            }

            fault_result.value_ptr.* = .{
                .checksum = checksum,
                .progress = progress,
            };
            return .insert;
        }
    }

    pub fn repair_waiting(queue: *const GridRepairQueue, address: u64, checksum: u128) bool {
        const fault_index = queue.faulty_blocks.getIndex(address) orelse return false;
        const fault = &queue.faulty_blocks.entries.items(.value)[fault_index];
        return fault.checksum == checksum and fault.state == .waiting;
    }

    pub fn repair_commence(queue: *const GridRepairQueue, address: u64, checksum: u128) void {
        assert(queue.repair_waiting(address, checksum));

        const fault_index = queue.faulty_blocks.getIndex(address).?;
        const fault = &queue.faulty_blocks.entries.items(.value)[fault_index];
        assert(fault.checksum == checksum);
        assert(fault.state == .waiting);

        if (fault.progress == .table_content) {
            const progress = &fault.progress.table_content;
            assert(progress.table.table_blocks_written < progress.table.table_blocks_total.?);
            assert(!progress.table.content_blocks_received.isSet(progress.index));

            progress.table.content_blocks_received.set(progress.index);
        }

        fault.state = .writing;
    }

    pub fn repair_complete(queue: *GridRepairQueue, block: BlockPtrConst) void {
        const block_header = schema.header_from_block(block);
        const fault_index = queue.faulty_blocks.getIndex(block_header.op).?;
        const fault_address = queue.faulty_blocks.entries.items(.key)[fault_index];
        const fault: FaultyBlock = queue.faulty_blocks.entries.items(.value)[fault_index];
        assert(!queue.canceling);
        assert(fault_address == block_header.op);
        assert(fault.checksum == block_header.checksum);
        assert(fault.state == .aborting or fault.state == .writing);

        queue.release_fault(fault_index);

        if (fault.state == .aborting) {
            queue.checkpointing.?.aborting -= 1;
            return;
        }

        switch (fault.progress) {
            .block => {},
            .table_index => |progress| {
                assert(progress.table.content_blocks_received.count() == 0);

                // The reason that the content blocks are queued here (when the write ends) rather
                // than when the write begins is so that a `enqueue_block()` can be converted to a
                // `enqueue_table()` after the former's write is already in progress.
                queue.enqueue_table_content(fault.progress.table_index.table, block);
            },
            .table_content => |progress| {
                assert(progress.table.content_blocks_received.isSet(progress.index));
            },
        }

        if (switch (fault.progress) {
            .block => null,
            .table_index => |progress| progress.table,
            .table_content => |progress| progress.table,
        }) |table| {
            assert(table.table_blocks_total != null); // We already received the index block.
            assert(table.table_blocks_written < table.table_blocks_total.?);
            assert(table.content_blocks_received.count() <= table.table_blocks_total.? - 1);

            table.table_blocks_written += 1;
            if (table.table_blocks_written == table.table_blocks_total.?) {
                queue.faulty_tables.remove(table);
                (table.callback)(table, .repaired);
            }
        }
    }

    fn enqueue_table_content(
        queue: *GridRepairQueue,
        table: *RepairTable,
        index_block_data: BlockPtrConst,
    ) void {
        assert(!queue.canceling);
        assert(queue.faulty_blocks.count() ==
            queue.enqueued_blocks_single + queue.enqueued_blocks_table);
        assert(table.table_blocks_total == null);
        assert(table.table_blocks_written == 0);
        assert(table.content_blocks_received.count() == 0);

        const index_schema = schema.TableIndex.from(index_block_data);
        const index_block_header = schema.header_from_block(index_block_data);
        assert(index_block_header.op == table.index_address);
        assert(index_block_header.checksum == table.index_checksum);
        assert(schema.BlockType.from(index_block_header.operation) == .index);

        const content_blocks_total = index_schema.content_blocks_used(index_block_data);
        table.table_blocks_total = 1 + content_blocks_total;

        for (0..content_blocks_total) |content_block_index_usize| {
            const content_block_index: u32 = @intCast(content_block_index_usize);
            const block_id = index_schema.content_block(index_block_data, content_block_index);

            const enqueue = queue.enqueue_faulty_block(
                block_id.block_address,
                block_id.block_checksum,
                .{ .table_content = .{ .table = table, .index = content_block_index } },
            );

            if (enqueue == .replace) {
                if (enqueue.replace.state == .writing) {
                    table.content_blocks_received.set(content_block_index);
                }
            } else {
                assert(enqueue == .insert);
            }
        }
    }

    fn release_fault(queue: *GridRepairQueue, fault_index: usize) void {
        assert(!queue.canceling);
        assert(queue.faulty_blocks_repair_index < queue.faulty_blocks.count());

        switch (queue.faulty_blocks.entries.items(.value)[fault_index].progress) {
            .block => queue.enqueued_blocks_single -= 1,
            .table_index => queue.enqueued_blocks_table -= 1,
            .table_content => queue.enqueued_blocks_table -= 1,
        }

        queue.faulty_blocks.swapRemoveAt(fault_index);

        if (queue.faulty_blocks_repair_index == queue.faulty_blocks.count()) {
            queue.faulty_blocks_repair_index = 0;
        }
    }

    pub fn cancel(queue: *GridRepairQueue) void {
        assert(!queue.canceling);
        assert(queue.checkpointing == null);

        queue.canceling = true;
        while (queue.faulty_tables.pop()) |table| {
            (table.callback)(table, .canceled);
        }

        queue.faulty_blocks.clearRetainingCapacity();
        queue.* = .{
            .options = queue.options,
            .faulty_blocks = queue.faulty_blocks,
        };
    }

    pub fn checkpoint_commence(
        queue: *GridRepairQueue,
        free_set: *const vsr.superblock.SuperBlockFreeSet,
    ) void {
        assert(!queue.canceling);
        assert(queue.checkpointing == null);
        assert(queue.faulty_blocks.count() ==
            queue.enqueued_blocks_single + queue.enqueued_blocks_table);

        var aborting: usize = 0;

        var faulty_blocks = queue.faulty_blocks.iterator();
        while (faulty_blocks.next()) |fault_entry| {
            const fault_address = fault_entry.key_ptr.*;
            assert(!free_set.is_free(fault_address));
            assert(fault_entry.value_ptr.state != .aborting);

            if (free_set.is_released(fault_address)) {
                switch (fault_entry.value_ptr.state) {
                    .waiting => {
                        faulty_blocks.index -= 1;
                        faulty_blocks.len -= 1;
                        queue.release_fault(faulty_blocks.index);
                    },
                    .writing => {
                        fault_entry.value_ptr.state = .aborting;
                        aborting += 1;
                    },
                    .aborting => unreachable,
                }
            }
        }

        var tables: FIFO(RepairTable) = .{ .name = queue.faulty_tables.name };
        while (queue.faulty_tables.pop()) |table| {
            assert(!free_set.is_free(table.index_address));

            if (free_set.is_released(table.index_address)) {
                (table.callback)(table, .released);
            } else {
                tables.push(table);
            }
        }
        queue.faulty_tables = tables;

        queue.checkpointing = .{ .aborting = aborting };
    }

    /// Returns `true` when the `state≠waiting` faults for blocks that are staged to be
    /// released have finished. (All other writes can safely complete after the checkpoint.)
    pub fn checkpoint_complete(queue: *GridRepairQueue) bool {
        assert(!queue.canceling);
        assert(queue.checkpointing != null);
        assert(queue.faulty_blocks.count() ==
            queue.enqueued_blocks_single + queue.enqueued_blocks_table);

        if (queue.checkpointing.?.aborting == 0) {
            queue.checkpointing = null;

            var faulty_blocks = queue.faulty_blocks.iterator();
            while (faulty_blocks.next()) |fault_entry| {
                assert(fault_entry.value_ptr.state != .aborting);
            }

            return true;
        } else {
            return false;
        }
    }
};
