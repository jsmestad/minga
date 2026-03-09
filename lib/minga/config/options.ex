defmodule Minga.Config.Options do
  @moduledoc """
  Central registry for typed editor options.

  Stores global option values and per-filetype overrides. Other modules
  read options via `get/1` (global) or `get_for_filetype/2` (merged with
  filetype overrides).

  ## Supported options

  | Option          | Type                                          | Default   |
  |-----------------|-----------------------------------------------|-----------|
  | `:tab_width`    | positive integer                               | `2`       |
  | `:line_numbers` | `:hybrid`, `:absolute`, `:relative`, `:none`   | `:hybrid` |
  | `:autopair`     | boolean                                        | `true`    |
  | `:scroll_margin`| non-negative integer                           | `5`       |
  | `:theme`        | theme name atom (see `Minga.Theme.available/0`) | `:doom_one`|
  | `:indent_with`  | `:spaces` or `:tabs`                            | `:spaces`  |
  | `:trim_trailing_whitespace` | boolean                             | `false`    |
  | `:insert_final_newline`     | boolean                             | `false`    |
  | `:format_on_save`           | boolean                             | `false`    |
  | `:formatter`    | string or `nil`                                  | `nil`      |
  | `:title_format` | string with `{placeholder}` tokens               | `"{filename} {dirty}({directory}) - Minga"` |
  | `:recent_files_limit` | positive integer                            | `200`      |
  | `:persist_recent_files` | boolean                                  | `true`     |
  | `:scratch_filetype`     | filetype atom                              | `:markdown`|
  | `:wrap`                 | boolean                                    | `false`    |
  | `:linebreak`            | boolean                                    | `true`     |
  | `:breakindent`          | boolean                                    | `true`     |
  | `:agent_tool_approval`  | `:destructive`, `:all`, or `:none`          | `:destructive` |
  | `:agent_destructive_tools` | list of tool name strings                | `["write_file", "edit_file", "shell"]` |
  | `:agent_panel_split`      | positive integer (30-80)                   | `65`       |
  | `:font_family`            | string (font name)                          | `"Menlo"`   |
  | `:font_size`              | positive integer (point size)               | `13`        |
  | `:font_weight`            | `:thin` / `:light` / `:regular` / `:medium` / `:semibold` / `:bold` / `:heavy` / `:black` | `:regular` |
  | `:font_ligatures`         | boolean                                     | `true`      |

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

  use Agent

  @typedoc "Valid option names."
  @type option_name ::
          :tab_width
          | :line_numbers
          | :autopair
          | :scroll_margin
          | :theme
          | :indent_with
          | :trim_trailing_whitespace
          | :insert_final_newline
          | :format_on_save
          | :formatter
          | :title_format
          | :recent_files_limit
          | :persist_recent_files
          | :scratch_filetype
          | :clipboard
          | :wrap
          | :linebreak
          | :breakindent
          | :agent_provider
          | :agent_model
          | :agent_tool_approval
          | :agent_destructive_tools
          | :agent_session_retention_days
          | :agent_panel_split
          | :font_family
          | :font_size
          | :font_weight
          | :font_ligatures

  @typedoc "Line number display style."
  @type line_number_style :: :hybrid | :absolute | :relative | :none

  @typedoc "Option spec: `{name, type_descriptor, default_value}`."
  @type option_spec :: {option_name(), type_descriptor(), term()}

  @typep type_descriptor ::
           :pos_integer
           | :non_neg_integer
           | :boolean
           | :atom
           | {:enum, [atom()]}
           | :theme_atom
           | :string_or_nil
           | :string_list

  @typedoc "Internal state: global options + per-filetype overrides."
  @type state :: %{
          global: %{option_name() => term()},
          filetype: %{atom() => %{option_name() => term()}}
        }

  @option_specs [
    {:tab_width, :pos_integer, 2},
    {:line_numbers, {:enum, [:hybrid, :absolute, :relative, :none]}, :hybrid},
    {:autopair, :boolean, true},
    {:scroll_margin, :non_neg_integer, 5},
    {:theme, :theme_atom, :doom_one},
    {:indent_with, {:enum, [:spaces, :tabs]}, :spaces},
    {:trim_trailing_whitespace, :boolean, false},
    {:insert_final_newline, :boolean, false},
    {:format_on_save, :boolean, false},
    {:formatter, :string_or_nil, nil},
    {:title_format, :string, "{filename} {dirty}({directory}) - Minga"},
    {:recent_files_limit, :pos_integer, 200},
    {:persist_recent_files, :boolean, true},
    {:scratch_filetype, :atom, :markdown},
    {:clipboard, {:enum, [:unnamedplus, :unnamed, :none]}, :unnamedplus},
    {:wrap, :boolean, false},
    {:linebreak, :boolean, true},
    {:breakindent, :boolean, true},
    {:agent_provider, {:enum, [:auto, :native, :pi_rpc]}, :auto},
    {:agent_model, :string_or_nil, nil},
    {:agent_tool_approval, {:enum, [:destructive, :all, :none]}, :destructive},
    {:agent_destructive_tools, :string_list, ["write_file", "edit_file", "shell"]},
    {:agent_session_retention_days, :pos_integer, 30},
    {:agent_panel_split, :pos_integer, 65},
    {:font_family, :string, "Menlo"},
    {:font_size, :pos_integer, 13},
    {:font_weight, {:enum, [:thin, :light, :regular, :medium, :semibold, :bold, :heavy, :black]},
     :regular},
    {:font_ligatures, :boolean, true}
  ]

  @valid_names Enum.map(@option_specs, &elem(&1, 0))

  @defaults Map.new(@option_specs, fn {name, _type, default} -> {name, default} end)

  @types Map.new(@option_specs, fn {name, type, _default} -> {name, type} end)

  # ── Client API ──────────────────────────────────────────────────────────────

  @doc "Starts the options registry."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    {name, _opts} = Keyword.pop(opts, :name, __MODULE__)
    Agent.start_link(fn -> %{global: @defaults, filetype: %{}} end, name: name)
  end

  @doc """
  Sets a global option value after type validation.

  Returns `{:ok, value}` on success or `{:error, reason}` if the option
  name is unknown or the value has the wrong type.
  """
  @spec set(option_name(), term()) :: {:ok, term()} | {:error, String.t()}
  @spec set(GenServer.server(), option_name(), term()) :: {:ok, term()} | {:error, String.t()}
  def set(name, value) when is_atom(name), do: set(__MODULE__, name, value)

  def set(server, name, value) when is_atom(name) do
    case validate(name, value) do
      :ok ->
        Agent.update(server, fn %{global: g} = state ->
          %{state | global: Map.put(g, name, value)}
        end)

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
    Agent.get(server, fn %{global: g} ->
      Map.get(g, name, Map.get(@defaults, name))
    end)
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
    Agent.get(server, fn %{global: g, filetype: ft} ->
      ft_opts = Map.get(ft, filetype, %{})

      case Map.fetch(ft_opts, name) do
        {:ok, value} -> value
        :error -> Map.get(g, name, Map.get(@defaults, name))
      end
    end)
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
    case validate(name, value) do
      :ok ->
        Agent.update(server, fn %{filetype: ft} = state ->
          ft_opts = Map.get(ft, filetype, %{})
          %{state | filetype: Map.put(ft, filetype, Map.put(ft_opts, name, value))}
        end)

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
  def all(server), do: Agent.get(server, & &1.global)

  @doc """
  Resets all options (global and per-filetype) to defaults.
  """
  @spec reset() :: :ok
  @spec reset(GenServer.server()) :: :ok
  def reset, do: reset(__MODULE__)
  def reset(server), do: Agent.update(server, fn _ -> %{global: @defaults, filetype: %{}} end)

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

  @spec validate(atom(), term()) :: :ok | {:error, String.t()}
  defp validate(name, value) do
    case Map.fetch(@types, name) do
      {:ok, type} -> validate_type(type, name, value)
      :error -> {:error, "unknown option: #{inspect(name)}"}
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
end
