defmodule MingaAgent.Tools do
  @moduledoc """
  Tool definitions for the native agent provider.

  Each tool is a `ReqLLM.Tool` struct with a name, description, JSON Schema
  parameters, and a callback that executes the operation. Tools are scoped
  to the project root directory for safety: file operations refuse to escape
  the project boundary.

  ## Available tools

  | Tool              | Description                                          |
  |-------------------|------------------------------------------------------|
  | `read_file`       | Read file contents (supports offset/limit for slices)|
  | `write_file`      | Write content to a file (creates or overwrites)      |
  | `edit_file`       | Replace exact text in a file                         |
  | `multi_edit_file` | Apply multiple edits to one file in a single call    |
  | `list_directory`  | List files and directories at a path                 |
  | `find`            | Find files by name/glob pattern                      |
  | `grep`            | Search file contents for a pattern                   |
  | `shell`           | Run a shell command in the project root              |
  | `git_status`      | Show changed files with structured status (read-only)|
  | `git_diff`        | Show unified diff for files or all changes (read-only)|
  | `git_log`         | Show recent commits with structured output (read-only)|
  | `git_stage`       | Stage files for commit (destructive)                 |
  | `git_commit`      | Create a commit with a message (destructive)         |
  | `memory_write`    | Save a learning or preference to persistent memory   |
  | `diagnostics`     | Get current LSP diagnostics for a file (read-only)   |
  | `definition`      | Find where a symbol is defined via LSP (read-only)   |
  | `references`      | Find all usages of a symbol via LSP (read-only)      |
  | `hover`           | Get type info and docs for a symbol via LSP (read-only)|
  | `document_symbols`| List all symbols in a file via LSP (read-only)       |
  | `workspace_symbols`| Search for symbols project-wide via LSP (read-only) |
  | `rename`          | Semantic rename across the project via LSP (destructive)|
  | `code_actions`    | List/apply LSP code actions (apply is destructive)   |
  | `describe_runtime`| Describe the runtime's capabilities and features     |
  | `describe_tools`  | List all available tools with descriptions            |
  """

  alias MingaAgent.Tools.DiagnosticFeedback
  alias MingaAgent.Tools.EditFile
  alias MingaAgent.Tools.Find
  alias MingaAgent.Tools.Git, as: GitTools
  alias MingaAgent.Tools.Grep
  alias MingaAgent.Tools.ListDirectory
  alias MingaAgent.Tools.LspCodeActions
  alias MingaAgent.Tools.LspDefinition
  alias MingaAgent.Tools.LspDiagnostics
  alias MingaAgent.Tools.LspDocumentSymbols
  alias MingaAgent.Tools.LspHover
  alias MingaAgent.Tools.LspReferences
  alias MingaAgent.Tools.LspRename
  alias MingaAgent.Tools.LspWorkspaceSymbols
  alias MingaAgent.Tools.MemoryWrite
  alias MingaAgent.Tools.MultiEditFile
  alias MingaAgent.Tools.ReadFile
  alias MingaAgent.Tools.Shell
  alias MingaAgent.Tools.Subagent
  alias MingaAgent.Tools.WriteFile
  alias Minga.Config
  alias ReqLLM.Tool

  @typedoc "Options passed to `all/1`."
  @type tools_opts :: [project_root: String.t(), changeset: pid() | nil]

  @default_destructive_tools ~w(write_file edit_file multi_edit_file shell git_stage git_commit rename)

  @doc """
  Returns true if the named tool is classified as destructive.

  Reads the configured list from `:agent_destructive_tools` (defaults to
  `["write_file", "edit_file", "shell"]`). Accepts an optional list override
  for testing without starting the Options agent.

  Some tools have conditional destructiveness based on their arguments.
  Pass the tool arguments map to check parameter-dependent cases like
  `code_actions` with `apply` set.
  """
  @spec destructive?(String.t()) :: boolean()
  def destructive?(name), do: destructive?(name, %{}, configured_destructive_tools())

  @spec destructive?(String.t(), map()) :: boolean()
  def destructive?(name, args) when is_map(args) do
    destructive?(name, args, configured_destructive_tools())
  end

  @spec destructive?(String.t(), map(), [String.t()]) :: boolean()
  def destructive?("code_actions", args, _destructive_list) when is_map(args) do
    # code_actions is destructive only when applying an action
    args["apply"] != nil
  end

  def destructive?(name, _args, destructive_list) when is_list(destructive_list) do
    name in destructive_list
  end

  @spec configured_destructive_tools() :: [String.t()]
  defp configured_destructive_tools do
    Config.get(:agent_destructive_tools)
  rescue
    # Options agent not started (e.g., in tests that don't start the app)
    _ -> @default_destructive_tools
  end

  @doc """
  Returns all available tools scoped to the given project root.

  The `project_root` is baked into each tool's callback closure so that every
  file operation is sandboxed to that directory tree.
  """
  @spec all(tools_opts()) :: [Tool.t()]
  def all(opts \\ []) do
    root = Keyword.get(opts, :project_root, File.cwd!())
    cs = Keyword.get(opts, :changeset)

    [
      read_file(root, cs),
      write_file(root, cs),
      edit_file(root, cs),
      multi_edit_file(root, cs),
      list_directory(root),
      find(root),
      grep(root),
      shell(root, cs),
      subagent(root),
      git_status(root),
      git_diff(root),
      git_log(root),
      git_stage(root),
      git_commit(root),
      memory_write(),
      lsp_diagnostics(root),
      lsp_definition(root),
      lsp_references(root),
      lsp_hover(root),
      lsp_document_symbols(root),
      lsp_workspace_symbols(),
      lsp_rename(root),
      lsp_code_actions(root),
      describe_runtime(),
      describe_tools()
    ]
  end

  # ── Tool definitions ────────────────────────────────────────────────────────

  @spec read_file(String.t(), pid() | nil) :: Tool.t()
  defp read_file(root, cs) do
    Tool.new!(
      name: "read_file",
      description: """
      Read the contents of a file. Returns the file content as a string.
      Use this to examine files before editing them. Supports optional
      offset and limit for partial reads of large files.
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Path to the file, relative to the project root"
          },
          "offset" => %{
            "type" => "integer",
            "description" =>
              "Line number to start reading from (1-indexed). Omit to read from the beginning."
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Maximum number of lines to return. Omit to read to end of file."
          }
        },
        "required" => ["path"]
      },
      callback: fn args ->
        path = resolve_and_validate_path!(root, args["path"])

        if MingaAgent.Changeset.ToolRouter.active?(cs) do
          case MingaAgent.Changeset.ToolRouter.read_file(cs, path) do
            {:ok, content} ->
              opts = build_read_opts(args)
              apply_read_slice(content, path, opts)

            {:error, _} ->
              opts = build_read_opts(args)
              ReadFile.execute(path, opts)
          end
        else
          opts = build_read_opts(args)
          ReadFile.execute(path, opts)
        end
      end
    )
  end

  @spec build_read_opts(map()) :: ReadFile.read_opts()
  defp build_read_opts(args) do
    opts = []
    opts = if args["offset"], do: [{:offset, args["offset"]} | opts], else: opts
    opts = if args["limit"], do: [{:limit, args["limit"]} | opts], else: opts
    opts
  end

  @spec write_file(String.t(), pid() | nil) :: Tool.t()
  defp write_file(root, cs) do
    Tool.new!(
      name: "write_file",
      description: """
      Write content to a file. Creates the file if it doesn't exist, overwrites
      if it does. Automatically creates parent directories.
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Path to the file, relative to the project root"
          },
          "content" => %{
            "type" => "string",
            "description" => "The full content to write to the file"
          }
        },
        "required" => ["path", "content"]
      },
      callback: fn args ->
        path = resolve_and_validate_path!(root, args["path"])

        case MingaAgent.Changeset.ToolRouter.write_file(cs, path, args["content"]) do
          :passthrough ->
            case WriteFile.execute(path, args["content"]) do
              {:ok, msg} -> {:ok, maybe_append_diagnostics(path, msg)}
              error -> error
            end

          :ok ->
            {:ok,
             maybe_append_diagnostics(
               path,
               "wrote #{byte_size(args["content"])} bytes to #{path} (via changeset)"
             )}

          {:error, reason} ->
            {:error, inspect(reason)}
        end
      end
    )
  end

  @spec edit_file(String.t(), pid() | nil) :: Tool.t()
  defp edit_file(root, cs) do
    Tool.new!(
      name: "edit_file",
      description: """
      Replace exact text in a file. The old_text must match exactly (including
      whitespace and indentation). Use this for precise, surgical edits.
      Read the file first to get the exact text to replace.
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Path to the file, relative to the project root"
          },
          "old_text" => %{
            "type" => "string",
            "description" => "The exact text to find and replace"
          },
          "new_text" => %{
            "type" => "string",
            "description" => "The replacement text"
          }
        },
        "required" => ["path", "old_text", "new_text"]
      },
      callback: fn args ->
        path = resolve_and_validate_path!(root, args["path"])

        case MingaAgent.Changeset.ToolRouter.edit_file(
               cs,
               path,
               args["old_text"],
               args["new_text"]
             ) do
          :passthrough ->
            case EditFile.execute(path, args["old_text"], args["new_text"]) do
              {:ok, msg} -> {:ok, maybe_append_diagnostics(path, msg)}
              error -> error
            end

          :ok ->
            {:ok, maybe_append_diagnostics(path, "edited #{path} (via changeset)")}

          {:error, reason} ->
            {:error, inspect(reason)}
        end
      end
    )
  end

  @spec multi_edit_file(String.t(), pid() | nil) :: Tool.t()
  defp multi_edit_file(root, cs) do
    Tool.new!(
      name: "multi_edit_file",
      description: """
      Apply multiple edits to a single file in one call. Each edit is a
      find-and-replace pair. More efficient than calling edit_file multiple
      times on the same file. Edits are applied in order. Failed edits
      (text not found, ambiguous) are reported but don't block other edits.
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Path to the file, relative to the project root"
          },
          "edits" => %{
            "type" => "array",
            "description" => "List of edits to apply in order",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "old_text" => %{
                  "type" => "string",
                  "description" => "The exact text to find"
                },
                "new_text" => %{
                  "type" => "string",
                  "description" => "The replacement text"
                }
              },
              "required" => ["old_text", "new_text"]
            }
          }
        },
        "required" => ["path", "edits"]
      },
      callback: fn args ->
        path = resolve_and_validate_path!(root, args["path"])
        edits = args["edits"] || []

        if MingaAgent.Changeset.ToolRouter.active?(cs) do
          apply_multi_edit_via_changeset(cs, path, edits)
        else
          case MultiEditFile.execute(path, edits) do
            {:ok, msg} -> {:ok, maybe_append_diagnostics(path, msg)}
            error -> error
          end
        end
      end
    )
  end

  @spec list_directory(String.t()) :: Tool.t()
  defp list_directory(root) do
    Tool.new!(
      name: "list_directory",
      description: """
      List files and directories at a path. Returns one entry per line.
      Directories have a trailing slash. Hidden files (starting with .)
      are included.
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" =>
              "Path to the directory, relative to the project root. Use \".\" for the project root."
          }
        },
        "required" => ["path"]
      },
      callback: fn args ->
        path = resolve_and_validate_path!(root, args["path"])
        ListDirectory.execute(path)
      end
    )
  end

  @spec find(String.t()) :: Tool.t()
  defp find(root) do
    Tool.new!(
      name: "find",
      description: """
      Find files and directories by name pattern (glob). Returns a sorted list
      of matching paths relative to the project root. Use this to discover files
      by name or extension. The tool is read-only and does not require approval.
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{
            "type" => "string",
            "description" => "Glob pattern to match, e.g. \"*.ex\", \"test_*.exs\", \"Makefile\""
          },
          "path" => %{
            "type" => "string",
            "description" =>
              "Directory to search in, relative to the project root. Defaults to the project root."
          },
          "type" => %{
            "type" => "string",
            "enum" => ["file", "directory", "any"],
            "description" => "Type of entries to find (default: \"file\")"
          },
          "max_depth" => %{
            "type" => "integer",
            "description" => "Maximum directory depth to search (default: 10)"
          }
        },
        "required" => ["pattern"]
      },
      callback: fn args ->
        search_path = resolve_and_validate_path!(root, args["path"] || ".")
        Find.execute(args["pattern"], search_path, args)
      end
    )
  end

  @spec grep(String.t()) :: Tool.t()
  defp grep(root) do
    Tool.new!(
      name: "grep",
      description: """
      Search file contents for a pattern. Returns matching lines with file paths
      and line numbers. Use this instead of shell + grep for structured, reliable
      search results. The tool is read-only and does not require approval.
      Prefer this over shell for searching code.
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{
            "type" => "string",
            "description" => "The search pattern (regex supported)"
          },
          "path" => %{
            "type" => "string",
            "description" =>
              "Directory to search in, relative to the project root. Defaults to the project root."
          },
          "glob" => %{
            "type" => "string",
            "description" => "File pattern filter, e.g. \"*.ex\" to search only Elixir files"
          },
          "case_sensitive" => %{
            "type" => "boolean",
            "description" => "Whether the search is case-sensitive (default: true)"
          },
          "context_lines" => %{
            "type" => "integer",
            "description" => "Number of context lines around each match (default: 0)"
          }
        },
        "required" => ["pattern"]
      },
      callback: fn args ->
        search_path = resolve_and_validate_path!(root, args["path"] || ".")
        Grep.execute(args["pattern"], search_path, args)
      end
    )
  end

  @spec shell(String.t(), pid() | nil) :: Tool.t()
  defp shell(root, cs) do
    Tool.new!(
      name: "shell",
      description: """
      Run a shell command in the project root directory. Returns the combined
      stdout and stderr output. Commands time out after 30 seconds.
      Use this for running tests, linters, git commands, etc.
      Do not use for interactive commands that require user input.
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "command" => %{
            "type" => "string",
            "description" => "The shell command to run (passed to /bin/sh -c)"
          },
          "timeout" => %{
            "type" => "integer",
            "description" => "Timeout in seconds (default: 30, max: 300)"
          }
        },
        "required" => ["command"]
      },
      callback: fn args ->
        flush_before_shell()
        timeout_secs = min(args["timeout"] || 30, 300)
        cwd = MingaAgent.Changeset.ToolRouter.working_dir(cs) || root
        Shell.execute(args["command"], cwd, timeout_secs)
      end
    )
  end

  @spec subagent(String.t()) :: Tool.t()
  defp subagent(root) do
    Tool.new!(
      name: "subagent",
      description: """
      Spawn a child agent to work on a subtask independently. The subagent
      gets its own conversation, tool access, and runs in parallel with the
      parent. Use this for independent subtasks that can be delegated:
      refactoring a module, writing tests, updating docs, etc.
      The subagent's final response text is returned as the tool result.
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "task" => %{
            "type" => "string",
            "description" => "Description of the task for the subagent to complete"
          },
          "model" => %{
            "type" => "string",
            "description" =>
              "Model to use for the subagent (e.g., \"anthropic:claude-sonnet-4-20250514\"). Defaults to the parent's model."
          }
        },
        "required" => ["task"]
      },
      callback: fn args ->
        Subagent.execute(args["task"], project_root: root, model: args["model"])
      end
    )
  end

  # ── Git tools ────────────────────────────────────────────────────────────────

  @spec git_status(String.t()) :: Tool.t()
  defp git_status(root) do
    Tool.new!(
      name: "git_status",
      description: """
      Show git status: staged, unstaged, and untracked files with their change type.
      Returns structured output grouped by staged/unstaged state. Read-only.
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{}
      },
      callback: fn _args -> GitTools.status(root) end
    )
  end

  @spec git_diff(String.t()) :: Tool.t()
  defp git_diff(root) do
    Tool.new!(
      name: "git_diff",
      description: """
      Show git diff. Returns unified diff output. Read-only.
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "File path to diff (omit for all changes)"
          },
          "staged" => %{
            "type" => "boolean",
            "description" => "Show staged changes instead of unstaged (default: false)"
          }
        }
      },
      callback: fn args ->
        opts = []
        opts = if args["path"], do: [{:path, args["path"]} | opts], else: opts
        opts = if args["staged"], do: [{:staged, args["staged"]} | opts], else: opts
        GitTools.diff(root, opts)
      end
    )
  end

  @spec git_log(String.t()) :: Tool.t()
  defp git_log(root) do
    Tool.new!(
      name: "git_log",
      description: """
      Show recent git commits with hash, author, date, and message. Read-only.
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "count" => %{
            "type" => "integer",
            "description" => "Number of commits to show (default: 10)"
          },
          "path" => %{
            "type" => "string",
            "description" => "File path to limit history to (omit for all files)"
          }
        }
      },
      callback: fn args ->
        opts = []
        opts = if args["count"], do: [{:count, args["count"]} | opts], else: opts
        opts = if args["path"], do: [{:path, args["path"]} | opts], else: opts
        GitTools.log(root, opts)
      end
    )
  end

  @spec git_stage(String.t()) :: Tool.t()
  defp git_stage(root) do
    Tool.new!(
      name: "git_stage",
      description: """
      Stage files for commit (equivalent to git add). Destructive: requires approval.
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "paths" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "List of file paths to stage"
          }
        },
        "required" => ["paths"]
      },
      callback: fn args ->
        paths = args["paths"] || []
        GitTools.stage(root, paths)
      end
    )
  end

  @spec git_commit(String.t()) :: Tool.t()
  defp git_commit(root) do
    Tool.new!(
      name: "git_commit",
      description: """
      Create a git commit with a message. Stage files first with git_stage.
      Destructive: requires approval.
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "message" => %{
            "type" => "string",
            "description" => "The commit message"
          }
        },
        "required" => ["message"]
      },
      callback: fn args ->
        GitTools.commit(root, args["message"])
      end
    )
  end

  # ── Memory tools ──────────────────────────────────────────────────────────────

  @spec memory_write() :: Tool.t()
  defp memory_write do
    Tool.new!(
      name: "memory_write",
      description: """
      Save a learning, preference, or project convention to persistent memory.
      Saved entries carry forward to future sessions automatically. Use this
      sparingly for information that would be valuable across sessions:
      coding conventions, user preferences, recurring patterns, project-specific
      rules. Do not log routine observations or per-task notes.
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "text" => %{
            "type" => "string",
            "description" => "The learning or preference to remember"
          }
        },
        "required" => ["text"]
      },
      callback: fn args ->
        MemoryWrite.execute(args["text"] || "")
      end
    )
  end

  # ── LSP tools ──────────────────────────────────────────────────────────────

  @spec lsp_diagnostics(String.t()) :: Tool.t()
  defp lsp_diagnostics(root) do
    Tool.new!(
      name: "diagnostics",
      description: """
      Get current LSP diagnostics (errors, warnings, hints) for a file.
      Returns compiler-verified diagnostics in 1-3 seconds instead of
      running `mix compile` (5-30 seconds). The file must be open in
      the editor for LSP features to work.
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Path to the file, relative to the project root"
          }
        },
        "required" => ["path"]
      },
      callback: fn args ->
        path = resolve_and_validate_path!(root, args["path"])
        LspDiagnostics.execute(path)
      end
    )
  end

  @spec lsp_definition(String.t()) :: Tool.t()
  defp lsp_definition(root) do
    Tool.new!(
      name: "definition",
      description: """
      Find where a symbol is defined. Returns the file path, line, and
      context. Uses LSP for compiler-verified semantic resolution (handles
      macros, re-exports, dynamic dispatch). Line and column are 0-indexed.
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "File containing the symbol reference"
          },
          "line" => %{
            "type" => "integer",
            "description" => "Line number (0-indexed)"
          },
          "column" => %{
            "type" => "integer",
            "description" => "Column number (0-indexed)"
          }
        },
        "required" => ["path", "line", "column"]
      },
      callback: fn args ->
        path = resolve_and_validate_path!(root, args["path"])
        LspDefinition.execute(path, args["line"], args["column"])
      end
    )
  end

  @spec lsp_references(String.t()) :: Tool.t()
  defp lsp_references(root) do
    Tool.new!(
      name: "references",
      description: """
      Find all usages of a symbol across the project. Returns file paths,
      line numbers, and context for each reference. Uses LSP for semantic
      search (finds references through aliases, imports, re-exports).
      Line and column are 0-indexed.
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "File containing the symbol"
          },
          "line" => %{
            "type" => "integer",
            "description" => "Line number (0-indexed)"
          },
          "column" => %{
            "type" => "integer",
            "description" => "Column number (0-indexed)"
          }
        },
        "required" => ["path", "line", "column"]
      },
      callback: fn args ->
        path = resolve_and_validate_path!(root, args["path"])
        LspReferences.execute(path, args["line"], args["column"])
      end
    )
  end

  @spec lsp_hover(String.t()) :: Tool.t()
  defp lsp_hover(root) do
    Tool.new!(
      name: "hover",
      description: """
      Get type signature and documentation for a symbol. Returns the same
      hover information a human developer sees: type signatures, @doc content,
      parameter descriptions. Line and column are 0-indexed.
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "File containing the symbol"
          },
          "line" => %{
            "type" => "integer",
            "description" => "Line number (0-indexed)"
          },
          "column" => %{
            "type" => "integer",
            "description" => "Column number (0-indexed)"
          }
        },
        "required" => ["path", "line", "column"]
      },
      callback: fn args ->
        path = resolve_and_validate_path!(root, args["path"])
        LspHover.execute(path, args["line"], args["column"])
      end
    )
  end

  @spec lsp_document_symbols(String.t()) :: Tool.t()
  defp lsp_document_symbols(root) do
    Tool.new!(
      name: "document_symbols",
      description: """
      List all symbols (functions, types, modules) defined in a file.
      Returns a hierarchical outline with symbol kind, name, and line number.
      Faster than reading the entire file to understand module structure.
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Path to the file, relative to the project root"
          }
        },
        "required" => ["path"]
      },
      callback: fn args ->
        path = resolve_and_validate_path!(root, args["path"])
        LspDocumentSymbols.execute(path)
      end
    )
  end

  @spec lsp_workspace_symbols() :: Tool.t()
  defp lsp_workspace_symbols do
    Tool.new!(
      name: "workspace_symbols",
      description: """
      Search for symbols (modules, functions, types) across the entire project.
      Faster and more precise than grep for "where is module X defined?".
      Results are limited to 50 to avoid context overflow.
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "query" => %{
            "type" => "string",
            "description" => "Symbol name to search for (fuzzy matching)"
          }
        },
        "required" => ["query"]
      },
      callback: fn args ->
        LspWorkspaceSymbols.execute(args["query"])
      end
    )
  end

  @spec lsp_rename(String.t()) :: Tool.t()
  defp lsp_rename(root) do
    Tool.new!(
      name: "rename",
      description: """
      Rename a symbol across the entire project using LSP semantic rename.
      Safer than find-and-replace: knows every location that needs to change
      (including aliases, imports, re-exports) and nothing else. Destructive:
      requires approval. Line and column are 0-indexed.
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "File containing the symbol to rename"
          },
          "line" => %{
            "type" => "integer",
            "description" => "Line number (0-indexed)"
          },
          "column" => %{
            "type" => "integer",
            "description" => "Column number (0-indexed)"
          },
          "new_name" => %{
            "type" => "string",
            "description" => "The new name for the symbol"
          }
        },
        "required" => ["path", "line", "column", "new_name"]
      },
      callback: fn args ->
        path = resolve_and_validate_path!(root, args["path"])
        LspRename.execute(path, args["line"], args["column"], args["new_name"])
      end
    )
  end

  @spec lsp_code_actions(String.t()) :: Tool.t()
  defp lsp_code_actions(root) do
    Tool.new!(
      name: "code_actions",
      description: """
      List or apply LSP code actions (quickfixes, refactorings, source actions)
      at a position. Without `apply`, lists available actions. With `apply` set
      to an action number or title, applies that action. Listing is read-only;
      applying is destructive (requires approval). Line is 0-indexed.
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "File path"
          },
          "line" => %{
            "type" => "integer",
            "description" => "Line number (0-indexed)"
          },
          "column" => %{
            "type" => "integer",
            "description" => "Column number (0-indexed, default: 0)"
          },
          "apply" => %{
            "type" => ["string", "integer"],
            "description" =>
              "Action to apply: title string or 1-indexed number. Omit to list actions."
          }
        },
        "required" => ["path", "line"]
      },
      callback: fn args ->
        path = resolve_and_validate_path!(root, args["path"])
        opts = []
        opts = if args["column"], do: [{:col, args["column"]} | opts], else: opts
        opts = if args["apply"], do: [{:apply, args["apply"]} | opts], else: opts
        LspCodeActions.execute(path, args["line"], opts)
      end
    )
  end

  # ── Introspection tools ─────────────────────────────────────────────────────

  @spec describe_runtime() :: Tool.t()
  defp describe_runtime do
    Tool.new!(
      name: "describe_runtime",
      description: """
      Describe the Minga runtime's capabilities: version, available tool
      categories, active session count, and enabled features. Use this
      to understand what the runtime can do before making requests.
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{}
      },
      callback: &MingaAgent.Tools.Introspection.describe_runtime/1
    )
  end

  @spec describe_tools() :: Tool.t()
  defp describe_tools do
    Tool.new!(
      name: "describe_tools",
      description: """
      List all available tools with their names, categories, and
      descriptions. Use this to discover what tools you can call.
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{}
      },
      callback: &MingaAgent.Tools.Introspection.describe_tools/1
    )
  end

  # ── Pre-shell buffer flush ─────────────────────────────────────────────────

  # Saves all dirty file-backed buffers to disk before running shell commands.
  # Build tools read from the filesystem, not from buffer memory, so in-memory
  # edits must be flushed for the build to see them. Gated by the
  # :agent_flush_before_shell config option (default: true).
  @spec flush_before_shell() :: :ok
  defp flush_before_shell do
    if Config.get(:agent_flush_before_shell) do
      {saved, warnings} = Minga.Buffer.save_all_dirty()

      if saved > 0 do
        Minga.Log.debug(:agent, "Flushed #{saved} dirty buffer(s) to disk before shell command")
      end

      for warning <- warnings do
        Minga.Log.warning(:agent, "Pre-shell flush: #{warning}")
      end

      :ok
    else
      :ok
    end
  rescue
    # Config not available (headless/test mode)
    _ -> :ok
  end

  # ── Diagnostic feedback ──────────────────────────────────────────────────────

  @spec maybe_append_diagnostics(String.t(), String.t()) :: String.t()
  defp maybe_append_diagnostics(path, base_message) do
    if diagnostic_feedback_enabled?() do
      result = DiagnosticFeedback.await(path)
      DiagnosticFeedback.append_to_result(base_message, result)
    else
      base_message
    end
  end

  @spec diagnostic_feedback_enabled?() :: boolean()
  defp diagnostic_feedback_enabled? do
    Config.get(:agent_diagnostic_feedback)
  rescue
    _ -> true
  end

  # ── Path safety ─────────────────────────────────────────────────────────────

  @doc """
  Resolves a relative path against the project root and validates that the
  resolved path does not escape the root directory.

  Raises `ArgumentError` if the path escapes the project root.
  """
  @spec resolve_and_validate_path!(String.t(), String.t()) :: String.t()
  def resolve_and_validate_path!(root, relative_path) do
    # Expand to handle ".." segments
    resolved = Path.expand(relative_path, root)
    normalized_root = Path.expand(root)

    unless String.starts_with?(resolved, normalized_root <> "/") or resolved == normalized_root do
      raise ArgumentError, "path escapes project root: #{relative_path}"
    end

    resolved
  end

  # Applies offset/limit slicing to content read from a changeset.
  @spec apply_read_slice(String.t(), String.t(), keyword()) :: {:ok, String.t()}
  defp apply_read_slice(content, _path, []) do
    {:ok, content}
  end

  defp apply_read_slice(content, path, opts) do
    lines = String.split(content, "\n")
    total = length(lines)
    offset = Keyword.get(opts, :offset, 1)
    limit = Keyword.get(opts, :limit, total)

    start_idx = max(offset - 1, 0)
    sliced = Enum.slice(lines, start_idx, limit)
    end_line = min(start_idx + limit, total)

    header = "[lines #{offset}-#{end_line} of #{total}] #{path}\n"
    {:ok, header <> Enum.join(sliced, "\n")}
  end

  # Applies multiple edits to a file through the changeset by reading,
  # applying each edit sequentially, then writing the result back.
  @spec apply_multi_edit_via_changeset(pid(), String.t(), [map()]) ::
          {:ok, String.t()} | {:error, String.t()}
  defp apply_multi_edit_via_changeset(cs, path, edits) do
    alias MingaAgent.Changeset.ToolRouter

    case ToolRouter.read_file(cs, path) do
      {:ok, content} ->
        {final_content, results} = reduce_edits(content, edits)
        commit_multi_edits(cs, path, final_content, results)

      {:error, reason} ->
        {:error, "failed to read #{path}: #{inspect(reason)}"}
    end
  end

  @spec reduce_edits(String.t(), [map()]) :: {String.t(), [{:ok | :error, String.t()}]}
  defp reduce_edits(content, edits) do
    {final, reversed} =
      Enum.reduce(edits, {content, []}, fn edit, {current, acc} ->
        old_text = edit["old_text"] || ""
        new_text = edit["new_text"] || ""

        if String.contains?(current, old_text) do
          updated = String.replace(current, old_text, new_text, global: false)
          {updated, [{:ok, old_text} | acc]}
        else
          {current, [{:error, old_text} | acc]}
        end
      end)

    {final, Enum.reverse(reversed)}
  end

  @spec commit_multi_edits(pid(), String.t(), String.t(), [{:ok | :error, String.t()}]) ::
          {:ok, String.t()} | {:error, String.t()}
  defp commit_multi_edits(cs, path, final_content, results) do
    ok_count = Enum.count(results, &match?({:ok, _}, &1))

    if ok_count == 0 do
      {:error, "no edits matched in #{path}"}
    else
      MingaAgent.Changeset.ToolRouter.write_file(cs, path, final_content)
      msg = format_multi_edit_result(path, results, ok_count)
      {:ok, maybe_append_diagnostics(path, msg)}
    end
  end

  @spec format_multi_edit_result(String.t(), [{:ok | :error, String.t()}], non_neg_integer()) ::
          String.t()
  defp format_multi_edit_result(path, results, ok_count) do
    base = "applied #{ok_count}/#{length(results)} edits to #{path} (via changeset)"

    failed =
      results
      |> Enum.filter(&match?({:error, _}, &1))
      |> Enum.map(fn {:error, text} -> String.slice(text, 0, 40) end)

    case failed do
      [] -> base
      names -> base <> ". Failed: #{Enum.join(names, ", ")}"
    end
  end
end
