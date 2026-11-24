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
  | `write_file`      | Explicit revision-checked creation or replacement   |
  | `edit_file`       | Atomic ordered exact replacements in one file       |
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
  | `fetch_output`    | Fetch an exact retained byte/item range              |
  """

  alias MingaAgent.ProjectView
  alias MingaAgent.Tool.Context
  alias MingaAgent.Tool.Output
  alias MingaAgent.Tool.Spec
  alias MingaAgent.ToolRouter
  alias MingaAgent.Tools.DirectoryListing
  alias MingaAgent.Tools.DiagnosticFeedback
  alias MingaAgent.Tools.FetchOutput
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
  alias MingaAgent.Tools.OutputCapture
  alias MingaAgent.Tools.ReadFile
  alias MingaAgent.Tools.ProcessBackend.System, as: SystemProcessBackend
  alias MingaAgent.Tools.Subagent
  alias Minga.Config

  @typedoc "Options passed to `all/1`."
  @type tools_opts :: [
          project_root: String.t(),
          project_view: ProjectView.t() | nil,
          changeset: pid() | nil,
          fork_store: pid() | nil,
          parent_session: GenServer.server() | nil,
          shell_output_callback: (String.t() -> :ok) | nil,
          process_backend: module(),
          artifact_store: GenServer.server() | nil,
          capture_key: Context.capture_key() | nil,
          image_tool_result_delivery: Context.image_tool_result_delivery()
        ]

  @default_destructive_tools ~w(write_file edit_file delete_file shell git_stage git_commit rename)
  @file_read_tools ~w(read_file list_directory find grep)
  @read_only_tools ~w(read_file memory_read fetch_output list_directory find grep fetch_url git_status git_diff git_log diagnostics definition references hover document_symbols workspace_symbols describe_runtime describe_tools produce_rewrite job_status job_output)
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
      fetch_output(),
      MingaAgent.Tools.Checklist.read_spec(),
      MingaAgent.Tools.Checklist.write_spec(),
      MingaAgent.Tools.AskUser.spec(),
      write_file(),
      edit_file(),
      delete_file(),
      list_directory(),
      find(),
      grep(),
      fetch_url(),
      shell(),
      job_status(),
      job_output(),
      job_cancel(),
      subagent(),
      git_status(),
      git_diff(),
      git_log(),
      git_stage(),
      git_commit(),
      memory_read(),
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
  def builtin_specs, do: specs_for_source(:builtin)

  @doc "Returns canonical tool declarations owned by one source."
  @spec specs_for_source(Spec.source()) :: [Spec.t()]
  def specs_for_source(source), do: Enum.filter(specs(), &(&1.source == source))

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

        fn args ->
          path = resolve_and_validate_path!(root, args["path"])
          ReadFile.capture(context, path, build_read_opts(args))
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

  @spec fetch_output() :: Spec.t()
  defp fetch_output do
    Spec.new!(
      name: "fetch_output",
      description: """
      Fetch an exact bounded byte or item range from retained tool output.
      Uses immutable captured content and never re-runs the original tool.
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "reference" => %{
            "type" => "object",
            "properties" => %{
              "token" => %{"type" => "string"},
              "media_type" => %{"type" => "string"},
              "bytes" => %{"type" => "integer"},
              "items" => %{"type" => ["integer", "null"]},
              "sha256" => %{"type" => "string"}
            },
            "required" => ["token", "media_type", "bytes", "sha256"]
          },
          "unit" => %{"type" => "string", "enum" => ["bytes", "items"]},
          "start" => %{"type" => "integer", "minimum" => 0},
          "count" => %{"type" => "integer", "minimum" => 0}
        },
        "required" => ["reference", "unit", "start", "count"]
      },
      source: :builtin,
      category: :filesystem,
      approval_level: :auto,
      capabilities: [:read_project],
      context_requirements: [:tool_context],
      build: fn context -> fn args -> FetchOutput.execute(context, args) end end
    )
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
      context_requirements: [:tool_context],
      metadata: %{pack: :read_only_tools},
      build: fn context ->
        fn args -> FetchUrl.execute(args) |> retained_process_result(context) end
      end
    )
  end

  @spec write_file() :: Spec.t()
  defp write_file do
    Spec.new!(
      name: "write_file",
      description: """
      Explicitly create or replace one file atomically. For mode=create, expected_revision must be \"absent\" and the target must not exist. For mode=replace, pass the exact full-source revision from read_file. A stale revision changes nothing. This is one-file atomicity, not a cross-file transaction. Changes remain in the session's owned view for existing review and undo.
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Path relative to the project root"},
          "mode" => %{"type" => "string", "enum" => ["create", "replace"]},
          "content" => %{"type" => "string", "description" => "Complete new file content"},
          "expected_revision" => revision_schema()
        },
        "required" => ["path", "mode", "content", "expected_revision"]
      },
      source: :builtin,
      category: :filesystem,
      approval_level: :ask,
      capabilities: [:mutate_project],
      context_requirements: [:tool_context],
      build: fn context ->
        fn args ->
          with {:ok, operation} <- write_operation(args) do
            mutate_file(context, args, operation)
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
      Apply an ordered batch of exact replacements to one file as one undoable change or none. Pass expected_revision from a full read_file result. Each nonempty old_text must occur exactly once in the sequential prepared content, including overlapping occurrences. An empty old_text appends new_text at the end of the existing file; a newline separates it from a last line that lacks one. Use write_file to create files. Later edits see earlier changes but cannot touch earlier replacement bytes. Any stale, missing, ambiguous, overlapping, or invalid edit rejects the entire batch and reports the failing edit. No fuzzy matching. Atomicity is per file only; cross-file work reports separate outcomes.
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Path relative to the project root"},
          "expected_revision" => revision_schema(),
          "edits" => %{
            "type" => "array",
            "minItems" => 1,
            "items" => %{
              "type" => "object",
              "properties" => %{
                "old_text" => %{
                  "type" => "string",
                  "description" => "Exact text to replace; empty appends new_text at the end"
                },
                "new_text" => %{"type" => "string"}
              },
              "required" => ["old_text", "new_text"]
            }
          }
        },
        "required" => ["path", "expected_revision", "edits"]
      },
      source: :builtin,
      category: :filesystem,
      approval_level: :ask,
      capabilities: [:mutate_project],
      context_requirements: [:tool_context],
      build: fn context ->
        fn args ->
          edits =
            Enum.map(args["edits"] || [], fn edit -> {edit["old_text"], edit["new_text"]} end)

          mutate_file(context, args, {:edit, edits})
        end
      end
    )
  end

  @spec delete_file() :: Spec.t()
  defp delete_file do
    Spec.new!(
      name: "delete_file",
      description:
        "Delete one file only if expected_revision matches its full read_file revision. Destructive: requires ordinary approval. Stale revisions leave content unchanged. No cross-file transaction.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Path relative to the project root"},
          "expected_revision" => revision_schema()
        },
        "required" => ["path", "expected_revision"]
      },
      source: :builtin,
      category: :filesystem,
      approval_level: :ask,
      capabilities: [:mutate_project],
      context_requirements: [:tool_context],
      build: fn context -> fn args -> mutate_file(context, args, :delete) end end
    )
  end

  @spec revision_schema() :: map()
  defp revision_schema do
    %{
      "type" => "string",
      "description" =>
        "Exact revision token from a complete full-source read_file result; use \"absent\" only for creation"
    }
  end

  @spec write_operation(map()) ::
          {:ok, Minga.Buffer.FileMutation.operation()} | {:error, String.t()}
  defp write_operation(%{"mode" => "create", "content" => content}), do: {:ok, {:create, content}}

  defp write_operation(%{"mode" => "replace", "content" => content}),
    do: {:ok, {:replace, content}}

  defp write_operation(_args),
    do:
      {:error, "stale revision: explicit create/replace mode and expected_revision are required"}

  @spec mutate_file(Context.t(), map(), Minga.Buffer.FileMutation.operation()) ::
          {:ok, String.t() | MingaAgent.Tool.FileMutationResult.t()} | {:error, String.t()}
  defp mutate_file(context, args, operation) do
    path = resolve_and_validate_path!(context.project_root, args["path"])

    expected =
      if args["expected_revision"] == "absent", do: :absent, else: args["expected_revision"]

    case ToolRouter.conditional_mutate(context.router_context, path, expected, operation) do
      {:ok, %Minga.Buffer.FileMutation.Receipt{} = receipt} ->
        text =
          maybe_append_diagnostics(
            path,
            append_workspace_context(
              context.router_context,
              "committed one atomic file mutation to #{path}"
            )
          )

        case context.session_invocation do
          nil ->
            {:ok, text}

          {_session, _invocation} ->
            {:ok, MingaAgent.Tool.FileMutationResult.new(path, receipt, text)}
        end

      {:error, :stale_revision} ->
        {:error, "stale revision for #{path}; read the file again"}

      {:error, :revision_required} ->
        {:error, "stale revision: expected_revision is required for #{path}"}

      {:error, {:edit_failed, index, :empty_edit}} ->
        {:error,
         "edit #{index} failed for #{path}: old_text and new_text are both empty, so the edit changes nothing; no edits committed"}

      {:error, {:edit_failed, index, reason}} ->
        {:error, "edit #{index} failed for #{path}: #{inspect(reason)}; no edits committed"}

      {:error, :enoent} when is_tuple(operation) and elem(operation, 0) == :edit ->
        {:error,
         "#{path} does not exist; edit_file only changes existing files. Use write_file with mode=create and expected_revision=absent to create it"}

      {:error, reason} ->
        {:error, "file mutation rejected for #{path}: #{inspect(reason)}"}
    end
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

          result =
            case ToolRouter.list_directory(router_ctx, path) do
              :passthrough ->
                ListDirectory.execute(path)

              {:ok, entries} ->
                {:ok,
                 append_workspace_context(router_ctx, format_project_view_entries(path, entries))}

              {:error, reason} ->
                {:error, inspect(reason)}
            end

          retained_process_result(result, context)
        end
      end
    )
  end

  @spec find() :: Spec.t()
  defp find do
    Spec.new!(
      name: "find",
      description: """
      Find files and directories by name pattern (glob). Returns the first 100
      sorted matching paths and retains the canonical result for item pagination.
      Generated, dependency, build, cache, and secret env paths are omitted.
      Use this for broad file discovery instead of shell + find.
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

              process_backend.find(args["pattern"], search.exec_path, public_args,
                filter_root: search.filter_root,
                artifact_store: context.artifact_store,
                capture_key: context.capture_key
              )
              |> retained_process_result(context)

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

              process_backend.grep(args["pattern"], search.exec_path, public_args,
                filter_root: search.filter_root,
                artifact_store: context.artifact_store,
                capture_key: context.capture_key
              )
              |> retained_process_result(context)

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
      stdout and stderr with a bounded 51KB preview and a stable fetch_output
      reference to admitted raw output. Quota exhaustion and interruption are
      explicit incomplete results. Commands time out after 30 seconds.
      Use this for running tests, linters, git commands, etc.
      Use find and grep for broad file discovery and content search.
      Do not use for interactive commands that require user input.
      Pass background: true to start the command and return a job handle
      immediately without waiting for completion. Use job_status and
      job_output to inspect background jobs.
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
          },
          "background" => %{
            "type" => "boolean",
            "description" =>
              "When true, start the command in the background and return a stable job handle immediately. Use job_status and job_output to inspect the result. Defaults to false."
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
        job_owner = Map.get(context.metadata, :job_owner)

        fn args ->
          timeout_secs = normalize_shell_timeout(args["timeout"])
          background? = args["background"] == true

          with {:ok, cwd} <- ToolRouter.working_dir_result(router_ctx),
               {:ok, env} <- ToolRouter.command_env_result(router_ctx) do
            shell_root = cwd || root

            if is_nil(cwd) do
              flush_before_shell()
            end

            shell_opts = [
              env: env,
              on_output: shell_output_callback,
              artifact_store: context.artifact_store,
              capture_key: context.capture_key
            ]

            if background? and job_owner != nil do
              execute_background_shell(
                job_owner,
                args["command"],
                shell_root,
                timeout_secs,
                shell_opts
              )
            else
              process_backend.shell(args["command"], shell_root, timeout_secs, shell_opts)
              |> retained_process_result(context)
            end
          else
            {:error, reason} -> {:error, inspect(reason)}
          end
        end
      end
    )
  end

  @spec execute_background_shell(
          GenServer.server(),
          String.t(),
          String.t(),
          pos_integer(),
          keyword()
        ) :: {:ok, String.t()} | {:error, term()}
  defp execute_background_shell(job_owner, command, cwd, timeout_secs, opts) do
    alias MingaAgent.Tools.JobOwner

    case JobOwner.start_background(job_owner, command, cwd, timeout_secs, opts) do
      {:ok, job_id} ->
        {:ok,
         "Background job started: #{job_id}\nUse job_status(\"#{job_id}\") to check progress."}

      {:error, reason} ->
        {:error, "Failed to start background job: #{inspect(reason)}"}
    end
  end

  # ── Job management tools ──────────────────────────────────────────────────

  @spec job_status() :: Spec.t()
  defp job_status do
    Spec.new!(
      name: "job_status",
      description: """
      Check the status of a background shell job. Returns the job's current
      lifecycle state (starting, running, completed, failed, timeout,
      cancelled, crashed, interrupted), exit code, and timing information.
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "job_id" => %{
            "type" => "string",
            "description" => "The job handle returned by shell with background: true"
          }
        },
        "required" => ["job_id"]
      },
      source: :builtin,
      category: :shell,
      approval_level: :auto,
      capabilities: [],
      context_requirements: [:tool_context],
      build: fn context ->
        job_owner = Map.get(context.metadata, :job_owner)

        fn args ->
          if job_owner == nil do
            {:error, "No job owner available. Background jobs require a session context."}
          else
            case MingaAgent.Tools.JobOwner.job_status(job_owner, args["job_id"]) do
              {:ok, job} ->
                {:ok, format_job_status(job)}

              {:error, :job_not_found} ->
                {:error, "Job not found: #{args["job_id"]}"}
            end
          end
        end
      end
    )
  end

  @spec job_output() :: Spec.t()
  defp job_output do
    Spec.new!(
      name: "job_output",
      description: """
      Retrieve the output of a completed background shell job. Returns the
      combined stdout/stderr text. The job must have reached a terminal state.
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "job_id" => %{
            "type" => "string",
            "description" => "The job handle returned by shell with background: true"
          }
        },
        "required" => ["job_id"]
      },
      source: :builtin,
      category: :shell,
      approval_level: :auto,
      capabilities: [],
      context_requirements: [:tool_context],
      build: fn context ->
        job_owner = Map.get(context.metadata, :job_owner)

        fn args ->
          if job_owner == nil do
            {:error, "No job owner available. Background jobs require a session context."}
          else
            case MingaAgent.Tools.JobOwner.job_output(job_owner, args["job_id"]) do
              {:ok, text} ->
                {:ok, text}

              {:error, :job_not_found} ->
                {:error, "Job not found: #{args["job_id"]}"}

              {:error, :job_still_running} ->
                {:error,
                 "Job is still running. Wait for completion or use job_status to check progress."}
            end
          end
        end
      end
    )
  end

  @spec job_cancel() :: Spec.t()
  defp job_cancel do
    Spec.new!(
      name: "job_cancel",
      description: """
      Cancel a running background shell job. The job's process tree is
      terminated and the job transitions to the cancelled terminal state.
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "job_id" => %{
            "type" => "string",
            "description" => "The job handle returned by shell with background: true"
          }
        },
        "required" => ["job_id"]
      },
      source: :builtin,
      category: :shell,
      approval_level: :ask,
      capabilities: [:run_shell],
      context_requirements: [:tool_context],
      build: fn context ->
        job_owner = Map.get(context.metadata, :job_owner)

        fn args ->
          if job_owner == nil do
            {:error, "No job owner available. Background jobs require a session context."}
          else
            case MingaAgent.Tools.JobOwner.cancel(job_owner, args["job_id"]) do
              :ok ->
                {:ok, "Job #{args["job_id"]} cancelled."}

              {:error, :job_not_found} ->
                {:error, "Job not found: #{args["job_id"]}"}

              {:error, :already_terminal} ->
                {:error, "Job already finished. Use job_output to retrieve its result."}
            end
          end
        end
      end
    )
  end

  @spec format_job_status(MingaAgent.Tools.Job.t()) :: String.t()
  defp format_job_status(job) do
    alias MingaAgent.Tools.Job

    status = Job.summary_status(job)

    elapsed =
      if job.finished_at,
        do: job.finished_at - job.started_at,
        else: System.monotonic_time(:millisecond) - job.started_at

    lines = [
      "Job: #{job.id}",
      "Status: #{status}",
      "Command: #{job.command}",
      "Elapsed: #{elapsed}ms"
    ]

    lines =
      if job.exit_code != nil do
        lines ++ ["Exit code: #{job.exit_code}"]
      else
        lines
      end

    lines =
      if job.background? do
        lines ++ ["Mode: background"]
      else
        lines ++ ["Mode: foreground"]
      end

    Enum.join(lines, "\n")
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
        fn _args -> GitTools.status(root) |> retained_process_result(context) end
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
          GitTools.diff(root, opts, router_ctx) |> retained_process_result(context)
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
          GitTools.log(root, opts) |> retained_process_result(context)
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

  @spec memory_read() :: Spec.t()
  defp memory_read do
    Spec.new!(
      name: "memory_read",
      description: "Read the existing user memory file when explicitly requested.",
      parameter_schema: %{"type" => "object", "properties" => %{}},
      source: {:bundle, :memory_tools},
      category: :memory,
      approval_level: :auto,
      capabilities: [],
      context_requirements: [],
      build: fn _context ->
        fn _args -> {:ok, MingaAgent.Memory.read() || "No saved memory."} end
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
          LspDiagnostics.execute(path) |> retained_process_result(context)
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
          |> retained_process_result(context)
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
          |> retained_process_result(context)
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
          |> retained_process_result(context)
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
          LspDocumentSymbols.execute(path) |> retained_process_result(context)
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
      build: fn context ->
        fn args ->
          LspWorkspaceSymbols.execute(args["query"]) |> retained_process_result(context)
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
          LspRename.execute(context, path, args["line"], args["column"], args["new_name"])
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
          result = LspCodeActions.execute(context, path, args["line"], opts)
          if args["apply"], do: result, else: retained_process_result(result, context)
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
      source: {:bundle, :introspection_tools},
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
      source: {:bundle, :introspection_tools},
      category: :agent,
      approval_level: :auto,
      capabilities: [],
      context_requirements: [],
      build: fn _context ->
        &MingaAgent.Tools.Introspection.describe_tools/1
      end
    )
  end

  # ── Shell execution ───────────────────────────────────────────────────────

  @spec normalize_shell_timeout(term()) :: pos_integer()
  defp normalize_shell_timeout(value) when is_integer(value), do: value |> max(1) |> min(300)
  defp normalize_shell_timeout(_value), do: 30

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

  @spec retained_process_result(
          {:ok, String.t() | Output.t()} | {:error, term()},
          Context.t()
        ) :: {:ok, Output.t()} | {:error, Output.t() | term()}
  defp retained_process_result({:ok, %Output{}} = result, _context), do: result
  defp retained_process_result({:error, %Output{}} = result, _context), do: result

  defp retained_process_result(
         {:error, {:incomplete, reason, bytes}},
         %Context{} = context
       )
       when is_atom(reason) and is_binary(bytes) do
    OutputCapture.bytes(context.artifact_store, context.capture_key, bytes,
      capture_status: {:incomplete, reason}
    )
  end

  defp retained_process_result({:ok, message}, %Context{} = context) when is_binary(message) do
    {captured, capture_status} = legacy_capture(message)

    OutputCapture.bytes(context.artifact_store, context.capture_key, captured,
      capture_status: capture_status
    )
  end

  defp retained_process_result({:error, _reason} = error, _context), do: error

  @spec legacy_capture(String.t()) :: {String.t(), Output.capture_status()}
  defp legacy_capture(message) do
    if String.contains?(message, ["[truncated", "... (truncated", "[stream truncated"]) do
      captured =
        Regex.replace(
          ~r/\n+(?:\[truncated[^\]]*\]|\.\.\. \(truncated[^)]*\))\z/,
          message,
          ""
        )

      {captured, {:incomplete, :capture_byte_limit}}
    else
      {message, :complete}
    end
  end

  @spec append_workspace_context(ToolRouter.context(), String.t()) :: String.t()
  defp append_workspace_context(router_ctx, message) do
    case ToolRouter.workspace_label(router_ctx) do
      nil -> message
      label -> "[#{label}]\n" <> message
    end
  end

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
end
