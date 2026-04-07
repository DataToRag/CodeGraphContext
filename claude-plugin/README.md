# CodeGraphContext — Claude Code Plugin

Code graph analysis powered by FalkorDB. Index repositories into a graph database, query relationships between functions, classes, and modules, detect dead code, and visualize architecture.

## Prerequisites

1. **CodeGraphContext Mac app** must be running (menu bar icon visible)
2. The MCP server must be healthy (green status dot in the menu bar)
3. At least one repository must be indexed

## Installation

Install from the Claude Code plugin marketplace:

```bash
claude plugin install codegraphcontext
```

Or add manually to your project's `.mcp.json`:

```json
{
  "mcpServers": {
    "codegraphcontext": {
      "type": "http",
      "url": "http://localhost:3100/mcp"
    }
  }
}
```

## Available Tools

### Indexing
- **add_code_to_graph** — Index a repository into the graph database
- **list_repos** — List all indexed repositories

### Code Search & Navigation
- **find_code** — Search for functions, classes, or modules by name or pattern
- **get_file_summary** — Get an overview of a file's contents and structure
- **get_function_detail** — Get full details of a function (signature, body, dependencies)

### Relationship Analysis
- **who_calls_function** — Find all callers of a given function
- **what_does_function_call** — Find all functions called by a given function
- **analyze_code_relationships** — Map relationships between code entities
- **get_dependency_graph** — Get the dependency graph for a module or package
- **find_import_chains** — Trace import/dependency chains between two modules

### Architecture & Quality
- **find_dead_code** — Detect unreachable or unused code
- **find_circular_dependencies** — Detect circular import/dependency cycles
- **get_module_coupling** — Measure coupling between modules
- **get_code_complexity** — Analyze complexity metrics for functions or files

### Graph Queries
- **query_graph** — Run a raw Cypher query against the code graph
- **get_graph_stats** — Get statistics about the indexed graph (node/edge counts, etc.)

## Example Usage

### Index a repository
```
> Index the RamPump project at /Users/myang/git/RamPump
```
Claude will use `add_code_to_graph` to index the repository.

### Explore architecture
```
> How is the RamPump backend structured? What are the main modules and how do they connect?
```
Claude will use `find_code`, `analyze_code_relationships`, and `get_dependency_graph` to map the architecture.

### Find callers
```
> What calls the main entry point in RamPump?
```
Claude will use `who_calls_function` to trace the call chain.

### Detect dead code
```
> Find dead code in the Python backend
```
Claude will use `find_dead_code` to identify unreachable functions and unused imports.

### Custom graph queries
```
> Show me all Python classes that inherit from BaseModel
```
Claude will use `query_graph` with a Cypher query to find the inheritance chain.
