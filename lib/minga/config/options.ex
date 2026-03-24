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

  | Option          | Type                                          | Default   |
  |-----------------|-----------------------------------------------|-----------|
  | `:tab_width`    | positive integer                               | `2`       |
  | `:line_numbers` | `:hybrid`, `:absolute`, `:relative`, `:none`   | `:hybrid` |
  | `:autopair`     | boolean                                        | `true`    |
  | `:scroll_margin`| non-negative integer                           | `5`       |
  | `:scroll_lines` | positive integer                               | `1`       |
  | `:theme`        | theme name atom (see `Minga.Theme.available/0`) | `:doom_one`|
  | `:indent_with`  | `:spaces` or `:tabs`                            | `:spaces`  |
  | `:trim_trailing_whitespace` | boolean                             | `false`    |
  | `:insert_final_newline`     | boolean                             | `false`    |
  | `:format_on_save`           | boolean                             | `false`    |
  | `:formatter`    | string or `nil`                                  | `nil`      |
  | `:title_format` | string with `{placeholder}` tokens               | `"{filename} {dirty}({directory}) - Minga"` |
  | `:recent_files_limit` | positive integer                            | `200`      |
  | `:persist_recent_files` | boolean                                  | `true`     |
  | `:wrap`                 | boolean                                    | `false`    |
  | `:linebreak`            | boolean                                    | `true`     |
  | `:breakindent`          | boolean                                    | `true`     |
  | `:agent_tool_approval`  | `:destructive`, `:all`, or `:none`          | `:destructive` |
  | `:agent_destructive_tools` | list of tool name strings                | `["write_file", "edit_file", "shell"]` |
  | `:agent_panel_split`      | positive integer (30-80)                   | `65`       |
  | `:startup_view`           | `:agent` or `:editor`                       | `:agent`   |
  | `:agent_auto_context`     | boolean                                     | `true`     |
  | `:font_family`            | string (font name)                          | `"Menlo"`   |
  | `:font_size`              | positive integer (point size)               | `13`        |
  | `:font_weight`            | `:thin` / `:light` / `:regular` / `:medium` / `:semibold` / `:bold` / `:heavy` / `:black` | `:regular` |
  | `:font_ligatures`         | boolean                                     | `true`      |
  | `:font_fallback`          | list of font family strings                 | `[]`        |
  | `:prettify_symbols`       | boolean                                     | `false`     |
  | `:whichkey_layout`        | `:bottom` or `:float`                       | `:bottom`   |
  | `:cursorline`             | boolean                                        | `true`    |
  | `:nav_flash`              | boolean                                        | `true`    |
  | `:nav_flash_threshold`    | positive integer                               | `5`       |
  | `:log_level`              | `:debug` / `:info` / `:warning` / `:error` / `:none` | `:info` |
  | `:log_level_render`       | log level or `:default`                     | `:default`  |
  | `:log_level_lsp`          | log level or `:default`                     | `:default`  |
  | `:log_level_agent`        | log level or `:default`                     | `:default`  |
  | `:log_level_editor`       | log level or `:default`                     | `:default`  |
  | `:log_level_config`       | log level or `:default`                     | `:default`  |
  | `:log_level_port`         | log level or `:default`                     | `:default`  |
  | `:event_retention_days`   | positive integer (days to keep event log)    | `90`        |

  Log level options control per-subsystem verbosity. Subsystem options
  default to `:default` (inherit from `:log_level`). See `Minga.Log`
  for the filtering API.

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
          | :space_leader_timeout
          | :tab_width
          | :line_numbers
          | :show_gutter_separator
          | :autopair
          | :scroll_margin
          | :scroll_lines
          | :theme
          | :indent_with
          | :trim_trailing_whitespace
          | :insert_final_newline
          | :format_on_save
          | :formatter
          | :title_format
          | :recent_files_limit
          | :persist_recent_files
          | :clipboard
          | :wrap
          | :linebreak
          | :breakindent
          | :agent_provider
          | :agent_model
          | :agent_tool_approval
          | :agent_destructive_tools
          | :agent_tool_permissions
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
          | :agent_compaction_threshold
          | :agent_compaction_keep_recent
          | :agent_approval_timeout
          | :agent_subagent_timeout
          | :agent_mention_max_file_size
          | :agent_notify_debounce
          | :confirm_quit
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
          | :nav_flash
          | :nav_flash_threshold
          | :log_level_config
          | :log_level_port
          | :parser_tree_ttl
          | :event_retention_days

  @typedoc "Line number display style."
  @type line_number_style :: :hybrid | :absolute | :relative | :none

  @typedoc "Option spec: `{name, type_descriptor, default_value}`."
  @type option_spec :: {option_name(), type_descriptor(), term()}

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
          | :map_or_nil
          | :float_or_nil
          | :any

  @typedoc "ETS table reference used for reads and writes."
  @type table :: :ets.table()

  @option_specs [
    {:editing_model, {:enum, [:vim, :cua]}, :vim},
    {:space_leader, {:enum, [:chord, :off]}, :chord},
    {:space_leader_timeout, :pos_integer, 200},
    {:tab_width, :pos_integer, 2},
    {:line_numbers, {:enum, [:hybrid, :absolute, :relative, :none]}, :hybrid},
    {:show_gutter_separator, :boolean, true},
    {:autopair, :boolean, true},
    {:scroll_margin, :non_neg_integer, 5},
    {:scroll_lines, :pos_integer, 1},
    {:theme, :theme_atom, :doom_one},
    {:indent_with, {:enum, [:spaces, :tabs]}, :spaces},
    {:trim_trailing_whitespace, :boolean, false},
    {:insert_final_newline, :boolean, false},
    {:format_on_save, :boolean, false},
    {:formatter, :string_or_nil, nil},
    {:title_format, :string, "{filename} {dirty}({directory}) - Minga"},
    {:recent_files_limit, :pos_integer, 200},
    {:persist_recent_files, :boolean, true},
    {:clipboard, {:enum, [:unnamedplus, :unnamed, :none]}, :unnamedplus},
    {:wrap, :boolean, false},
    {:linebreak, :boolean, true},
    {:breakindent, :boolean, true},
    {:agent_provider, {:enum, [:auto, :native, :pi_rpc]}, :auto},
    {:agent_model, :string_or_nil, nil},
    {:agent_tool_approval, {:enum, [:destructive, :all, :none]}, :destructive},
    {:agent_destructive_tools, :string_list,
     ["write_file", "edit_file", "multi_edit_file", "shell"]},
    {:agent_tool_permissions, :map_or_nil, nil},
    {:agent_session_retention_days, :pos_integer, 30},
    {:agent_panel_split, :pos_integer, 65},
    {:startup_view, {:enum, [:agent, :editor]}, :agent},
    {:agent_auto_context, :boolean, true},
    {:agent_max_tokens, :pos_integer, 16_384},
    {:agent_max_retries, :non_neg_integer, 3},
    {:agent_models, :string_list, []},
    {:agent_prompt_cache, :boolean, true},
    {:agent_notifications, :boolean, true},
    {:agent_notify_on, :any, [:approval, :complete, :error]},
    {:agent_system_prompt, :string, ""},
    {:agent_append_system_prompt, :string, ""},
    {:agent_diff_size_threshold, :pos_integer, 1_048_576},
    {:agent_max_turns, :pos_integer, 100},
    {:agent_max_cost, :float_or_nil, nil},
    {:agent_api_base_url, :string, ""},
    {:agent_api_endpoints, :map_or_nil, nil},
    {:agent_compaction_threshold, :float_or_nil, 0.8},
    {:agent_compaction_keep_recent, :pos_integer, 6},
    {:agent_approval_timeout, :pos_integer, 300_000},
    {:agent_subagent_timeout, :pos_integer, 300_000},
    {:agent_mention_max_file_size, :pos_integer, 262_144},
    {:agent_notify_debounce, :pos_integer, 5_000},
    {:confirm_quit, :boolean, true},
    {:cursorline, :boolean, true},
    {:nav_flash, :boolean, true},
    {:nav_flash_threshold, :pos_integer, 5},
    {:whichkey_layout, {:enum, [:bottom, :float]}, :bottom},
    {:font_family, :string, "Menlo"},
    {:font_size, :pos_integer, 13},
    {:font_weight, {:enum, [:thin, :light, :regular, :medium, :semibold, :bold, :heavy, :black]},
     :regular},
    {:font_ligatures, :boolean, true},
    {:font_fallback, :string_list, []},
    {:prettify_symbols, :boolean, false},
    {:log_level, {:enum, [:debug, :info, :warning, :error, :none]}, :info},
    {:log_level_render, {:enum, [:default, :debug, :info, :warning, :error, :none]}, :default},
    {:log_level_lsp, {:enum, [:default, :debug, :info, :warning, :error, :none]}, :default},
    {:log_level_agent, {:enum, [:default, :debug, :info, :warning, :error, :none]}, :default},
    {:log_level_editor, {:enum, [:default, :debug, :info, :warning, :error, :none]}, :default},
    {:log_level_config, {:enum, [:default, :debug, :info, :warning, :error, :none]}, :default},
    {:log_level_port, {:enum, [:default, :debug, :info, :warning, :error, :none]}, :default},
    {:parser_tree_ttl, :integer, 300},
    {:event_retention_days, :pos_integer, 90}
  ]

  @valid_names Enum.map(@option_specs, &elem(&1, 0))

  @defaults Map.new(@option_specs, fn {name, _type, default} -> {name, default} end)

  @types Map.new(@option_specs, fn {name, type, _default} -> {name, type} end)

  # ── GenServer (table lifecycle only) ────────────────────────────────────────

  @doc "Starts the options registry and creates the backing ETS table."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, _opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, name, name: name)
  end

  @impl GenServer
  def init(name) do
    table = :ets.new(table_name(name), [:set, :public, :named_table, read_concurrency: true])
    seed_defaults(table)
    {:ok, %{table: table}}
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
  @spec register_extension_schema(atom(), [Minga.Extension.option_spec()], keyword()) ::
          :ok | {:error, String.t()}
  @spec register_extension_schema(
          GenServer.server(),
          atom(),
          [Minga.Extension.option_spec()],
          keyword()
        ) ::
          :ok | {:error, String.t()}
  def register_extension_schema(ext_name, schema, user_config) when is_atom(ext_name),
    do: register_extension_schema(__MODULE__, ext_name, schema, user_config)

  def register_extension_schema(server, ext_name, schema, user_config)
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
  @spec get_extension_option(atom(), atom()) :: term()
  @spec get_extension_option(GenServer.server(), atom(), atom()) :: term()
  def get_extension_option(ext_name, opt_name) when is_atom(ext_name) and is_atom(opt_name),
    do: get_extension_option(__MODULE__, ext_name, opt_name)

  def get_extension_option(server, ext_name, opt_name)
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
  @spec set_extension_option(atom(), atom(), term()) :: {:ok, term()} | {:error, String.t()}
  @spec set_extension_option(GenServer.server(), atom(), atom(), term()) ::
          {:ok, term()} | {:error, String.t()}
  def set_extension_option(ext_name, opt_name, value)
      when is_atom(ext_name) and is_atom(opt_name),
      do: set_extension_option(__MODULE__, ext_name, opt_name, value)

  def set_extension_option(server, ext_name, opt_name, value)
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
  @spec set_extension_option_for_filetype(atom(), atom(), atom(), term()) ::
          {:ok, term()} | {:error, String.t()}
  @spec set_extension_option_for_filetype(GenServer.server(), atom(), atom(), atom(), term()) ::
          {:ok, term()} | {:error, String.t()}
  def set_extension_option_for_filetype(ext_name, filetype, opt_name, value)
      when is_atom(ext_name) and is_atom(filetype) and is_atom(opt_name),
      do: set_extension_option_for_filetype(__MODULE__, ext_name, filetype, opt_name, value)

  def set_extension_option_for_filetype(server, ext_name, filetype, opt_name, value)
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
  @spec get_extension_option_for_filetype(atom(), atom(), atom() | nil) :: term()
  @spec get_extension_option_for_filetype(GenServer.server(), atom(), atom(), atom() | nil) ::
          term()
  def get_extension_option_for_filetype(ext_name, opt_name, filetype),
    do: get_extension_option_for_filetype(__MODULE__, ext_name, opt_name, filetype)

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
  @spec extension_schema(atom()) :: [Minga.Extension.option_spec()] | nil
  @spec extension_schema(GenServer.server(), atom()) :: [Minga.Extension.option_spec()] | nil
  def extension_schema(ext_name) when is_atom(ext_name),
    do: extension_schema(__MODULE__, ext_name)

  def extension_schema(server, ext_name) when is_atom(ext_name) do
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
  @spec extension_option_description(atom(), atom()) :: String.t() | nil
  @spec extension_option_description(GenServer.server(), atom(), atom()) :: String.t() | nil
  def extension_option_description(ext_name, opt_name),
    do: extension_option_description(__MODULE__, ext_name, opt_name)

  def extension_option_description(server, ext_name, opt_name)
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
  @spec set(option_name(), term()) :: {:ok, term()} | {:error, String.t()}
  @spec set(GenServer.server(), option_name(), term()) :: {:ok, term()} | {:error, String.t()}
  def set(name, value) when is_atom(name), do: set(__MODULE__, name, value)

  def set(server, name, value) when is_atom(name) do
    case validate(server, name, value) do
      :ok ->
        :ets.insert(table_name(server), {name, value})
        {:ok, value}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Gets the current global value of an option, falling back to its default.
  """
  @spec get(option_name()) :: term()
  @spec get(GenServer.server(), option_name()) :: term()
  def get(name) when is_atom(name), do: get(__MODULE__, name)

  def get(server, name) when is_atom(name) do
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
  @spec get_for_filetype(option_name(), atom() | nil) :: term()
  @spec get_for_filetype(GenServer.server(), option_name(), atom() | nil) :: term()
  def get_for_filetype(name, filetype) when is_atom(name),
    do: get_for_filetype(__MODULE__, name, filetype)

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
  @spec set_for_filetype(atom(), option_name(), term()) :: {:ok, term()} | {:error, String.t()}
  @spec set_for_filetype(GenServer.server(), atom(), option_name(), term()) ::
          {:ok, term()} | {:error, String.t()}
  def set_for_filetype(filetype, name, value)
      when is_atom(filetype) and is_atom(name),
      do: set_for_filetype(__MODULE__, filetype, name, value)

  def set_for_filetype(server, filetype, name, value)
      when is_atom(filetype) and is_atom(name) do
    case validate(server, name, value) do
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
  @spec all() :: %{option_name() => term()}
  @spec all(GenServer.server()) :: %{option_name() => term()}
  def all, do: all(__MODULE__)

  def all(server) do
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
  @spec reset() :: :ok
  @spec reset(GenServer.server()) :: :ok
  def reset, do: reset(__MODULE__)

  def reset(server) do
    table = table_name(server)
    :ets.delete_all_objects(table)
    seed_defaults(table)
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

  # ── Validation ──────────────────────────────────────────────────────────────

  @doc """
  Validates an option name and value against the type registry.

  Returns `:ok` if valid, or `{:error, reason}` if the name is unknown
  or the value has the wrong type. Used by `Buffer.Server.set_option/3`
  to validate buffer-local option overrides.
  """
  @spec validate_option(atom(), term()) :: :ok | {:error, String.t()}
  def validate_option(name, value), do: validate(__MODULE__, name, value)

  @spec validate(GenServer.server(), atom(), term()) :: :ok | {:error, String.t()}
  defp validate(_server, name, value) do
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

  defp validate_type(:map_or_nil, _name, nil), do: :ok
  defp validate_type(:map_or_nil, _name, value) when is_map(value), do: :ok

  defp validate_type(:map_or_nil, name, value) do
    {:error, "#{name} must be a map or nil, got: #{inspect(value)}"}
  end

  defp validate_type(:float_or_nil, _name, nil), do: :ok
  defp validate_type(:float_or_nil, _name, value) when is_float(value) and value > 0, do: :ok
  defp validate_type(:float_or_nil, _name, value) when is_integer(value) and value > 0, do: :ok

  defp validate_type(:float_or_nil, name, value) do
    {:error, "#{name} must be a positive number or nil, got: #{inspect(value)}"}
  end

  # :any is used for options whose values are complex types (lists of atoms,
  # nested keywords) that don't fit the simple type validators. Currently only
  # used by :agent_notify_on which accepts a list of event atoms.
  defp validate_type(:any, _name, _value), do: :ok

  defp validate_type(:theme_atom, _name, value) when is_atom(value) do
    if value in Minga.Theme.available() do
      :ok
    else
      {:error, "theme must be one of #{inspect(Minga.Theme.available())}, got: #{inspect(value)}"}
    end
  end

  defp validate_type(:theme_atom, _name, value) do
    {:error, "theme must be a theme name atom, got: #{inspect(value)}"}
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

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

  @spec table_name(GenServer.server()) :: atom()
  defp table_name(name) when is_atom(name), do: :"#{name}_ets"
  defp table_name(pid) when is_pid(pid), do: GenServer.call(pid, :table_name)

  @spec seed_defaults(:ets.table()) :: true
  defp seed_defaults(table) do
    entries = Enum.map(@defaults, fn {name, value} -> {name, value} end)
    :ets.insert(table, entries)
  end

  @impl GenServer
  def handle_call(:table_name, _from, %{table: table} = state) do
    {:reply, table, state}
  end
end
