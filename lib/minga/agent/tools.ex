defmodule Minga.Agent.Tools do
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
  """

  alias Minga.Agent.Tools.EditFile
  alias Minga.Agent.Tools.Find
  alias Minga.Agent.Tools.Grep
  alias Minga.Agent.Tools.ListDirectory
  alias Minga.Agent.Tools.MultiEditFile
  alias Minga.Agent.Tools.ReadFile
  alias Minga.Agent.Tools.Shell
  alias Minga.Agent.Tools.Subagent
  alias Minga.Agent.Tools.WriteFile
  alias Minga.Config.Options
  alias ReqLLM.Tool

  @typedoc "Options passed to `all/1`."
  @type tools_opts :: [project_root: String.t()]

  @default_destructive_tools ~w(write_file edit_file multi_edit_file shell)

  @doc """
  Returns true if the named tool is classified as destructive.

  Reads the configured list from `:agent_destructive_tools` (defaults to
  `["write_file", "edit_file", "shell"]`). Accepts an optional list override
  for testing without starting the Options agent.
  """
  @spec destructive?(String.t()) :: boolean()
  def destructive?(name), do: destructive?(name, configured_destructive_tools())

  @spec destructive?(String.t(), [String.t()]) :: boolean()
  def destructive?(name, destructive_list) when is_list(destructive_list) do
    name in destructive_list
  end

  @spec configured_destructive_tools() :: [String.t()]
  defp configured_destructive_tools do
    Options.get(:agent_destructive_tools)
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

    [
      read_file(root),
      write_file(root),
      edit_file(root),
      multi_edit_file(root),
      list_directory(root),
      find(root),
      grep(root),
      shell(root),
      subagent(root)
    ]
  end

  # ── Tool definitions ────────────────────────────────────────────────────────

  @spec read_file(String.t()) :: Tool.t()
  defp read_file(root) do
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
        opts = build_read_opts(args)
        ReadFile.execute(path, opts)
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

  @spec write_file(String.t()) :: Tool.t()
  defp write_file(root) do
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
        WriteFile.execute(path, args["content"])
      end
    )
  end

  @spec edit_file(String.t()) :: Tool.t()
  defp edit_file(root) do
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
        EditFile.execute(path, args["old_text"], args["new_text"])
      end
    )
  end

  @spec multi_edit_file(String.t()) :: Tool.t()
  defp multi_edit_file(root) do
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
        MultiEditFile.execute(path, edits)
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

  @spec shell(String.t()) :: Tool.t()
  defp shell(root) do
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
        timeout_secs = min(args["timeout"] || 30, 300)
        Shell.execute(args["command"], root, timeout_secs)
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
end
