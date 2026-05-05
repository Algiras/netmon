# MCP Integration

netmon ships with `netmon_mcp.py` — an MCP (Model Context Protocol) server that lets Claude Code, Claude Desktop, or any MCP-compatible client query and act on network events directly from a conversation.

---

## What you can do via MCP

| Tool | What it does |
|------|-------------|
| `get_pending_events` | List all events waiting for review |
| `get_recent_events` | List the last N resolved events |
| `confirm_event` | Confirm a pending event (add to baseline) |
| `reject_event` | Reject a pending event (flag IP) |
| `get_config` | Read the current netmon config |
| `update_config` | Update config values |
| `get_baseline` | List all baseline entries |
| `remove_baseline_entry` | Remove a specific baseline entry |
| `get_blocked_ips` | List blocked IPs |
| `unblock_ip` | Unblock an IP |
| `trigger_recheck` | Re-run analysis on pending events |

---

## Setup

### Claude Code

Add to your Claude Code settings (`~/.claude/settings.json` or `claude config`):

```json
{
  "mcpServers": {
    "netmon": {
      "command": "python3",
      "args": ["/Users/you/.netmon/netmon_mcp.py"]
    }
  }
}
```

Or via the CLI:

```bash
claude mcp add netmon python3 ~/.netmon/netmon_mcp.py
```

### Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "netmon": {
      "command": "python3",
      "args": ["/Users/you/.netmon/netmon_mcp.py"]
    }
  }
}
```

---

## Example conversation

Once the MCP server is connected, you can ask Claude things like:

> "What network events are pending in netmon?"

> "Reject event #932 — that IP shouldn't have been contacted."

> "Show me the last 10 resolved events and summarize which processes were most active."

> "Enable autonomous mode in netmon."

Claude will call the appropriate MCP tools and show you the results in the conversation.

---

## Authentication

`netmon_mcp.py` reads the token from `~/.netmon/panel_token` automatically. No manual configuration required — the same token used by the Swift app is used by the MCP server.

---

## Running the MCP server manually

```bash
python3 ~/.netmon/netmon_mcp.py
```

The server communicates over stdin/stdout (the MCP stdio transport). It does not need to run as a daemon — the MCP client manages its lifecycle.

---

## Troubleshooting MCP

If tools return errors, check:

1. Panel server is running: `curl -H "Host: localhost:6543" -H "X-Netmon-Token: $(cat ~/.netmon/panel_token)" http://localhost:6543/api/config`
2. Token file exists: `ls -l ~/.netmon/panel_token`
3. Python packages installed: `python3 -c "import mcp; import anthropic"`
