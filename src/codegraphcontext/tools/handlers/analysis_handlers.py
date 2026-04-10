from typing import Any, Dict, List
from ..code_finder import CodeFinder
from ...utils.debug_log import debug_log

# Framework decorators that register functions dynamically (routes, CLI commands, tasks, etc.)
_DEFAULT_EXCLUDE_DECORATORS = [
    # Flask / FastAPI / Django
    "app.route", "router.get", "router.post", "router.put", "router.delete",
    "api_view", "action", "login_required",
    # Celery / task queues
    "task", "shared_task", "periodic_task",
    # Click / Typer / argparse CLI
    "cli.command", "command", "group",
    # pytest / unittest
    "fixture", "parametrize", "mark",
    # Paver
    "task",
    # General registration
    "register", "subscriber", "receiver", "hook", "listener",
    "staticmethod", "classmethod", "property", "abstractmethod",
]

# File patterns where functions are expected to be "entry points" (not called statically)
_ENTRY_POINT_FILES = {
    "conftest.py", "setup.py", "manage.py", "wsgi.py", "asgi.py",
    "Gruntfile.js", "gulpfile.js", "webpack.config.js",
    "jest.config.js", "vite.config.ts", "vite.config.js",
}


def _filter_dead_code_results(results: List[Dict]) -> List[Dict]:
    """Remove common false positives from dead code results."""
    filtered = []
    for r in results:
        name = r.get("function_name", "")
        path = r.get("path", "")
        file_name = r.get("file_name", "")

        # Skip test functions
        if name.startswith("test_") or name.startswith("Test"):
            continue

        # Skip known entry point files
        if file_name in _ENTRY_POINT_FILES:
            continue

        # Skip MCP tool handlers
        if "/handlers/" in path and path.endswith("_handlers.py"):
            continue

        filtered.append(r)
    return filtered


def find_dead_code(code_finder: CodeFinder, **args) -> Dict[str, Any]:
    """Tool to find potentially dead code across the entire project."""
    exclude_decorated_with = args.get("exclude_decorated_with", [])
    include_all = args.get("include_all", False)
    repo_path = args.get("repo_path")

    # Merge user exclusions with defaults
    all_exclusions = list(set(_DEFAULT_EXCLUDE_DECORATORS + exclude_decorated_with))

    try:
        debug_log(f"Finding dead code. repo_path={repo_path}, include_all={include_all}")
        results = code_finder.find_dead_code(exclude_decorated_with=all_exclusions, repo_path=repo_path)

        # Filter common false positives unless include_all is set
        if not include_all:
            raw_count = len(results.get("potentially_unused_functions", []))
            results["potentially_unused_functions"] = _filter_dead_code_results(
                results.get("potentially_unused_functions", [])
            )
            results["filtered_count"] = raw_count - len(results["potentially_unused_functions"])

        return {
            "success": True,
            "query_type": "dead_code",
            "results": results
        }
    except Exception as e:
        debug_log(f"Error finding dead code: {str(e)}")
        return {"error": f"Failed to find dead code: {str(e)}"}

def calculate_cyclomatic_complexity(code_finder: CodeFinder, **args) -> Dict[str, Any]:
    """Tool to calculate cyclomatic complexity for a given function."""
    function_name = args.get("function_name")
    path = args.get("path")
    repo_path = args.get("repo_path")

    try:
        debug_log(f"Calculating cyclomatic complexity for function: {function_name}, repo_path={repo_path}")
        results = code_finder.get_cyclomatic_complexity(function_name, path, repo_path=repo_path)
        
        response = {
            "success": True,
            "function_name": function_name,
            "results": results
        }
        if path:
            response["path"] = path
        
        return response
    except Exception as e:
        debug_log(f"Error calculating cyclomatic complexity: {str(e)}")
        return {"error": f"Failed to calculate cyclomatic complexity: {str(e)}"}

def find_most_complex_functions(code_finder: CodeFinder, **args) -> Dict[str, Any]:
    """Tool to find the most complex functions."""
    limit = int(args.get("limit", 10))
    repo_path = args.get("repo_path")
    try:
        debug_log(f"Finding the top {limit} most complex functions. repo_path={repo_path}")
        results = code_finder.find_most_complex_functions(limit, repo_path=repo_path)
        return {
            "success": True,
            "limit": limit,
            "results": results
        }
    except Exception as e:
        debug_log(f"Error finding most complex functions: {str(e)}")
        return {"error": f"Failed to find most complex functions: {str(e)}"}

def analyze_code_relationships(code_finder: CodeFinder, **args) -> Dict[str, Any]:
    """Tool to analyze code relationships"""
    query_type = args.get("query_type")
    target = args.get("target")
    context = args.get("context")
    repo_path = args.get("repo_path")

    if not query_type or not target:
        return {
            "error": "Both 'query_type' and 'target' are required",
            "supported_query_types": [
                "find_callers", "find_callees", "find_all_callers", "find_all_callees", "find_importers", "who_modifies",
                "class_hierarchy", "overrides", "dead_code", "call_chain",
                "module_deps", "variable_scope", "find_complexity", "find_functions_by_argument", "find_functions_by_decorator"
            ]
        }
    
    try:
        debug_log(f"Analyzing relationships: {query_type} for {target}, repo_path={repo_path}")
        results = code_finder.analyze_code_relationships(query_type, target, context, repo_path=repo_path)
        
        return {
            "success": True, "query_type": query_type, "target": target,
            "context": context, "results": results
        }
    
    except Exception as e:
        debug_log(f"Error analyzing relationships: {str(e)}")
        return {"error": f"Failed to analyze relationships: {str(e)}"}

def _compact_result(result: Dict) -> Dict:
    """Strip full source from a result, keep only the signature/first line."""
    r = dict(result)
    source = r.pop("source", None)
    if source and isinstance(source, str):
        # Keep just the first line (def/class signature)
        first_line = source.strip().split("\n")[0]
        r["signature"] = first_line
    return r


def find_code(code_finder: CodeFinder, **args) -> Dict[str, Any]:
    """Tool to find relevant code snippets"""
    query = args.get("query")
    DEFAULT_EDIT_DISTANCE = 2
    DEFAULT_FUZZY_SEARCH = False

    fuzzy_search = args.get("fuzzy_search", DEFAULT_FUZZY_SEARCH)
    edit_distance = args.get("edit_distance", DEFAULT_EDIT_DISTANCE)
    include_source = args.get("include_source", False)
    repo_path = args.get("repo_path")

    if fuzzy_search:
        query = query.lower().replace("_", " ").strip()

    try:
        debug_log(f"Finding code for query: {query} with fuzzy_search={fuzzy_search}, edit_distance={edit_distance}, repo_path={repo_path}")
        results = code_finder.find_related_code(query, fuzzy_search, edit_distance, repo_path=repo_path)

        # Strip full source by default — return compact summaries
        if not include_source:
            for key in ["functions_by_name", "classes_by_name", "variables_by_name", "content_matches"]:
                if key in results:
                    results[key] = [_compact_result(r) for r in results[key]]
            if "ranked_results" in results:
                results["ranked_results"] = [_compact_result(r) for r in results["ranked_results"]]

        return {"success": True, "query": query, "results": results}

    except Exception as e:
        debug_log(f"Error finding code: {str(e)}")
        return {"error": f"Failed to find code: {str(e)}"}
