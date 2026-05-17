defmodule Minga.Config.Options do
  @moduledoc """
  Central registry for typed editor options.

  Stores global option values and per-filetype overrides. Other modules
  read options via `get/1` (global) or `get_for_filetype/2` (merged with
  filetype overrides).

  Backed by ETS with `read_concurrency: true` for lock-free reads on
  every render frame and keystroke. The GenServer exists only to own
  the ETS table lifecycle. Reads go directly to ETS; writes validate
  and then insert directly (no GenServer round-trip needed since ETS
  writes are atomic per-key).

  ## Supported options

  Option metadata lives in `@option_specs`, including each option's type, default value, and user-facing description. Use `option_specs/0` for the full list, `describe/1` for one built-in option, and `extension_option_specs/1` for extension-registered options.

  Log level options control per-subsystem verbosity. Subsystem options default to `:default` (inherit from `:log_level`). See `Minga.Log` for the filtering API.

  ## Per-filetype overrides

  Per-filetype settings override globals for buffers of that type:

      Minga.Config.Options.set_for_filetype(:go, :tab_width, 8)
      Minga.Config.Options.get_for_filetype(:tab_width, :go)
      #=> 8

  ## Example

      Minga.Config.Options.set(:tab_width, 4)
      Minga.Config.Options.get(:tab_width)
      #=> 4
  """

  use GenServer

  @typedoc "Valid option names."
  @type option_name ::
          :editing_model
          | :space_leader
          | :tab_width
          | :line_numbers
          | :show_gutter_separator
          | :autopair
          | :scroll_margin
          | :scroll_lines
          | :theme
          | :indent_with
          | :indent_guides
          | :show_invisible
          | :trim_trailing_whitespace
          | :insert_final_newline
          | :format_on_save
          | :auto_save_delay_ms
          | :lsp_auto_start
          | :formatter
          | :title_format
          | :modeline_left_segments
          | :modeline_right_segments
          | :modeline_separator
          | :recent_files_limit
          | :persist_recent_files
          | :persist_known_projects
          | :clipboard
          | :wrap
          | :linebreak
          | :breakindent
          | :agent_provider
          | :agent_model
          | :agent_tool_approval
          | :agent_destructive_tools
          | :agent_tool_permissions
          | :agent_hooks
          | :agent_session_retention_days
          | :agent_panel_split
          | :startup_view
          | :agent_auto_context
          | :agent_max_tokens
          | :agent_max_retries
          | :agent_models
          | :agent_prompt_cache
          | :agent_notifications
          | :agent_notify_on
          | :agent_system_prompt
          | :agent_append_system_prompt
          | :agent_diff_size_threshold
          | :agent_max_turns
          | :agent_max_cost
          | :agent_api_base_url
          | :agent_api_endpoints
          | :agent_mcp_servers
          | :agent_compaction_threshold
          | :agent_compaction_keep_recent
          | :agent_approval_timeout
          | :agent_subagent_timeout
          | :agent_mention_max_file_size
          | :agent_notify_debounce
          | :agent_diagnostic_feedback
          | :agent_flush_before_shell
          | :confirm_quit
          | :line_spacing
          | :font_family
          | :font_size
          | :font_weight
          | :font_ligatures
          | :font_fallback
          | :prettify_symbols
          | :whichkey_layout
          | :log_level
          | :log_level_render
          | :log_level_lsp
          | :log_level_agent
          | :log_level_editor
          | :cursorline
          | :cursor_animate
          | :cursor_blink
          | :nav_flash
          | :nav_flash_threshold
          | :log_level_config
          | :log_level_port
          | :log_level_distribution
          | :parser_tree_ttl
          | :event_retention_days
          | :default_shell
          | :file_find_excludes

  @typedoc "Line number display style."
  @type line_number_style :: :hybrid | :absolute | :relative | :none

  @typedoc "Option spec: `{name, type_descriptor, default_value, description}`."
  @type option_spec :: {option_name(), type_descriptor(), term(), String.t()}

  @typedoc "Human-readable metadata for one option."
  @type option_metadata :: %{
          name: option_name(),
          type: type_descriptor(),
          default: term(),
          description: String.t()
        }

  @typedoc "Human-readable metadata for an extension option."
  @type extension_option_metadata :: %{
          extension: atom(),
          name: atom(),
          type: type_descriptor(),
          default: term(),
          description: String.t()
        }

  @type type_descriptor ::
          :pos_integer
          | :non_neg_integer
          | :integer
          | :boolean
          | :atom
          | {:enum, [atom()]}
          | :theme_atom
          | :string
          | :string_or_nil
          | :string_list
          | :atom_list
          | :map_or_nil
          | :map_list
          | :float_or_nil
          | :any

  @typedoc "ETS table reference used for reads and writes."
  @type table :: :ets.table()

  @typedoc "Reference to a Config.Options GenServer (registered name or pid)."
  @type server :: GenServer.server()

  @typedoc "Options server state."
  @type state :: %{
          table: :ets.table(),
          source: server(),
          events_registry: Minga.Events.registry()
        }

  # Single source of truth for the default registered Options server. Other
  # modules call `default_server/0` rather than referencing `__MODULE__`
  # directly so future renames or alternate defaults stay localized here.
  @default_server __MODULE__

  @doc "Returns the registered name of the default options server."
  @spec default_server() :: server()
  def default_server, do: @default_server

  @doc """
  Asserts that `server` is a valid `server/0` reference (pid or non-nil atom).

  Raises `ArgumentError` otherwise. Use at boundaries that accept a caller-
  supplied `:options_server` opt — bad values would otherwise silently
  short-circuit later (e.g. `Process.get(:minga_config_options, default)`
  returns `nil` if the key is set to `nil`, defeating the fallback).
  """
  @spec validate_server!(term()) :: server()
  def validate_server!(server) when is_pid(server), do: server
  def validate_server!(server) when is_atom(server) and not is_nil(server), do: server

  def validate_server!(invalid) do
    raise ArgumentError,
          "expected Minga.Config.Options server (pid or non-nil atom), got: #{inspect(invalid)}"
  end

  @option_specs [
    {:editing_model, {:enum, [:vim, :cua]}, :vim,
     "Editing model used for text input and selection."},
    {:space_leader, {:enum, [:chord, :off]}, :chord,
     "How the Space key enters leader-key sequences in normal mode."},
    {:tab_width, :pos_integer, 2, "Number of spaces per tab stop."},
    {:line_numbers, {:enum, [:hybrid, :absolute, :relative, :none]}, :hybrid,
     "Line number style shown in the editor gutter."},
    {:show_gutter_separator, :boolean, true,
     "Whether to draw a separator between the gutter and buffer text."},
    {:autopair, :boolean, true, "Whether insert mode automatically inserts matching delimiters."},
    {:scroll_margin, :non_neg_integer, 5,
     "Minimum number of context lines kept around the cursor while scrolling."},
    {:scroll_lines, :pos_integer, 1, "Number of lines moved for each wheel-scroll step."},
    {:theme, :theme_atom, :doom_one, "Active color theme."},
    {:indent_with, {:enum, [:spaces, :tabs]}, :spaces,
     "Whether indentation inserts spaces or tab characters."},
    {:indent_guides, :boolean, true, "Whether indentation guide decorations are shown."},
    {:show_invisible, :boolean, false,
     "Whether invisible characters (tabs, trailing whitespace) are shown with visible markers."},
    {:trim_trailing_whitespace, :boolean, false,
     "Whether trailing whitespace is removed before saving."},
    {:insert_final_newline, :boolean, false, "Whether files are saved with a final newline."},
    {:format_on_save, :boolean, false, "Whether the configured formatter runs before saving."},
    {:auto_save_delay_ms, :non_neg_integer, 1000,
     "Delay before automatic save work runs; zero disables the timer."},
    {:lsp_auto_start, :boolean, true,
     "Whether buffer-open events automatically start configured language servers."},
    {:formatter, :string_or_nil, nil, "External formatter command for the current buffer."},
    {:title_format, :string, "{filename} {dirty}({directory}) - Minga",
     "Window title template with placeholder tokens."},
    {:modeline_left_segments, :atom_list, [:mode, :filename, :git, :agent, :background_agent],
     "Modeline segments shown on the left, in render order."},
    {:modeline_right_segments, :atom_list,
     [:diagnostics, :indent, :parser, :lsp, :filetype, :position, :percent],
     "Modeline segments shown on the right, in render order."},
    {:modeline_separator, {:enum, [:powerline, :round, :slant, :none]}, :powerline,
     "Separator style between modeline color zones."},
    {:recent_files_limit, :pos_integer, 200, "Maximum number of recent files to keep."},
    {:persist_recent_files, :boolean, true,
     "Whether recent files are written to disk between sessions."},
    {:persist_known_projects, :boolean, true,
     "Whether known projects are written to disk between sessions."},
    {:clipboard, {:enum, [:unnamedplus, :unnamed, :none]}, :unnamedplus,
     "Clipboard register integration mode."},
    {:wrap, :boolean, false, "Whether long visual lines wrap in editor windows."},
    {:linebreak, :boolean, true, "Whether wrapped lines break at word boundaries when possible."},
    {:breakindent, :boolean, true,
     "Whether wrapped line continuations align with the original indentation."},
    {:agent_provider, {:enum, [:auto, :native]}, :auto, "Agent provider backend selection."},
    {:agent_model, :string_or_nil, nil, "Default model used by new agent sessions."},
    {:agent_tool_approval, {:enum, [:destructive, :all, :none]}, :destructive,
     "When agent tool calls require user approval."},
    {:agent_destructive_tools, :string_list,
     ["write_file", "edit_file", "multi_edit_file", "shell", "git_stage", "git_commit", "rename"],
     "Tool names treated as destructive for approval prompts."},
    {:agent_tool_permissions, :map_or_nil, nil, "Per-tool permission overrides for agent tools."},
    {:agent_hooks, :any, [], "Agent lifecycle hook declarations loaded from config."},
    {:agent_session_retention_days, :pos_integer, 30,
     "Number of days to retain persisted agent sessions."},
    {:agent_panel_split, :pos_integer, 65,
     "Percentage of available width assigned to the agent panel."},
    {:startup_view, {:enum, [:agent, :editor]}, :agent, "Initial view shown when Minga starts."},
    {:agent_auto_context, :boolean, true,
     "Whether the active buffer is automatically included in agent context."},
    {:agent_max_tokens, :pos_integer, 16_384, "Maximum token budget sent to the agent provider."},
    {:agent_max_retries, :non_neg_integer, 3,
     "Maximum retry attempts for failed agent provider requests."},
    {:agent_models, :string_list, [],
     "Additional model identifiers shown in agent model pickers."},
    {:agent_prompt_cache, :boolean, true,
     "Whether prompt caching hints are enabled for supported providers."},
    {:agent_notifications, :boolean, true,
     "Whether agent events can produce user notifications."},
    {:agent_notify_on, :any, [:approval, :complete, :error],
     "Agent event kinds that trigger notifications."},
    {:agent_system_prompt, :string, "", "Replacement system prompt text for agent sessions."},
    {:agent_append_system_prompt, :string, "",
     "Additional text appended to the default agent system prompt."},
    {:agent_diff_size_threshold, :pos_integer, 1_048_576,
     "Maximum diff size shown inline before truncation or summarization."},
    {:agent_max_turns, :pos_integer, 100, "Maximum number of turns allowed in an agent session."},
    {:agent_max_cost, :float_or_nil, nil, "Optional cost ceiling for an agent session."},
    {:agent_api_base_url, :string, "", "Base URL override for agent API requests."},
    {:agent_api_endpoints, :map_or_nil, nil,
     "Provider endpoint overrides for agent API requests."},
    {:agent_mcp_servers, :map_list, [], "MCP server definitions made available to the agent."},
    {:agent_compaction_threshold, :float_or_nil, 0.8,
     "Conversation-size threshold that triggers agent context compaction."},
    {:agent_compaction_keep_recent, :pos_integer, 6,
     "Number of recent conversation turns preserved during compaction."},
    {:agent_approval_timeout, :pos_integer, 300_000,
     "Milliseconds before an agent approval prompt times out."},
    {:agent_subagent_timeout, :pos_integer, 300_000,
     "Milliseconds before a delegated subagent task times out."},
    {:agent_mention_max_file_size, :pos_integer, 262_144,
     "Maximum file size in bytes that can be inlined from an agent mention."},
    {:agent_notify_debounce, :pos_integer, 5_000,
     "Milliseconds used to debounce repeated agent notifications."},
    {:agent_diagnostic_feedback, :boolean, true,
     "Whether diagnostics are fed back into agent context."},
    {:agent_flush_before_shell, :boolean, true,
     "Whether pending agent output flushes before shell tools run."},
    {:confirm_quit, :boolean, true,
     "Whether quitting with unsaved changes asks for confirmation."},
    {:cursorline, :boolean, true, "Whether the current cursor line is highlighted."},
    {:cursor_animate, :boolean, true,
     "Whether cursor movement is smoothly animated in GUI frontends."},
    {:cursor_blink, :boolean, true, "Whether GUI frontends blink the editor cursor."},
    {:nav_flash, :boolean, true, "Whether large cursor jumps briefly highlight the destination."},
    {:nav_flash_threshold, :pos_integer, 5,
     "Minimum jump distance that triggers navigation flash."},
    {:yank_flash, :boolean, true,
     "Whether yanked text briefly highlights after yank operations."},
    {:whichkey_layout, {:enum, [:bottom, :float]}, :bottom, "Layout used for which-key popups."},
    {:line_spacing, :float_or_nil, 1.0, "Additional line spacing multiplier for GUI frontends."},
    {:font_family, :string, "Menlo", "Primary editor font family used by GUI frontends."},
    {:font_size, :pos_integer, 13, "Editor font size in points for GUI frontends."},
    {:font_weight, {:enum, [:thin, :light, :regular, :medium, :semibold, :bold, :heavy, :black]},
     :regular, "Editor font weight used by GUI frontends."},
    {:font_ligatures, :boolean, true, "Whether GUI frontends enable font ligatures."},
    {:font_fallback, :string_list, [],
     "Fallback font families used when the primary font lacks a glyph."},
    {:prettify_symbols, :boolean, false,
     "Whether symbolic text substitutions are rendered in buffers."},
    {:log_level, {:enum, [:debug, :info, :warning, :error, :none]}, :info,
     "Default log verbosity for all subsystems."},
    {:log_level_render, {:enum, [:default, :debug, :info, :warning, :error, :none]}, :default,
     "Render subsystem log verbosity override."},
    {:log_level_lsp, {:enum, [:default, :debug, :info, :warning, :error, :none]}, :default,
     "LSP subsystem log verbosity override."},
    {:log_level_agent, {:enum, [:default, :debug, :info, :warning, :error, :none]}, :default,
     "Agent subsystem log verbosity override."},
    {:log_level_editor, {:enum, [:default, :debug, :info, :warning, :error, :none]}, :default,
     "Editor subsystem log verbosity override."},
    {:log_level_config, {:enum, [:default, :debug, :info, :warning, :error, :none]}, :default,
     "Config subsystem log verbosity override."},
    {:log_level_port, {:enum, [:default, :debug, :info, :warning, :error, :none]}, :default,
     "Port protocol subsystem log verbosity override."},
    {:log_level_distribution, {:enum, [:default, :debug, :info, :warning, :error, :none]},
     :default, "Distribution subsystem log verbosity override."},
    {:parser_tree_ttl, :integer, 300, "Seconds to keep cached parser trees alive."},
    {:event_retention_days, :pos_integer, 90,
     "Number of days to keep persisted event log entries."},
    {:default_shell, {:enum, [:traditional, :board]}, :traditional,
     "Shell implementation opened by default."},
    {:file_find_excludes, :string_list,
     [
       ".git",
       "tmp",
       "temp",
       "log",
       "dist",
       ".cache",
       ".expert",
       "node_modules",
       ".venv",
       "__pycache__",
       ".mypy_cache",
       "vendor",
       "target",
       "build",
       "out",
       "_build",
       "deps",
       ".DS_Store"
     ], "Directory names excluded from the file finder (SPC f f). Stacks with .gitignore."}
  ]
  @valid_names Enum.map(@option_specs, &elem(&1, 0))

  @defaults Map.new(@option_specs, fn {name, _type, default, _description} -> {name, default} end)

  @filetype_defaults [
    {{:filetype, :markdown, :wrap}, true},
    {{:filetype, :gitcommit, :wrap}, true},
    {{:filetype, :text, :wrap}, true}
  ]

  @types Map.new(@option_specs, fn {name, type, _default, _description} -> {name, type} end)

  @descriptions Map.new(@option_specs, fn {name, _type, _default, description} ->
                  {name, description}
                end)

  # ── GenServer (table lifecycle only) ────────────────────────────────────────

  @doc """
  Starts the options registry and creates the backing ETS table.

  Pass `name: nil` to start anonymously (no registered name, unnamed ETS
  table). Useful for isolated test fixtures: pass the returned pid to
  server-aware functions instead of generating per-test atoms.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    events_registry = Keyword.get(opts, :events_registry, Minga.Events.default_registry())

    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> GenServer.start_link(__MODULE__, {:anonymous, events_registry}, [])
      {:ok, name} -> GenServer.start_link(__MODULE__, {name, events_registry}, name: name)
      :error -> GenServer.start_link(__MODULE__, {__MODULE__, events_registry}, name: __MODULE__)
    end
  end

  @impl GenServer
  def init({:anonymous, events_registry}) do
    # The first arg to :ets.new/2 is a tag, not a table identity, when
    # :named_table is omitted. Do NOT add :named_table here — multiple
    # anonymous Options servers may run concurrently (per-test isolation),
    # and a named ETS table can only exist once per BEAM node.
    table = :ets.new(:config_options, [:set, :public, read_concurrency: true])
    seed_defaults(table)
    seed_runtime_metadata(table, self(), events_registry)
    {:ok, %{table: table, source: self(), events_registry: events_registry}}
  end

  def init({name, events_registry}) do
    table = :ets.new(table_name(name), [:set, :public, :named_table, read_concurrency: true])
    seed_defaults(table)
    seed_runtime_metadata(table, name, events_registry)
    {:ok, %{table: table, source: name, events_registry: events_registry}}
  end

  # ── Extension Option Registration ──────────────────────────────────────────

  @doc """
  Registers a typed option for use by an extension.

  Registers a full option schema for an extension and validates user
  config against it. Called by `Extension.Supervisor` at load time,
  not by extensions directly.

  Each spec in the schema is stored under `{:extension, ext_name, opt_name}`
  in ETS, with type metadata under `{:extension_schema, ext_name}`.

  User config values that match a schema entry are validated and stored.
  Unknown keys produce a warning log. Type mismatches return an error.
  """
  @spec register_extension_schema(
          server(),
          atom(),
          [Minga.Extension.option_spec()],
          keyword()
        ) ::
          :ok | {:error, String.t()}
  def register_extension_schema(server \\ @default_server, ext_name, schema, user_config)
      when is_atom(ext_name) and is_list(schema) and is_list(user_config) do
    table = table_name(server)

    # Store the full schema for introspection
    :ets.insert(table, {{:extension_schema, ext_name}, schema})

    # Register each option with its type, default, and doc
    for {opt_name, type, default, description} <- schema do
      :ets.insert(table, {{:extension_type, ext_name, opt_name}, type})
      :ets.insert(table, {{:extension_default, ext_name, opt_name}, default})
      :ets.insert(table, {{:extension_description, ext_name, opt_name}, description})

      # Seed the default value
      key = {:extension, ext_name, opt_name}

      case :ets.lookup(table, key) do
        [{^key, _}] -> :ok
        [] -> :ets.insert(table, {key, default})
      end
    end

    # Validate and apply user config values
    schema_names = MapSet.new(schema, &elem(&1, 0))
    validate_and_apply_user_config(table, ext_name, user_config, schema_names)
  end

  @spec validate_and_apply_user_config(:ets.table(), atom(), keyword(), MapSet.t()) ::
          :ok | {:error, String.t()}
  defp validate_and_apply_user_config(table, ext_name, user_config, schema_names) do
    errors =
      Enum.reduce(user_config, [], fn {key, value}, errs ->
        validate_user_config_entry(table, ext_name, key, value, schema_names, errs)
      end)

    case Enum.reverse(errors) do
      [] -> :ok
      [first | _] -> {:error, first}
    end
  end

  @spec validate_user_config_entry(:ets.table(), atom(), atom(), term(), MapSet.t(), [String.t()]) ::
          [String.t()]
  defp validate_user_config_entry(table, ext_name, key, value, schema_names, errors) do
    case MapSet.member?(schema_names, key) do
      true ->
        apply_validated_config_entry(table, ext_name, key, value, errors)

      false ->
        Minga.Log.warning(
          :config,
          "Extension #{ext_name}: unknown option #{inspect(key)} (ignored)"
        )

        errors
    end
  end

  @spec apply_validated_config_entry(:ets.table(), atom(), atom(), term(), [String.t()]) ::
          [String.t()]
  defp apply_validated_config_entry(table, ext_name, key, value, errors) do
    case validate_extension_value(table, ext_name, key, value) do
      :ok ->
        :ets.insert(table, {{:extension, ext_name, key}, value})
        errors

      {:error, msg} ->
        [msg | errors]
    end
  end

  @doc """
  Gets an extension option value, falling back to its registered default.

  ## Examples

      Config.Options.get_extension_option(:minga_org, :conceal)
      # => true
  """
  @spec get_extension_option(server(), atom(), atom()) :: term()
  def get_extension_option(server \\ @default_server, ext_name, opt_name)
      when is_atom(ext_name) and is_atom(opt_name) do
    table = table_name(server)
    key = {:extension, ext_name, opt_name}

    case :ets.lookup(table, key) do
      [{^key, value}] -> value
      [] -> extension_default(table, ext_name, opt_name)
    end
  end

  @doc """
  Sets an extension option value after type validation.

  ## Examples

      Config.Options.set_extension_option(:minga_org, :conceal, false)
      # => {:ok, false}
  """
  @spec set_extension_option(server(), atom(), atom(), term()) ::
          {:ok, term()} | {:error, String.t()}
  def set_extension_option(server \\ @default_server, ext_name, opt_name, value)
      when is_atom(ext_name) and is_atom(opt_name) do
    table = table_name(server)

    case validate_extension_value(table, ext_name, opt_name, value) do
      :ok ->
        :ets.insert(table, {{:extension, ext_name, opt_name}, value})
        {:ok, value}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Sets an extension option override for a specific filetype.

  The value is validated against the extension's registered schema.

  ## Examples

      Config.Options.set_extension_option_for_filetype(:minga_org, :org, :conceal, false)
  """
  @spec set_extension_option_for_filetype(server(), atom(), atom(), atom(), term()) ::
          {:ok, term()} | {:error, String.t()}
  def set_extension_option_for_filetype(
        server \\ @default_server,
        ext_name,
        filetype,
        opt_name,
        value
      )
      when is_atom(ext_name) and is_atom(filetype) and is_atom(opt_name) do
    table = table_name(server)

    case validate_extension_value(table, ext_name, opt_name, value) do
      :ok ->
        :ets.insert(table, {{:filetype, filetype, {:extension, ext_name, opt_name}}, value})
        {:ok, value}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Gets an extension option with filetype override applied.

  Checks filetype-specific override first, then falls back to the
  global extension option value.
  """
  @spec get_extension_option_for_filetype(server(), atom(), atom(), atom() | nil) :: term()
  def get_extension_option_for_filetype(server \\ @default_server, ext_name, opt_name, filetype)

  def get_extension_option_for_filetype(server, ext_name, opt_name, nil),
    do: get_extension_option(server, ext_name, opt_name)

  def get_extension_option_for_filetype(server, ext_name, opt_name, filetype)
      when is_atom(ext_name) and is_atom(opt_name) and is_atom(filetype) do
    table = table_name(server)
    ft_key = {:filetype, filetype, {:extension, ext_name, opt_name}}

    case :ets.lookup(table, ft_key) do
      [{^ft_key, value}] -> value
      [] -> get_extension_option(server, ext_name, opt_name)
    end
  end

  @doc """
  Returns the registered option schema for an extension, or `nil` if
  the extension has no schema.
  """
  @spec extension_schema(server(), atom()) :: [Minga.Extension.option_spec()] | nil
  def extension_schema(server \\ @default_server, ext_name) when is_atom(ext_name) do
    table = table_name(server)

    case :ets.lookup(table, {:extension_schema, ext_name}) do
      [{_, schema}] -> schema
      [] -> nil
    end
  end

  @doc """
  Returns the description string for an extension option, or `nil` if
  not found.

  Used by `SPC h v` (describe option) and other introspection features.
  """
  @spec extension_option_description(server(), atom(), atom()) :: String.t() | nil
  def extension_option_description(server \\ @default_server, ext_name, opt_name)
      when is_atom(ext_name) and is_atom(opt_name) do
    table = table_name(server)

    case :ets.lookup(table, {:extension_description, ext_name, opt_name}) do
      [{_, description}] -> description
      [] -> nil
    end
  end

  # ── Client API (reads go directly to ETS) ───────────────────────────────────

  @doc """
  Sets a global option value after type validation.

  Returns `{:ok, value}` on success or `{:error, reason}` if the option
  name is unknown or the value has the wrong type.
  """
  @spec set(server(), option_name(), term()) :: {:ok, term()} | {:error, String.t()}
  def set(server \\ @default_server, name, value) when is_atom(name) do
    table = table_name(server)

    case validate(name, value) do
      :ok ->
        :ets.insert(table, {name, value})

        Minga.Events.broadcast(
          :option_changed,
          %Minga.Events.OptionChangedEvent{
            source: option_source(table, server),
            name: name,
            value: value
          },
          option_events_registry(table)
        )

        {:ok, value}

      {:error, _} = err ->
        err
    end
  end

  @doc "Marks an option as explicitly set by the GUI settings overlay."
  @spec mark_explicit(server(), option_name()) :: :ok
  def mark_explicit(server \\ @default_server, name) when is_atom(name) do
    :ets.insert(table_name(server), {{:explicit, name}, true})
    :ok
  end

  @doc "Returns whether an option was explicitly set by the GUI settings overlay."
  @spec explicitly_set?(server(), option_name()) :: boolean()
  def explicitly_set?(server \\ @default_server, name) when is_atom(name) do
    case :ets.lookup(table_name(server), {:explicit, name}) do
      [{{:explicit, ^name}, true}] -> true
      _ -> false
    end
  end

  @doc """
  Gets the current global value of an option, falling back to its default.
  """
  @spec get(server(), option_name()) :: term()
  def get(server \\ @default_server, name) when is_atom(name) do
    table = table_name(server)

    case :ets.lookup(table, name) do
      [{^name, value}] -> value
      [] -> Map.get(@defaults, name)
    end
  end

  @doc """
  Gets an option value with filetype override applied.

  Checks filetype-specific settings first, then falls back to the global
  value. If `filetype` is `nil`, returns the global value.
  """
  @spec get_for_filetype(server(), option_name(), atom() | nil) :: term()
  def get_for_filetype(server \\ @default_server, name, filetype)

  def get_for_filetype(server, name, nil), do: get(server, name)

  def get_for_filetype(server, name, filetype) when is_atom(name) and is_atom(filetype) do
    table = table_name(server)

    case :ets.lookup(table, {:filetype, filetype, name}) do
      [{_key, value}] -> value
      [] -> get(server, name)
    end
  end

  @doc """
  Sets an option override for a specific filetype.

  The value is validated the same way as global options.
  """
  @spec set_for_filetype(server(), atom(), option_name(), term()) ::
          {:ok, term()} | {:error, String.t()}
  def set_for_filetype(server \\ @default_server, filetype, name, value)
      when is_atom(filetype) and is_atom(name) do
    case validate(name, value) do
      :ok ->
        :ets.insert(table_name(server), {{:filetype, filetype, name}, value})
        {:ok, value}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Returns all current global option values as a map.
  """
  @spec all(server()) :: %{option_name() => term()}
  def all(server \\ @default_server) do
    table = table_name(server)

    :ets.foldl(
      fn
        {name, value}, acc when is_atom(name) -> Map.put(acc, name, value)
        _filetype_entry, acc -> acc
      end,
      %{},
      table
    )
  end

  @doc """
  Resets all options (global and per-filetype) to defaults.
  """
  @spec reset(server()) :: :ok
  def reset(server \\ @default_server) do
    table = table_name(server)
    source = option_source(table, server)
    events_registry = option_events_registry(table)
    previous_cursor_animate = get(server, :cursor_animate)
    :ets.delete_all_objects(table)
    seed_defaults(table)
    seed_runtime_metadata(table, source, events_registry)

    broadcast_reset_option(
      :cursor_animate,
      previous_cursor_animate,
      get(server, :cursor_animate),
      source,
      events_registry
    )

    :ok
  end

  @doc """
  Returns the default value for an option.
  """
  @spec default(option_name()) :: term()
  def default(name) when name in @valid_names, do: Map.fetch!(@defaults, name)

  @doc """
  Returns the list of valid option names.
  """
  @spec valid_names() :: [option_name()]
  def valid_names, do: @valid_names

  @doc """
  Returns the type descriptor for an option, or `nil` if unknown.

  Used by `Config.Completion` to determine what value completions
  to offer (enum variants, booleans, etc.).
  """
  @spec type_for(option_name()) :: type_descriptor() | nil
  def type_for(name) when is_atom(name), do: Map.get(@types, name)

  @doc """
  Returns metadata for an option, or `nil` if unknown.
  """
  @spec describe(atom()) :: option_metadata() | nil
  def describe(name) when is_atom(name) do
    with {:ok, type} <- Map.fetch(@types, name),
         {:ok, default} <- Map.fetch(@defaults, name),
         {:ok, description} <- Map.fetch(@descriptions, name) do
      %{name: name, type: type, default: default, description: description}
    else
      :error -> nil
    end
  end

  @doc """
  Returns the config-level provenance chain for an option's effective value.
  """
  @spec provenance(option_name(), atom() | nil) :: [String.t()]
  @spec provenance(server(), option_name(), atom() | nil) :: [String.t()]
  def provenance(name, filetype), do: provenance(@default_server, name, filetype)

  def provenance(server, name, filetype) when is_atom(name) do
    ["default"]
    |> maybe_append(global_override?(server, name), "config.exs")
    |> maybe_append(filetype_override?(server, name, filetype), "filetype #{inspect(filetype)}")
  end

  @doc """
  Returns metadata for all registered extension options.
  """
  @spec extension_option_specs(server()) :: [extension_option_metadata()]
  def extension_option_specs(server \\ @default_server) do
    table = table_name(server)

    :ets.foldl(
      fn
        {{:extension_schema, extension}, schema}, acc
        when is_atom(extension) and is_list(schema) ->
          extension_specs(extension, schema) ++ acc

        _entry, acc ->
          acc
      end,
      [],
      table
    )
    |> Enum.sort_by(&{&1.extension, &1.name})
  end

  @doc """
  Returns metadata for a registered extension option, or `nil` if unknown.
  """
  @spec describe_extension_option(server(), atom(), atom()) :: extension_option_metadata() | nil
  def describe_extension_option(server \\ @default_server, extension, name)
      when is_atom(extension) and is_atom(name) do
    Enum.find(extension_option_specs(server), &(&1.extension == extension and &1.name == name))
  end

  @doc """
  Returns the config-level provenance chain for an extension option's effective value.
  """
  @spec extension_provenance(server(), atom(), atom(), atom() | nil) :: [String.t()]
  def extension_provenance(server \\ @default_server, extension, name, filetype)
      when is_atom(extension) and is_atom(name) do
    ["default"]
    |> maybe_append(extension_global_override?(server, extension, name), "config.exs")
    |> maybe_append(
      extension_filetype_override?(server, extension, name, filetype),
      "filetype #{inspect(filetype)}"
    )
  end

  @doc """
  Returns the full option spec list: `[{name, type, default, description}]`.

  Used by `Config.Completion` to generate completion items with
  type and default information in the detail text.
  """
  @spec option_specs() :: [option_spec()]
  def option_specs, do: @option_specs

  # ── Validation ──────────────────────────────────────────────────────────────

  @doc """
  Validates an option name and value against the type registry.

  Returns `:ok` if valid, or `{:error, reason}` if the name is unknown
  or the value has the wrong type. Used by `Buffer.set_option/3`
  to validate buffer-local option overrides.
  """
  @spec validate_option(atom(), term()) :: :ok | {:error, String.t()}
  def validate_option(name, value), do: validate(name, value)

  @spec validate(atom(), term()) :: :ok | {:error, String.t()}
  defp validate(name, value) do
    case Map.fetch(@types, name) do
      {:ok, type} ->
        validate_type(type, name, value)

      :error ->
        {:error, "unknown option: #{inspect(name)}"}
    end
  end

  @spec validate_type(type_descriptor(), atom(), term()) :: :ok | {:error, String.t()}
  defp validate_type(:pos_integer, _name, value) when is_integer(value) and value > 0, do: :ok

  defp validate_type(:pos_integer, name, value) do
    {:error, "#{name} must be a positive integer, got: #{inspect(value)}"}
  end

  defp validate_type(:non_neg_integer, _name, value) when is_integer(value) and value >= 0,
    do: :ok

  defp validate_type(:non_neg_integer, name, value) do
    {:error, "#{name} must be a non-negative integer, got: #{inspect(value)}"}
  end

  defp validate_type(:integer, _name, value) when is_integer(value), do: :ok

  defp validate_type(:integer, name, value) do
    {:error, "#{name} must be an integer, got: #{inspect(value)}"}
  end

  defp validate_type(:boolean, _name, value) when is_boolean(value), do: :ok

  defp validate_type(:boolean, name, value) do
    {:error, "#{name} must be a boolean, got: #{inspect(value)}"}
  end

  defp validate_type(:atom, _name, value) when is_atom(value), do: :ok

  defp validate_type(:atom, name, value) do
    {:error, "#{name} must be an atom, got: #{inspect(value)}"}
  end

  defp validate_type({:enum, _allowed}, :agent_provider, :pi_rpc) do
    {:error, "agent_provider no longer supports :pi_rpc. Use :native instead."}
  end

  defp validate_type({:enum, allowed}, name, value) when is_atom(value) do
    if value in allowed do
      :ok
    else
      {:error, "#{name} must be one of #{inspect(allowed)}, got: #{inspect(value)}"}
    end
  end

  defp validate_type({:enum, allowed}, name, value) do
    {:error, "#{name} must be one of #{inspect(allowed)}, got: #{inspect(value)}"}
  end

  defp validate_type(:string, _name, value) when is_binary(value), do: :ok

  defp validate_type(:string, name, value) do
    {:error, "#{name} must be a string, got: #{inspect(value)}"}
  end

  defp validate_type(:string_or_nil, _name, nil), do: :ok
  defp validate_type(:string_or_nil, _name, value) when is_binary(value), do: :ok

  defp validate_type(:string_or_nil, name, value) do
    {:error, "#{name} must be a string or nil, got: #{inspect(value)}"}
  end

  defp validate_type(:string_list, _name, value) when is_list(value) do
    if Enum.all?(value, &is_binary/1) do
      :ok
    else
      {:error, "expected a list of strings, got non-string elements"}
    end
  end

  defp validate_type(:string_list, name, value) do
    {:error, "#{name} must be a list of strings, got: #{inspect(value)}"}
  end

  defp validate_type(:atom_list, _name, value) when is_list(value) do
    if Enum.all?(value, &is_atom/1) do
      :ok
    else
      {:error, "expected a list of atoms, got non-atom elements"}
    end
  end

  defp validate_type(:atom_list, name, value) do
    {:error, "#{name} must be a list of atoms, got: #{inspect(value)}"}
  end

  defp validate_type(:map_or_nil, _name, nil), do: :ok
  defp validate_type(:map_or_nil, _name, value) when is_map(value), do: :ok

  defp validate_type(:map_or_nil, name, value) do
    {:error, "#{name} must be a map or nil, got: #{inspect(value)}"}
  end

  defp validate_type(:map_list, _name, value) when is_list(value) do
    if Enum.all?(value, &is_map/1) do
      :ok
    else
      {:error, "expected a list of maps, got non-map elements"}
    end
  end

  defp validate_type(:map_list, name, value) do
    {:error, "#{name} must be a list of maps, got: #{inspect(value)}"}
  end

  defp validate_type(:float_or_nil, _name, nil), do: :ok
  defp validate_type(:float_or_nil, _name, value) when is_float(value) and value > 0, do: :ok
  defp validate_type(:float_or_nil, _name, value) when is_integer(value) and value > 0, do: :ok

  defp validate_type(:float_or_nil, name, value) do
    {:error, "#{name} must be a positive number or nil, got: #{inspect(value)}"}
  end

  # :any is used for options whose values are complex types (lists of atoms,
  # nested keywords) that don't fit the simple type validators. Agent hooks use
  # it because they are normalized by MingaAgent.Config into typed structs.
  defp validate_type(:any, _name, _value), do: :ok

  defp validate_type(:theme_atom, _name, value) when is_atom(value) do
    available = Minga.Config.ThemeRegistry.available()

    if value in available do
      :ok
    else
      {:error, "theme must be one of #{inspect(available)}, got: #{inspect(value)}"}
    end
  end

  defp validate_type(:theme_atom, _name, value) do
    {:error, "theme must be a theme name atom, got: #{inspect(value)}"}
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  @spec maybe_append([String.t()], boolean(), String.t()) :: [String.t()]
  defp maybe_append(chain, true, label), do: chain ++ [label]
  defp maybe_append(chain, false, _label), do: chain

  @spec global_override?(server(), atom()) :: boolean()
  defp global_override?(server, name) do
    case Map.fetch(@defaults, name) do
      {:ok, default} -> get(server, name) != default
      :error -> false
    end
  end

  @spec filetype_override?(server(), atom(), atom() | nil) :: boolean()
  defp filetype_override?(_server, _name, nil), do: false

  defp filetype_override?(server, name, filetype) when is_atom(filetype) do
    table = table_name(server)
    :ets.lookup(table, {:filetype, filetype, name}) != []
  rescue
    ArgumentError -> false
  end

  @spec extension_specs(atom(), [Minga.Extension.option_spec()]) :: [extension_option_metadata()]
  defp extension_specs(extension, schema) do
    Enum.map(schema, fn {name, type, default, description} ->
      %{
        extension: extension,
        name: name,
        type: type,
        default: default,
        description: description
      }
    end)
  end

  @spec extension_global_override?(server(), atom(), atom()) :: boolean()
  defp extension_global_override?(server, extension, name) do
    case describe_extension_option(server, extension, name) do
      %{default: default} -> get_extension_option(server, extension, name) != default
      nil -> false
    end
  end

  @spec extension_filetype_override?(server(), atom(), atom(), atom() | nil) :: boolean()
  defp extension_filetype_override?(_server, _extension, _name, nil), do: false

  defp extension_filetype_override?(server, extension, name, filetype) when is_atom(filetype) do
    table = table_name(server)
    :ets.lookup(table, {:filetype, filetype, {:extension, extension, name}}) != []
  rescue
    ArgumentError -> false
  end

  @spec extension_default(:ets.table(), atom(), atom()) :: term() | nil
  defp extension_default(table, ext_name, opt_name) do
    case :ets.lookup(table, {:extension_default, ext_name, opt_name}) do
      [{_, default}] -> default
      [] -> nil
    end
  end

  @spec validate_extension_value(:ets.table(), atom(), atom(), term()) ::
          :ok | {:error, String.t()}
  defp validate_extension_value(table, ext_name, opt_name, value) do
    case :ets.lookup(table, {:extension_type, ext_name, opt_name}) do
      [{_, type}] -> validate_type(type, opt_name, value)
      [] -> {:error, "extension #{ext_name}: unknown option #{inspect(opt_name)}"}
    end
  end

  @spec table_name(GenServer.server()) :: :ets.table()
  defp table_name(name) when is_atom(name), do: :"#{name}_ets"
  defp table_name(pid) when is_pid(pid), do: GenServer.call(pid, :table_name)

  @spec seed_defaults(:ets.table()) :: true
  defp seed_defaults(table) do
    entries = Enum.map(@defaults, fn {name, value} -> {name, value} end)
    :ets.insert(table, entries ++ @filetype_defaults)
  end

  @spec seed_runtime_metadata(:ets.table(), server(), Minga.Events.registry()) :: true
  defp seed_runtime_metadata(table, source, events_registry) do
    :ets.insert(table, [
      {{:__metadata__, :source}, source},
      {{:__metadata__, :events_registry}, events_registry}
    ])
  end

  @spec option_source(:ets.table(), server()) :: server()
  defp option_source(table, fallback) do
    case :ets.lookup(table, {:__metadata__, :source}) do
      [{{:__metadata__, :source}, source}] -> source
      [] -> fallback
    end
  end

  @spec broadcast_reset_option(option_name(), term(), term(), server(), Minga.Events.registry()) ::
          :ok
  defp broadcast_reset_option(_name, value, value, _source, _events_registry), do: :ok

  defp broadcast_reset_option(name, _previous_value, value, source, events_registry) do
    Minga.Events.broadcast(
      :option_changed,
      %Minga.Events.OptionChangedEvent{source: source, name: name, value: value},
      events_registry
    )
  end

  @spec option_events_registry(:ets.table()) :: Minga.Events.registry()
  defp option_events_registry(table) do
    case :ets.lookup(table, {:__metadata__, :events_registry}) do
      [{{:__metadata__, :events_registry}, events_registry}] -> events_registry
      [] -> Minga.Events.default_registry()
    end
  end

  @impl GenServer
  def handle_call(:table_name, _from, %{table: table} = state) do
    {:reply, table, state}
  end
end
