---
name: phero
description: Build LLM agents and AI apps in Go with phero (github.com/henomis/phero/v2). Use it whenever the user wants to create, scaffold, extend or debug a Go program that uses phero. That includes chatbots, tool-calling agents, orchestrators with sub-agents, handoffs or triage, RAG over their own documents (embeddings, chunking, Qdrant/pgvector/Weaviate vector stores), semantic long-term memory, streaming, tracing, MCP servers, skills, A2A and the NATS Agent Protocol, even when they only say "an agent in Go with phero". It grounds the code in the exact phero version from the Go module cache (source, examples, go doc) and covers agent.New, llm.NewTool, Run/RunStream, AddHandoff, AsTool, memory, and the rag/vectorstore/embedding/textsplitter packages.
---

# Building agents with phero

phero is a Go framework of small, composable packages for LLM agents. Module path:
`github.com/henomis/phero/v2`. Every package is an interface plus
implementations, so pick the pieces you need.

## Read the real library first

This file is a map of phero, not the source of truth. The API shifts between
releases, and code written from memory tends to compile only after a few
rounds of fixes. Read the exact version you are building against first.
`scripts/golib.sh` (in this skill's directory) does the lookup:

```bash
bash <this-skill-dir>/scripts/golib.sh github.com/henomis/phero/v2
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

1. **Start from the closest example.** Read its `main.go` and keep its
   imports, client setup and error handling. It is known to compile against
   that version. The examples table under "Multi-agent" helps you pick it.
2. **Check every API you call** with `cd <source dir> && go doc ./<pkg> <Symbol>` (this works before the user's module exists). Inside the user's module
   after `go get`, `go doc github.com/henomis/phero/v2/<pkg>.<Symbol>` also works.
   Read the source when behaviour matters, for example what a handoff returns.
3. If the source and this file disagree, go with the source. Never edit files
   under the module cache.

## Starting a new app

If golib.sh reports that Go is missing, the user has to install it first
(https://go.dev/dl/). If their Go is older than the module needs, `go get`
downloads the right toolchain once (about 70 MB), so say so before it seems to
hang. Then:

```bash
go mod init example.com/myapp
go get github.com/henomis/phero/v2@<version printed by golib.sh>
# write main.go, then iterate until clean:
go build ./... && go vet ./...
```

Read API keys from the environment (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, ...).
For a local run without keys, offer Ollama (`openai.OllamaBaseURL`). Finish by
telling the user exactly how to run the app and what it needs, such as a model,
NATS or Qdrant.

## The core loop

```go
import (
    "github.com/henomis/phero/v2/agent"
    "github.com/henomis/phero/v2/llm"
    "github.com/henomis/phero/v2/llm/openai"
)

client := openai.New(apiKey, openai.WithModel("gpt-4o-mini"))
// Ollama / OpenAI-compatible: openai.New("", openai.WithBaseURL(openai.OllamaBaseURL), openai.WithModel("llama3.2"))
// Anthropic: anthropic.New(apiKey, ...)   Gemini: google.New(apiKey, ...)

a, err := agent.New(client, "Math Assistant", "You are a helpful math assistant.")
if err != nil { return err }

res, err := a.Run(ctx, llm.Text("What is 15 - 7 + 23?"))
if err != nil { return err }
fmt.Println(res.TextContent())   // res.Summary has tokens, latency, iterations
```

`Run` loops: call the LLM, run the requested tools, append the results, and
repeat until the model answers. The loop stops after `agent.DefaultMaxIterations`
(25); change it with `a.SetMaxIterations(n)`.

Input is typed content parts: `llm.Text`, `llm.ImageURL`, `llm.ImageFile`.

## Tools

Turn a typed Go function into a tool. The JSON Schema comes from the input struct,
including its `jsonschema` tags:

```go
type CalcIn struct {
    Op string  `json:"op" jsonschema:"description=add or subtract,enum=add,enum=subtract"`
    A  float64 `json:"a"`
    B  float64 `json:"b"`
}
type CalcOut struct{ Result float64 `json:"result"` }

tool, err := llm.NewTool("calculator", "Adds or subtracts two numbers",
    func(ctx context.Context, in *CalcIn) (*CalcOut, error) { ... })
err = a.AddTool(tool)
```

- Return errors the model can act on in the output struct (e.g. an `Error` field).
  A Go `error` means the tool itself failed.
- `llm.NewRawTool(name, desc, schemaMap, handler)` takes a hand-written schema.
- Built-in tools: `tool/file` (`NewReadTool`, `NewWriteTool`, `NewEditTool`,
  `NewGlobTool`, `NewGrepTool`), `tool/bash` (blocklist, allowlist, timeout, safe mode,
  background shells), `tool/human` (human checkpoints; you supply the interactor
  with `WithInteractor`), `tool/skill` (loads `SKILL.md` folders into the
  conversation), `tool/kv`, and `tool/agent` (a sub-agent as a tool).

## Structured output

```go
rf, err := llm.NewResponseFormat[Report]("report", "The final report")
a.SetResponseFormat(rf)
```

## Memory

`a.SetMemory(m)` gives the agent conversation history across `Run` calls:

| Package | Backend |
|---|---|
| `memory/simple` | in-process ring: `simple.New(maxItems)` |
| `memory/jsonfile` | a JSON file |
| `memory/psql` | PostgreSQL |
| `memory/nats` | NATS JetStream KV (survives restarts, named sessions) |
| `rag` → `r.AsMemory()` | semantic long-term memory (see `references/rag.md`) |

Several memories support summarizing once a threshold is reached; check the
package options.

## RAG (answering from documents)

The pipeline has four parts, each an interface: chunk (`textsplitter/recursive`,
`textsplitter/markdown`), embed (`embedding/openai`, which also covers Ollama),
store (`vectorstore/qdrant`, `psql`, `weaviate`) and glue (`rag.New(store, embedder)`).
The usual shape is `r.Ingest(ctx, splitter)`, then `r.AsTool(...)` added to the agent, or
`a.SetMemory(r.AsMemory())` for semantic memory.

**Read `references/rag.md` before you write any RAG code.** It has the
pipeline code, filters and the mistakes that bite most often: the vector size
must match the embedding model, and `IngestOnce` skips new files.

## Multi-agent

There are three ways to combine agents. Pick by who decides the control flow:

1. **Agent as a tool**: the caller stays in charge.
   `t, _ := specialist.AsTool("ask_researcher", "Researches a topic")`, then
   `orchestrator.AddTool(t)`.
2. **Handoffs**: the model passes control to another agent.
   `triage.AddHandoff(billing)`. After `Run`, `res.Handoffs` lists
   `{Agent, Context}`. Your code routes the next turn to `h.Agent` with
   `h.Context`. More than one handoff means fan-out. Cap the number of hops
   yourself.
3. **Plain Go orchestration** (chaining, parallel fan-out with goroutines,
   evaluator-optimizer loops, debate): call `Run` on each agent and connect the
   results in code.

The module's `examples/` folder (path printed by `golib.sh`) has a working
program for each one. Read the matching program before you write your own:

| Building | Example |
|---|---|
| One agent with tools | `simple-agent`, `conversational-agent` (memory) |
| Handoffs / triage | `handoff` |
| Orchestrator calling sub-agents | `orchestrator-workers`, `multi-agent-workflow` |
| Parallel fan-out | `parallel-research` |
| Generate → critique loop | `evaluator-optimizer` |
| Debate / voting | `debate-committee` |
| Sequential pipeline | `prompt-chaining` |
| Shared state | `supervisor-blackboard` |
| Human approval | `human-in-the-loop` |
| Streaming, tracing, middleware | `streaming`, `tracing`, `llm-middleware` |
| RAG chatbot over documents | `rag-chatbot` |
| Semantic long-term memory | `long-term-memory` |
| MCP, A2A, NATS, skills | `mcp`, `playwright-mcp`, `a2a`, `nats-agent`, `nats-memory`, `skills` |

If the workflow must survive crashes, retry, or wait hours for a human, use
packtrail/stiggy instead of in-process orchestration.

## Streaming

```go
for ev, err := range a.RunStream(ctx, llm.Text(prompt)) {
    if err != nil { return err }
    switch ev.Type {
    case agent.EventTextDelta:      // token text
    case agent.EventReasoningDelta:
    case agent.EventToolCall, agent.EventToolResult:
    case agent.EventDone:
    }
}
```

## Tracing

`a.SetTracer(text.NewDefault())` (`trace/text`) prints colored logs of LLM calls,
tool calls and memory. Other tracers: `trace/jsonfile` (NDJSON) and `trace/otel`
(OpenTelemetry). `trace.NewLLM` wraps a raw LLM client.

## LLM middleware

`llm.Use(client, mw...)` wraps any backend with retry, rate limits, guardrails or
semantic caching. The agent sees a normal `llm.LLM`.

## Integrations

- **MCP**: `mcp.StdioTransport(cmd, args, env)` connects to a server, and
  `mcp.New(session)` exposes its tools to an agent. See `examples/mcp` and
  `examples/playwright-mcp`.
- **A2A**: `a2a.New(agent, baseURL)` serves an agent over HTTP.
  `a2a.NewClient(ctx, url)` calls a remote agent, which can then be used as a tool.
- **NATS Agent Protocol**: `nats.New(nc, handler, owner, name)` registers an agent
  as a NATS micro service. `nats.NewClient(nc)` finds and calls agents, and
  `Client.AsTool()` makes a remote agent a tool. It is wire-compatible with the
  TypeScript and Python SDKs.

## Common mistakes

- Every tool name on an agent must be unique. `AddTool` returns
  `*agent.ToolAlreadyExistsError`. Clean up generated names with `agent.SanitizeToolName`.
- Every constructor returns an error. Check it, because bad schemas fail at
  construction time.
- Use `res.TextContent()` for the final answer. When a run ends in a handoff,
  `Parts` holds only what the model wrote next to the handoff call.
