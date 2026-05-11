defmodule MingaAgent.Hooks.Hook do
  @moduledoc """
  Normalized agent hook declaration.

  Hooks are declared in user config as maps or keyword lists, then normalized
  by `MingaAgent.Config.resolve/0` into this struct. The event field selects
  the lifecycle point; `tool_pattern` is required only for tool-related events
  (`:pre_tool_use`, `:post_tool_use`).
  """

  @default_timeout_ms 30_000

  @tool_events [:pre_tool_use, :post_tool_use]

  @typedoc "Supported hook event names."
  @type event ::
          :pre_tool_use
          | :post_tool_use
          | :session_start
          | :session_end
          | :stop
          | :user_prompt_submit
          | :pre_compact
          | :notification

  @typedoc "Hook type: shell command or in-process Elixir module."
  @type hook_type :: :shell | :module

  @typedoc "Normalized hook declaration."
  @type t :: %__MODULE__{
          event: event(),
          type: hook_type(),
          tool_pattern: String.t() | nil,
          command: String.t() | nil,
          module: module() | nil,
          function: atom() | nil,
          timeout_ms: pos_integer()
        }

  @enforce_keys [:event]
  defstruct [:event, :tool_pattern, :command, :module, :function, type: :shell, timeout_ms: @default_timeout_ms]

  @doc "Returns the default per-hook timeout in milliseconds."
  @spec default_timeout_ms() :: pos_integer()
  def default_timeout_ms, do: @default_timeout_ms

  @doc "Normalizes a user config hook declaration into a `%Hook{}`."
  @spec normalize(term()) :: {:ok, t()} | {:error, String.t()}
  def normalize(raw) when is_list(raw) do
    case map_from_list(raw) do
      {:ok, map} -> normalize(map)
      :error -> {:error, "agent hook must be a map or keyword list"}
    end
  end

  def normalize(raw) when is_map(raw) do
    with {:ok, event} <- normalize_event(fetch(raw, :event)),
         {:ok, type} <- normalize_type(raw),
         {:ok, tool_pattern} <- normalize_tool_pattern(raw, event),
         {:ok, fields} <- normalize_type_fields(raw, type),
         {:ok, timeout_ms} <- normalize_timeout(fetch(raw, :timeout_ms)) do
      {:ok,
       %__MODULE__{
         event: event,
         type: type,
         tool_pattern: tool_pattern,
         timeout_ms: timeout_ms
       }
       |> Map.merge(fields)}
    end
  end

  def normalize(_raw), do: {:error, "agent hook must be a map or keyword list"}

  @doc "Returns true when this hook applies to the given non-tool event."
  @spec matches?(t(), event()) :: boolean()
  def matches?(%__MODULE__{event: event}, event), do: true
  def matches?(%__MODULE__{}, _event), do: false

  @doc "Returns true when this hook applies to the event and tool name."
  @spec matches?(t(), event(), String.t()) :: boolean()
  def matches?(%__MODULE__{event: event, tool_pattern: pattern}, event, tool_name)
      when is_binary(tool_name) do
    match_tool_pattern?(pattern, tool_name)
  end

  def matches?(%__MODULE__{}, _event, _tool_name), do: false

  @doc "Returns true if the event is tool-related and uses `tool_pattern` matching."
  @spec tool_event?(event()) :: boolean()
  def tool_event?(event), do: event in @tool_events

  @doc "Returns the human-readable label for an event atom."
  @spec event_label(event()) :: String.t()
  def event_label(:pre_tool_use), do: "PreToolUse"
  def event_label(:post_tool_use), do: "PostToolUse"
  def event_label(:session_start), do: "SessionStart"
  def event_label(:session_end), do: "SessionEnd"
  def event_label(:stop), do: "Stop"
  def event_label(:user_prompt_submit), do: "UserPromptSubmit"
  def event_label(:pre_compact), do: "PreCompact"
  def event_label(:notification), do: "Notification"

  @spec map_from_list(list()) :: {:ok, map()} | :error
  defp map_from_list(raw) do
    {:ok, Map.new(raw)}
  rescue
    ArgumentError -> :error
  end

  @spec normalize_event(term()) :: {:ok, event()} | {:error, String.t()}
  defp normalize_event(nil), do: {:error, "agent hook requires :event"}
  defp normalize_event(:pre_tool_use), do: {:ok, :pre_tool_use}
  defp normalize_event(:PreToolUse), do: {:ok, :pre_tool_use}
  defp normalize_event("PreToolUse"), do: {:ok, :pre_tool_use}
  defp normalize_event("pre_tool_use"), do: {:ok, :pre_tool_use}
  defp normalize_event(:post_tool_use), do: {:ok, :post_tool_use}
  defp normalize_event(:PostToolUse), do: {:ok, :post_tool_use}
  defp normalize_event("PostToolUse"), do: {:ok, :post_tool_use}
  defp normalize_event("post_tool_use"), do: {:ok, :post_tool_use}
  defp normalize_event(:session_start), do: {:ok, :session_start}
  defp normalize_event(:SessionStart), do: {:ok, :session_start}
  defp normalize_event("SessionStart"), do: {:ok, :session_start}
  defp normalize_event("session_start"), do: {:ok, :session_start}
  defp normalize_event(:session_end), do: {:ok, :session_end}
  defp normalize_event(:SessionEnd), do: {:ok, :session_end}
  defp normalize_event("SessionEnd"), do: {:ok, :session_end}
  defp normalize_event("session_end"), do: {:ok, :session_end}
  defp normalize_event(:stop), do: {:ok, :stop}
  defp normalize_event(:Stop), do: {:ok, :stop}
  defp normalize_event("Stop"), do: {:ok, :stop}
  defp normalize_event("stop"), do: {:ok, :stop}
  defp normalize_event(:user_prompt_submit), do: {:ok, :user_prompt_submit}
  defp normalize_event(:UserPromptSubmit), do: {:ok, :user_prompt_submit}
  defp normalize_event("UserPromptSubmit"), do: {:ok, :user_prompt_submit}
  defp normalize_event("user_prompt_submit"), do: {:ok, :user_prompt_submit}
  defp normalize_event(:pre_compact), do: {:ok, :pre_compact}
  defp normalize_event(:PreCompact), do: {:ok, :pre_compact}
  defp normalize_event("PreCompact"), do: {:ok, :pre_compact}
  defp normalize_event("pre_compact"), do: {:ok, :pre_compact}
  defp normalize_event(:notification), do: {:ok, :notification}
  defp normalize_event(:Notification), do: {:ok, :notification}
  defp normalize_event("Notification"), do: {:ok, :notification}
  defp normalize_event("notification"), do: {:ok, :notification}
  defp normalize_event(other), do: {:error, "unsupported agent hook event: #{inspect(other)}"}

  @spec normalize_tool_pattern(map(), event()) :: {:ok, String.t() | nil} | {:error, String.t()}
  defp normalize_tool_pattern(raw, event) do
    value =
      raw
      |> fetch(:tool_pattern)
      |> fallback(fetch(raw, :tool))

    if event in @tool_events do
      normalize_non_empty_string(value, "agent hook requires :tool_pattern or :tool")
    else
      {:ok, nil}
    end
  end

  @spec normalize_type(map()) :: {:ok, hook_type()} | {:error, String.t()}
  defp normalize_type(raw) do
    case fetch(raw, :type) do
      nil ->
        cond do
          fetch(raw, :module) != nil -> {:ok, :module}
          true -> {:ok, :shell}
        end

      :shell -> {:ok, :shell}
      "shell" -> {:ok, :shell}
      :module -> {:ok, :module}
      "module" -> {:ok, :module}
      other -> {:error, "agent hook type must be :shell or :module, got: #{inspect(other)}"}
    end
  end

  @spec normalize_type_fields(map(), hook_type()) ::
          {:ok, %{command: String.t()} | %{module: module(), function: atom()}}
          | {:error, String.t()}
  defp normalize_type_fields(raw, :shell) do
    case normalize_non_empty_string(fetch(raw, :command), "shell hook requires :command") do
      {:ok, command} -> {:ok, %{command: command}}
      error -> error
    end
  end

  defp normalize_type_fields(raw, :module) do
    with {:ok, mod} <- normalize_module(fetch(raw, :module)),
         {:ok, fun} <- normalize_function(fetch(raw, :function)) do
      {:ok, %{module: mod, function: fun}}
    end
  end

  @spec normalize_module(term()) :: {:ok, module()} | {:error, String.t()}
  defp normalize_module(nil), do: {:error, "module hook requires :module"}
  defp normalize_module(mod) when is_atom(mod), do: {:ok, mod}

  defp normalize_module(mod) when is_binary(mod) do
    {:ok, String.to_existing_atom("Elixir." <> mod)}
  rescue
    ArgumentError -> {:error, "module hook :module #{inspect(mod)} is not a loaded module"}
  end

  defp normalize_module(other), do: {:error, "module hook :module must be an atom, got: #{inspect(other)}"}

  @spec normalize_function(term()) :: {:ok, atom()} | {:error, String.t()}
  defp normalize_function(nil), do: {:error, "module hook requires :function"}
  defp normalize_function(fun) when is_atom(fun), do: {:ok, fun}

  defp normalize_function(fun) when is_binary(fun) do
    {:ok, String.to_existing_atom(fun)}
  rescue
    ArgumentError -> {:error, "module hook :function #{inspect(fun)} is not a known atom"}
  end

  defp normalize_function(other), do: {:error, "module hook :function must be an atom, got: #{inspect(other)}"}

  @spec normalize_timeout(term()) :: {:ok, pos_integer()} | {:error, String.t()}
  defp normalize_timeout(nil), do: {:ok, @default_timeout_ms}
  defp normalize_timeout(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp normalize_timeout(value),
    do: {:error, "agent hook timeout_ms must be a positive integer, got: #{inspect(value)}"}

  @spec normalize_non_empty_string(term(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp normalize_non_empty_string(value, error) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      {:error, error}
    else
      {:ok, value}
    end
  end

  defp normalize_non_empty_string(_value, error), do: {:error, error}

  @spec fetch(map(), atom()) :: term()
  defp fetch(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  @spec fallback(term(), term()) :: term()
  defp fallback(nil, fallback_value), do: fallback_value
  defp fallback(value, _fallback_value), do: value

  @spec match_tool_pattern?(String.t(), String.t()) :: boolean()
  defp match_tool_pattern?("*", _tool_name), do: true

  defp match_tool_pattern?(pattern, tool_name) do
    if String.contains?(pattern, ["*", "?"]) do
      pattern
      |> glob_to_regex()
      |> Regex.match?(tool_name)
    else
      pattern == tool_name
    end
  end

  @spec glob_to_regex(String.t()) :: Regex.t()
  defp glob_to_regex(pattern) do
    pattern
    |> String.graphemes()
    |> Enum.map_join(&glob_char_to_regex/1)
    |> then(&Regex.compile!("^" <> &1 <> "$"))
  end

  @spec glob_char_to_regex(String.t()) :: String.t()
  defp glob_char_to_regex("*"), do: ".*"
  defp glob_char_to_regex("?"), do: "."
  defp glob_char_to_regex(char), do: Regex.escape(char)
end
