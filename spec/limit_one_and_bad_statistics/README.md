# Limit 1 and bad statistics

The Postgres query planner uses statistics to decide how to execute queries.
These statistics are combined with estimated unit cost for each operation and
used to predict the cost of a query when executed with a candidate plan.

As with all statistics, it's easy to make mistakes that can cause the figures to
suggest things about the dataset that are inaccurate. In the case of Postgres
deciding effective query plans, poor statistics can result in plans that are
orders of magnitude less effective than the alternative.

Postgres ships with good default statistics configuration that will suit most
database sizes. As a database grows beyond millions of row tables these defaults
become less appropriate and tuning is required to ensure the planner continues
to make good decisions.

## What we saw

One day we started seeing unusual query performance from several sources: both
async workers and API requests seemed to take longer to respond than was
normal. Examining the database queries executed from these sources the common
factor was that each query touched the payment transitions table (almost half a
billion rows) and associated relations.

Looking further, we saw a concerning number of queries that were very long
running that normally execute in <50ms. Now suspicious that we'd hit a poor
query plan, it was time to find an exemplar query and dig in:

```sql
  SELECT *
    FROM payment_transitions
    JOIN payments
      ON payments.id = payment_transitions.payment_id
   WHERE payment_transitions.payout_id = 'PO00123456789Z'
ORDER BY payment_transitions.id ASC
   LIMIT 1;
```

## How many payments, how many transitions?

Debugging query plans almost always follow the same pattern: take time to
understand the query, identify why plan you received was bad, then hypothesise
an ideal plan that would be fast. That new plan often requires an index that
is yet to be created, or perhaps a fast plan doesn't exist for this query.
Whatever the outcome, it's key to every step that you understand the shape of
the data you're querying.

Our query references two tables, `payments` and `payment_transitions`. In this
system every payment has states it can transition through, and each of those
states is represented as a row in the `payment_transitions` table.  We'll be
filtering on a foreign key of `payment_transitions` called `payout_id` which
marks that transition as having been included in a payout.

Approximately 20% of our payment transitions will be marked with a `payout_id`,
and there are approximately 20 payment transitions per payout. We can reasonably
expect the number of `payout_id` values to grow linearly with the size of our
`payment_transitions` table.

Using approximate figures, if we have 350M payment transitions, we can expect
70M to be marked with a `payout_id`, and there would be almost 3.5M distinct
`payout_id` values in the `payment_transitions` table. This should provide
enough context for us to properly evaluate each potential plan for this query.

## Explaining our query

Using the query we'd pinpointed as problematic, we ran an `EXPLAIN` in a
Postgres prompt to display the selected query plan.

```sql
 EXPLAIN
  SELECT *
    FROM payment_transitions
    JOIN payments
      ON payments.id = payment_transitions.payment_id
   WHERE payment_transitions.payout_id = 'PO00123456789Z'
ORDER BY payment_transitions.id ASC
   LIMIT 1;
                                                     QUERY PLAN
--------------------------------------------------------------------------------------------------------------------
 Limit  (cost=1.14..21700.47 rows=1 width=262)
   ->  Nested Loop  (cost=1.14..58045700.29 rows=2675 width=262)
         ->  Index Scan using payment_transitions_pkey on payment_transitions  (cost=0.57..58022604.77 rows=2688 width=262)
               Filter: (payout_id = 'PO00123456789Z'::text)
         ->  Index Scan using payments_pkey on payments  (cost=0.57..8.58 rows=1 width=14)
               Index Cond: ((id)::text = (payment_transitions.payment_id)::text)
(6 rows)
```

This query includes a join operation between our `payments` and
`payment_transitions` table. Formally, a relational join is an operation on two
sets- R and S- will produce a result consisting of all combinations of tuples in
R and S that are equal under a particular matching condition.

When joining two tables, Postgres employs one of three strategies: merge, hash
or nested loop. The strategy Postgres has chosen for our query is nested loop,
the most naive of join strategies. Nested loop joins will iterate over every tuple in
`payment_transitions` and for each tuple scan the `payments` table for tuples
that match the join condition, which is this case is `payments.id =
payment_transitions.payment_id`. Our result will be all the tuples that
satisfied our condition.

Looking at our plan, we're using the `payment_transitions_pkey` to select each
transition tuple and for each transition that has a matching `payout_id`, we'll
use an index lookup into the `payouts` table to perform the join. The advantage
of this query plan is that the first matching row we find using the
`payment_transitions_pkey` index is guaranteed to match our query ordering
constraint (`ORDER BY payment_transitions.id`), so we can halt execution at this
point as we only require a single tuple (`LIMIT 1`).

> The `payment_transitions_pkey` index contains references to
> `payment_transitions` tuples in order of `payment_transitions.id`. This is why
> the first result from scanning our transitions using this index is guaranteed
> to have the minimum `id` value.

Sadly, this query plan is not going to work well for us. Recalling the
underlying distribution of this data, for every payout we expect there to be
approximately 20 matching transitions. If we assume that these matches are
evenly distributed throughout the transitions pkey index (a fair assumption for
query planning purposes) then we expect to scan 1/20th of the table before we
find our first match.

> In our case, the assumption that `payout_id` values are evenly distributed
> with respect to the `payment_transitions.id` is going to be terrible for us.
> 
> Our real world example happens to be queries for recently created `payout_id`
> values, and given the `payment_transitions.id` is a monotonically increasing
> sequence, we can expect our matching transitions to be right at the end of our
> scan.
>
> This is an example of how reasonable assumptions in theory can lead to
> pathological data access patterns in practice.

At 350M rows, this amounts to 25M rows we need to scan, or about 20GB of data.
This plan will never match the performance we expect from this query, so
something has gone deeply wrong.

> Scanning such a large amount of data is not only going to make the current
> query slow, but will have a large performance impact on the rest of your
> database. These large scans will likely read old data that is not currently in
> our page cache, causing eviction of pages that are needed for other on-going
> queries.
>
> It's worth bearing this in mind when your database has strict performance
> requirements and depends on hot data being cached to meet them.

## What did Postgres expect

The calculations we just performed are very similar to how Postgres evaluates
query plans. In fact, the statistics we've been quoting are tracked and updated
regularly by Postgres through the [auto-analyze](
https://www.postgresql.org/docs/current/routine-vacuuming.html) process, and are
known as the statistic values `n_distinct` and `null_frac`.

Having a measure for each column of the number of distinct values (`n_distinct`)
and fraction of rows for which the column is null (`null_frac`) enables Postgres
to compute the expected number of rows returned for a given query as
approximately `row_count * (1 - null_frac) / n_distinct`.

> In practice, Postgres also adjusts for the known most common values and their
> histogram bounds, allowing the computation to take into account statistical
> outliers. In this example, we can safely ignore these histogram bounds because
> the most common values cover only a small percentage of the table.

Looking at the explained output of our plan:

```sql
-> Index Scan using payment_transitions_pkey on payment_transitions  (cost=0.57..58022604.77 rows=2688 width=262)
     Filter: (payout_id = 'PO00123456789Z'::text)
```

We see that Postgres expected that 2688 payment transitions would match our
filter condition on `payout_id`. Assuming this is a typical payout (it doesn't
appear in Postgres' most common values) then we've way over-estimated the number
of transitions attached to the average payout, which should be about 20. When we
look at our statistics for this column, we start to see some concerning numbers:

```sql
postgres=# select attname, n_distinct, null_frac from pg_stats where tablename='payment_transitions' and attname='payout_id';
  attname  | n_distinct | null_frac
-----------+------------+-----------
 payout_id |      25650 |      0.81
```

Running our approximate calculation from before, we expect 350M * 0.19 / 36514
= 2592 to be the number of transitions that share a `payout_id` value, which is
almost exactly what Postgres is estimating. Our `n_distinct` is incorrect by two
orders of magnitude, which is going to prevent Postgres from making sane
decisions when comparing plans.

## What is the correct plan, and why didn't we choose it?

Our ideal plan would be to fetch all matching payment transitions for our
payout, then (knowing this will be a small number) perform an in-memory sort on
the results, returning the transition with minimum ID. The initial fetching of
matching transitions would be fast, because we'd use an index that covers the
`payout_id` column.

The plan (with correct row estimations) would look something like this:

```sql
                                            QUERY PLAN
-------------------------------------------------------------------------------------------------------------
Limit  (rows=1)
  -> Sort  (rows=20)                                                        Sort Key: payment_transitions.id
      ->  Nested Loop  (rows=20)
          ->  Index Scan using index_payment_transitions_on_payout_id on payment_transitions  (rows=20)
                Index Cond: (payout_id = 'PO00123456789Z'::text)
          ->  Index Scan using payments_pkey on payments  (rows=1)
                Index Cond: ((id)::text = (payment_transitions.payment_id)::text)
```

Materialize all matching transitions for most payouts will be quick and the
subsequent sort cheap, as on average there will be so few of them. This is what
we want the query plan to produce but our statistics meant Postgres vastly
overestimated the cost of our sort, opting for the much more expensive primary
key scan.

## How did Postgres compare these plans?

Postgres' planner has made a choice to use a query plan that could potentially
require far more data that the alternative, given it believes the chance of an
early exit will be high. We can see in the planner code exactly why this has
happened and how the decision was made:

```c
// src/backend/optimizer/plan/planner.c:1664
static void
grouping_planner(
  PlannerInfo *root,
  bool inheritance_update,
	double tuple_fraction)
{
  ...

  /*
   * If ORDER BY was given, consider ways to
   * implement that, and generate a new upperrel
   * containing only paths that emit the correct
   * ordering and project the correct final_target.
   * We can apply the original limit_tuples limit
   * in sort costing here, but only if there are no
   * postponed SRFs.
   */
  if (parse->sortClause)
  {
    current_rel = create_ordered_paths(
      root,
      current_rel,
      final_target,
      final_target_parallel_safe,
      have_postponed_srfs ? -1.0 :
      limit_tuples);

    ...
  }
  ...
}
```

This code is taken from `src/backend/optimizer/plan/planner.c`, which contains
much of the Postgres planner implementation. The part we're interested in is
when Postgres identifies that the current query (stored in `root`) has a sort
clause, in which case we ask `create_ordered_paths` to generate candidate plans
that will produce results that match the sort condition.

```c
// src/backend/optimizer/util/pathnode.c:3414
LimitPath *
create_limit_path(
  PlannerInfo *root, RelOptInfo *rel, Path *subpath,
	Node *limitOffset, Node *limitCount,
	int64 offset_est, int64 count_est)
{
  ...

	if (count_est != 0)
	{
		if (subpath->rows > 0)
			pathnode->path.total_cost = pathnode->path.startup_cost +
				(subpath->total_cost - subpath->startup_cost)
				* count_est / subpath->rows;
    ...
	}
}
```

After we've created a candidate ordered path, `grouping_planner` uses
`create_limit_path` to adjust for our query limit. It's here that we discount
the total cost of our already-sorted plan by `limit_tuples / count_est`, as-
assuming our matching tuples are found evenly distributed across our result set-
this is the fraction of the plan we'll need to execute before we've produced all
tuples we require to satisfy our query.

In our case, our `limit_tuples` is 1, and our `count_est` is expected to be
high due to our underestimation of `n_distinct` for `payout_id`. Small numerator
and large denominator means the discount is huge and is why the nested join
through the `payment_transitions_pkey` index was chosen as the best plan.

## Fixing our statistics

As soon as we realised our statistics were causing such a poor query plan we
re-ran an analyze to cause Postgres to resample. We had to do this a few times
before our plans got better, which hints at the more concerning root cause of
this problem.

When Postgres runs an analyze, it takes a sample of the table to use for
generating statistics. There are several subtleties around how Postgres samples
the table that can impact the accuracy of the tables statistics, and at present
it's not possible to solve all of them.

### Sample size

The Postgres GUC (Grand Unified Configuration) variable
`default_statistics_target` defines the default sample size Postgres uses for
computing statistics, as well as setting the number of most common values to
track for each column. The default value is 100, which means "take samples of
100 * 300 (magic number) pages when running an analyze", then sample randomly
from amongst the rows included in these pages.

But how large a sample is large enough? The n distinct estimator used by
Postgres is from IBM Research Report RJ 10025 (Haas and Stokes), where the
authors discuss the bias and error that is expected from the estimator given
various sample sizes and underlying data characteristics.

In their analysis of the estimator, they note that it has been proven by Bunge
and Fitzpatrick (Estimating the Number of Species: A Review) that unbiased
estimators do not exist when the sample size is smaller than the count of the
most frequently occurring value in the population. The bias in these estimators
is significant (anywhere up-to 80%) and small sample sizes will cause the bias
to increase.

The estimator bias is always negative, meaning we estimate fewer distinct values
than are actually present- this could explain the underestimation leading to our
query plan malfunction. There can be anywhere up to 100k `payment_transitions`
with the same `payout_id` value, so we should sample at least as many transition
rows as to provide that many distinct `payout_id` values. As ~80% of
`payout_id`s are NULL, we require 1/0.8 * 100k = 500k rows, or 1666 as a
statistics target.

We bumped the statistics target for this column like so:

```sql
ALTER TABLE payment_transitions
ALTER COLUMN payout_id SET STATISTICS 1666;
```

And repeatedly ran analyzes, checking the n distinct value at each run. While
the values were slightly better than what we'd seen before we continued to see
large variation and massive underestimation. It wasn't until we bumped our
target to 5000 that the value became more stable.

### Not all samples are created equal

We expected that bumping our sample size to ~500 would produce markedly better
results than the default 100, but this turned out not to be the case. Careful
thought about how Postgres generates our random sample lead to the conclusion
that we were unduly biasing our estimator by taking a fair, random sample from a
statistically biased selection of pages.

Postgres generates its samples in a two stage process: if we want to collect a
sample of 100k rows, we'll first gather 100k pages and then collect our sample
from those pages. It is not the case that every table tuple has the same
probability of appearing in our sample, as we're confined to a specific
selection of pages. Ideally this shouldn't be a problem, assuming column values
are distributed independently amongst pages, but in our case (and we suspect
many others) this is not true.

Our system creates all `payment_transitions` for the same `payout_id` in one
sweep. The `payment_transitions` table is mostly append-only, so Postgres is
prone to place all those new transitions physically adjacent to one another,
sharing the same pages. If we take our random sample from a restricted set of
pages we've vastly increased the probability of sampling a value multiple times
in comparison to selecting from the entire table. 

We can confirm this bias by using Postgres [table
samples](https://blog.2ndquadrant.com/tablesample-in-postgresql-9-5-2/) to
compute our statistics with a system strategy (approximates our analyze process)
vs statistically fair sampling with bernoulli. The results are quite stark:

```
postgres=# select count(distinct(payout_id)) from payment_transitions tablesample system(0.1);
 count 
-------
 41486
postgres=# select count(distinct(payout_id)) from payment_transitions tablesample bernoulli(0.1);
 count 
-------
 78120
```

## Conclusions

Postgres has a fantastic statistics engine that can help scale a database far
beyond the size of the average organisation. It also provides great tools and
documentation that can help you deal with most performance issues that crop up
with growth, and the flexibility via configuration values to handle most use
cases.

That said, sometimes the heuristics that power the query planner can lead
Postgres to make decisions that can flip your performance on its head. In this
production issue we saw a normally fast query degrade in a spectacular fashion,
and it was only after peeling back a few layers that we began to understand why
it happened.

Whenever these problems arise, it pays to have a strategy to detect the
regression and the confidence to properly tackle the debugging. Over time you'll
develop a playbook that can help you solve each problem faster, and eventually
the tooling to prevent them from happening in the first place.

Hopefully this provides a useful case study for people aiming to learn more
about the query planner and it's sharper edges. Please comment if anything is
unclear, and any corrections/suggestions for improvements are welcome.
