# packtrail reference

Converted from https://henomis.github.io/packtrail/docs.html. Everything needed to declare flows, write workers, drive executions and operate a deployment. Packtrail is an event-sourced workflow engine on NATS JetStream: every execution is an ordered log of decisions, and everything else — state, indexes, jobs, timers — is derived from it. The Go API reference is on [pkg.go.dev](https://pkg.go.dev/github.com/henomis/packtrail).

## Installation

Packtrail is a Go module. It needs Go 1.26+ and a NATS Server 2.12+ with JetStream enabled: durable timers and cron are JetStream message schedules.

```
$ go get github.com/henomis/packtrail
$ go install github.com/henomis/packtrail/cmd/packtrail@latest      # CLI
$ go install github.com/henomis/packtrail/cmd/packtrail-ui@latest   # dashboard

# a NATS server with JetStream for local development
$ docker run --rm -p 4222:4222 nats:2.14.2 -js
```

Packages: `packtrail` (engine and client), `worker` (the Go worker SDK), `flow` (definitions: parse, build, validate) and `event` (event types, for readers of `History` and `Watch`). Packtrail never owns the `*nats.Conn` you pass in: your code connects and closes it.

------------------------------------------------------------------------

## Quick start

An engine, one worker and a client in a single program. In production they are usually separate processes — they share nothing but NATS.

```
const hello = `
name: hello
nodes:
  - {id: greet, type: task, kind: greeter, next: shout}
  - {id: shout, type: task, kind: shouter}
`

nc, _ := nats.Connect(nats.DefaultURL)
defer nc.Close()

eng, err := packtrail.New(nc, packtrail.WithFlowYAML([]byte(hello)))
if err != nil { log.Fatal(err) }
if err = eng.Init(ctx); err != nil { log.Fatal(err) } // provision, register flows
go eng.Run(ctx)

greeter, _ := worker.New(nc, "greeter",
    func(ctx context.Context, j *worker.Job) (*worker.Result, error) {
        var in struct{ Name string }
        if err := j.Input(&in); err != nil {
            return nil, worker.Permanent(err)
        }
        return &worker.Result{Output: mapstringany{"text": "hello " + in.Name}}, nil
    })
go greeter.Run(ctx)

shouter, _ := worker.New(nc, "shouter",
    func(ctx context.Context, j *worker.Job) (*worker.Result, error) {
        var prev struct{ Text string }
        _ = j.Result("greet", &prev) // a previous node's output
        return &worker.Result{Output: mapstringany{"text": strings.ToUpper(prev.Text)}}, nil
    })
go shouter.Run(ctx)

c := eng.Client()
id, _ := c.Start(ctx, "hello", mapstringany{"name": "world"})
st, _ := c.Wait(ctx, id)
fmt.Println(st.Status, string(st.Results"shout")) // completed {"text":"HELLO WORLD"}
```

**`New` performs no I/O.** It validates the configuration — flows, schedules, namespace, tuning — and returns. `Init` provisions the namespace (streams, buckets, object stores), checks the server and registers the flows; `Run` calls it if needed. Call `Init` explicitly when you want `Client()` before `Run`, or provisioning errors to fail fast.

The repository has runnable [examples](https://github.com/henomis/packtrail/tree/main/examples): human in the loop, parallel research with reducers, map-reduce, retries and timeouts, time travel, an agent-style tool loop, subflows, cron and message triggers. `make examples` runs them all.

------------------------------------------------------------------------

## Core concepts

| Concept    | Description                                                                                                                                                                         |
|------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Flow       | An immutable, versioned definition (`<name>.<hash>`). Registering a changed definition creates a new version; executions keep the version they started with.                        |
| Execution  | An event log on `<ns>.ev.<partition>.<exec>`. Status `running`, `waiting`, `completed`, `failed` or `cancelled`.                                                                    |
| Engine     | Processes commands per partition: load state → decide → append the decision with an expected-sequence check → ack. One engine is active per partition; others take over on failure. |
| Dispatcher | Turns stored events into effects: jobs, timer schedules, child starts, parent notifications, index updates, archival.                                                               |
| Worker     | Serves one *kind*: consumes jobs, heartbeats long ones, answers with `complete`, `fail` or `interrupt`.                                                                             |
| Channels   | Typed state written by tasks as deltas and folded by reducers.                                                                                                                      |
| Context    | What workers and expressions see: `input`, `channels`, `results`, `last_node`, `visits`, `signals`, `branches`, `counters`, `errors`, and `item`/`index`/`resume` when set.         |

### Workflow as data

You declare the graph; packtrail interprets it. That puts it closer to other graph-based engines than to the workflow-as-code model, whose workflows are code replayed deterministically. What it shares with other durable engines is the durability model: event history, durable timers, workers in any language. Your worker code has no determinism rules.

### Delivery semantics

Delivery to workers is **at-least-once**: after a crash a task can run more than once. Make side effects idempotent, or enable the result cache. The engine itself is **exactly-once per decision**: every result carries the task's generation and attempt, and duplicate or stale commands are absorbed by the fold without producing events.

Work that is no longer wanted is stopped: when an execution ends, a task is cancelled (a join settled, a map aborted) or an attempt times out, the running job's context is cancelled with cause `worker.ErrCancelled`. The handler should return promptly; its result is dropped.

------------------------------------------------------------------------

## Anatomy of a flow

A flow is YAML (one flow per document) or a `flow.Flow` struct. Both go through the same validation: unknown node types, fields that do not belong to a node type, dangling routes, unreachable nodes, routes into a fan-out branch, invalid expressions and bad reducer defaults are all rejected before anything runs. `packtrail validate flows/*.yaml` does it offline.

research.yaml

```
name: research
description: Ask three sources in parallel, write when two answered
channels:
  notes:   {reducer: append}
  sources: {reducer: merge}
  cost:    {reducer: sum}
budget: {cost: 10}
max_steps: 100
search_attributes: {topic: "input.topic"}
retention: 720h
nodes:
  - {id: gather, type: fanout, branches: archive, journals, forums, next: enough}
  - {id: archive,  type: task, kind: source, timeout: 5s}
  - {id: journals, type: task, kind: source, timeout: 5s}
  - {id: forums,   type: task, kind: source, timeout: 5s}
  - {id: enough, type: join, policy: "quorum:2", next: write}
  - {id: write, type: task, kind: writer}
```

| Field             | Description                                                                                                                                                                                                                 |
|-------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| name              | Flow name, `A-Za-z0-9_-{1,128}`. Required.                                                                                                                                                                                |
| version           | Definition schema version. Omit it; the current schema is assumed.                                                                                                                                                          |
| description       | Free text.                                                                                                                                                                                                                  |
| start             | Entry node. When omitted, the unique node with no inbound route.                                                                                                                                                            |
| channels          | Typed state: `{reducer, default}` per channel — see channels.                                                                                                                                                  |
| output            | An expression evaluated on completion that yields what the execution returns: an object or null. Default: every channel, or the last node's result when the flow declares none — see channels. |
| nodes             | The graph. Node ids are tokens and unique; `next` is the static successor (empty on a terminal node).                                                                                                                       |
| budget            | Caps on generic counters reported by workers (`Result.Usage`, `worker.WithUsage` for runs that fail or interrupt) and the built-in `steps`. Exceeding one fails the execution with `budget_exceeded`.                       |
| max_steps         | Recursion limit: total node entries (default 1000). Exceeding it fails with `max_steps`.                                                                                                                                    |
| search_attributes | Expressions evaluated on the start input and indexed, for `List` / `packtrail list -attr`.                                                                                                                                  |
| retention         | How long a finished execution is kept before it expires (default: forever). What expiry does is `on_expire`.                                                                                                                |
| on_expire         | `archive` (default): the execution moves to the archive, where it stays readable. `delete`: it is removed for good, with no archive. Needs a `retention`. See retention.                                      |
| archive_retention | Delete an archived execution this long after it was archived (default: keep archives forever). Not with `on_expire: delete`.                                                                                                |
| triggers          | Start the flow when a message arrives on a subject — see triggers.                                                                                                                                             |

An execution completes when it reaches a terminal node and nothing else is in flight. Durations are Go duration strings (`30s`, `5m`, `72h`).

------------------------------------------------------------------------

## Channels & reducers

Channels are the shared, typed state of an execution. A worker returns `Writes` — deltas keyed by channel — and each channel folds them with its reducer. Because writes are folded, parallel branches never overwrite each other. Writing an undeclared channel, or a value that does not fit the reducer, fails the attempt.

| Reducer | Behaviour                                                                   |
|---------|-----------------------------------------------------------------------------|
| replace | The default: the last write wins.                                           |
| append  | The channel is a list; a write appends a value (or each element of a list). |
| merge   | The channel is an object; a write is merged in key by key.                  |
| sum     | The channel is a number; a write adds to it.                                |

Channels can also be written from outside the graph: synchronously on a running execution with `Client.Update`, or on a fork with `WithForkWrites`. Both go through the reducers.

A completed execution returns its channels as an object keyed by channel name (a flow with no channels returns its last node's result). To keep working state such as an agent's memory out of the output, set the flow's `output` expression: `output: "{answer: channels.answer}"` returns only `answer`, and `output: "resultslast_node"` returns the last node's result even though channels exist. Quote it, since YAML would read a bare `{…}` as a map. Channels the output leaves out stay in the state, so `State`, history and forks still see them. An output that is not an object or null fails the execution with reason `expression_error`.

`last_node` is the last task, join, map, subflow or await to settle: an await's result is the signal payload, and a node that failed into `on_failure` counts too. A choice never sets it. So when a flow ends from a choice the default output is the result of whatever ran just before it: in an evaluator-optimizer loop or behind a guardrail that is the verdict, not the work being judged, and after an approval await it is the signal payload. Name the result you want, as in `output: "results.generate"`.

------------------------------------------------------------------------

## Expressions & context

Choice rules, map sources, subflow inputs, concurrency keys, search attributes and the flow's `output` are [expr](https://github.com/expr-lang/expr) expressions, compiled when the flow is validated. They see the execution context:

| Variable     | Contents                                                                                                                                                   |
|--------------|------------------------------------------------------------------------------------------------------------------------------------------------------------|
| input        | The start payload (a JSON object).                                                                                                                         |
| channels     | The reduced state channels.                                                                                                                                |
| results      | Each settled node's latest output, by node id. A join's result is its branch outputs; a map's, its outputs in item order; a subflow's, the child's output. |
| last_node    | The most recently settled node.                                                                                                                            |
| visits       | How many times each node was entered.                                                                                                                      |
| signals      | Consumed signal payloads, by signal name.                                                                                                                  |
| branches     | Branch status of the last fan-out, by branch id.                                                                                                           |
| counters     | Generic usage counters (and `steps`).                                                                                                                      |
| errors       | The last permanent failure of each node: `{error, reason, attempt, index?}`.                                                                               |
| item / index | The current element of a map (map instances only).                                                                                                         |

Expressions are restricted to a bounded, straight-line subset: comparisons, arithmetic, boolean logic, membership (`in`), regex `matches`, field and index access and `len()`. Other function calls, ranges and iteration are rejected at validation, so a flow author cannot write an expression that runs unbounded inside the engine.

------------------------------------------------------------------------

##  task

A `task` is a job for a worker of the given `kind`, published on `<ns>.work.<kind>` with the execution context. Its output becomes `results.<node>`.

| Field         | Description                                                                                                                                                                                                                                                                                                                                                                                                 |
|---------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| kind          | Worker kind. Required.                                                                                                                                                                                                                                                                                                                                                                                      |
| timeout       | Per-attempt deadline. A late result is ignored; the attempt counts as failed and is retried by the policy.                                                                                                                                                                                                                                                                                                  |
| retry         | `{max_attempts, backoff, delay, max_delay}`. `max_attempts` is the total (1 = no retry, at most 64). `backoff`: `fixed` (default), `linear` or `exponential`; `delay` defaults to 1s, `max_delay` to 5m. Backoff waits are durable timers.                                                                                                                                                                  |
| output_schema | A JSON Schema the output must match; a mismatch fails the attempt with `invalid_output`. External `$ref`s are not loaded.                                                                                                                                                                                                                                                                                   |
| cache         | `{ttl}`: reuse a previous result for the same flow version, node and inputs (input, channels, results, signals, item, resume) within the TTL, instead of dispatching a job. A result is stored once its node completes, so runs with the same inputs that start while the first is still working each miss and run the job too: the cache saves repeated work over time, it does not merge concurrent work. |
| concurrency   | `{key, max}`: at most `max` jobs of this node run at once per value of the `key` expression, across all executions (e.g. per customer).                                                                                                                                                                                                                                                                     |
| dynamic       | Nodes the worker may route to by returning `Result.Next` (a dynamic edge). Without a `next` from the worker, `next` applies.                                                                                                                                                                                                                                                                                |
| next          | Static successor.                                                                                                                                                                                                                                                                                                                                                                                           |
| on_failure    | Handler node for a permanent failure — see failure routing.                                                                                                                                                                                                                                                                                                                                  |
| meta          | Free-form configuration for the worker (any JSON object), handed over as `Job.Meta`. See below.                                                                                                                                                                                                                                                                                                             |

Any node may carry `meta`; the engine ignores it. It is part of the definition, so it changes the flow hash and is returned by `Client.Flow(name, version)`, and each job of a task or map node carries the `meta` of the version its execution runs: a redeploy never changes it under a running execution, a fork or a rerun. Keep secrets out of it, since it is stored with the flow and sent with every job.

agent loop with dynamic edges

```
name: agent
max_steps: 30
budget: {calls: 5}
channels:
  messages: {reducer: append}
nodes:
  - {id: plan, type: task, kind: planner, dynamic: search, calculate, answer}
  - {id: search,    type: task, kind: tool, next: plan}
  - {id: calculate, type: task, kind: tool, next: plan}
  - {id: answer,    type: task, kind: tool}
start: plan
```

------------------------------------------------------------------------

##  choice

Routes on the first rule whose `when` expression is true; exactly one rule must be the `default`. Every evaluation is recorded as a `ChoiceEvaluated` event, so the route taken is part of the history. A rule may carry a `name` (unique within the node), recorded on that event so the history says why, not just which rule index.

yaml

```
- id: route
  type: choice
  rules:
    - {name: approved, when: "signals['manager-decision'].approved", to: pay}
    - {when: "results.check.amount > 1000 && visits.check < 3", to: check}
    - {default: true, to: reject}
```

A rule's `to` may be `$end` instead of a node: the execution completes right there, with the flow's `output`. `$end` is not a node, so it is never entered and does not count towards `visits` or `max_steps`. In a subflow's child it ends the child; the parent goes on. This is how a loop such as evaluator-optimizer finishes without a no-op task:

yaml

```
start: generate
output: "results.generate"
nodes:
  - {id: generate, type: task, kind: writer, next: evaluate}
  - {id: evaluate, type: task, kind: judge, next: check}
  - id: check
    type: choice
    rules:
      - {when: "results.evaluate.pass || visits.generate >= 3", to: $end}
      - {default: true, to: generate}
```

`on_error` decides what an expression error (typically a missing field) does. By default the rule simply does not match and evaluation moves on; with `on_error: fail` the execution fails with `expression_error`.

------------------------------------------------------------------------

##  fanout & join

A `fanout` starts its `branches` in parallel; its `next` must be the `join` that closes it. Each branch is a `task` or a `subflow` node with no successor of its own — the join owns what happens after the fan. A subflow branch runs any graph (a chain, an await, a nested fan-out) as a child execution and settles with the child. At most 256 branches; use a map for wider or data-driven fan-outs.

| join field | Description                                                                                                                                                                                                                                                                         |
|------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| policy     | `all` (default): every branch must succeed. `any`: the first success settles it. `quorum:N`: N successes. These settle as soon as the outcome is known; branches still running are then cancelled — a subflow branch's child too, unless its `on_parent_close` is `abandon`: then it carries on, unlinked from the join. `min:N`: waits for every branch, then succeeds if at least N did (`min:0` never fails); the output holds every success, and `branches` and `errors` tell which failed and why — the way to tolerate failures without losing results. |
| wait_for   | The branches the policy counts (default: all branches of the fanout).                                                                                                                                                                                                               |
| next       | Successor once the policy is met.                                                                                                                                                                                                                                                   |
| on_failure | Handler when the policy can no longer be met (for `min:N`, once every branch has finished); without it the execution fails with `join_failed`.                                                                                                                                                                                    |

After the join, `results.<join>` holds the branch outputs and `branches` their status. Branches typically contribute to shared state through reducer channels.

------------------------------------------------------------------------

##  await

Waits for a named signal. The `timeout` is mandatory: a durable timer, so an execution parked for days holds no engine resources. On timeout the execution follows `on_timeout`, or fails with `await_timeout` when there is none. The consumed payload is available as `signals.<name>`.

yaml

```
- id: approval
  type: await
  signal: manager-decision
  timeout: 72h
  on_timeout: escalate
  next: route
```

A signal sent before the execution reaches the await is buffered, never lost. Signals carry an id (`WithSignalID`) and delivering the same id twice is a no-op.

------------------------------------------------------------------------

##  map

Runs one task of `kind` per element of the list the `over` expression returns, computed at run time. Each instance sees its element as `item` and its position as `index` (`j.Item(&v)`, `j.Context.Index` in Go). `results.<map>` is the list of outputs in item order.

With `flow` instead of `kind`, each item runs that flow as a child execution (LangGraph's `Send` to a subgraph). The child's input is the item itself when it is an object, or what the `input` expression returns — it sees `item` and `index` besides the parent's context, e.g. `input: "{'name': item, 'slot': index}"`. `on_parent_close` applies to every item's child; `timeout`, `retry` and `output_schema` belong on the child flow's nodes.

wordcount.yaml

```
name: wordcount
channels:
  total:   {reducer: sum}
  longest: {reducer: append}
nodes:
  - {id: count, type: map, kind: counter, over: input.docs, max_parallel: 4}
```

`max_parallel` bounds the instances in flight (default 100, at most 256). `timeout`, `retry` and `output_schema` apply to each instance. When an item fails permanently (or its child does not complete) the map is aborted: items in flight are cancelled (children too, unless abandoned) and `on_failure` (if set) is entered with `errors.<map>.index` naming the item.

------------------------------------------------------------------------

##  subflow

Runs another registered flow as a child execution with its own id, log and state. The child's output becomes `results.<node>` and its usage counters are added to the parent's.

| Field             | Description                                                                                                       |
|-------------------|-------------------------------------------------------------------------------------------------------------------|
| flow              | The child flow name. Required.                                                                                    |
| input             | Expression for the child's input (default: the parent's input).                                                   |
| on_parent_close   | `cancel` (default): cancelling or failing the parent cancels a running child. `abandon`: the child keeps running. |
| next / on_failure | Successor, and handler when the child does not complete (otherwise `child_failed`).                               |

yaml

```
- {id: identity, type: subflow, flow: verify, input: "input.person", next: welcome}
```

------------------------------------------------------------------------

## Failure routing

`task`, `map`, `subflow` and `join` nodes may declare `on_failure: <node>`. When the node fails permanently — retries exhausted, a permanent error, an invalid or unencodable output, a last attempt that timed out, a map item that failed, a child that did not complete, a join whose policy was not met — the execution enters the handler instead of failing. This is how sagas and compensation are expressed in the graph.

yaml

```
- {id: reserve, type: task, kind: inventory, next: charge}
- {id: charge,  type: task, kind: payments,
   retry: {max_attempts: 3, backoff: exponential}, on_failure: release, next: ship}
- {id: release, type: task, kind: inventory}   # undo the reservation
- {id: ship,    type: task, kind: shipping}
```

The handler sees `last_node` = the failed node and `errors.<node>` = `{error, reason, attempt, index?}`; a later success of that node clears its error. Execution-level stops — budget, `max_steps`, cancel — never route. Fan-out branches cannot declare `on_failure`: their join's policy settles them.

------------------------------------------------------------------------

## Schedules & triggers

### Cron schedules

A schedule starts a flow on a cron expression: six fields (second minute hour day-of-month month day-of-week) or a predefined form such as `@hourly` or `@every 30s`. Each firing starts execution `<schedule>-<sequence>`. Schedules are JetStream message schedules, so they survive restarts and fire once however many engines run.

go

```
// installed at Init, validated at New
packtrail.WithSchedule("nightly", "report", "0 0 2 * * *", mapstringany{"scope": "all"})

// or at run time
c.Schedule(ctx, "nightly", "report", "0 0 2 * * *", input,
    packtrail.ScheduleTimeZone("Europe/Rome"), packtrail.ScheduleVersion(hash))
c.Unschedule(ctx, "nightly")
```

### Message triggers

A flow's `triggers` start it for every message on a subject; the message body is the input. With `stream` set, the trigger is a durable JetStream consumer of that stream (at-least-once); without it, a core NATS queue subscription (at-most-once). The execution id is derived from the flow and the message's `Nats-Msg-Id` (`packtrail.TriggerExecID(flow, msgID)`, `<flow>-t<digest>`), so a duplicate message starts nothing twice and several flows triggered by the same message each run once; without a `Nats-Msg-Id` it is derived from the stream and sequence (stream) or fresh (core). A stream message that still cannot be started after its redeliveries is dead-lettered (`trigger`). Create the stream yourself: until it exists the trigger keeps retrying and `Engine.Ready()` stays open.

yaml

```
name: order
triggers:
  - {subject: orders.created, stream: ORDERS}
nodes:
  - {id: fulfil, type: task, kind: work}
```

------------------------------------------------------------------------

## Workers

A worker serves one kind. Every process of a kind shares one durable consumer; each process fetches no more jobs than its free slots (`WithConcurrency`, default 4). Long jobs are heartbeated automatically. A panic in the handler is recovered and reported as a retryable failure — it never takes the process down.

worker.go

```
w, err := worker.New(nc, "source", handle,
    worker.WithNamespace("acme"), worker.WithConcurrency(16))
if err != nil { log.Fatal(err) }
log.Fatal(w.Run(ctx)) // drains in-flight jobs when ctx ends

func handle(ctx context.Context, j *worker.Job) (*worker.Result, error) {
    var in struct{ Topic string }
    if err := j.Input(&in); err != nil {
        return nil, worker.Permanent(err)       // fail now, no retry
    }
    _ = j.Progress(mapstringany{"step": "fetching"}) // optional, never stored

    hits, err := search(ctx, in.Topic)
    if err != nil {
        return nil, err                         // retried by the node's policy
    }
    return &worker.Result{
        Output: mapstringany{"hits": len(hits)},    // results.<node>
        Writes: mapstringany{"notes": hits0},     // channel deltas
        Usage:  mapstringfloat64{"cost": 0.4},    // budget counters
    }, nil
}
```

### The job

| Member                               | Description                                                                                                                                                                               |
|--------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| ExecID, Flow, Node, Kind             | Where the job comes from.                                                                                                                                                                 |
| Attempt, Generation                  | Attempt number (from 1) and the instance generation. A redelivered job keeps both.                                                                                                        |
| Deliveries                           | How many times this message was delivered (redelivery after a crash).                                                                                                                     |
| Context                              | The raw execution view (context variables).                                                                                                                               |
| Input, Channel, Result, Signal, Item | Decode a part of the context into a Go value.                                                                                                                                             |
| Resumed(&v)                          | Whether this run resumes an interrupt, and the resume value.                                                                                                                              |
| Interrupted(&v)                      | On a resumed run (every attempt), the payload this node interrupted with.                                                                                                                 |
| Progress(v)                          | Publish an intermediate result on `<ns>.progress.<exec>.<node>`.                                                                                                                          |
| Store()                              | The long-term store of the worker's namespace, the same one `Client.Store()` reads: `Put`, `Get`, `Delete`, `Keys`. Writes are outside the log, so keep them idempotent under redelivery. |
| ResumedBy                            | On a resumed run (every attempt), who resumed it (`WithResumedBy`); empty when the resume named nobody.                                                                                   |
| Traceparent                          | W3C trace context of the command that scheduled the job: the one given with `WithTraceparent` at start reaches the jobs that follow from the start. Empty when that command had none, such as a timer, or a signal or resume sent with `Client`. |
| Logger()                             | The worker's logger with this attempt bound: `exec`, `flow`, `node`, `key`, `kind`, `generation`, and `attempt`, plus `trace_id` and `span_id` from a valid traceparent. See Logging.        |
| Meta, DecodeMeta(&v)                 | The node's `meta` from the execution's flow version (raw JSON, nil when absent), and a decoder for it.                                                                                    |

### Outcomes

| Return                       | Effect                                                                                                                                                                                                                                                                                                                                                        |
|------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| \*Result, nil                | Complete: `Output` (a JSON object or nil), `Writes`, `Next` (a declared dynamic successor), `Usage`. A result that cannot be encoded as JSON (e.g. NaN in `Usage`) fails the task permanently.                                                                                                                                                                |
| nil, err                     | Fail the attempt; retried by the node's policy.                                                                                                                                                                                                                                                                                                               |
| worker.Permanent(err)        | Fail without retry; `on_failure` or execution failure follows.                                                                                                                                                                                                                                                                                                |
| worker.Interrupt(payload)    | Pause at this node until `Client.Resume` — see human in the loop.                                                                                                                                                                                                                                                                                   |
| worker.WithUsage(err, usage) | Any of the errors above, plus the usage the run spent: added to the counters like `Result.Usage`, for every attempt. It composes with `Permanent`, `Interrupt` and `%w` in any order (the outermost counts). A counter past its budget fails the execution at this node: no retry, no pause. A run that never returns (cancelled, timed out) reports nothing. |

### Cancellation

When an execution ends, a task is cancelled or an attempt times out while a job runs, its context is cancelled with cause `worker.ErrCancelled` (check `context.Cause(ctx)`). Return promptly: the result is dropped. Stop notices are best effort; a periodic check of the execution's log head (`worker.WithLiveCheck`) covers a lost notice.

Workers in other languages implement the protocol; `PT_CONFORMANCE_WORKER="<command>"` runs the conformance suite against them.

------------------------------------------------------------------------

## The client

`eng.Client()` returns a client bound to the engine's namespace; from another process use `packtrail.NewClient(nc, packtrail.WithClientNamespace("acme"))`. It is safe for concurrent use and performs no I/O until the first call. `WithClientLogger(l)` sets the logger for its own diagnostics (default `slog.Default()`); the engine's client uses the engine's logger.

| Method                          | Description                                                                                                                                                                                                                                                                                                        |
|---------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Start(flow, input, …)           | Start an execution; returns its id. `WithExecutionID` makes it idempotent on that id (an id of another flow's execution fails with `ErrExecutionConflict`; `WithJoinExisting(false)` fails with `ErrExecutionExists` instead of joining), `WithVersion` pins a flow version, `WithTraceparent` propagates a trace. |
| Signal(exec, name, payload)     | Deliver a signal (buffered if no await is waiting yet); `WithSignalID` deduplicates.                                                                                                                                                                                                                               |
| Update(exec, writes)            | Write channels synchronously and return the state right after.                                                                                                                                                                                                                                                     |
| Resume(exec, node, value, …)    | Re-run an interrupted node with a value. `WithResumedBy(actor)` (≤ 256 bytes) records who resumed it on the history and hands it to the worker as `Job.Context.ResumedBy`.                                                                                                                                                                                                                                                           |
| Cancel(exec, reason)            | Cancel; a no-op on a finished execution.                                                                                                                                                                                                                                                                           |
| Get(exec)                       | Current state (archived executions are read from the archive).                                                                                                                                                                                                                                                     |
| Wait(exec)                      | Block until the execution finishes and return the final state. Only `ctx` ends it early.                                                                                                                                                                                                                           |
| Watch(exec, from)               | Stream events from a sequence.                                                                                                                                                                                                                                                                                     |
| WatchTerminal(from)             | Stream the end of every execution (status and sequence), from now or a sequence.                                                                                                                                                                                                                                   |
| Progress(exec)                  | Stream workers' progress messages from now on.                                                                                                                                                                                                                                                                     |
| List(filter)                    | Indexed executions by status, flow or search attribute, newest first.                                                                                                                                                                                                                                              |
| History, StateAt, OutputHistory | See time travel.                                                                                                                                                                                                                                                                                    |
| Fork, Rerun                     | See time travel.                                                                                                                                                                                                                                                                                    |
| Register, Flows, Flow           | Store a definition (new version when changed), list versions, read one.                                                                                                                                                                                                                                            |
| Schedule, Unschedule, Schedules | Manage cron schedules.                                                                                                                                                                                                                                                                                             |
| DeadLetters, Redrive            | Inspect and re-publish dead letters (a `trigger` one restarts only its own flow).                                                                                                                                                                                                                                  |
| Quarantined, Unquarantine       | See quarantine.                                                                                                                                                                                                                                                                                     |
| Store()                         | A namespaced key-value store for application data that outlives executions: `Put`, `Get`, `Delete`, `Keys`.                                                                                                                                                                                                        |

`State` carries `Status`, `Input`, `Channels`, `Results`, `LastNode`, `Visits`, `Steps`, `Signals`, `Counters`, `Branches`, `Errors`, the work in flight, and on a finished execution `Output`, `Error`, `Reason` and `FailedNode`.

------------------------------------------------------------------------

## Human in the loop

Three mechanisms, for three situations:

| Mechanism          | Use it when                                                                                                                                                                                                                                                                              |
|--------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| await + Signal     | The graph knows it has to wait for an external event (an approval, a webhook). Durable timeout and route.                                                                                                                                                                                |
| Interrupt + Resume | A worker discovers mid-task that it needs input. It returns `worker.Interrupt(question)`; the execution is `waiting`; `Client.Resume(exec, node, answer)` runs the node again, where `j.Resumed(&answer)` is true and `j.Interrupted(&question)` returns the question, on every attempt. |
| Update             | Someone outside the graph corrects the state of a running execution. Validated against the channels, applied once per update id, synchronous.                                                                                                                                            |

go

```
// worker side
var answer struct{ Approved bool }
if ok, _ := j.Resumed(&answer); !ok {
    return nil, worker.Interrupt(mapstringany{"question": "refund 1200€?"})
}

// operator side
_ = c.Resume(ctx, id, "refund", mapstringany{"approved": true})
st, err := c.Update(ctx, id, mapstringany{"notes": "checked by ops"},
    packtrail.WithUpdateID("ticket-4711"))
```

------------------------------------------------------------------------

## Time travel & forks

The events of one decision are stored as one message, so a stream sequence identifies a decision and every stored message is a consistent cut. All of these read the log; none of them touch the source execution.

| Call                      | Description                                                                                                                                                                                                                                                                                                                                                                                                          |
|---------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| History(exec)             | Every event in order, including archived segments of long executions.                                                                                                                                                                                                                                                                                                                                                |
| StateAt(exec, seq)        | The state right after the decision at `seq`.                                                                                                                                                                                                                                                                                                                                                                         |
| OutputHistory(exec, node) | Every output the node produced, oldest first — one per visit.                                                                                                                                                                                                                                                                                                                                                        |
| Fork(exec, seq, …)        | A new execution from the state at `seq`, continuing from there: what was in flight is dispatched again. `WithForkWrites` edits its channels first; `WithForkID` names it.                                                                                                                                                                                                                                            |
| Rerun(exec, node, …)      | Fork at the point the node was last entered, so it (and what follows) runs again — the usual move after fixing a worker bug. The node must still be in flight when the decision that entered it ends (a task, map, subflow, fan-out or waiting await): a node that settled right away (a choice, a join, an await whose signal was already buffered) is refused with `ErrInvalidArgument`; rerun the node before it. |

go

```
evs, _ := c.History(ctx, id)
past, _ := c.StateAt(ctx, id, 12)
fork, _ := c.Fork(ctx, id, 12, packtrail.WithForkWrites(mapstringany{"notes": "try again"}))
again, _ := c.Rerun(ctx, id, "draft")
```

------------------------------------------------------------------------

## Statuses & failures

| Status    | Meaning                                                                                               |
|-----------|-------------------------------------------------------------------------------------------------------|
| running   | Work is in flight or about to be.                                                                     |
| waiting   | Only awaits or interrupted tasks are open: nothing will happen without a signal, a resume or a timer. |
| completed | Reached a terminal node; `Output` is set.                                                             |
| failed    | `Error`, `Reason` and `FailedNode` say why.                                                           |
| cancelled | Cancelled by a client, or by its parent.                                                              |

| Reason             | Cause                                                                                                                                                        |
|--------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------|
| error              | A task failed permanently or ran out of attempts.                                                                                                            |
| timeout            | The last attempt timed out.                                                                                                                                  |
| invalid_output     | The output did not match `output_schema`.                                                                                                                    |
| await_timeout      | An await timed out with no `on_timeout`.                                                                                                                     |
| join_failed        | A join's policy could not be met.                                                                                                                            |
| child_failed       | A subflow's child did not complete.                                                                                                                          |
| expression_error   | A choice rule failed with `on_error: fail`, a map's `over` or a subflow or map input could not be built, or the flow's `output` failed or was not an object. |
| budget_exceeded    | A counter passed its budget.                                                                                                                                 |
| max_steps          | The recursion limit was reached.                                                                                                                             |
| delivery_failed    | A job exhausted its deliveries (worker crashes); it is dead-lettered.                                                                                        |
| unknown_flow       | A subflow names a flow that is not registered.                                                                                                               |
| decision_too_large | One decision would exceed 1 000 events.                                                                                                                      |

Node failures — `error`, `timeout`, `invalid_output`, `delivery_failed`, `join_failed`, `child_failed` — route to `on_failure` when the failed node declares one. Budget, `max_steps`, an await timeout without a route, an expression error and an oversized decision always end the execution.

------------------------------------------------------------------------

## Logging

The engine (`WithLogger`), workers (`worker.WithLogger`) and clients (`WithClientLogger`) log through a `*slog.Logger`, with the request context when there is one. Messages start with `packtrail:` or `worker:`, and attributes use the same keys everywhere: `exec`, `flow`, `node`, `key`, `kind`, `generation`, `attempt`, `cmd`, `type`, `seq`, `err`, `duration`.

| Level | What |
|---|---|
| Error | Work lost or an operator must act: an execution quarantined, a dead letter not written, a handler panic. |
| Warn  | Something failed and is retried, or was dead-lettered. |
| Info  | Rejected commands and commands for archived executions. |
| Debug | One line per decision (`packtrail: decision applied`: type, events, seq, duration), per job sent (`packtrail: job dispatched`) and per attempt (`worker: job started` with the queue wait, `worker: job ended` with the outcome and duration). |

A handler logs through `job.Logger()`, so its lines carry the same keys as the engine's: filter on `exec` to follow one execution across processes. When the job carries a traceparent (`WithTraceparent` at start), worker lines also carry `trace_id` and `span_id`, and the engine's decision lines `trace_id`, so logs join the traces of the caller.

------------------------------------------------------------------------

## Engine options

| Option                                   | Description                                                                                                                           |
|------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------|
| WithNamespace(ns)                        | Prefix of every NATS resource (default `packtrail`); independent deployments can share a cluster.                                     |
| WithFlow, WithFlowYAML, WithFlowsDir     | Flows registered at `Init` (a struct, YAML bytes, every `*.yaml`/`*.yml` of a directory).                                             |
| WithSchedule(name, flow, cron, input)    | A cron schedule installed at `Init`.                                                                                                  |
| WithPartitions(n)                        | Partition count of a new namespace (default 64, at most 1024). Permanent.                                                             |
| WithOwnedPartitions(ps…)                 | Restrict this engine to some partitions (default: compete for all; one is active per partition).                                      |
| WithReplicas(n)                          | Replication of every stream, bucket and object store. Use 3 in production.                                                            |
| WithoutDispatcher, WithoutCommands       | Run only one role, to scale them independently.                                                                                       |
| WithHistoryLimit(n)                      | Continue as new past n live events (default 10 000; negative disables).                                                               |
| WithSnapshotEvery(n)                     | Snapshot states every n events (default 100; negative disables).                                                                      |
| WithStateCacheSize(n)                    | In-memory state cache entries (default 10 000).                                                                                       |
| WithDrainTimeout(d)                      | Graceful drain budget on shutdown (default 30s).                                                                                      |
| WithAckWait(d)                           | How long a message held by a crashed engine waits before another gets it (default 5s).                                                |
| WithPullExpiry(d)                        | Pull request lifetime (default 5s); shorter hands partitions over faster.                                                             |
| WithReadTimeout(d)                       | One batched read of an event log (default 5s).                                                                                        |
| WithBlobThreshold(n), WithBlobTimeout(d) | Claim-check: bodies above n bytes go to the object store (default: server max payload minus a margin); transfer timeout (default 2m). |
| WithLogger, WithClock                    | A `*slog.Logger`; the decision clock (tests).                                                                                         |

`packtrail.ValidateOptions(opts...)` runs every check `New` does without a connection, so CI can reject a bad configuration. `ValidateNamespace`, `ValidateName` and `ValidateCron` expose the identifier and cron rules.

`Engine.Ready()` and `Worker.Ready()` return a channel that closes once `Run` has provisioned and every consumer of the process (commands, dispatch, cron, triggers; a worker's jobs and stop notices) is pulling: wire it to a readiness probe. It stays open when `Run` fails; once `Run` returns, `Ready()` hands out a new, open channel, so call it at each probe. It reports start-up, not later connectivity.

------------------------------------------------------------------------

## Worker options

| Option                                                 | Description                                                                                                 |
|--------------------------------------------------------|-------------------------------------------------------------------------------------------------------------|
| WithNamespace(ns)                                      | Must match the engine's (default `packtrail`).                                                              |
| WithConcurrency(n)                                     | Parallel jobs in this process (default 4); it never prefetches more.                                        |
| WithAckWait(d)                                         | How long a job may go without a heartbeat before redelivery (default 30s, at least 1s). Kind-wide.          |
| WithMaxDeliver(n)                                      | Deliveries before a job is dead-lettered and its node failed (default 5). Kind-wide.                        |
| WithMaxAckPending(n)                                   | Jobs of this kind in flight across every process (default 10 000). Kind-wide.                               |
| WithReconfigure()                                      | Apply this worker's kind-wide settings to the shared consumer. Without it the first worker's settings stay. |
| WithLiveCheck(d)                                       | Period of the log-head check that stops jobs whose execution ended.                                         |
| WithDrainTimeout(d), WithBlobTimeout(d), WithLogger(l) | Shutdown drain, claim-check transfer timeout, logger.                                                       |

------------------------------------------------------------------------

## Running in production

### Replication

Use `WithReplicas(3)` on a JetStream cluster: the events stream is the source of truth. Without the option existing resources keep their replication, so an engine started without it never scales a deployment down. Asking for replicas on a standalone server fails at `Init`.

### Partitions are permanent

The partition is part of every event subject, so the count cannot change for a namespace. Pick it up front; to change it, run a new namespace alongside and let the old one drain.

### Scaling

Run as many engines as you like: pinned consumers make one active per partition and fail over automatically. `WithoutDispatcher` / `WithoutCommands` split the roles. Workers scale per kind, independently.

### Quarantine

An execution whose events the dispatcher can never process (deterministic failures: an undecodable event, an unknown flow version, a request the server rejects as bad) is quarantined instead of stalling its partition: `packtrail quarantined` lists them, and they can still be cancelled. Once the cause is fixed — typically by an upgrade — `packtrail unquarantine <exec>` replays what was skipped. Transient outages never quarantine: the dispatcher waits and retries forever.

### Metrics & alerting

`Engine.Metrics(ctx)` returns counters (commands, conflicts, events appended, jobs dispatched, cache hits, timers, dead letters, archived, deleted), `ProjectionLag` and `DispatchStall`: the longest time a partition with pending events has gone without progress. Alert when it exceeds a minute or so.

### Long histories

Once an execution's live log holds 10 000 events (`WithHistoryLimit`), it is continued as new under the same id: the log so far is archived as a segment and replaced by one event carrying the state. Nothing else changes; `History`, `StateAt`, `Fork` and `Rerun` still see every event.

### Retention & the index

A flow's `retention` is how long a finished execution stays live. When it expires the execution is archived to the archive object store (`on_expire: archive`, the default) or deleted (`on_expire: delete`); `Engine.Archive` and `Engine.Delete` do it immediately. An archived execution stays readable — state, history, time travel, fork — but cannot be driven any more, and its id is never started again. Archives are kept forever unless the flow sets `archive_retention`, which deletes an execution that long after it was archived.

expiry

```
# live for 30 days, then archived for a year, then deleted
retention: 720h
archive_retention: 8760h

# or: live for 5 hours, then deleted, never archived
retention: 5h
on_expire: delete
```

A deleted execution leaves nothing behind: its events, snapshot, blobs, timers, archive and index entries are removed, without delete markers, so storage does not grow with the executions that ever ran. It reads as `ErrNotFound` and its id is free: a `Start` with it runs a new execution. Because message ids are derived from the execution id and deduplicated for ten minutes, an execution is never deleted sooner than that after it finished: a shorter `retention` with `on_expire: delete` deletes at ten minutes, and `Engine.Delete` refuses until then.

The visibility index is a projection: `Engine.RebuildIndex` (`packtrail rebuild-index`) rebuilds it from the log.

### Benchmarks

On a laptop (Ryzen 7 5825U, embedded nats-server, file storage): ≈ 2 100 executions/s of a three-step flow on one engine, ≈ 0.86 ms per step for a single execution, ≈ 1 330 executions/s on a three-node R3 cluster. 10 000 parked executions survive an engine restart and all complete once signalled.

------------------------------------------------------------------------

## CLI

`packtrail [-server URL] [-ns NAMESPACE] [-log-level L] [-log-format F] <command>`. It is a client of the deployment, plus `run` to host an engine. Output is JSON on stdout; logs go to stderr at `-log-level` (`debug`, `info`, `warn`, `error`; default `$PACKTRAIL_LOG_LEVEL` or `info`) in `-log-format` (`text` or `json`; default `$PACKTRAIL_LOG_FORMAT` or `text`). `packtrail-ui` takes the same two flags.

packtrail

```
# engine
run -flows DIR -partitions N       # run an engine until interrupted
init -flows DIR -partitions N      # provision the namespace and register flows
rebuild-index                          # rebuild the visibility index from the log
archive <exec>                         # archive a finished execution now
delete <exec>                          # delete a finished execution now, archive included

# flows
validate <file.yaml>...                # validate flow files offline
register <file.yaml>...                # register flow versions
flows                                  # list registered versions

# executions
start <flow> -input JSON -id ID -version HASH -wait
signal <exec> <name> -payload JSON -id ID
update <exec> -writes JSON -id ID
resume <exec> <node> -value JSON -by ACTOR
cancel <exec> -reason TEXT
get <exec> -seq N                    # state now, or right after event N
history <exec>
watch <exec>                           # stream events until the execution ends
progress <exec>                        # stream workers' progress messages
wait <exec>
fork <exec> <seq> -id ID -writes JSON
rerun <exec> <node> -id ID
list -status S -flow F -attr K=V -limit N

# schedules and dead letters
schedule <name> <flow> <cron> -input JSON -tz ZONE
unschedule <name>
schedules
dlq -limit N
redrive <seq>
quarantined
unquarantine <exec>
```

------------------------------------------------------------------------

## packtrail-ui

A debugging dashboard: execution list, the flow graph coloured by node state, the event timeline with the state at any sequence, and actions — signal, resume, cancel, fork, rerun, dead-letter redrive. It needs only NATS (`NATS_URL`, default `nats://localhost:4222`).

| Flag        | Description                                                                                              |
|-------------|----------------------------------------------------------------------------------------------------------|
| -addr       | Listen address (default `127.0.0.1:8088`, env `PACKTRAIL_UI_ADDR`).                                      |
| -namespace  | Namespace selected first (default `packtrail`, env `PACKTRAIL_NAMESPACE`).                               |
| -namespaces | Comma-separated allowlist (env `PACKTRAIL_UI_NAMESPACES`); default: every namespace on the NATS account. |

**No built-in authentication.** The UI can drive executions. It binds to loopback by default; put an authenticating reverse proxy in front before exposing it.

------------------------------------------------------------------------

## Protocol

Everything packtrail exchanges is plain NATS + JSON, so clients and workers can be written in any language. Messages carry `Pt-Protocol-Version: 1`; receivers dead-letter versions they do not know. The Go packages are the reference implementation.

### Resources

| Resource                                               | Kind · subjects / keys                                                                                                                |
|--------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------|
| \<ns\>-events                                          | Stream, one message per decision: `<ns>.ev.<partition>.<exec>`                                                                        |
| \<ns\>-cmd                                             | Work-queue stream with message schedules: `<ns>.cmd.<p>.<exec>`, `<ns>.timer.<exec>.<timer>`, `<ns>.sched.<name>`, `<ns>.cron.<name>` |
| \<ns\>-work                                            | Work-queue stream: `<ns>.work.<kind>`, `<ns>.workdelay.<kind>.<id>`                                                                   |
| \<ns\>-dlq                                             | Stream, 30 days: `<ns>.dlq.<kind>.<key>`                                                                                              |
| \<ns\>-snapshots, -flows, -index, -cache, -sem, -store | KV buckets                                                                                                                            |
| \<ns\>-blobs, \<ns\>-archive                           | Object stores                                                                                                                         |

The partition of an execution is FNV-1a 32-bit of its id modulo the partition count (stored in the `<ns>-cmd` stream metadata, key `packtrail.partitions`). Identifiers that become subject tokens match `A-Za-z0-9_-{1,128}`.

**Claim-check.** A body larger than the threshold (server `max_payload` − 16 KiB by default) is stored in `<ns>-blobs` and the message carries `Pt-Blob: <name>` with an empty body. Every reader resolves it before decoding.

### Commands

Published to `<ns>.cmd.<p>.<exec>` with `Nats-Msg-Id` = the command id (deduplication) and `Pt-Cmd-Type`:

command

```, "reply": "…"}
```

| Type      | data                                                                                                                                                |
|-----------|-----------------------------------------------------------------------------------------------------------------------------------------------------|
| start     | `flow, version?, input?, parent?` — idempotent per execution id (command id `start.<exec>`); `conflict` when the id is an execution of another flow |
| fork      | `from, seq, writes?`                                                                                                                                |
| complete  | `key, generation, attempt, output?, writes?, next?, usage?, cache_key?`                                                                             |
| fail      | `key, generation, attempt, error, retryable, reason?`                                                                                               |
| interrupt | `key, generation, attempt, payload?`                                                                                                                |
| resume    | `node, key?, value?, by?`                                                                                                                           |
| signal    | `name, payload?` — the command id is the signal id                                                                                                  |
| update    | `writes` — send with `reply`; the command id is the update id                                                                                       |
| cancel    | `reason?`                                                                                                                                           |

With `reply` set, the engine answers once the command is decided: `{"ok": true, "seq": N}` (plus `"joined": true` for a start that found its execution already there) or `{"ok": false, "code": "invalid" | "rejected" | "conflict" | "not_found" | "failed", "error": "…"}`; the `Nats-Msg-Id` is then `<id>@<reply>` so a retry with a new inbox still gets an answer. Commands are idempotent; one that can never apply is dead-lettered.

### Jobs and conforming workers

A worker of kind `K` consumes `<ns>.work.K` through the shared durable consumer `<ns>-work-K` (explicit ack). A job body:

job

```, "channels": {}, "results": {}, "last_node": "", "visits": {},
             "signals": {}, "branches": {}, "counters": {}, "errors": {},
             "item": …, "index": …, "resume": …, "resumed_by": …, "interrupt": …},
 "reply": "<ns>.cmd.<p>.e1", "cache_key": "…", "concurrency": {"key": "…", "max": 2},
 "traceparent": "…"}
```

A conforming worker:

1.  Resolves `Pt-Blob` and checks `Pt-Protocol-Version`.
2.  If `concurrency` is set, takes a slot in KV `<ns>-sem` under the key (JSON `{"holders": {"<job id>": "<expiry>"}}`, compare-and-swap, a lease of 3 × ack wait renewed while the job runs). When the key is full, one job per key per process waits; others are handed back by republishing a copy to `<ns>.workdelay.<kind>.<id>` with `Nats-Schedule: @at …`, `Nats-Schedule-Target: <ns>.work.<kind>` and `Pt-Busy` (delays 1, 2, 4, 8 s), then acking the original.
3.  Sends `InProgress` every ack wait / 3 while it holds the job.
4.  Publishes exactly one command to `reply` — `complete`, `fail` or `interrupt` — with `key`, `generation`, `attempt` copied from the job and command id `w.<exec>.<key>.<generation>.<attempt>`, then acks. If publishing fails, it naks.
5.  When deliveries exceed its cap, publishes a non-retryable `fail` (reason `delivery_failed`), records a dead letter and terminates the message.

A handler crash is reported as a retryable `fail`.

### Progress and stop notices (optional)

Progress goes to core NATS `<ns>.progress.<exec>.<node>` as `{exec_id, node, key, generation, attempt, seq, time, data}`, `seq` counting from 1 per attempt. It is never stored. Stop notices arrive on `<ns>.ctl.stop.<exec>` as `{"exec_id", "all": true}` or `{"exec_id", "tasks": {key, generation, attempt}}`; because they may be lost, a worker should also check the last message of the execution's log while a job runs (a terminal type in `Pt-Event-Types`, or no message twice in a row, means it ended). A stopped job sends no command and is acked.

### Clients, timers, dead letters

- **Read** by folding the events (a live log may start with `ExecutionContinued`, whose state is the base) or from the summary in `<ns>-index` (`x.<exec>`; membership keys `s.<status>.<exec>`, `f.<flow>.<exec>`, `a.<attr>.<sha256(value):16>.<exec>`). Flows are in `<ns>-flows`: `<name>.latest` → hash, `<name>.<hash>` → definition.
- **Timers** are messages on `<ns>.timer.<exec>.<timer>` with `Nats-Schedule: @at <RFC 3339>` targeting the execution's command subject. **Cron** lives on `<ns>.sched.<name>` targeting `<ns>.cron.<name>`; each firing starts `<name>-<stream sequence>`.
- **Dead letters** (`cmd`, `job`, `trigger`, `dispatch`) have body `{kind, key, flow?, reason, deliveries, time, subject, header, body}`; redrive re-publishes `body` to `subject` without the `Nats-*` headers, except a `trigger` dead letter: it becomes the start of its `flow` with execution id `key`, so other consumers of the subject do not see the message again.

------------------------------------------------------------------------

## Event log

The events of one decision are stored as **one message**: a JSON array of envelopes, appended with `Nats-Expected-Last-Subject-Sequence` = the execution's previous decision, so there is a single writer without locks. Header `Pt-Event-Types` lists the types in order; `Pt-Cmd-Id` names the command that produced it. A decision holds at most 1 000 events.

envelope

```}
```

`i` is the 1-based index of the event in its execution (the fold rejects a gap). Readers reject unknown types and versions rather than fold wrongly; types are added, never repurposed.

| Type               | Data                                                                                   |
|--------------------|----------------------------------------------------------------------------------------|
| ExecutionStarted   | `exec_id, flow, flow_hash, input, parent?, attrs?`                                     |
| ExecutionForked    | `exec_id, from, seq, state`                                                            |
| ExecutionContinued | `state, segment{object, first_index, last_index, first_seq, last_seq}`                 |
| ExecutionCompleted | `output`                                                                               |
| ExecutionFailed    | `error, reason, node?, cancel_children[]`                                              |
| ExecutionCancelled | `reason, cancel_children[]`                                                            |
| NodeEntered        | `node`                                                                                 |
| NodeScheduled      | `key, node, kind, index?, generation, attempt, owner?, item?, resume?, resumed_by?`    |
| NodeCompleted      | `key, node, generation, attempt, output?, writes?, next?, usage?, cached?, cache_key?` |
| NodeFailed         | `key, node, generation, attempt, error, reason, will_retry`                            |
| NodeInterrupted    | `key, node, generation, payload?`                                                      |
| NodeCancelled      | `key, node, reason`                                                                    |
| ChoiceEvaluated    | `node, rule, name?, to, error?`                                                        |
| FanoutStarted      | `node, join, branches[]`                                                               |
| JoinCompleted      | `node, fanout, succeeded[], failed[], ok, output, cancel_children[]?`                  |
| AwaitStarted       | `node, signal, timer_id`                                                               |
| AwaitTimedOut      | `node, to?`                                                                            |
| SignalReceived     | `name, id, payload?`                                                                   |
| SignalConsumed     | `node, name, id`                                                                       |
| ChannelsUpdated    | `id, writes`                                                                           |
| MapStarted         | `node, items[], max_parallel`                                                          |
| MapCompleted       | `node`                                                                                 |
| MapAborted         | `node, index, cancel_children[]?`                                                      |
| ChildStarted       | `node, child_id, child_n, flow, input, policy, key?, owner?, index?`                   |
| ChildCompleted     | `node, key?, child_id, status, output?, error?, counters?`                             |
| TimerScheduled     | `id, n, at, purpose, key?, node?, generation?, attempt?`                               |
| TimerFired         | `id`                                                                                   |

**Identity and staleness.** Every new visit, resume and fork re-dispatch gets a fresh `generation` from a per-execution counter; retries keep it and bump `attempt`. A completion, failure, interrupt or timer that does not match the active instance is stale and produces no events. Timer ids (`t<n>`) and child ids (`<exec>-c<n>`) come from the same counter, so re-deriving them is idempotent.

------------------------------------------------------------------------

## Errors

The public API returns sentinel errors; test them with `errors.Is`.

| Error                | Meaning                                                                             |
|----------------------|-------------------------------------------------------------------------------------|
| ErrInvalidArgument   | Wraps every validation error of caller input: ids, names, payloads, flows, options. |
| ErrNotFound          | The execution does not exist and was never archived, or it was deleted.             |
| ErrArchived          | The execution is archived: readable, but it cannot be driven any more.              |
| ErrUnknownFlow       | The flow or version is not registered.                                              |
| ErrExecutionConflict | `Start` named the id of another flow's execution; nothing started.                  |
| ErrExecutionExists   | `Start` with `WithJoinExisting(false)` found its execution already there.           |
| ErrTerminal          | The execution already finished (e.g. `Update` on a completed execution).            |
| worker.ErrCancelled  | Cause of a job context cancelled because its work is no longer wanted.              |

------------------------------------------------------------------------

## Testing

Tests run against a real embedded nats-server — no mocks. The acceptance suite injects faults: engine kills, NATS restarts, duplicate and reordered completions.

shell

```
$ make check      # go test -race + golangci-lint + go vet
$ make examples   # run every example against $NATS_URL
$ PT_CONFORMANCE_WORKER="python worker.py" go test ./internal/conformance/
```

`PT_CONFORMANCE_WORKER` runs the protocol conformance suite against a worker written in another language. In your own tests, `WithClock` injects the decision clock.

