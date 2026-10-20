---
name: packtrail-flows
description: Build durable, event-sourced workflow apps on NATS JetStream with packtrail (github.com/henomis/packtrail). Use it whenever the user wants a Go service with long-running or crash-safe workflows, retries, approvals or human-in-the-loop waits, fan-out/join, map-reduce or sagas on NATS, or writes packtrail flow YAML or flow.Flow structs, Go workers (worker.New) or client code (Start, Signal, Wait, Resume, Fork, Rerun). Also use it for choice/fanout/join/await/map/subflow nodes, channels and reducers, timeouts, budgets, time travel, the packtrail CLI or operating an engine. It grounds the code in the exact packtrail version from the Go module cache (examples, docs, go doc).
---

# packtrail workflows

packtrail is a workflow-as-data engine built only on NATS (2.12+, JetStream).
You declare a graph in YAML or as `flow.Flow` structs. The engine interprets it
and keeps every execution as an ordered event log. Workers serve a `kind` in any
language. The Go SDK is `github.com/henomis/packtrail/worker`.

## Read the real library first

This file is a map of packtrail, not the source of truth. Start by running the
script in this skill's directory:

```bash
bash <this-skill-dir>/scripts/golib.sh github.com/henomis/packtrail
```

It works on a fresh machine. The first run downloads the module once, into
the Go module cache (or `~/.cache/golib-src` when Go isn't installed). Later
runs are instant and work offline. It uses the version the project's `go.mod`
pins, or the latest release. The output has three parts:

- **Environment**: the Go version compared with what the module needs, and
  whether `docker` and `nats-server` are installed. If the app needs something
  that's missing, tell the user what to install before you write code they
  can't run.
- **Source**: a read-only directory with the README, docs, `examples/` and
  packages. Never edit files there.
- **NOT AVAILABLE LOCALLY** (exit code 2): the machine is offline or the proxy
  is blocked. Read the URLs it prints with a web fetch tool. Don't fall back to
  memory.

Then:

1. **Start from the closest example** (the list is at the end of this file).
   Read its `main.go`, where the flows are defined inline, and keep its
   wiring: engine options, `Ready()`, worker lifecycle and shutdown. It is
   known to work with that version. The examples import
   `examples/internal/devserver` and `exutil`, and Go won't let another
   module import those. In the user's app, connect with
   `nats.Connect(os.Getenv("NATS_URL"))` (default `nats.DefaultURL`) and use
   an `errgroup` or plain goroutines instead.
2. **Look up every node field and option** in `references/docs.md` (bundled,
   written for v1.0.3). If the project uses another version, use the module's
   `web/docs.html` instead.
3. **Check each Go API you call** with `cd <source dir> && go doc ./<pkg> <Symbol>` (this works before the user's module exists), for example
   `go doc ./worker Job`.

If the source and this file disagree, go with the source. Never edit files
under the module cache.

## Starting a new app

If golib.sh reports that Go is missing, the user has to install it first
(https://go.dev/dl/). If their Go is older than the module needs, `go get`
downloads the right toolchain once (about 70 MB), so say so before it seems to
hang. The same applies to `go install` of the CLI. NATS 2.12+ with
JetStream must be running, through Docker or `nats-server -js`.

```bash
go mod init example.com/myapp
go get github.com/henomis/packtrail@<version printed by golib.sh>
go install github.com/henomis/packtrail/cmd/packtrail@<same version>   # CLI: validate, run, inspect
docker run --rm -p 4222:4222 nats:2.14.2 -js                          # or: nats-server -js
```

Put flows in `flows/*.yaml`. Check them with `packtrail validate flows/*.yaml`
and the code with `go build ./... && go vet ./...`, and fix until both are
clean. Write a test with `packtrailtest.Start(t)` that runs one execution end to
end. Finish by telling the user how to start NATS, the engine and the workers.

## The three parts

```go
import (
    "github.com/henomis/packtrail"
    "github.com/henomis/packtrail/worker"
)

// 1. Engine: provisions the namespace, registers flows, processes commands.
eng, err := packtrail.New(nc, packtrail.WithNamespace("orders"), packtrail.WithFlowsDir("flows"))
go eng.Run(ctx)
<-eng.Ready()

// 2. Worker: serves one kind. j.Node says which node the job is for.
w, err := worker.New(nc, "writer", func(ctx context.Context, j *worker.Job) (*worker.Result, error) {
    var in struct{ Topic string }
    if err := j.Input(&in); err != nil {
        return nil, worker.Permanent(err) // never retried
    }
    return &worker.Result{
        Output: map[string]any{"text": "...", "score": 9}, // -> results.<node>
        Writes: map[string]any{"notes": "drafted"},       // channel deltas
    }, nil
}, worker.WithNamespace("orders"))
go w.Run(ctx)

// 3. Client: drive executions.
c := eng.Client() // or packtrail.NewClient(nc, packtrail.WithClientNamespace("orders"))
id, err := c.Start(ctx, "review", map[string]any{"topic": "NATS"})
st, err := c.Wait(ctx, id)
```

The engine, the workers and the clients share only NATS. In production they are
usually separate processes. Your code owns the `*nats.Conn`. Every part needs
the same namespace.

## Flow YAML

```yaml
name: review
channels:
  notes: {reducer: append}          # replace (default) | append | merge | sum
budget: {cost: 10}                  # caps on Result.Usage counters (+ built-in "steps")
max_steps: 100
output: "{draft: results.draft}"    # quote it: YAML would read {...} as a map
nodes:
  - id: draft
    type: task
    kind: writer
    timeout: 1m
    retry: {max_attempts: 3, backoff: exponential}
    on_failure: give_up             # route a permanent failure instead of failing
    next: check
  - id: check
    type: choice
    rules:
      - {name: good_enough, when: "results.draft.score >= 8", to: approve}  # name: optional, shows in history
      - {name: too_many_tries, when: "visits.draft >= 3", to: $end}
      - {default: true, to: draft}
  - {id: approve, type: await, signal: approval, timeout: 48h, on_timeout: give_up, next: publish}
  - {id: publish, type: task, kind: publisher}
  - {id: give_up, type: task, kind: notify}
start: draft
```

| Node | Use for |
|---|---|
| `task` | A job for a worker `kind`. `dynamic: [a, b]` lets the worker pick the next node with `Result.Next` |
| `choice` | Branch on `rules` ([expr](https://github.com/expr-lang/expr) expressions). `to: $end` completes |
| `fanout` + `join` | Static parallel branches. The fanout's `next` must be its join. Branches have no `next`. Join `policy`: `all`, `any`, `quorum:N`, or `min:N` (wait for every branch, succeed if ≥ N did; tolerate failures without losing results) |
| `map` | Data-driven fan-out: `over: input.docs`, `max_parallel`. Each instance reads `j.Item` |
| `await` | Wait for a signal (`timeout` required). For human approval and external events |
| `subflow` | Run another flow as a child: `flow`, `input` (an expression) |

Expressions see `input`, `channels`, `results`, `last_node`, `visits`, `signals`,
`branches`, `counters`, `errors`, `item`/`index`. They are a bounded subset:
comparisons, arithmetic, logic, `in`, `matches`, field/index access, `len()`.

Validate offline before running: `packtrail validate flows/*.yaml`, or
`packtrail.ValidateOptions(opts...)` in Go/CI.

## Worker rules

- **Delivery is at least once.** A task can run twice after a crash. Make side
  effects idempotent (key them on `j.ExecID` + `j.Node` + `j.Generation`), or set
  `cache: {ttl: ...}` on the node.
- **Respect cancellation.** When a join settles, a map aborts, an attempt times
  out or the execution ends, the job's ctx is cancelled with cause
  `worker.ErrCancelled`. Return promptly; the result is dropped anyway.
- **Errors**: return a plain error to retry by the node's `retry` policy, and
  `worker.Permanent(err)` to fail now (and go to `on_failure`, if set).
  `worker.WithUsage(err, usage)` charges budgets even when the run fails.
- **Read context**: `j.Input`, `j.Result(node, &v)`, `j.Channel(name, &v)`,
  `j.Item(&v)` (map), `j.Signal(name, &v)`, `j.DecodeMeta(&v)` (node `meta`).
- **Human in the loop from inside a task**: `return nil, worker.Interrupt(question)`.
  The execution waits. `c.Resume(ctx, id, node, answer)` re-runs the node, and
  there `j.Resumed(&answer)` returns true. Pass `packtrail.WithResumedBy(reviewer)`
  to record who answered; the worker sees it as `j.Context.ResumedBy`.
- **Streaming**: `j.Progress(v)`; clients read it with `c.Progress(ctx, id)`.
  Progress is never stored.
- **Logging**: log through `j.Logger()`. Its lines carry `exec`, `flow`, `node`,
  `attempt`, ... like the engine's, plus `trace_id`/`span_id` when the execution
  was started with `packtrail.WithTraceparent(tp)`. Pass a traceparent at
  `Start` to join packtrail logs to the caller's distributed trace.
- Only `Output`, `Writes` (declared channels only), `Next` (declared `dynamic`
  only) and `Usage` go back to the engine.

## Client cheat sheet

| Need | Call |
|---|---|
| Start / idempotent start | `Start(ctx, flow, input, packtrail.WithExecutionID(id))`; `WithTraceparent(tp)` links a trace |
| Wait for the end / for a condition | `Wait`, `WaitUntil(ctx, id, func(*State) bool)` |
| Send an event to an `await` | `Signal(ctx, id, name, payload)` (buffered if it arrives early) |
| Answer a `worker.Interrupt` | `Resume(ctx, id, node, value, packtrail.WithResumedBy(who))` |
| Write channels now | `Update(ctx, id, writes)` |
| Inspect | `Get`, `History`, `StateAt(ctx, id, seq)`, `Watch`, `List` |
| Time travel | `Fork(ctx, id, seq, packtrail.WithForkWrites(w))`, `Rerun(ctx, id, node)` |
| Stop | `Cancel(ctx, id, reason)` |

On a `State`, use `st.Result(node, &v)`, `st.Channel(name, &v)`,
`st.DecodeOutput(&v)`, `st.Status`, and `st.Tasks[node].Interrupt`.

## Testing

`packtrailtest.Start(t)` starts an embedded nats-server with JetStream for tests
(`Restart` simulates an outage). Test against it rather than mocking NATS.

## Operations quick facts

- Use `WithReplicas(3)` on a cluster. On a standalone server it fails at `Init`.
- **Partitions are permanent** per namespace (`WithPartitions`, default 64).
  Choose the count up front.
- Alert on `Engine.Metrics(ctx).DispatchStall`.
- Logs: engine `WithLogger`, `worker.WithLogger`, `WithClientLogger`; debug level gives one line per decision/job. CLI and `packtrail-ui` take `-log-level` and `-log-format`.
- CLI: `packtrail run | start | get | history | fork | rerun | update | signal | cancel`.
  `packtrail-ui` is a debugging dashboard. It has no auth and binds to loopback.

## Examples

The module's `examples/` folder (path printed by `golib.sh`) has runnable
programs. Read the closest one before you write your own:

| Building | Example |
|---|---|
| First flow, one worker | `hello` |
| Human approval with `await` + `Signal` | `approval` |
| Parallel branches, quorum join | `research` |
| Data-driven fan-out | `mapreduce` |
| LLM/agent loop, worker picks the next node | `agentloop` |
| Composing flows | `subflow` |
| Retries, timeouts, crashes | `resilience` |
| Fork / rerun / StateAt | `timetravel` |
| Watching the event log | `events` |
