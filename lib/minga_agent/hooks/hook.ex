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
          timeout_ms: pos_integer(),
          extension_source: atom() | nil,
          extension_module: module() | nil
        }

  @enforce_keys [:event]
  defstruct [
    :event,
    :tool_pattern,
    :command,
    :module,
    :function,
    :extension_source,
    :extension_module,
    type: :shell,
    timeout_ms: @default_timeout_ms
  ]

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
         {:ok, command, mod, fun} <- normalize_type_fields(raw, type),
         {:ok, timeout_ms} <- normalize_timeout(fetch(raw, :timeout_ms)),
         {:ok, extension_source} <- normalize_optional_atom(fetch(raw, :extension_source)),
         {:ok, extension_module} <- normalize_optional_atom(fetch(raw, :extension_module)) do
      {:ok,
       %__MODULE__{
         event: event,
         type: type,
         tool_pattern: tool_pattern,
         command: command,
         module: mod,
         function: fun,
         timeout_ms: timeout_ms,
         extension_source: extension_source,
         extension_module: extension_module
       }}
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

  @event_aliases Map.new(
                   for {canonical, aliases} <- %{
                         pre_tool_use: [:pre_tool_use, :PreToolUse, "PreToolUse", "pre_tool_use"],
                         post_tool_use: [
                           :post_tool_use,
                           :PostToolUse,
                           "PostToolUse",
                           "post_tool_use"
                         ],
                         session_start: [
                           :session_start,
                           :SessionStart,
                           "SessionStart",
                           "session_start"
                         ],
                         session_end: [:session_end, :SessionEnd, "SessionEnd", "session_end"],
                         stop: [:stop, :Stop, "Stop", "stop"],
                         user_prompt_submit: [
                           :user_prompt_submit,
                           :UserPromptSubmit,
                           "UserPromptSubmit",
                           "user_prompt_submit"
                         ],
                         pre_compact: [:pre_compact, :PreCompact, "PreCompact", "pre_compact"],
                         notification: [
                           :notification,
                           :Notification,
                           "Notification",
                           "notification"
                         ]
                       },
                       alias_val <- aliases,
                       do: {alias_val, canonical}
                 )

  @spec normalize_event(term()) :: {:ok, event()} | {:error, String.t()}
  defp normalize_event(nil), do: {:error, "agent hook requires :event"}

  defp normalize_event(value) do
    case Map.fetch(@event_aliases, value) do
      {:ok, event} -> {:ok, event}
      :error -> {:error, "unsupported agent hook event: #{inspect(value)}"}
    end
  end

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
      nil -> infer_type(raw)
      :shell -> {:ok, :shell}
      "shell" -> {:ok, :shell}
      :module -> {:ok, :module}
      "module" -> {:ok, :module}
      other -> {:error, "agent hook type must be :shell or :module, got: #{inspect(other)}"}
    end
  end

  @spec infer_type(map()) :: {:ok, hook_type()}
  defp infer_type(raw) do
    if fetch(raw, :module) != nil, do: {:ok, :module}, else: {:ok, :shell}
  end

  @spec normalize_type_fields(map(), hook_type()) ::
          {:ok, String.t() | nil, module() | nil, atom() | nil} | {:error, String.t()}
  defp normalize_type_fields(raw, :shell) do
    case normalize_non_empty_string(fetch(raw, :command), "shell hook requires :command") do
      {:ok, command} -> {:ok, command, nil, nil}
      error -> error
    end
  end

  defp normalize_type_fields(raw, :module) do
    with {:ok, mod} <- normalize_module(fetch(raw, :module)),
         {:ok, fun} <- normalize_function(fetch(raw, :function)) do
      {:ok, nil, mod, fun}
    end
  end

  @spec normalize_module(term()) :: {:ok, module()} | {:error, String.t()}
  defp normalize_module(nil), do: {:error, "module hook requires :module"}
  defp normalize_module(mod) when is_atom(mod), do: {:ok, mod}

  defp normalize_module(mod) when is_binary(mod) do
    full_name = if String.starts_with?(mod, "Elixir."), do: mod, else: "Elixir." <> mod
    {:ok, String.to_existing_atom(full_name)}
  rescue
    ArgumentError -> {:error, "module hook :module #{inspect(mod)} is not a loaded module"}
  end

  defp normalize_module(other),
    do: {:error, "module hook :module must be an atom, got: #{inspect(other)}"}

  @spec normalize_function(term()) :: {:ok, atom()} | {:error, String.t()}
  defp normalize_function(nil), do: {:error, "module hook requires :function"}
  defp normalize_function(fun) when is_atom(fun), do: {:ok, fun}

  defp normalize_function(fun) when is_binary(fun) do
    {:ok, String.to_existing_atom(fun)}
  rescue
    ArgumentError -> {:error, "module hook :function #{inspect(fun)} is not a known atom"}
  end

  defp normalize_function(other),
    do: {:error, "module hook :function must be an atom, got: #{inspect(other)}"}

  @spec normalize_timeout(term()) :: {:ok, pos_integer()} | {:error, String.t()}
  defp normalize_timeout(nil), do: {:ok, @default_timeout_ms}
  defp normalize_timeout(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp normalize_timeout(value),
    do: {:error, "agent hook timeout_ms must be a positive integer, got: #{inspect(value)}"}

  @spec normalize_optional_atom(term()) :: {:ok, atom() | nil} | {:error, String.t()}
  defp normalize_optional_atom(nil), do: {:ok, nil}
  defp normalize_optional_atom(value) when is_atom(value), do: {:ok, value}

  defp normalize_optional_atom(value),
    do: {:error, "agent hook extension metadata must be an atom, got: #{inspect(value)}"}

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
