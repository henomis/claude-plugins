# Fleet reference

A fleet is one YAML document (or the equivalent Go options). Decoding is
strict: an unknown key is an error, reported with its line. `stiggy validate`
reports every problem at once.

```yaml
version: "1"          # optional
namespace: newsroom   # packtrail namespace; default "stiggy"
models: {}
embedders: {}
vectorstores: {}
knowledge: {}
tools: {}
agents: {}
remotes: {}
flows: {}
crews: {}
patterns: {}
expose: {}
schedules: {}
```

Names (keys of every section, node ids) must match `[A-Za-z0-9_-]`. Agent,
owner and exposed names are NATS subject tokens of at most 64 characters.

## Environment

String values outside `flows`, `crews` and `patterns` may use `${VAR}`, `${VAR:-default}` and `$$`
(a literal `$`). A missing variable without a default is an error. Quote a
reference inside a `{...}` mapping (`api_key: "${OPENAI_API_KEY}"`), where
YAML would otherwise read its braces.
`stiggy validate -no-env` skips expansion. Flows are never expanded: they are
versioned definitions stored by packtrail, so they must not depend on the
environment or hold secrets. Crews and patterns compile into flows, so a
`${VAR}` in them is a load error; pass runtime values as inputs instead.

## models

```yaml
models:
  fast:
    provider: openai          # openai | anthropic | google | ollama (or a registered one)
    model: gpt-4o-mini        # provider default when empty; required for ollama
    api_key: ${OPENAI_API_KEY}
    base_url: https://...     # OpenAI-compatible endpoints
    temperature: 0.2
    max_tokens: 1024
    retries: 2                # retry a failed call (exponential back-off)
    retry_backoff: 5s         # first wait, doubling up to 30s (default 500ms); 4xx errors but 408/429 are not retried
    rate_limit: {requests_per_minute: 60, max_concurrent: 4}   # per process; either one alone is fine
```

`ollama` uses Ollama's OpenAI-compatible endpoint (default
`http://localhost:11434/v1`), e.g. `{provider: ollama, model: llama3.2-eco}`.

`google` uses the Gemini API natively, e.g. `{provider: google, model:
gemini-3.5-flash, api_key: "${GEMINI_API_KEY}"}` (an empty `api_key` falls back
to `GOOGLE_API_KEY` or `GEMINI_API_KEY`). Use it rather than Gemini's
OpenAI-compatible endpoint for agents with tools: Gemini 3 needs the thought
signature of each tool call sent back, which only the native provider keeps.

## tools

```yaml
tools:
  shell: {type: bash, allowlist: [ls, cat], timeout: 30s, working_dir: /work}
  files: {type: file_read, working_dir: /work}    # also file_write, file_edit, glob, grep
  skills: {type: skill, root: ./skills}
  scratch: {type: kv, bucket: scratchpad}         # NATS KV read/write tools
  browser: {type: mcp, command: npx, args: [-y, "@playwright/mcp"], allow: [browser_navigate]}
  remote: {type: mcp, url: https://mcp.example.com/mcp, deny: [delete_everything]}
```

Options are checked strictly per type. An `mcp` entry is either a stdio
`command` (with `args` and `env`; only a minimal environment is passed on) or
a streamable-HTTP `url`, filtered with `allow` and `deny`.

A tool's key (`shell`, `files` above) only names the entry in the fleet;
agents list it in `tools:`. The model sees the names of the tools the entry
provides, so use those in prompts:

| Type | Tools the model sees |
|---|---|
| `bash` | `bash` |
| `file_read`, `file_write`, `file_edit` | `read`, `write`, `edit` |
| `glob`, `grep` | `glob`, `grep` |
| `skill` | `skill` |
| `kv` | `kv_read`, `kv_write` |
| `mcp` | the server's own tool names, after `allow` and `deny` |

An agent also gets `search_<knowledge>` per knowledge entry, `ask_<delegate>`
per delegate, and, on steps that route, `route_to_<node>` and `ask_human`.
All the names an agent gets must be distinct: two entries of one type (two
`file_read` tools on different directories, say) both provide `read`, and the
app stops at startup, naming the clashing entries.

**Go tools** (`stiggy.WithTool`) can ask which step calls them with
`stiggy.JobFromContext(ctx)`: execution, flow, node, agent, attempt, step id,
flow input, map item, and packtrail's long-term store (`Store`, shared by every
worker; key its writes on `StepID`). Trust it, not the model's arguments, to know who is
calling. It reports false outside a flow step (an exposed agent). Delegates'
tools see the job of the step that delegates.

**Side effects must be idempotent.** Delivery is at least once: a retried step
(a provider error, a timeout, a worker crash) runs the agent
again, and with it every tool call. A tool that posts, writes or sends should
key its effect on `Job.StepID`, which retries keep and the next visit of the
node (or a resume after an interrupt) changes.

## agents

```yaml
agents:
  writer:
    model: fast
    system: You write for a newsroom.   # system prompt (a template, see below)
    role: Writer                        # appended to system
    goal: Short, accurate articles.
    backstory: Ten years at a daily paper.
    description: Writes articles.       # for agents that delegate to it
    tools: [shell, files]
    knowledge: [handbook]               # one search_<name> tool each
    delegates: [researcher, legal]      # agents or remotes, as ask_<name> tools
    max_iterations: 10                  # default 25
    stream: true                        # progress events while it runs
    memory: execution                   # see below
```

`system`, `role`, `goal` and `backstory` are templates over the job context,
like a step prompt: `role: "{{.item.name}}"` gives each item of a map its own
persona, and delegates render over the job of the step that delegates. A
missing key renders as `<no value>`. Exposed agents and their delegates answer
outside any job, so theirs must be static.

### memory

| Type | Kept in | Notes |
|---|---|---|
| `none` (default) | nowhere | Every step starts fresh |
| `execution` | the execution's state (hidden channel `_mem_<agent>`) | Correct under fork, rerun and time travel |
| `simple` | the worker process | `max_items` (default 100) |
| `nats` | NATS KV | `bucket` |
| `psql` | PostgreSQL | `dsn`, `table`, `ensure_schema` |
| `rag` | a knowledge index | `knowledge` |

Long-term types (all but `none` and `execution`) also take:
- `session`: default the agent's name, shared by every execution. It is a
  template over the job context, so `session: "user-{{.input.user_id}}"` keeps
  one memory per user. It fails closed: a missing key fails the step instead of
  sharing a session, and the result must be letters, digits, `-` `_` `=` `/`
  and inner dots. Exposed agents need a static session. In an exposed flow,
  `.input` comes from the caller, so a session built from it is only as
  trustworthy as the caller;
- `per_execution: true`: append the execution id to the session;
- `summarize: {model, threshold, size}`.

## embedders, vectorstores, knowledge

```yaml
embedders:
  small: {provider: openai, model: text-embedding-3-small, api_key: "${OPENAI_API_KEY}"}  # or ollama
vectorstores:
  docs: {type: qdrant, host: localhost, port: 6334, collection: handbook, vector_size: 1536, distance: cosine}
  pg: {type: psql, dsn: "${DATABASE_URL}", collection: handbook, vector_size: 1536}
  wv: {type: weaviate, host: localhost:8080, class: Handbook}
knowledge:
  handbook:
    embedder: small
    vectorstore: docs
    description: The editorial handbook.
    top_k: 4
    sources:
      - {path: docs/*.md, chunk_size: 1000, chunk_overlap: 100}   # splitter: markdown | recursive
```

The engine role ingests the sources at startup when the store is empty.

## remotes

Agents served by others on the NATS Agent Protocol, found by discovery:

```yaml
remotes:
  legal: {owner: legal-team, name: reviewer, description: Reviews legal risks.}
```

Steps run them with `remote: legal`; agents list them in `delegates`.

## flows

A flow is a [packtrail flow](https://github.com/henomis/packtrail): `start`,
`channels` (with reducers `replace`, `append`, `merge`, `sum`), `output`
(an expression; default all channels, or the last node's result), `budget`,
`max_steps`, `retention`, `on_expire`, `archive_retention`, `triggers`, and
`nodes` of types `task`, `choice` (`to: $end` ends the flow), `fanout`,
`join`, `await`, `map` and `subflow`.

`retention` is how long a finished execution is kept (default: forever).
Then it is archived, where it stays readable, or deleted for good with
`on_expire: delete`. `archive_retention` deletes an archived execution that
long after it was archived. packtrail never deletes an execution sooner than
ten minutes after it finished.

```yaml
flows:
  report:
    retention: 5h        # kept 5 hours, then deleted, never archived
    on_expire: delete
```

A `task` or `map` node runs a stiggy step when it sets one of these:

| Field | Meaning |
|---|---|
| `agent` | Run a fleet agent |
| `activity` | Run a Go activity (library mode) |
| `remote` | Prompt a remote agent |
| `prompt` | Go template over the job context; default: the input or map item, plus the context outputs |
| `expected_output` | Appended to the prompt; a template like `prompt` |
| `context` | Nodes whose outputs the prompt includes; default the previous node |
| `writes` | `{channel: output}` or `{channel: output.field}` |
| `routes` | Nodes the agent may choose next, and `human` for `ask_human` (task nodes only, not in fan-outs or maps) |
| `human_input` | A human reviews the answer: `{"approve": true}` or feedback |

The node's own `output_schema`, `retry`, `timeout`, `cache` and `concurrency`
still apply. With `output_schema` the agent answers structured JSON.

**Prompt templates** see `.input`, `.channels`, `.results`, `.item`,
`.index`, `.last_node`, `.visits`, `.signals`, `.errors`, `.counters` and
`.resume`, plus the `json` function: `{{json .channels.notes}}`.

**Outputs:** an agent step's output is `{"text": "<answer>"}`, or the parsed
object when it has an `output_schema`. An empty answer (from an agent or a
remote) is an error the node's `retry` absorbs; without one the step fails.
An agent that chose a route may answer empty: the route is its decision.

**Usage counters** for budgets: `agent_steps`, `tokens_in`, `tokens_out` and
`cost_usd`. They are charged for every run, including failed and paused
ones.

**Human in the loop:** a paused step shows `{kind, agent, node, question |
answer}` in `State.Tasks[...].Interrupt`. Resume it with
`stiggy resume <exec> <node> -value '"answer"'` or `Client.Resume`.

## crews

```yaml
crews:
  launch:
    process: sequential            # or hierarchical (needs manager)
    manager: boss
    max_steps: 40
    budget: {tokens_out: 50000}
    retry: {max_attempts: 3, delay: 2s}   # every agent step of the crew
    tasks:
      - id: research
        agent: researcher
        description: "Research {{.input.product}}."
        expected_output: Three facts.
        async: true                # runs in parallel with neighbouring async tasks
      - id: draft
        agent: writer
        description: Write the post.
        context: [research]
        output_schema: {...}
        human_input: true
        guardrail: {agent: editor, max_retries: 2}
        retry: {max_attempts: 2}   # this task's step only, instead of the crew's
```

A crew runs as a flow named after it. `retry` is a node retry policy (as on
flow nodes) given to every agent step the crew runs: tasks, guardrail checks
and the manager. Without it each step has one attempt, so an empty answer or
an answer that misses its schema fails the execution.

`stiggy validate` reports every problem in a fleet, with one exception: a crew
or pattern stops at its first problem, so fix it and validate again to see
the next. Each crew and pattern still reports its own first problem.

## patterns

```yaml
patterns:
  team: {type: supervisor, supervisor: boss, workers: [researcher, writer]}
  swarm: {type: swarm, agents: [triage, billing, tech]}
  polish: {type: evaluator_optimizer, generator: writer, evaluator: editor, max_rounds: 3}
  argue: {type: debate, debaters: [optimist, skeptic], judge: editor, rounds: 2}
  project: {type: plan_execute, planner: boss, executor: researcher, synthesizer: writer, max_parallel: 4}
```

All patterns take `prompt`, `max_steps`, `budget` and `retry`. A custom
`prompt` is the task for every step that refers to it (the evaluator,
plan_execute's executor and synthesizer, the debaters and the judge), not
only the first. `retry` works as for crews: every agent step of the pattern
gets it, e.g. `retry: {max_attempts: 3, delay: 2s}` for real models. Each
runs as a flow named after it; `stiggy compile` shows the graph.

## expose

```yaml
expose:
  owner: newsroom          # default: the namespace
  agents: [writer]         # each prompt runs a fresh agent
  flows: [launch]          # each prompt starts an execution, answered with its output
```

Exposed flows take the prompt as input: a JSON object as is, otherwise
`{"prompt": text}`. A `Stiggy-Execution-Id` request header makes retries join
the same execution, and keeps it running when the caller or the server goes
away; without the header, an execution whose caller is gone is cancelled.

## schedules

```yaml
schedules:
  morning: {flow: launch, cron: "0 0 7 * * *", input: {product: stiggy}}
```

## Worker kinds

`agent-<name>`, `act-<name>` and `remote-<name>` belong to stiggy. A plain
task node with any other `kind` is left to external packtrail workers, in any
language.
