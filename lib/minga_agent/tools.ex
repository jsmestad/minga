defmodule MingaAgent.Tools do
  @moduledoc """
  Tool definitions for the native agent provider.

  Each tool is declared once as a `MingaAgent.Tool.Spec` with a name, description,
  JSON Schema parameters, and a context-bound callback factory. Tools are scoped
  to the project root directory for safety: file operations refuse to escape
  the project boundary.

  ## Available tools

  | Tool              | Description                                          |
  |-------------------|------------------------------------------------------|
  | `read_file`       | Read file contents (supports offset/limit for slices)|
  | `write_file`      | Write content to a file (creates or overwrites)      |
  | `edit_file`       | Replace exact text in a file                         |
  | `multi_edit_file` | Apply multiple edits to one file in a single call    |
  | `apply_diff`      | Apply a unified diff to one file                     |
  | `delete_file`     | Delete a file                                        |
  | `list_directory`  | List files and directories at a path                 |
  | `find`            | Find files by name/glob pattern                      |
  | `grep`            | Search file contents for a pattern                   |
  | `fetch_url`       | Fetch a URL and return readable text content         |
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

  alias Minga.Buffer.Document
  alias Minga.Buffer.Replace
  alias MingaAgent.ProjectView
  alias MingaAgent.Tool.Spec
  alias MingaAgent.ToolRouter
  alias MingaAgent.Tools.DeleteFile
  alias MingaAgent.Tools.DirectoryListing
  alias MingaAgent.Tools.ApplyDiff
  alias MingaAgent.Tools.DiagnosticFeedback
  alias MingaAgent.Tools.EditFile
  alias MingaAgent.Tools.FetchUrl
  alias MingaAgent.Tools.Git, as: GitTools
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
  alias MingaAgent.Tools.ProcessBackend.System, as: SystemProcessBackend
  alias MingaAgent.Tools.Subagent
  alias MingaAgent.Tools.WriteFile
  alias Minga.Config

  @typedoc "Options passed to `all/1`."
  @type tools_opts :: [
          project_root: String.t(),
          project_view: ProjectView.t() | nil,
          changeset: pid() | nil,
          fork_store: pid() | nil,
          parent_session: GenServer.server() | nil,
          shell_output_callback: (String.t() -> :ok) | nil,
          process_backend: module()
        ]

  @default_destructive_tools ~w(write_file edit_file multi_edit_file apply_diff delete_file shell git_stage git_commit rename)
  @file_read_tools ~w(read_file list_directory find grep)
  @read_only_tools ~w(read_file list_directory find grep fetch_url git_status git_diff git_log diagnostics definition references hover document_symbols workspace_symbols describe_runtime describe_tools produce_rewrite)
  @max_symlink_depth 40

  @doc """
  Returns true if the named tool is classified as destructive.

  Reads the configured list from `:agent_destructive_tools`. Accepts an
  optional list override for testing without starting the Options agent.

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

  def destructive?("list_mcp_tools", _args, _destructive_list), do: true
  def destructive?("call_mcp_tool", _args, _destructive_list), do: true
  def destructive?("mcp_" <> _rest, _args, _destructive_list), do: true

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

  @doc "Returns every canonical built-in and bundled tool declaration."
  @spec specs() :: [Spec.t()]
  def specs do
    [
      read_file(),
      write_file(),
      edit_file(),
      multi_edit_file(),
      apply_diff(),
      delete_file(),
      list_directory(),
      find(),
      grep(),
      fetch_url(),
      shell(),
      subagent(),
      git_status(),
      git_diff(),
      git_log(),
      git_stage(),
      git_commit(),
      memory_write(),
      lsp_diagnostics(),
      lsp_definition(),
      lsp_references(),
      lsp_hover(),
      lsp_document_symbols(),
      lsp_workspace_symbols(),
      lsp_rename(),
      lsp_code_actions(),
      describe_runtime(),
      describe_tools()
    ]
  end

  @doc "Returns every canonical tool declaration. Options are accepted for source compatibility."
  @spec all(tools_opts()) :: [Spec.t()]
  def all(_opts \\ []), do: specs()

  @doc "Returns source-owned built-in tool declarations."
  @spec builtin_specs() :: [Spec.t()]
  def builtin_specs, do: Enum.filter(specs(), &(&1.source == :builtin))

  @doc "Returns all core built-in tool names."
  @spec builtin_names() :: [String.t()]
  def builtin_names, do: Enum.map(builtin_specs(), & &1.name)

  @doc "Returns the read-only tool declaration subset for ephemeral inline ask sessions."
  @spec read_only(tools_opts()) :: [Spec.t()]
  def read_only(_opts \\ []), do: Enum.filter(specs(), &read_only_name?/1)

  @doc "Returns the file/project read declaration subset for constrained rewrite sessions."
  @spec file_read(tools_opts()) :: [Spec.t()]
  def file_read(_opts \\ []), do: Enum.filter(specs(), &file_read_name?/1)

  @doc "Returns true when the tool name is allowed in constrained file-read sessions."
  @spec file_read_name?(Spec.t() | %{required(:name) => String.t()} | String.t()) :: boolean()
  def file_read_name?(%{name: name}), do: file_read_name?(name)
  def file_read_name?(name) when is_binary(name), do: name in @file_read_tools

  @doc "Returns true when the tool name is allowed in read-only sessions."
  @spec read_only_name?(Spec.t() | %{required(:name) => String.t()} | String.t()) :: boolean()
  def read_only_name?(%{name: name}), do: read_only_name?(name)
  def read_only_name?(name) when is_binary(name), do: name in @read_only_tools

  # ── Tool definitions ────────────────────────────────────────────────────────

  @spec read_file() :: Spec.t()
  defp read_file do
    Spec.new!(
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
      source: :builtin,
      category: :filesystem,
      approval_level: :auto,
      capabilities: [:read_project],
      context_requirements: [:tool_context],
      build: fn context ->
        root = context.project_root
        router_ctx = context.router_context

        fn args ->
          path = resolve_and_validate_path!(root, args["path"])

          case ToolRouter.read_file(router_ctx, path) do
            {:ok, content} ->
              opts = build_read_opts(args)
              routed_result(router_ctx, apply_read_slice(content, path, opts))

            {:error, reason} ->
              read_file_fallback(router_ctx, path, reason, args)
          end
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

  @spec fetch_url() :: Spec.t()
  defp fetch_url do
    Spec.new!(
      name: "fetch_url",
      description: """
      Fetch a URL and return readable text content. HTML pages are converted to structured text with headings, lists, paragraphs, and code blocks preserved. Non-HTML text responses such as JSON, plain text, and XML are returned as-is. This is read-only and does not require approval.
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "url" => %{
            "type" => "string",
            "description" => "HTTP or HTTPS URL to fetch"
          },
          "timeout_ms" => %{
            "type" => "integer",
            "description" =>
              "Request timeout in milliseconds. Defaults to 10000 and is capped at 30000."
          },
          "max_bytes" => %{
            "type" => "integer",
            "description" => "Maximum bytes of extracted text to return. Defaults to 100000."
          }
        },
        "required" => ["url"]
      },
      source: {:bundle, :read_only_tools},
      category: :network,
      approval_level: :auto,
      capabilities: [:network],
      context_requirements: [],
      metadata: %{pack: :read_only_tools},
      build: fn _context ->
        &FetchUrl.execute/1
      end
    )
  end

  @spec write_file() :: Spec.t()
  defp write_file do
    Spec.new!(
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
      source: :builtin,
      category: :filesystem,
      approval_level: :ask,
      capabilities: [:mutate_project],
      context_requirements: [:tool_context],
      build: fn context ->
        root = context.project_root
        router_ctx = context.router_context

        fn args ->
          path = resolve_and_validate_path!(root, args["path"])

          case ToolRouter.write_file(router_ctx, path, args["content"]) do
            :passthrough ->
              case WriteFile.execute(path, args["content"]) do
                {:ok, msg} -> {:ok, maybe_append_diagnostics(path, msg)}
                error -> error
              end

            :ok ->
              {:ok,
               maybe_append_diagnostics(
                 path,
                 append_workspace_context(
                   router_ctx,
                   "wrote #{byte_size(args["content"])} bytes to #{path} (via #{route_name(router_ctx)})"
                 )
               )}

            {:error, reason} ->
              {:error, inspect(reason)}
          end
        end
      end
    )
  end

  @spec edit_file() :: Spec.t()
  defp edit_file do
    Spec.new!(
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
      source: :builtin,
      category: :filesystem,
      approval_level: :ask,
      capabilities: [:mutate_project],
      context_requirements: [:tool_context],
      build: fn context ->
        root = context.project_root
        router_ctx = context.router_context

        fn args ->
          path = resolve_and_validate_path!(root, args["path"])

          case ToolRouter.edit_file(
                 router_ctx,
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
              {:ok,
               maybe_append_diagnostics(
                 path,
                 append_workspace_context(
                   router_ctx,
                   "edited #{path} (via #{route_name(router_ctx)})"
                 )
               )}

            {:error, reason} ->
              {:error, inspect(reason)}
          end
        end
      end
    )
  end

  @spec multi_edit_file() :: Spec.t()
  defp multi_edit_file do
    Spec.new!(
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
      source: :builtin,
      category: :filesystem,
      approval_level: :ask,
      capabilities: [:mutate_project],
      context_requirements: [:tool_context],
      build: fn context ->
        root = context.project_root
        router_ctx = context.router_context

        fn args ->
          path = resolve_and_validate_path!(root, args["path"])
          edits = args["edits"] || []

          if ToolRouter.routing_configured?(router_ctx) do
            apply_multi_edit_via_router(router_ctx, path, edits)
          else
            case MultiEditFile.execute(path, edits) do
              {:ok, msg} -> {:ok, maybe_append_diagnostics(path, msg)}
              error -> error
            end
          end
        end
      end
    )
  end

  @spec apply_diff() :: Spec.t()
  defp apply_diff do
    Spec.new!(
      name: "apply_diff",
      description: """
      Apply a unified diff to a single file. The diff must use standard
      unified diff hunks (`@@ -start,count +start,count @@`) with context
      lines. Context is validated against the current file content, with a
      small fuzz window for hunks whose line numbers drifted by a few lines.
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Path to the file, relative to the project root"
          },
          "diff" => %{
            "type" => "string",
            "description" => "Unified diff content to apply to the file"
          }
        },
        "required" => ["path", "diff"]
      },
      source: :builtin,
      category: :filesystem,
      approval_level: :ask,
      capabilities: [:mutate_project],
      context_requirements: [:tool_context],
      build: fn context ->
        root = context.project_root
        router_ctx = context.router_context

        fn args ->
          path = resolve_and_validate_path!(root, args["path"])
          diff = args["diff"] || ""

          if ToolRouter.routing_configured?(router_ctx) do
            apply_diff_via_router(router_ctx, path, diff)
          else
            case ApplyDiff.execute(path, diff) do
              {:ok, msg} -> {:ok, maybe_append_diagnostics(path, msg)}
              error -> error
            end
          end
        end
      end
    )
  end

  @spec delete_file() :: Spec.t()
  defp delete_file do
    Spec.new!(
      name: "delete_file",
      description: """
      Delete a file from the project. Destructive: requires approval.
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
      source: :builtin,
      category: :filesystem,
      approval_level: :ask,
      capabilities: [:mutate_project],
      context_requirements: [:tool_context],
      build: fn context ->
        root = context.project_root
        router_ctx = context.router_context

        fn args ->
          path = resolve_and_validate_path!(root, args["path"])

          case ToolRouter.delete_file(router_ctx, path) do
            :passthrough ->
              DeleteFile.execute(path)

            :ok ->
              {:ok,
               append_workspace_context(
                 router_ctx,
                 "deleted #{path} (via #{route_name(router_ctx)})"
               )}

            {:error, reason} ->
              {:error, inspect(reason)}
          end
        end
      end
    )
  end

  @spec list_directory() :: Spec.t()
  defp list_directory do
    Spec.new!(
      name: "list_directory",
      description: """
      List files and directories at a known-small path. Returns at most 200 entries, one per line. Directories have a trailing slash. Generated, dependency, build, cache, and secret env files are omitted. Use find for broad file discovery instead of walking directories.
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
      source: {:bundle, :read_only_tools},
      category: :filesystem,
      approval_level: :auto,
      capabilities: [:read_project],
      context_requirements: [:tool_context],
      metadata: %{pack: :read_only_tools},
      build: fn context ->
        root = context.project_root
        router_ctx = context.router_context

        fn args ->
          path = resolve_and_validate_path!(root, args["path"])

          case ToolRouter.list_directory(router_ctx, path) do
            :passthrough ->
              ListDirectory.execute(path)

            {:ok, entries} ->
              {:ok,
               append_workspace_context(router_ctx, format_project_view_entries(path, entries))}

            {:error, reason} ->
              {:error, inspect(reason)}
          end
        end
      end
    )
  end

  @spec find() :: Spec.t()
  defp find do
    Spec.new!(
      name: "find",
      description: """
      Find files and directories by name pattern (glob). Returns at most 200
      sorted matching paths relative to the project root. Generated, dependency,
      build, cache, and secret env paths are omitted. Use this for broad file
      discovery instead of shell + find.
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
      source: {:bundle, :read_only_tools},
      category: :filesystem,
      approval_level: :auto,
      capabilities: [:read_project],
      context_requirements: [:tool_context],
      metadata: %{pack: :read_only_tools},
      build: fn context ->
        root = context.project_root
        router_ctx = context.router_context
        process_backend = Map.get(context.metadata, :process_backend, SystemProcessBackend)

        fn args ->
          path = resolve_and_validate_path!(root, args["path"] || ".")

          case ToolRouter.search_context(router_ctx, path) do
            {:ok, search} ->
              public_args = Map.take(args, ["type", "max_depth"])

              routed_result(
                router_ctx,
                process_backend.find(args["pattern"], search.exec_path, public_args,
                  filter_root: search.filter_root
                )
              )

            {:error, reason} ->
              {:error, inspect(reason)}
          end
        end
      end
    )
  end

  @spec grep() :: Spec.t()
  defp grep do
    Spec.new!(
      name: "grep",
      description: """
      Search file contents for a pattern. Returns at most 100 matching lines with
      file paths and line numbers. Generated, dependency, build, cache, and secret
      env paths are omitted. Use this instead of shell + grep for structured,
      bounded search results.
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
      source: {:bundle, :read_only_tools},
      category: :filesystem,
      approval_level: :auto,
      capabilities: [:read_project],
      context_requirements: [:tool_context],
      metadata: %{pack: :read_only_tools},
      build: fn context ->
        root = context.project_root
        router_ctx = context.router_context
        process_backend = Map.get(context.metadata, :process_backend, SystemProcessBackend)

        fn args ->
          path = resolve_and_validate_path!(root, args["path"] || ".")

          case ToolRouter.search_context(router_ctx, path) do
            {:ok, search} ->
              public_args = Map.take(args, ["glob", "case_sensitive", "context_lines"])

              routed_result(
                router_ctx,
                process_backend.grep(args["pattern"], search.exec_path, public_args,
                  filter_root: search.filter_root
                )
              )

            {:error, reason} ->
              {:error, inspect(reason)}
          end
        end
      end
    )
  end

  @spec shell() :: Spec.t()
  defp shell do
    Spec.new!(
      name: "shell",
      description: """
      Run a shell command in the project root directory. Returns the combined
      stdout and stderr output, capped at 64KB for the model. Commands time out
      after 30 seconds. Use this for running tests, linters, git commands, etc.
      Use find and grep for broad file discovery and content search.
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
      source: :builtin,
      category: :shell,
      approval_level: :ask,
      capabilities: [:run_shell],
      context_requirements: [:tool_context],
      build: fn context ->
        root = context.project_root
        router_ctx = context.router_context
        shell_output_callback = Map.get(context.metadata, :shell_output_callback)
        process_backend = Map.get(context.metadata, :process_backend, SystemProcessBackend)

        fn args ->
          timeout_secs = normalize_shell_timeout(args["timeout"])

          run_shell_with_timeout(timeout_secs, fn ->
            with {:ok, cwd} <- ToolRouter.working_dir_result(router_ctx),
                 {:ok, env} <- ToolRouter.command_env_result(router_ctx) do
              shell_root = cwd || root

              if is_nil(cwd) do
                flush_before_shell()
              end

              routed_result(
                router_ctx,
                process_backend.shell(args["command"], shell_root, timeout_secs,
                  env: env,
                  on_output: shell_output_callback
                )
              )
            else
              {:error, reason} -> {:error, inspect(reason)}
            end
          end)
        end
      end
    )
  end

  @spec subagent() :: Spec.t()
  defp subagent do
    Spec.new!(
      name: "subagent",
      description: """
      Spawn a child agent to work on a subtask. By default this is foreground:
      the parent waits and receives the child agent's final response text.
      Pass background: true for long-running independent work. Background mode
      returns immediately with a stable session handle, keeps the child chat
      available, and reports completion or failure through normal agent notifications.
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
          },
          "provider" => %{
            "type" => "string",
            "enum" => ["native", "pi_rpc"],
            "description" =>
              "Provider to use for the subagent. Defaults to the parent's provider; explicit overrides are shown in the subagent's first system message."
          },
          "background" => %{
            "type" => "boolean",
            "description" =>
              "When true, return immediately with a stable child session handle instead of waiting for the final response. Defaults to false."
          },
          "isolation" => %{
            "type" => "string",
            "enum" => ["worktree"],
            "description" =>
              "When set to worktree, run the foreground child in a fresh git worktree and preserve it only if the child changes it."
          }
        },
        "required" => ["task"]
      },
      source: :builtin,
      category: :agent,
      approval_level: :auto,
      capabilities: [:spawn_agent],
      context_requirements: [:tool_context],
      build: fn context ->
        root = context.project_root
        parent_session = Map.get(context.metadata, :parent_session)

        fn args ->
          Subagent.execute(args["task"],
            project_root: root,
            model: args["model"],
            provider: args["provider"],
            background: args["background"] == true,
            isolation: args["isolation"],
            parent_session: parent_session
          )
        end
      end
    )
  end

  # ── Git tools ────────────────────────────────────────────────────────────────

  @spec git_status() :: Spec.t()
  defp git_status do
    Spec.new!(
      name: "git_status",
      description: """
      Show git status: staged, unstaged, and untracked files with their change type.
      Returns structured output grouped by staged/unstaged state. Read-only.
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{}
      },
      source: :builtin,
      category: :git,
      approval_level: :auto,
      capabilities: [:git_read],
      context_requirements: [:tool_context],
      build: fn context ->
        root = context.project_root
        fn _args -> GitTools.status(root) end
      end
    )
  end

  @spec git_diff() :: Spec.t()
  defp git_diff do
    Spec.new!(
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
      source: :builtin,
      category: :git,
      approval_level: :auto,
      capabilities: [:git_read],
      context_requirements: [:tool_context],
      build: fn context ->
        root = context.project_root
        router_ctx = context.router_context

        fn args ->
          opts = []
          opts = if args["path"], do: [{:path, args["path"]} | opts], else: opts
          opts = if args["staged"], do: [{:staged, args["staged"]} | opts], else: opts
          GitTools.diff(root, opts, router_ctx)
        end
      end
    )
  end

  @spec git_log() :: Spec.t()
  defp git_log do
    Spec.new!(
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
      source: :builtin,
      category: :git,
      approval_level: :auto,
      capabilities: [:git_read],
      context_requirements: [:tool_context],
      build: fn context ->
        root = context.project_root

        fn args ->
          opts = []
          opts = if args["count"], do: [{:count, args["count"]} | opts], else: opts
          opts = if args["path"], do: [{:path, args["path"]} | opts], else: opts
          GitTools.log(root, opts)
        end
      end
    )
  end

  @spec git_stage() :: Spec.t()
  defp git_stage do
    Spec.new!(
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
      source: :builtin,
      category: :git,
      approval_level: :ask,
      capabilities: [:git_mutate],
      context_requirements: [:tool_context],
      build: fn context ->
        root = context.project_root

        fn args ->
          paths = args["paths"] || []
          GitTools.stage(root, paths)
        end
      end
    )
  end

  @spec git_commit() :: Spec.t()
  defp git_commit do
    Spec.new!(
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
      source: :builtin,
      category: :git,
      approval_level: :ask,
      capabilities: [:git_mutate],
      context_requirements: [:tool_context],
      build: fn context ->
        root = context.project_root

        fn args ->
          GitTools.commit(root, args["message"])
        end
      end
    )
  end

  # ── Memory tools ──────────────────────────────────────────────────────────────

  @spec memory_write() :: Spec.t()
  defp memory_write do
    Spec.new!(
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
      source: :builtin,
      category: :memory,
      approval_level: :auto,
      capabilities: [:memory_write],
      context_requirements: [:tool_context],
      build: fn _context ->
        fn args ->
          MemoryWrite.execute(args["text"] || "")
        end
      end
    )
  end

  # ── LSP tools ──────────────────────────────────────────────────────────────

  @spec lsp_diagnostics() :: Spec.t()
  defp lsp_diagnostics do
    Spec.new!(
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
      source: {:bundle, :lsp_tools},
      category: :lsp,
      approval_level: :auto,
      capabilities: [:lsp_read],
      context_requirements: [:tool_context],
      metadata: %{pack: :lsp_tools, destructive: false},
      build: fn context ->
        root = context.project_root

        fn args ->
          path = resolve_and_validate_path!(root, args["path"])
          LspDiagnostics.execute(path)
        end
      end
    )
  end

  @spec lsp_definition() :: Spec.t()
  defp lsp_definition do
    Spec.new!(
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
      source: {:bundle, :lsp_tools},
      category: :lsp,
      approval_level: :auto,
      capabilities: [:lsp_read],
      context_requirements: [:tool_context],
      metadata: %{pack: :lsp_tools, destructive: false},
      build: fn context ->
        root = context.project_root

        fn args ->
          path = resolve_and_validate_path!(root, args["path"])
          LspDefinition.execute(path, args["line"], args["column"])
        end
      end
    )
  end

  @spec lsp_references() :: Spec.t()
  defp lsp_references do
    Spec.new!(
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
      source: {:bundle, :lsp_tools},
      category: :lsp,
      approval_level: :auto,
      capabilities: [:lsp_read],
      context_requirements: [:tool_context],
      metadata: %{pack: :lsp_tools, destructive: false},
      build: fn context ->
        root = context.project_root

        fn args ->
          path = resolve_and_validate_path!(root, args["path"])
          LspReferences.execute(path, args["line"], args["column"])
        end
      end
    )
  end

  @spec lsp_hover() :: Spec.t()
  defp lsp_hover do
    Spec.new!(
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
      source: {:bundle, :lsp_tools},
      category: :lsp,
      approval_level: :auto,
      capabilities: [:lsp_read],
      context_requirements: [:tool_context],
      metadata: %{pack: :lsp_tools, destructive: false},
      build: fn context ->
        root = context.project_root

        fn args ->
          path = resolve_and_validate_path!(root, args["path"])
          LspHover.execute(path, args["line"], args["column"])
        end
      end
    )
  end

  @spec lsp_document_symbols() :: Spec.t()
  defp lsp_document_symbols do
    Spec.new!(
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
      source: {:bundle, :lsp_tools},
      category: :lsp,
      approval_level: :auto,
      capabilities: [:lsp_read],
      context_requirements: [:tool_context],
      metadata: %{pack: :lsp_tools, destructive: false},
      build: fn context ->
        root = context.project_root

        fn args ->
          path = resolve_and_validate_path!(root, args["path"])
          LspDocumentSymbols.execute(path)
        end
      end
    )
  end

  @spec lsp_workspace_symbols() :: Spec.t()
  defp lsp_workspace_symbols do
    Spec.new!(
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
      source: {:bundle, :lsp_tools},
      category: :lsp,
      approval_level: :auto,
      capabilities: [:lsp_read],
      context_requirements: [:tool_context],
      metadata: %{pack: :lsp_tools, destructive: false},
      build: fn _context ->
        fn args ->
          LspWorkspaceSymbols.execute(args["query"])
        end
      end
    )
  end

  @spec lsp_rename() :: Spec.t()
  defp lsp_rename do
    Spec.new!(
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
      source: {:bundle, :lsp_tools},
      category: :lsp,
      approval_level: :ask,
      capabilities: [:lsp_mutate],
      context_requirements: [:tool_context],
      metadata: %{pack: :lsp_tools, destructive: true},
      build: fn context ->
        root = context.project_root

        fn args ->
          path = resolve_and_validate_path!(root, args["path"])
          LspRename.execute(path, args["line"], args["column"], args["new_name"])
        end
      end
    )
  end

  @spec lsp_code_actions() :: Spec.t()
  defp lsp_code_actions do
    Spec.new!(
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
      source: {:bundle, :lsp_tools},
      category: :lsp,
      approval_level: :ask,
      capabilities: [:lsp_read, :lsp_mutate],
      context_requirements: [:tool_context],
      metadata: %{pack: :lsp_tools, destructive: :conditional},
      build: fn context ->
        root = context.project_root

        fn args ->
          path = resolve_and_validate_path!(root, args["path"])
          opts = []
          opts = if args["column"], do: [{:col, args["column"]} | opts], else: opts
          opts = if args["apply"], do: [{:apply, args["apply"]} | opts], else: opts
          LspCodeActions.execute(path, args["line"], opts)
        end
      end
    )
  end

  # ── Introspection tools ─────────────────────────────────────────────────────

  @spec describe_runtime() :: Spec.t()
  defp describe_runtime do
    Spec.new!(
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
      source: :builtin,
      category: :agent,
      approval_level: :auto,
      capabilities: [],
      context_requirements: [],
      build: fn _context ->
        &MingaAgent.Tools.Introspection.describe_runtime/1
      end
    )
  end

  @spec describe_tools() :: Spec.t()
  defp describe_tools do
    Spec.new!(
      name: "describe_tools",
      description: """
      List all available tools with their names, categories, and
      descriptions. Use this to discover what tools you can call.
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{}
      },
      source: :builtin,
      category: :agent,
      approval_level: :auto,
      capabilities: [],
      context_requirements: [],
      build: fn _context ->
        &MingaAgent.Tools.Introspection.describe_tools/1
      end
    )
  end

  # ── Shell execution guard ─────────────────────────────────────────────────

  @spec normalize_shell_timeout(term()) :: pos_integer()
  defp normalize_shell_timeout(value) when is_integer(value), do: value |> max(1) |> min(300)
  defp normalize_shell_timeout(_value), do: 30

  @spec run_shell_with_timeout(
          pos_integer(),
          (-> {:ok, String.t()} | {:error, String.t()})
        ) :: {:ok, String.t()} | {:error, String.t()}
  defp run_shell_with_timeout(timeout_secs, callback) do
    parent = self()
    result_ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn -> coordinate_shell_worker(parent, result_ref, callback) end)

    receive do
      {^result_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        receive_shell_result_after_down(result_ref, reason)
    after
      timeout_secs * 1_000 ->
        Process.exit(pid, :kill)
        await_shell_worker_down(monitor_ref, pid)
        {:error, "command timed out"}
    end
  end

  @spec coordinate_shell_worker(pid(), reference(), (-> term())) :: term()
  defp coordinate_shell_worker(parent, result_ref, callback) do
    parent_monitor = Process.monitor(parent)
    coordinator = self()
    callback_pid = spawn_link(fn -> send(coordinator, {:shell_callback_result, callback.()}) end)

    receive do
      {:shell_callback_result, result} ->
        Process.demonitor(parent_monitor, [:flush])
        send(parent, {result_ref, result})

      {:DOWN, ^parent_monitor, :process, ^parent, _reason} ->
        Process.exit(callback_pid, :kill)
    end
  end

  @spec receive_shell_result_after_down(reference(), term()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp receive_shell_result_after_down(result_ref, reason) do
    receive do
      {^result_ref, result} -> result
    after
      0 -> {:error, "command failed: #{inspect(reason)}"}
    end
  end

  @spec await_shell_worker_down(reference(), pid()) :: :ok
  defp await_shell_worker_down(monitor_ref, pid) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
    after
      1_000 ->
        Process.demonitor(monitor_ref, [:flush])
        :ok
    end
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

  # ── ProjectView routing helpers ────────────────────────────────────────────

  @spec read_file_fallback(ToolRouter.context(), String.t(), term(), map()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp read_file_fallback(router_ctx, path, reason, args) do
    if routing_error?(reason) do
      {:error, inspect(reason)}
    else
      if ToolRouter.project_view?(router_ctx) do
        {:error,
         "failed to read #{path} from #{ToolRouter.workspace_label(router_ctx)}: #{inspect(reason)}"}
      else
        routed_result(router_ctx, ReadFile.execute(path, build_read_opts(args)))
      end
    end
  end

  @spec routed_result(ToolRouter.context(), {:ok, String.t()} | {:error, String.t()}) ::
          {:ok, String.t()} | {:error, String.t()}
  defp routed_result(router_ctx, {:ok, message}) do
    {:ok, append_workspace_context(router_ctx, message)}
  end

  defp routed_result(_router_ctx, {:error, _message} = error), do: error

  @spec routing_error?(term()) :: boolean()
  defp routing_error?({:fork_unavailable, _}), do: true
  defp routing_error?({:project_view_unavailable, _}), do: true
  defp routing_error?({:changeset_unavailable, _}), do: true
  defp routing_error?(:deleted), do: true
  defp routing_error?(_), do: false

  @spec append_workspace_context(ToolRouter.context(), String.t()) :: String.t()
  defp append_workspace_context(router_ctx, message) do
    case ToolRouter.workspace_label(router_ctx) do
      nil -> message
      label -> "[#{label}]\n" <> message
    end
  end

  @spec route_name(ToolRouter.context()) :: String.t()
  defp route_name(router_ctx) do
    route_name(ToolRouter.project_view?(router_ctx), router_ctx.fork_store)
  end

  @spec route_name(boolean(), pid() | nil) :: String.t()
  defp route_name(true, _fork_store), do: "ProjectView"
  defp route_name(false, fork_store) when fork_store != nil, do: "fork"
  defp route_name(false, nil), do: "changeset"

  @spec format_project_view_entries(String.t(), [ProjectView.Backend.directory_entry()]) ::
          String.t()
  defp format_project_view_entries(path, entries) do
    DirectoryListing.format_entries(path, entries)
  end

  # ── Path safety ─────────────────────────────────────────────────────────────

  @doc """
  Resolves a relative path against the project root and validates that the
  resolved path does not escape the root directory.

  Raises `ArgumentError` if the path escapes the project root.
  """
  @spec resolve_and_validate_path!(String.t(), String.t()) :: String.t()
  def resolve_and_validate_path!(root, relative_path) do
    normalized_root = Path.expand(root)
    resolved = Path.expand(relative_path, normalized_root)

    validate_inside_root!(resolved, normalized_root, relative_path)

    canonical_root = canonical_root!(normalized_root, relative_path)

    canonical_resolved =
      resolve_inside_root!(
        canonical_root,
        relative_parts(resolved, normalized_root),
        relative_path
      )

    validate_inside_root!(canonical_resolved, canonical_root, relative_path)

    canonical_resolved
  end

  @spec canonical_root!(String.t(), String.t()) :: String.t()
  defp canonical_root!(root, original_path) do
    root
    |> Path.expand()
    |> absolute_parts()
    |> resolve_existing_parts!(filesystem_anchor(root), original_path, %{}, 0)
  end

  @spec absolute_parts(String.t()) :: [String.t()]
  defp absolute_parts(path) do
    case Path.split(path) do
      ["/" | parts] -> parts
      parts -> parts
    end
  end

  @spec filesystem_anchor(String.t()) :: String.t()
  defp filesystem_anchor(path) do
    case Path.split(Path.expand(path)) do
      ["/" | _parts] -> "/"
      [anchor | _parts] -> anchor
      [] -> "/"
    end
  end

  @spec resolve_existing_parts!(
          [String.t()],
          String.t(),
          String.t(),
          %{String.t() => true},
          non_neg_integer()
        ) :: String.t()
  defp resolve_existing_parts!([], current, _original_path, _seen_links, _depth), do: current

  defp resolve_existing_parts!(_parts, _current, original_path, _seen_links, depth)
       when depth >= @max_symlink_depth do
    raise ArgumentError, "too many symlinks while resolving #{original_path}"
  end

  defp resolve_existing_parts!([part | rest], current, original_path, seen_links, depth) do
    next = Path.join(current, part)

    case File.lstat(next) do
      {:ok, %File.Stat{type: :symlink}} ->
        canonical_link = Path.expand(next)
        ensure_new_symlink!(canonical_link, seen_links, original_path)
        seen_links = Map.put(seen_links, canonical_link, true)
        target = read_link_target!(next, current)

        target =
          resolve_existing_parts!(
            absolute_parts(target),
            filesystem_anchor(target),
            original_path,
            seen_links,
            depth + 1
          )

        resolve_existing_parts!(rest, target, original_path, seen_links, depth + 1)

      {:ok, _stat} ->
        resolve_existing_parts!(rest, next, original_path, seen_links, depth)

      {:error, reason} ->
        raise ArgumentError,
              "cannot resolve project root for #{original_path}: #{inspect(reason)}"
    end
  end

  @spec resolve_inside_root!(String.t(), [String.t()], String.t()) :: String.t()
  defp resolve_inside_root!(canonical_root, parts, original_path) do
    resolve_parts!(parts, canonical_root, canonical_root, original_path, %{}, 0)
  end

  @spec relative_parts(String.t(), String.t()) :: [String.t()]
  defp relative_parts(path, root) do
    case Path.relative_to(path, root) do
      "." -> []
      relative -> Path.split(relative)
    end
  end

  @spec resolve_parts!(
          [String.t()],
          String.t(),
          String.t(),
          String.t(),
          %{String.t() => true},
          non_neg_integer()
        ) :: String.t()
  defp resolve_parts!([], _root, current, _original_path, _seen_links, _depth), do: current

  defp resolve_parts!([part | rest], root, current, original_path, seen_links, depth) do
    next = Path.join(current, part)
    validate_inside_root!(next, root, original_path)

    case File.lstat(next) do
      {:ok, %File.Stat{type: :symlink}} ->
        {target, seen_links} =
          resolve_symlink_target!(next, current, root, original_path, seen_links, depth)

        resolve_parts!(rest, root, target, original_path, seen_links, depth + 1)

      {:ok, _stat} ->
        resolve_parts!(rest, root, next, original_path, seen_links, depth)

      {:error, _reason} ->
        resolve_missing_parts!(rest, root, next, original_path)
    end
  end

  @spec resolve_missing_parts!([String.t()], String.t(), String.t(), String.t()) :: String.t()
  defp resolve_missing_parts!([], _root, current, _original_path), do: current

  defp resolve_missing_parts!([part | rest], root, current, original_path) do
    next = Path.join(current, part)
    validate_inside_root!(next, root, original_path)
    resolve_missing_parts!(rest, root, next, original_path)
  end

  @spec resolve_symlink_target!(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          %{String.t() => true},
          non_neg_integer()
        ) :: {String.t(), %{String.t() => true}}
  defp resolve_symlink_target!(_link_path, _parent, _root, original_path, _seen_links, depth)
       when depth >= @max_symlink_depth do
    raise ArgumentError, "too many symlinks while resolving #{original_path}"
  end

  defp resolve_symlink_target!(link_path, parent, root, original_path, seen_links, depth) do
    canonical_link = Path.expand(link_path)
    ensure_new_symlink!(canonical_link, seen_links, original_path)
    seen_links = Map.put(seen_links, canonical_link, true)

    target = read_link_target!(link_path, parent)
    validate_inside_root!(target, root, original_path)

    target_parts = relative_parts(target, root)
    target = resolve_parts!(target_parts, root, root, original_path, seen_links, depth + 1)
    validate_inside_root!(target, root, original_path)

    {target, seen_links}
  end

  @spec ensure_new_symlink!(String.t(), %{String.t() => true}, String.t()) :: :ok
  defp ensure_new_symlink!(link_path, seen_links, original_path) do
    if Map.has_key?(seen_links, link_path) do
      raise ArgumentError, "symlink loop while resolving #{original_path}"
    end

    :ok
  end

  @spec read_link_target!(String.t(), String.t()) :: String.t()
  defp read_link_target!(path, parent) do
    case File.read_link(path) do
      {:ok, target} ->
        Path.expand(target, parent)

      {:error, reason} ->
        raise ArgumentError, "cannot resolve symlink #{path}: #{inspect(reason)}"
    end
  end

  @spec validate_inside_root!(String.t(), String.t(), String.t()) :: :ok
  defp validate_inside_root!(_path, "/", _original_path), do: :ok

  defp validate_inside_root!(path, root, original_path) do
    expanded_path = Path.expand(path)
    expanded_root = Path.expand(root)

    unless String.starts_with?(expanded_path, expanded_root <> "/") or
             expanded_path == expanded_root do
      raise ArgumentError, "path escapes project root: #{original_path}"
    end

    :ok
  end

  # Applies offset/limit slicing to content read from a changeset.
  @spec apply_read_slice(String.t(), String.t(), keyword()) :: {:ok, String.t()}
  defp apply_read_slice(content, _path, []) do
    {:ok, content}
  end

  defp apply_read_slice(content, path, opts) do
    lines = String.split(content, "\n")
    total = Enum.count(lines)
    offset = Keyword.get(opts, :offset, 1)
    limit = Keyword.get(opts, :limit, total)

    start_idx = max(offset - 1, 0)
    sliced = Enum.slice(lines, start_idx, limit)
    end_line = min(start_idx + limit, total)

    header = "[lines #{offset}-#{end_line} of #{total}] #{path}\n"
    {:ok, header <> Enum.join(sliced, "\n")}
  end

  # Applies multiple edits to a file through the tool router by reading,
  # applying each edit sequentially, then writing the result back.
  @spec apply_diff_via_router(MingaAgent.ToolRouter.context(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp apply_diff_via_router(router_ctx, path, diff) do
    case ToolRouter.read_file(router_ctx, path) do
      {:ok, content} ->
        commit_apply_diff(router_ctx, path, ApplyDiff.apply_to_content(content, diff))

      {:error, reason} ->
        {:error, "failed to read #{path}: #{inspect(reason)}"}
    end
  end

  @spec commit_apply_diff(
          ToolRouter.context(),
          String.t(),
          {:ok, ApplyDiff.apply_result()} | {:error, String.t()}
        ) :: {:ok, String.t()} | {:error, String.t()}
  defp commit_apply_diff(router_ctx, path, {:ok, %{content: final_content, hunks: hunk_count}}) do
    case ToolRouter.write_file(router_ctx, path, final_content) do
      :ok ->
        msg =
          append_workspace_context(
            router_ctx,
            "applied #{hunk_count} diff hunk(s) to #{path} (via #{route_name(router_ctx)})"
          )

        {:ok, maybe_append_diagnostics(path, msg)}

      :passthrough ->
        case WriteFile.execute(path, final_content) do
          {:ok, _msg} ->
            {:ok, maybe_append_diagnostics(path, "applied #{hunk_count} diff hunk(s) to #{path}")}

          {:error, _message} = error ->
            error
        end

      {:error, reason} ->
        {:error, "failed to write #{path}: #{inspect(reason)}"}
    end
  end

  defp commit_apply_diff(_router_ctx, _path, {:error, _message} = error), do: error

  @spec apply_multi_edit_via_router(MingaAgent.ToolRouter.context(), String.t(), [map()]) ::
          {:ok, String.t()} | {:error, String.t()}
  defp apply_multi_edit_via_router(router_ctx, path, edits) do
    case ToolRouter.read_file(router_ctx, path) do
      {:ok, content} ->
        {final_content, results} = reduce_edits(content, edits)
        commit_multi_edits(router_ctx, path, edits, final_content, results)

      {:error, reason} ->
        {:error, "failed to read #{path}: #{inspect(reason)}"}
    end
  end

  @spec reduce_edits(String.t(), [map()]) :: {String.t(), [{:ok | :error, String.t()}]}
  defp reduce_edits(content, edits) do
    edit_pairs =
      Enum.map(edits, fn edit ->
        {edit["old_text"] || "", edit["new_text"] || ""}
      end)

    {final_doc, results, _any_applied?} =
      Replace.apply_batch(Document.new(content), edit_pairs, nil)

    {Document.content(final_doc), results}
  end

  @spec commit_multi_edits(
          ToolRouter.context(),
          String.t(),
          [map()],
          String.t(),
          [{:ok | :error, String.t()}]
        ) :: {:ok, String.t()} | {:error, String.t()}
  defp commit_multi_edits(router_ctx, path, edits, final_content, results) do
    ok_count = Enum.count(results, &match?({:ok, _}, &1))

    case ok_count do
      0 ->
        msg =
          append_workspace_context(
            router_ctx,
            format_multi_edit_result(router_ctx, path, results, ok_count)
          )

        {:ok, maybe_append_diagnostics(path, msg)}

      _ ->
        commit_multi_edit_write(router_ctx, path, edits, final_content, results, ok_count)
    end
  end

  @spec commit_multi_edit_write(
          ToolRouter.context(),
          String.t(),
          [map()],
          String.t(),
          [{:ok | :error, String.t()}],
          non_neg_integer()
        ) :: {:ok, String.t()} | {:error, String.t()}
  defp commit_multi_edit_write(router_ctx, path, edits, final_content, results, ok_count) do
    case ToolRouter.write_file(router_ctx, path, final_content) do
      :ok ->
        msg =
          append_workspace_context(
            router_ctx,
            format_multi_edit_result(router_ctx, path, results, ok_count)
          )

        {:ok, maybe_append_diagnostics(path, msg)}

      :passthrough ->
        case MultiEditFile.execute(path, edits) do
          {:ok, msg} -> {:ok, maybe_append_diagnostics(path, msg)}
          {:error, _message} = error -> error
        end

      {:error, reason} ->
        {:error, "failed to write #{path}: #{inspect(reason)}"}
    end
  end

  @spec format_multi_edit_result(
          ToolRouter.context(),
          String.t(),
          [{:ok | :error, String.t()}],
          non_neg_integer()
        ) :: String.t()
  defp format_multi_edit_result(router_ctx, path, results, ok_count) do
    base =
      "applied #{ok_count}/#{Enum.count(results)} edits to #{path} (via #{route_name(router_ctx)})"

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
