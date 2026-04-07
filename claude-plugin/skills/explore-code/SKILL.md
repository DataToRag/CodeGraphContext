---
name: explore-code
description: Systematically explore and explain a codebase using the code graph
---

# Explore Code

Use this skill when the user asks to understand a codebase, explain architecture, or figure out how something works. This skill leverages the code graph to give structural answers rather than just grep-based guesses.

## When to use

- "Explain this codebase"
- "How does X work?"
- "What's the architecture of this project?"
- "How do these modules connect?"
- "Walk me through the request flow"

## Approach

### 1. Identify scope

Determine what the user wants to understand:
- **Whole project** — start with high-level module structure
- **Specific feature** — find the entry point and trace through
- **Specific function/class** — get details and relationships

### 2. High-level overview (whole project)

Use these tools in sequence:

1. **`list_repos`** — confirm the project is indexed
2. **`get_graph_stats`** — understand the scale (files, functions, classes)
3. **`get_dependency_graph`** — map top-level module dependencies
4. **`find_code`** — identify key entry points (main functions, API routes, etc.)

Present a structured overview:
- Main modules and their responsibilities
- Key entry points
- How modules connect to each other
- External dependencies

### 3. Feature deep-dive

When exploring a specific feature or flow:

1. **`find_code`** — locate the relevant function or class
2. **`get_function_detail`** — understand the implementation
3. **`what_does_function_call`** — trace what it depends on
4. **`who_calls_function`** — trace what depends on it
5. **`analyze_code_relationships`** — map the full relationship web

Build a narrative:
- Where does execution start?
- What are the key decision points?
- What data flows through the system?
- What are the side effects?

### 4. Relationship questions

For "who calls X" / "what does X depend on" questions:

1. **`who_calls_function`** or **`what_does_function_call`** — direct relationships
2. **`find_import_chains`** — trace the dependency path between two points
3. **`get_module_coupling`** — quantify how tightly coupled things are

### 5. Quality assessment

If the user asks about code quality or potential issues:

1. **`find_dead_code`** — unused functions and imports
2. **`find_circular_dependencies`** — problematic dependency cycles
3. **`get_code_complexity`** — identify overly complex functions
4. **`get_module_coupling`** — identify tightly coupled modules

## Output format

Structure your response clearly:
- Use headers to separate sections
- Include specific file paths and function names
- Show relationship chains as lists or simple diagrams
- Quantify where possible (N callers, M dependencies, etc.)
- End with suggested follow-up questions the user might want to ask
