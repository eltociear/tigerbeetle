# Protocols

### Commands

| `vsr.Header.Command` |  Source |       Target | Protocols                                                              |
| -------------------: | ------: | -----------: | --------------------------------------------------------               |
|               `ping` | replica |      replica | [Ping (Replica-Replica)](#protocol-ping-replica-replica)               |
|               `pong` | replica |      replica | [Ping (Replica-Replica)](#protocol-ping-replica-replica)               |
|               `ping` |  client |      replica | [Ping (Client-Replica)](#protocol-ping-client-replica)                 |
|               `pong` | replica |       client | [Ping (Client-Replica)](#protocol-ping-client-replica)                 |
|            `request` |  client |      primary | [Normal](#protocol-normal)                                             |
|            `prepare` | replica |       backup | [Normal](#protocol-normal), [Repair Journal](#protocol-repair-journal) |
|         `prepare_ok` | replica |      primary | [Normal](#protocol-normal), [Repair Journal](#protocol-repair-journal) |
|              `reply` | primary |       client | [Normal](#protocol-normal)                                             |
|             `commit` | primary |       backup | [Normal](#protocol-normal)                                             |
|  `start_view_change` | replica | all replicas | [Start-View-Change](#protocol-start-view-change)                       |
|     `do_view_change` | replica | all replicas | [View-Change](#protocol-view-change)                                   |
|         `start_view` | primary |       backup | [Request/Start View](#protocol-request-start-view)                     |
| `request_start_view` |  backup |      primary | [Request/Start View](#protocol-request-start-view)                     |
|    `request_headers` | replica |      replica | [Repair Journal](#protocol-repair-journal)                             |
|    `request_prepare` | replica |      replica | [Repair WAL](#protocol-repair-wal)                                     |
|            `headers` | replica |      replica | [Repair Journal](#protocol-repair-journal)                             |
|       `nack_prepare` |  backup |      primary | [Repair WAL](#protocol-repair-wal)                                     |
|           `eviction` | primary |       client | [Client](#protocol-client)                                             |

### Recovery

Unlike [VRR](https://pmg.csail.mit.edu/papers/vr-revisited.pdf), TigerBeetle does not implement Recovery Protocol (see §4.3).
Instead, replicas persist their VSR state to the superblock.
This ensures that a recovering replica never backtracks to an older view (from the point of view of the cluster).

## Protocol: Ping (Replica-Replica)

Replicas send `command=ping`/`command=pong` messages to one another to synchronize clocks.

## Protocol: Ping (Replica-Client)

Clients send `command=ping` (and receive `command=pong`) messages to (from) replicas to learn the cluster's current view.

## Protocol: Normal

Normal protocol prepares and commits requests (from clients) and sends replies (to clients).

(As described in [VRR §4.1](https://pmg.csail.mit.edu/papers/vr-revisited.pdf).)

1. The client sends a `command=request` message to the primary. (If the client's view is outdated, the receiver will forward the message on to the actual primary).
2. The primary converts the `command=request` to a `command=prepare` (assigning it an `op` and `timestamp`).
3. Each replica (in a chain beginning with the primary) performs the following steps concurrently:
    - Write the prepare to the WAL.
    - Forward the prepare to the next replica in the chain.
4. Each replica sends a `command=prepare_ok` message to the primary once it has written the prepare to the WAL.
5. When a primary collects a [commit quorum](#quorums) of `prepare_ok`s _and_ it has committed all preceding prepares, it commits the prepare.
6. The primary replies to the client.
7. The backups are informed that the prepare was committed by either:
    - a subsequent prepare, or
    - a periodic `command=commit` message.

```mermaid
sequenceDiagram
    participant C0 as Client
    participant R0 as Replica 0 (primary)
    participant R1 as Replica 1 (backup)
    participant R2 as Replica 2 (backup)

    C0->>R0: Request A

    R0->>+R0: Prepare A
    R0->>+R1: Prepare A
    R1->>+R2: Prepare A

    R0->>-R0: Prepare-Ok A
    R1->>-R0: Prepare-Ok A
    R0->>C0: Reply A
    R2->>-R0: Prepare-Ok A
```

## Protocol: Start-View-Change

Start-View-Change (SVC) protocol initiates [view-changes](#protocol-view-change) with minimal disruption.

Unlike the Start-View-Change described in [VRR §4.2](https://pmg.csail.mit.edu/papers/vr-revisited.pdf), this protocol runs in both `status=normal` and `status=view_change` (not just `status=view_change`).

1. Depending on the replica's status:
    - `status=normal`: If the replica has not committed a message recently, send a `command=start_view_change` to all replicas (including self).
    - `status=view_change`: If the replica has not completed a view-change recently, send a `command=start_view_change` to all replicas (including self).
2. (Periodically retry sending the SVC).
3. If the replica commits or changes views (respectively), reset its SVC quorum and stop the `command=start_view_change` retries.
4. If the replica collects a [view-change quorum](#quorums) of SVC messages, transition to `status=view_change` for the next view. (That is, increment the replica's view and start sending a DVC).

To ensure that an idle (but healthy) cluster does not change views, a `status=normal` primary periodically prepares a heartbeat message.

This protocol approach enables liveness under asymmetric network partitions. For example, a replica which can send to the cluster but not receive may send SVCs, but if the remainder of the cluster is healthy, they will never achieve a quorum, so the view is stable. When the partition heals, the formerly-isolated replica may rejoin the original view (if it was isolated in `status=normal`) or a new view (if it was isolated in `status=view_change`).

See also:
- [Raft does not Guarantee Liveness in the face of Network Faults](https://decentralizedthoughts.github.io/2020-12-12-raft-liveness-full-omission/) ("PreVote and CheckQuorum")
- ["Consensus: Bridging Theory and Practice" §6.2](https://web.stanford.edu/~ouster/cgi-bin/papers/OngaroPhD.pdf) The sectioned titled "Leaders" describes periodically committing a heartbeat to detect stale leaders. (TODO explain divergence)

## Protocol: View-Change

A replica sends `command=do_view_change` to all replicas, with the `view` it is attempting to start.
- The _primary_ of the `view` collects a [view-change quorum](#quorums) of DVCs.
- The _backup_ of the `view` uses to `do_view_change` to updates its current `view` (transitioning to `status=view_change`).

When the primary collects its quorum:
1. The primary installs the headers to its suffix.
2. Then the primary repairs (and potentially truncates uncommitted ops).
3. When the primary finishes repair, it transitions to `status=normal` and broadcasts a `command=start_view`.

## Protocol: Request/Start View

### `request_start_view`

A backup sends a `command=request_start_view` to the primary of a view when any of the following occur:

  - the backup learns about a newer view via a `command=commit` message, or
  - the backup learns about a newer view via a `command=prepare` message, or
  - a replica recovers to `status=recovering_head`

### `start_view`

When a `status=normal` primary receives `command=request_start_view`, it replies with a `command=start_view`.
`command=start_view` includes the view's current suffix — the headers of the latest messages in the view.

Upon receiving a `start_view` for the new view, the backup installs the suffix, transitions to `status=normal`, and begins repair.

## Protocol: Repair Journal

`request_headers` and `headers` repair gaps or breaks in a replica's journal headers.
Because the headers are repaired backwards (from the head) by hash-chaining, it is safe for both backups and transitioning primaries.

## Protocol: Repair WAL

In response to a `request_prepare`:

- Reply the `command=prepare` with the requested prepare, if available.
- Reply `command=nack_prepare` if the request origin is the primary of the ongoing view-change and we never received the prepare. (This enables the primary to truncate uncommitted messages and remain available).
- Otherwise do not reply.

Per [PAR's CTRL Protocol](https://www.usenix.org/system/files/conference/fast18/fast18-alagappan.pdf), we do not nack corrupt entries, since they _might_ be the prepare being requested.

## Protocol: Client

1. Client registers with cluster (`command=request operation=register`). (See also: [Protocol: Normal](#protocol-normal)).
2. Client receives `command=reply operation=register` from the cluster. (If the cluster is at the maximum number of clients, it evicts the oldest).
3. Repeat:
    1. Send `command=request` to cluster.
    2. If the client has been evicted, receive `command=eviction` from the cluster. (The client must re-register before sending more requests.)
    3. If the client has not been evicted, receive `command=reply` from cluster.

See also:
- [Integration: Client Session Lifecycle](../../docs/usage/integration/md#client-session-lifecycle)
- [Integration: Client Session Eviction](../../docs/usage/integration/md#client-session-eviction)

## Protocol: Repair Grid (Backup)

TODO (Unimplemented)

## Protocol: Repair: State Transfer

TODO (Unimplemented)

## Protocol: Reconfiguration

TODO (Unimplemented)

# Quorums

- The _commit quorum_ is the minimum number of replicas required to complete a commit.
- The _view-change quorum_ is the minimum number of replicas required to complete a view-change.

With the default configuration:

|      **Replica Count** |   1 |  2 |  3 |  4 |  5 |  6 |
| ---------------------: | --: | -: | -: | -: | -: | -: |
|      **Commit Quorum** |   1 |  2 |  2 |  3 |  3 |  3 |
| **View-Change Quorum** |   1 |  2 |  2 |  3 |  3 |  4 |

See also:
- `constants.quorum_replication_max` for configuration.
- [Flexible Paxos](https://fpaxos.github.io/)