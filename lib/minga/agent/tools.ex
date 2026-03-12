defmodule Minga.Agent.Tools do
  @moduledoc """
  Tool definitions for the native agent provider.

  Each tool is a `ReqLLM.Tool` struct with a name, description, JSON Schema
  parameters, and a callback that executes the operation. Tools are scoped
  to the project root directory for safety: file operations refuse to escape
  the project boundary.

  ## Available tools

  | Tool             | Description                                     |
  |------------------|-------------------------------------------------|
  | `read_file`      | Read the contents of a file                     |
  | `write_file`     | Write content to a file (creates or overwrites) |
  | `edit_file`      | Replace exact text in a file                    |
  | `list_directory` | List files and directories at a path            |
  | `shell`          | Run a shell command in the project root         |
  """

  alias Minga.Agent.Tools.EditFile
  alias Minga.Agent.Tools.Grep
  alias Minga.Agent.Tools.ListDirectory
  alias Minga.Agent.Tools.ReadFile
  alias Minga.Agent.Tools.Shell
  alias Minga.Agent.Tools.WriteFile
  alias Minga.Config.Options
  alias ReqLLM.Tool

  @typedoc "Options passed to `all/1`."
  @type tools_opts :: [project_root: String.t()]

  @default_destructive_tools ~w(write_file edit_file shell)

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
      list_directory(root),
      grep(root),
      shell(root)
    ]
  end

  # ── Tool definitions ────────────────────────────────────────────────────────

  @spec read_file(String.t()) :: Tool.t()
  defp read_file(root) do
    Tool.new!(
      name: "read_file",
      description: """
      Read the contents of a file. Returns the file content as a string.
      Use this to examine files before editing them.
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
        ReadFile.execute(path)
      end
    )
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
