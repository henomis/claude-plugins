# henomis plugins

A plugin marketplace with agent skills for building multi-agent systems in Go.
It works with **Claude Code** and **GitHub Copilot CLI**: both read
`.claude-plugin/marketplace.json`, and the skills use the open Agent Skills
format (`SKILL.md`).

| Plugin | Skills | Library |
|---|---|---|
| `phero` | `phero` | [henomis/phero](https://github.com/henomis/phero): agents, tools, memory, handoffs, RAG, MCP, A2A, NATS |
| `packtrail` | `packtrail-flows` | [henomis/packtrail](https://github.com/henomis/packtrail): durable, event-sourced workflows on NATS JetStream |
| `stiggy` | `stiggy-fleet` | [henomis/stiggy](https://github.com/henomis/stiggy): multi-agent fleets on NATS, built on phero and packtrail |

stiggy builds on the other two. If you use it, install all three.

## Install

Claude Code:

```
/plugin marketplace add henomis/claude-plugins
/plugin install stiggy@henomis
```

GitHub Copilot CLI:

```
copilot plugin marketplace add henomis/claude-plugins
copilot plugin install stiggy@henomis
```

Other tools that support Agent Skills (Codex, Cursor, VS Code Copilot, ...):
copy a folder from `plugins/<plugin>/skills/` into the project's
`.github/skills/`, `.claude/skills/` or `.agents/skills/` directory.

## Layout

```
.claude-plugin/marketplace.json        # the catalog
plugins/<name>/.claude-plugin/plugin.json
plugins/<name>/skills/<skill>/SKILL.md
plugins/<name>/skills/<skill>/references/   # loaded on demand
plugins/<name>/skills/<skill>/scripts/golib.sh
```

## Versioning

Plugin versions are independent of the library versions. The skills don't pin
a library release. At run time `scripts/golib.sh` fetches the version the
user's `go.mod` requires (or the latest release) and points Claude at that
version's source, examples, docs and `go doc`. The SKILL.md files and
`references/` are a map, and the fetched source is the authority.

Bump a plugin's `version` (semver) whenever its skills change. Claude Code
uses that number to detect updates.

## Keeping skills in sync

- `golib.sh` is the same file in every skill, because each plugin installs on
  its own. Edit one copy and copy it to the others.
- `plugins/packtrail/skills/packtrail-flows/references/docs.md` is generated
  from packtrail's `web/docs.html` with pandoc, then patched by hand. It
  currently describes v1.0.3.
- `plugins/stiggy/skills/stiggy-fleet/references/fleet-reference.md` is a copy
  of stiggy's `docs/reference.md`, with the v0.3.1 additions (tracing, logs,
  budget counters, named pattern rules) taken from `web/guide.html`.

When a library release changes the API, refresh the cheat sheets and
references, but they don't have to land on release day. Until they do, the
skills tell Claude to trust the fetched source over them.

## License

Apache 2.0.
