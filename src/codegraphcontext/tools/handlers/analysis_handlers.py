import re
from typing import Any, Dict, List
from ..code_finder import CodeFinder
from ...utils.debug_log import debug_log

# ── Dead code confidence scoring ──────────────────────────────────────────

# Decorator substrings that indicate framework registration (not dead code).
# Matched against the full decorator text (e.g., "@app.route('/foo')")
_FRAMEWORK_DECORATOR_PATTERNS = [
    # Web routes
    "route", "api_view", "endpoint", "url_pattern",
    # Celery / task queues
    "task", "shared_task", "periodic_task",
    # CLI frameworks
    "command", "group", "argument", "option",
    # Pytest / unittest
    "fixture", "parametrize",
    # Signals / events
    "receiver", "listens_for", "listener", "subscriber", "hook",
    # Registration patterns
    "register", "callback", "handler", "middleware",
    # ORM / serialization
    "validates", "pre_save", "post_save",
    # Auth
    "login_required", "auth_required", "permission",
    # Abstract / interface
    "abstractmethod",
]

# File names where functions are expected to be entry points
_ENTRY_POINT_FILES = {
    "conftest.py", "setup.py", "manage.py", "wsgi.py", "asgi.py",
    "pavement.py", "fabfile.py", "tasks.py",
    "Gruntfile.js", "gulpfile.js", "webpack.config.js",
    "jest.config.js", "vite.config.ts", "vite.config.js",
    "karma.conf.js",
}

# File path patterns for test/config files
_ENTRY_POINT_PATH_PATTERNS = [
    r"/conftest\.py$",
    r"_test\.py$",
    r"/test_[^/]+\.py$",
    r"/tests/",
    r"/migrations/",
]


def _normalize_decorator(dec_text: str) -> str:
    """Extract the core decorator name from full text like '@app.route(...)'."""
    # Strip @ prefix
    d = dec_text.lstrip("@").strip()
    # Strip arguments: @app.route('/foo') → app.route
    paren = d.find("(")
    if paren != -1:
        d = d[:paren]
    return d.strip()


def _has_framework_decorator(decorators: list) -> bool:
    """Check if any decorator matches a framework registration pattern."""
    for dec in decorators:
        if not dec:
            continue
        normalized = _normalize_decorator(dec).lower()
        for pattern in _FRAMEWORK_DECORATOR_PATTERNS:
            if pattern in normalized:
                return True
    return False


def _score_dead_code(func: Dict, override_methods: set) -> str:
    """Assign confidence: high, medium, or low.

    high   = no decorators, no interface override, no convention match → likely truly dead
    medium = has some indicator but ambiguous
    low    = almost certainly a framework callback / interface impl → not dead
    """
    name = func.get("function_name", "")
    path = func.get("path", "")
    file_name = func.get("file_name", "")
    decorators = func.get("decorators") or []
    class_context = func.get("class_context") or ""
    line = func.get("line_number", 0)

    # LOW: framework decorator detected
    if _has_framework_decorator(decorators):
        return "low"

    # LOW: interface override (method exists in parent class via INHERITS)
    if (name, path, line) in override_methods:
        return "low"

    # LOW: known entry point files
    if file_name in _ENTRY_POINT_FILES:
        return "low"

    # LOW: test files
    for pat in _ENTRY_POINT_PATH_PATTERNS:
        if re.search(pat, path):
            return "low"

    # LOW: handler files (MCP, API, etc.)
    if "/handlers/" in path:
        return "low"

    # MEDIUM: has decorators (could be custom framework)
    non_empty = [d for d in decorators if d and d != ""]
    if non_empty:
        return "medium"

    # MEDIUM: is a class method (could be interface impl we couldn't detect)
    if class_context:
        return "medium"

    # HIGH: standalone function, no decorators, no class, no special file
    return "high"


def find_dead_code(code_finder: CodeFinder, **args) -> Dict[str, Any]:
    """Tool to find potentially dead code across the entire project."""
    include_all = args.get("include_all", False)
    include_low_confidence = args.get("include_low_confidence", False)
    repo_path = args.get("repo_path")

    try:
        debug_log(f"Finding dead code. repo_path={repo_path}, include_all={include_all}")
        results = code_finder.find_dead_code(repo_path=repo_path)

        raw = results.get("potentially_unused_functions", [])
        override_methods = results.get("override_methods", set())

        # Score each result
        for func in raw:
            func["confidence"] = _score_dead_code(func, override_methods)

        if include_all:
            filtered = raw
        elif include_low_confidence:
            filtered = [f for f in raw if f["confidence"] in ("high", "medium", "low")]
        else:
            # Default: only high confidence
            filtered = [f for f in raw if f["confidence"] == "high"]

        # Remove internal fields from output
        for f in filtered:
            f.pop("decorators", None)
            f.pop("class_context", None)

        counts = {"high": 0, "medium": 0, "low": 0}
        for f in raw:
            counts[f["confidence"]] = counts.get(f["confidence"], 0) + 1

        return {
            "success": True,
            "query_type": "dead_code",
            "results": {
                "potentially_unused_functions": filtered,
                "confidence_breakdown": counts,
                "total_uncalled": len(raw),
                "note": "Only high-confidence results shown by default. "
                        "Use include_low_confidence=true or include_all=true for more.",
            }
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
