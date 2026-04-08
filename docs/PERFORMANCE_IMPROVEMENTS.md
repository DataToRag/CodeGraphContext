# Indexing Performance Improvements

> Tracking optimizations to CodeGraphContext's graph indexing pipeline.
> Benchmark: 76 Python files (CGC `src/` directory, ~880 nodes).
> Real-world test: RamPump repository (9,382 files, 84,501 nodes).

## Summary

| Version | DB Write/File | Total (76 files) | DB Round Trips | Key Change |
|---------|--------------|-------------------|----------------|------------|
| **v0 (baseline)** | 43.1 ms | 6.37s | ~456 | Per-file MERGE, per-file directory creation |
| **v1 (dir batch)** | 30.9 ms | 4.64s | ~380 | Batch directory hierarchy creation |
| **v2 (cross-file batch)** | 25.2 ms | 4.11s | ~12 per flush | Accumulate nodes across files, flush every 100 |
| **v3 (parse-then-write)** | 26.1 ms | 4.29s | ~12 total | Parse ALL files first, single batch write |
| **v4 (large chunks + combined)** | 4.5 ms | 2.72s | ~6 | 50K chunk size, CREATE+CONTAINS in one query |
| **v5 (code-only files)** | 4.5 ms | 2.86s | ~6 | Skip non-code files (31% fewer files for RamPump) |
| **v6 (concurrent writes)** | 4.9 ms | 2.78s | ~6 | Thread pool for parallel node type writes |
| **v7 (skip vars+params)** | 2.2 ms | 3.35s | ~10 | Drop Variable/Parameter nodes (76% of total) |

**Overall improvement: 6.37s → 3.35s (47% faster), node count: 205K → 49K (76% reduction), round trips: 456 → ~10 (98% reduction)**

---

## Detailed Breakdown

### v0: Baseline (per-file operations)

Each file triggered 4-10 `session.run()` Cypher queries:

1. MERGE File node (1 query)
2. Directory hierarchy — one MERGE per parent directory level (2-5 queries per file)
3. MERGE code nodes per label — Function, Class, etc. (1-2 queries)
4. MERGE CONTAINS edges (1-2 queries)
5. MERGE Parameters (1 query if applicable)
6. MERGE Imports (1 query if applicable)

**For 76 files**: ~456 round trips to FalkorDB. Each round trip includes Cypher parsing, query planning, execution, and TCP/socket serialization overhead.

```
Profile:
  parse:          1.37s  (18.1 ms/file)
  db_write:       3.28s  (43.1 ms/file)  ← bottleneck
  dir_hierarchy:  included in db_write
  function_calls: 1.15s
  TOTAL:          6.37s
```

### v1: Batch Directory Hierarchy

**Change**: Replaced per-file directory creation (O(files × depth) queries) with a single batch operation after all files are processed.

New `_create_directory_hierarchy_batch()` method:
- Collects all unique directory paths in one pass
- Creates all Directory nodes in one UNWIND query
- Creates all CONTAINS edges (Repo→Dir, Dir→Dir, Dir→File) in ~4 UNWIND queries

**Result**: Eliminated ~300 per-file directory queries, replaced with ~5 total queries.

```
Profile:
  parse:          1.00s  (13.1 ms/file)
  db_write:       2.35s  (30.9 ms/file)  ← 28% faster
  dir_hierarchy:  0.01s  (was included above)
  function_calls: 0.86s
  TOTAL:          4.64s
```

### v2: Cross-File Batch Accumulation

**Change**: Instead of calling `add_file_to_graph()` per file (each doing ~6 queries), accumulate parsed data across files and flush every 100 files via `add_files_to_graph_batch()`.

The batch method accumulates:
- All File nodes across files
- All Function nodes across files (with file_path in each row)
- All Class nodes, Variable nodes, etc.
- All CONTAINS edges, Parameters, Imports

Then executes ~12 total queries (one per node type + edge type) regardless of file count within the batch.

**Result**: Round trips dropped from ~456 to ~12 per batch.

```
Profile:
  parse:          0.91s  (11.9 ms/file)
  db_write:       1.91s  (25.2 ms/file)  ← 42% faster than v0
  dir_hierarchy:  0.01s
  function_calls: 0.91s
  TOTAL:          4.11s
```

### v3: Parse-All-Then-Write-All

**Change**: Restructured the indexing pipeline into two clear phases:

1. **Parse phase**: Parse ALL files into memory using tree-sitter (no DB calls)
2. **Write phase**: Single call to `add_files_to_graph_batch()` for all files at once

This enables better progress reporting (separate "parsing" and "node_creation" phases) and ensures the DB write is one contiguous operation.

```
Profile:
  prescan+filter: 0.40s
  parse:          0.91s  (11.9 ms/file)
  batch_write:    1.98s  (all 76 files in one shot)
  dir_hierarchy:  0.02s
  relationships:  0.97s
  TOTAL:          4.29s
```

### v4: Large Chunks + Combined Queries

**Change**: Two optimizations:

1. **Increased UNWIND chunk size from 2,000 to 50,000**: With 84K nodes, chunk size 2000 generated 84 sequential queries. At 50K, this drops to ~2 queries per node type.

2. **Combined CREATE + CONTAINS in single query**: For fresh indexing (CREATE mode), the node creation and File→Node CONTAINS edge are created in one query instead of two, halving round trips.

Before (per label):
```cypher
-- Query 1: Create nodes
UNWIND $batch AS row
CREATE (n:Function {name: row.name, path: row.path, line_number: row.line_number})
SET n += row

-- Query 2: Create edges
UNWIND $batch AS row
MATCH (f:File {path: row.file_path})
MATCH (n:Function {name: row.name, ...})
CREATE (f)-[:CONTAINS]->(n)
```

After (combined):
```cypher
-- Single query: Create node + edge
UNWIND $batch AS row
MATCH (f:File {path: row.path})
CREATE (n:Function {name: row.name, path: row.path, line_number: row.line_number})
SET n += row
CREATE (f)-[:CONTAINS]->(n)
```

**Result**: Batch write went from 1.98s to 0.34s (83% faster).

```
Profile:
  prescan+filter: 0.40s
  parse:          0.91s  (11.9 ms/file)
  batch_write:    0.34s  (CREATE, chunk=50000)  ← 83% faster than v3
  dir_hierarchy:  0.01s
  relationships:  1.06s
  TOTAL:          2.72s
```

---

## CREATE vs MERGE

For initial indexing of a fresh repository, the pipeline uses `CREATE` instead of `MERGE`:

- **MERGE**: "Find this node; if it doesn't exist, create it." Requires an index lookup per node.
- **CREATE**: "Create this node." No existence check, direct insert.

Since the indexing handler already checks if a repository is indexed before starting, `CREATE` is safe for the initial load and avoids N existence checks.

---

## Non-Blocking HTTP Server

**Problem**: The indexing coroutine was scheduled on the main asyncio event loop via `asyncio.run_coroutine_threadsafe()`. Since `build_graph_from_path_async` does heavy synchronous work (file parsing, DB writes), it blocked uvicorn from serving HTTP requests during indexing.

**Fix**: Replaced with `threading.Thread` + `build_graph_from_path_sync()` that creates its own event loop. The HTTP server remains fully responsive during indexing — health checks, job status queries, and other tool calls work with ~400ms latency.

---

## Progress Tracking

`check_job_status` now returns detailed progress during indexing:

```json
{
  "status": "running",
  "phase": "node_creation",
  "processed_files": 5000,
  "total_files": 9382,
  "nodes_created": 42000,
  "edges_created": 0,
  "progress_percentage": 53.3,
  "avg_ms_per_file": 15.6,
  "estimated_time_remaining_human": "1m 8s",
  "elapsed_time_human": "1m 22s"
}
```

Phases: `parsing` → `node_creation` → `relationship_linking` → `completed`

---

## RamPump Real-World Results (9,382 files)

| Phase | Time | Notes |
|-------|------|-------|
| Parsing | ~2m 30s | 9,382 files parsed, 84,501 nodes extracted via tree-sitter |
| Node creation | 15m+ (in progress) | 84K CREATE operations via FalkorDB Lite embedded |
| Relationship linking | TBD | Inheritance + function call resolution |
| **Total** | **~20m+ estimated** | |

### Final Results (Docker FalkorDB, all optimizations)

| Phase | Time | Details |
|-------|------|---------|
| Filter + list | 6s | 6,429 code files (31% fewer after skipping non-code) |
| Pre-scan imports | 26s | Build imports map for cross-file resolution |
| Parse (tree-sitter) | 99s (1m 39s) | 15.4ms/file, 81,518 nodes extracted |
| Node creation (CREATE) | 190s (3m 10s) | 81K nodes via batched CREATE + thread pool |
| Directory hierarchy | 6s | Batch MERGE for directory tree |
| Inheritance links | 2s | INHERITS edges |
| **Total** | **328s (5m 28s)** | **Without CALLS edges** |

**CALLS edges disabled** — the upstream call resolver generates 600K+ spurious edges via aggressive name-based matching (e.g., `get`, `render`, `init` matched across unrelated files). This is a bug in `_resolve_function_call`, not a performance issue. With CALLS enabled, indexing takes 1-3+ hours and may crash FalkorDB Lite.

Key finding: Variables (101K) and Parameters (55K) were 76% of all nodes but rarely queried. Dropping them cut actual DB writes from ~205K to ~81K nodes.

### FalkorDB Lite vs Docker

| Metric | FalkorDB Lite (embedded) | Docker FalkorDB (TCP) |
|--------|-------------------------|----------------------|
| Node creation (81K) | ~10 min | ~3 min |
| Stability | Crashed at 3h (broken pipe) | Stable |
| Relationship linking | Failed | Works (but slow due to CALLS bug) |
| Setup | ARM64 .so patching required | `docker run falkordb/falkordb` |

Docker FalkorDB is 3x faster on node creation and doesn't crash under load.

### Bottleneck Analysis

The node creation phase dominates total time. Even with CREATE (no existence check) and 50K chunk sizes (minimal round trips), FalkorDB's internal processing of each UNWIND item is ~0.2ms. For 84K nodes: 84,000 x 0.2ms = ~17 seconds of pure processing, but the observed time is much higher due to:
- Property serialization overhead (each node has ~10-15 properties)
- Index maintenance on each CREATE
- Redis protocol serialization for large UNWIND batches
- Graph storage engine write amplification

### Potential Future Optimizations

- **FalkorDB GRAPH.BULK import API** — if FalkorDB adds a bulk loader, could bypass the Cypher/UNWIND path entirely
- **Reduce node count** — skip Variable/Parameter nodes for initial fast index, add them in a second pass
- **Parallel graph writes** — use separate FalkorDB graph instances per file type, merge after
- **Embedded mode tuning** — investigate FalkorDB server config (thread count, memory allocation)

---

## Architecture

```
[Parse Phase]
  files → tree-sitter → file_data[]  (CPU-bound, ~12ms/file)

[Write Phase]
  file_data[] → add_files_to_graph_batch()
    → UNWIND File nodes      (1 query, all files)
    → UNWIND Function nodes  (1 query, all functions across all files)
    → UNWIND Class nodes     (1 query)
    → UNWIND Parameters      (1 query)
    → UNWIND Imports          (1 query)
    → Directory hierarchy    (~5 queries)
  Total: ~10 queries regardless of file count

[Relationship Phase]
  → _create_all_inheritance_links()  (batched at 1000)
  → _create_all_function_calls()    (batched at 1000, label-specific)
```

---

## Database Backend

- **FalkorDB Lite** (embedded, in-process via Unix socket)
- ARM64 macOS requires replacing the x86-64 `falkordb.so` from `falkordblite` with the official ARM64 macOS build from [FalkorDB releases](https://github.com/FalkorDB/FalkorDB/releases)
- No Docker or external processes required
