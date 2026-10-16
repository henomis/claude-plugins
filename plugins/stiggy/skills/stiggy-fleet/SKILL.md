---
name: stiggy-fleet
description: Build multi-agent apps on NATS with stiggy (github.com/henomis/stiggy), as YAML fleet files or with the Go library. Use it whenever the user wants a team or crew of LLM agents that runs durably (researcher/writer pipelines, support triage, supervisor or swarm setups, review loops, human approval), writes or edits a stiggy fleet.yaml, uses stiggy.New / WithAgent / WithCrew, defines crews or patterns (supervisor, swarm, evaluator_optimizer, debate, plan_execute), agent flows with routes or human review, exposes agents on the NATS Agent Protocol, or runs the stiggy CLI (validate, compile, run, start, resume, design). It grounds the fleet in the exact stiggy version (guide, examples, stiggy validate).
---

# stiggy fleets

stiggy connects [phero](https://github.com/henomis/phero) (the agents) to
[packtrail](https://github.com/henomis/packtrail) (durable orchestration on NATS
JetStream). You describe a **fleet** once, as YAML or as Go options, and stiggy
compiles it into packtrail flows plus one worker per agent. Every job builds a
fresh phero agent.

## Read the real library first

This file is a map of stiggy, not the source of truth. stiggy is young and its
fleet schema changes between releases. Decoding is strict, so a key that is
misspelled, renamed or invented is an error. Run the script in this skill's
directory first:

```bash
bash <this-skill-dir>/scripts/golib.sh github.com/henomis/stiggy
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

`web/guide.html` is the full guide for that version: fleet structure,
models, tools, agents, knowledge, flows, crews, patterns, CLI and the Go
library. Then:

1. **Look up every field you write.** `references/fleet-reference.md` (bundled)
   lists every section, field, memory type, tool type and template variable.
   If the project uses a different stiggy version, the module's
   `web/guide.html` is the authority. Grep it for `<h2` to find the section,
   then read that part.
2. **Start from the closest example** (the list is at the end of this file).
   Each `examples/<name>/main.go` embeds a fleet and runs it. Its
   `README.md` explains it.
3. **Let `stiggy validate` have the last word.** Install the CLI at the same
   version (`go install github.com/henomis/stiggy/cmd/stiggy@<version>`). It
   checks the fleet against the real schema and reports line numbers.
4. In Go, check each API with `cd <source dir> && go doc ./<pkg> <Symbol>` (this works before the user's module exists), for example `go doc ./spec Agent`.

If the source and this file disagree, go with the source. Never edit files
under the module cache.

If the `packtrail` and `phero` plugins are installed, their skills cover the
layers underneath: flow node semantics and the client (packtrail), and agent
internals (phero).

## Workflow

If golib.sh reports that Go is missing, the user has to install it first
(https://go.dev/dl/). If their Go is older than the module needs, `go get`
downloads the right toolchain once (about 70 MB), so say so before it seems to
hang. The same applies to `go install` of the CLI. NATS with JetStream
must be running (`nats-server -js`, or `docker run --rm -p 4222:4222 nats -js`).

```bash
nats-server -js &
go install github.com/henomis/stiggy/cmd/stiggy@<version printed by golib.sh>
stiggy validate fleet.yaml        # every problem, with line numbers. Run this after each edit
stiggy compile fleet.yaml         # show the packtrail flows a fleet becomes
stiggy run fleet.yaml &
stiggy start -ns <namespace> <flow|crew|pattern> -input '{"topic":"NATS"}' -wait
```

Always run `stiggy validate` after you change a fleet. Crews and patterns
report only their first problem, so validate again after each fix.

## Choosing the shape

| The user wants | Use |
|---|---|
| A fixed sequence of agent tasks, optionally parallel (`async`) | `crews` (sequential, or hierarchical with a `manager`) |
| A well-known multi-agent topology | `patterns`: `supervisor`, `swarm`, `evaluator_optimizer`, `debate`, `plan_execute` |
| Custom control flow: choices, fan-out/join, maps, waits, subflows | `flows` (packtrail flows whose `task`/`map` nodes set `agent`, `activity` or `remote`) |
| An agent other services can prompt, without a workflow | `expose: {agents: [...]}` |
| Another team's agent as a step or a delegate | `remotes` |

Crews and patterns compile to flows named after them. `stiggy compile` shows the
graph.

## Minimal fleet

```yaml
namespace: newsroom
models:
  fast: {provider: ollama, model: llama3.2}     # openai | anthropic | google | ollama
agents:
  researcher: {model: fast, role: Researcher, goal: "Find accurate, recent facts."}
  writer:     {model: fast, role: Writer, goal: "Write short, clear articles."}
crews:
  article:
    retry: {max_attempts: 3, delay: 2s}         # recommended with real models
    tasks:
      - {id: research, agent: researcher, description: "Research {{.input.topic}}."}
      - {id: write, agent: writer, description: Write a 200-word article from the research., context: [research]}
```

## The same in Go

```go
app, err := stiggy.New(nc,
    stiggy.WithNamespace("newsroom"),
    stiggy.WithModel("fast", openai.New("", openai.WithBaseURL(openai.OllamaBaseURL), openai.WithModel("llama3.2"))),
    stiggy.WithAgent("researcher", spec.Agent{Model: "fast", Role: "Researcher"}),
    stiggy.WithAgent("writer", spec.Agent{Model: "fast", Role: "Writer"}),
    stiggy.WithCrew("article", spec.Crew{Tasks: []spec.Task{
        {ID: "research", Agent: "researcher", Description: "Research {{.input.topic}}."},
        {ID: "write", Agent: "writer", Description: "Write a 200-word article from the research."},
    }}),
)
go app.Run(ctx)
<-app.Ready()
id, _ := app.Client().Start(ctx, "article", map[string]any{"topic": "NATS"})
st, _ := app.Client().Wait(ctx, id)   // app.Client() is a packtrail client
```

Go-only extras: `stiggy.WithTool` for Go tools, and activities (`activity:` steps
run Go code). Inside a Go tool, `stiggy.JobFromContext(ctx)` says which
execution, node, agent and step is calling. Trust it over the model's arguments.

## Rules to follow

- **Secrets and env vars**: `${VAR}` / `${VAR:-default}` work everywhere
  *except* `flows`, `crews` and `patterns`, because those become versioned
  packtrail definitions. Pass runtime values as inputs (`{{.input.x}}`).
- **Quote `${...}` inside `{...}` YAML mappings**: `api_key: "${OPENAI_API_KEY}"`.
- **Idempotent tools**: steps are delivered at least once, so a retried step
  re-runs every tool call. Key side effects on `Job.StepID`.
- **Tool names must be distinct per agent**: two `file_read` entries both provide
  `read`, and the app refuses to start. In prompts, use the names the model
  actually sees (`bash`, `read`, `search_<knowledge>`, `ask_<delegate>`,
  `route_to_<node>`, `ask_human`), not the fleet keys.
- **Add `retry` to crews and patterns**: without it each step gets one attempt,
  and an empty answer or a schema miss fails the whole execution.
- **Memory**: `execution` is the only type that stays correct under fork, rerun
  and time travel. Long-term types (`simple`, `nats`, `psql`, `rag`) share a
  `session`. Template it (`"user-{{.input.user_id}}"`) to keep users apart.
- **Gemini with tools**: use `provider: google` (native), not the
  OpenAI-compatible endpoint.
- **Human in the loop**: `routes: [..., human]` gives the agent `ask_human`, and
  `human_input` adds review. Resume with `stiggy resume <exec> <node> -value '"answer"'`
  or `Client.Resume`. The question is in `State.Tasks[node].Interrupt`.

## Deploying

The same fleet file runs on every process. Pick each process's role:

```bash
stiggy run fleet.yaml -role engine  -http :8080
stiggy run fleet.yaml -role workers -http :8080 [-only researcher,writer]
stiggy agents -owner newsroom        # discover exposed agents
stiggy ask -owner newsroom writer "Write two lines about NATS."
```

Health checks are at `/healthz` and `/readyz`. To operate executions use
`stiggy get | history | progress | signal | resume | update | cancel | fork | rerun`,
or `packtrail-ui` on the fleet's namespace.

`stiggy design` is a browser block designer that saves `*.stiggy.json` and the
fleet it compiles to.

## Examples

The module's `examples/` folder (path printed by `golib.sh`) has runnable
programs. Read the closest one before you write your own:

| Building | Example |
|---|---|
| Smallest fleet: one agent, one flow (YAML) | `hello` |
| Agent-chosen routing / triage (Go API) | `router` |
| A crew with a guardrail, exposed as an agent (YAML) | `crew` |
| Parallel map-reduce with structured output (YAML) | `mapreduce` |
| Human questions and review | `hitl` |
| One exposed agent reused by several programs | `translator` |
| Using another team's agent over NATS | `remote` |
| Multi-agent simulation | `socialsim` |

The examples use `examples/internal/extest` for tests, and another module can't
import it. In the user's app, connect with `nats.Connect` and test against
`stiggytest`.
