# Concurrent Index Locking

Postgres provides two mechanisms to create indexes. The naive index creation
will take Share locks against the table that the index will be created on, which
will block any UPDATEs, as they take conflicting RowExclusive locks. This is
inconvenient in production systems, as you almost never want to block writes, so
we have an alternative concurrent index build method.

Concurrently building an index complicates the process of index creation, but
allows us to take less restrictive locks. The point at which this happens is in
`src/backend/commands/indexcmds.c`, where we do the following:

```c
/*
 * Only SELECT ... FOR UPDATE/SHARE are allowed while doing a standard
 * index build; but for concurrent builds we allow INSERT/UPDATE/DELETE
 * (but not VACUUM).
 */
lockmode = stmt->concurrent ? ShareUpdateExclusiveLock : ShareLock;
```

## Nuances

On the surface, this might imply concurrent index creation is unaffected by read
and writes to the target table, but there are places in the concurrent index
creation that are affected.

It's best practice to set aggressive `lock_timeout`s during database migrations
to prevent schema changes from unduly affecting normal database activity.
Setting 1500ms `lock_timeout`s were causing `CREATE INDEX CONCURRENTLY` queries
to lock timeout in our migrations, which was surprising because we couldn't see
any queries executing on the table that might feasibly block our index.

Instead, we were seeing totally unrelated queries with no locks on our
particular table causing our index creation to timeout. And weirdly, instead of
timing out on locks which target our table or index relation, the timeout was
due to a Share lock taken on a virtualxid. Here is an example output:

```
-[ RECORD 1 ]--------+----------------------------------------------------------
blocked_pid          | 19650
blocked_statement    | CREATE UNIQUE INDEX CONCURRENTLY "index_table_on_sort_key" ON "table" USING btree ("id", "sort_key")
blocking_pid         | 35447
blocking_statement   | SELECT  "another_table".* FROM "events" WHERE ...
blocking_mode        | ExclusiveLock
blocking_locktype    | virtualxid
blocking_virtualxid  | 38/50717675
blocking_granted     | t
```

Postgres transactions acquire Exclusive locks on their own virtualxid whenever
they begin to observe or mutate database state. There is no obvious relationship
between our index creation and the blocking statement, and yet the lock we've
taken is incredibly specific to that particular query.

The reason this has occured is that concurrent index creation builds an index in
several stages. We first create the system catalog entry for the index,
preparing the physical files and making it visible, which causes all future
transactions to make HOT compatible updates to tuples covered by our index.

At this point the index is marked as not ready and invalid, which means no
transaction will insert or make use of the index for queries. We then take a
snapshot and use it to build the index, including all tuples visible in that
snapshot. After this we update the index to be ready, and commit this change so
that all subsequent updates will make use of the index.

We are almost complete with our index, but are yet to mark it as valid. We can
only do so when we know for sure it contains all tuples it is intended to be
indexing. Any queries that are operating with a snapshot taken prior to our
index build snapshot may have delete tuples that we never included in our index
construction. If we mark the index as valid, these transactions will attempt to
use the index for their queries, which would be incorrect as we'd exclude tuples
that should otherwise be visible in their snapshot.

As a result, the index can only be marked as valid once those transactions have
completed operation. To do this, in `src/backend/commands/indexcmds.c` we have
the following (psuedo) code:

```c
old_snapshots = GetCurrentVirtualXIDs(limitXmin)
for (i = 0; i < n_old_snapshots; i++)
{
  if (!VirtualTransactionIdIsValid(old_snapshots[i]))
    continue; // transaction has finished

  // take new snapshots
  // filter any old_snapshots that are now invalid

  if (VirtualTransactionIdIsValid(old_snapshots[i]))
    VirtualXactLock(old_snapshots[i], true) // true means block
}
```

What we do here is find any transactions owning the snapshots that may contain
our invalid transactions, and lock on their virtualxid to wait until they have
terminated before proceeding. This is why we saw our Share lock on the
virtualxid, and why queries that target entirely different tables cause
`lock_timeout`s for our index build.

## Going forward

While concurrent index creation takes weaker locks that can be more compatible
with operating production databases, the process of finalising the index for use
is limited by any longer running transactions (in repeatable read or higher) or
queries that may be on-going in your database.

On the other hand, because the locks taken are much weaker than normal index
creation, you are typically safe to remove the `lock_timeout` without risk of
disrupting normal database activity.
