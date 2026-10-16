# RAG with phero

A RAG pipeline in phero has four parts. Each is an interface, so any backend fits:

| Step | Package | Implementations |
|---|---|---|
| Chunk | `textsplitter` | `textsplitter/recursive`, `textsplitter/markdown` |
| Embed | `embedding` | `embedding/openai` (OpenAI or Ollama) |
| Store | `vectorstore` | `vectorstore/qdrant`, `vectorstore/psql`, `vectorstore/weaviate` |
| Glue | `rag` | `rag.New(store, embedder, opts...)` |

Read this file when the app needs document search, a RAG chatbot,
embeddings, chunking, a vector store or semantic long-term memory. Agent
basics (tools, memory, `agent.New`, setting up the module) are in `SKILL.md`.

## Ground the RAG parts

Vector store clients and embedder options are the easiest things to get wrong
from memory. With the module directory printed by `scripts/golib.sh`:

1. Read `examples/rag-chatbot/main.go` (ingest plus a search tool) or
   `examples/long-term-memory/main.go` (`AsMemory`). Copy how they build the
   vector store client and the embedder.
2. Read `web/docs/rag.html`, `vectorstore.html`, `embedding.html` and
   `textsplitter.html` for the options.
3. Check each constructor with `go doc`. Use only the `vectorstore/<backend>`
   and `embedding/<provider>` packages that exist in that version.

## Pipeline

```go
import (
    embopenai "github.com/henomis/phero/v2/embedding/openai"
    "github.com/henomis/phero/v2/rag"
    "github.com/henomis/phero/v2/textsplitter/recursive"
    vsqdrant "github.com/henomis/phero/v2/vectorstore/qdrant"
)

embedder := embopenai.New(apiKey)                       // embopenai.WithModel, WithBaseURL(embopenai.OllamaBaseURL)
splitter := recursive.New("docs/handbook.md", 1000, 100) // source, chunkSize, chunkOverlap

store, err := vsqdrant.New(qdrantClient, "handbook",
    vsqdrant.WithVectorSize(1536),  // must match the embedding model
    vsqdrant.WithWait(true))

r, err := rag.New(store, embedder, rag.WithTopK(4))
err = r.IngestOnce(ctx, splitter)  // skips ingestion if the collection already has data; Ingest always ingests

search, err := r.AsTool("search_handbook", "Search the editorial handbook for relevant excerpts.")
err = a.AddTool(search)
```

In the system prompt, tell the agent to call the search tool before answering
questions about the documents, and to say when it finds nothing.

## Citing sources

`r.AsTool` returns only the chunk text. If the agent has to say which file an
answer came from, write a small tool on top of `r.Query` instead. Each
`ScoredPoint.Payload` holds the chunk's metadata plus its text under `"text"`.
The splitters set `"source"` (the path given to `New`, or
`recursive.MetaSource`) and `"chunk_index"`:

```go
type SearchIn struct{ Query string `json:"query" jsonschema:"description=What to look up in the docs"` }
type Hit struct{ Source, Text string; Score float32 }
type SearchOut struct{ Results []Hit `json:"results"` }

search, err := llm.NewTool("search_docs", "Search the docs. Returns excerpts with their source file.",
    func(ctx context.Context, in *SearchIn) (*SearchOut, error) {
        pts, err := r.Query(ctx, in.Query)
        if err != nil { return nil, err }
        out := &SearchOut{}
        for _, p := range pts {
            src, _ := p.Payload["source"].(string)
            txt, _ := p.Payload["text"].(string)
            out.Results = append(out.Results, Hit{Source: src, Text: txt, Score: p.Score})
        }
        return out, nil
    })
```

Check the payload keys against the version with `go doc ./textsplitter/recursive`
and by reading `rag/rag.go`. To index a whole folder, create one splitter per
file and call `Ingest` for each.

## Other uses

- **Query directly**: `r.Query(ctx, "question")` returns `[]vectorstore.ScoredPoint`,
  for use without an agent.
- **Filters**: set a default with
  `rag.WithFilter(vectorstore.NewFilter(vectorstore.Eq("lang", "en")))`, or pass one
  per query: `r.Query(ctx, q, vectorstore.WithFilter(f))`. Conditions: `Eq`,
  `Ne`, `Gt`, `Gte`, `Lt`, `Lte`, `In`.
- **Semantic long-term memory**: `a.SetMemory(r.AsMemory())` saves conversation
  turns as vectors and recalls the relevant ones, instead of the most recent ones.
- **Batching**: `rag.WithBatchSize(n)` sets the embedding batch size during ingestion.

## Common mistakes

- **Wrong vector size.** The collection's vector size must match the embedder
  (e.g. OpenAI `text-embedding-3-small` = 1536, `nomic-embed-text` = 768). If you
  change the model, create a new collection.
- **`IngestOnce` misses new files.** It only checks whether the collection is
  empty. Use `Ingest` (or a new collection) to re-index after the sources change.
  With one splitter per file, calling `IngestOnce` in a loop indexes only the
  first file. Check `store.Count(ctx)` once (`store.Clear(ctx)` to re-index), then `Ingest` every
  file. Chunk IDs are random UUIDs, so ingesting the same file twice stores
  duplicates.
- **Use the Markdown splitter for Markdown.** `textsplitter/markdown` splits on
  headings first, which keeps sections together.
- **Local stack**: `docker run -p 6333:6333 -p 6334:6334 qdrant/qdrant` (the Go
  client uses gRPC on 6334). Run Ollama with an embedding model for a setup with
  no API keys.
