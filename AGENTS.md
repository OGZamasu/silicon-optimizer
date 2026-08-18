# Silicon Optimizer

## Memories hub
This project is tracked on the Memories hub — our shared bug/wiki/memory service for every project, usable by any MCP-capable agent (Claude, ChatGPT in developer mode, …).
- At session start, call get_context for project "silicon-optimizer" to load open issues, recent changes, and relevant memories.
- File out-of-scope bugs/ideas with file_issue instead of fixing them inline.
- Save durable decisions, conventions, and gotchas with save_memory.
- Before ending a session, record shipped work with log_change.
Web UI: https://memories.zamasu.dev · MCP endpoint: https://memories.zamasu.workers.dev/mcp
