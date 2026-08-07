import Foundation

// MCP servers are spawned by their client and speak JSON-RPC over stdin/stdout. Nothing may be
// written to stdout except protocol frames.
setvbuf(stdout, nil, _IOLBF, 0)

await MCPServer().run()
