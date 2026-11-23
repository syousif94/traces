import Foundation

#if os(macOS)
if CommandLine.arguments.contains("--mcp") { MCPRelay.run() }
#endif
TracesApp.main()
