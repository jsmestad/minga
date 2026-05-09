defmodule MingaAgent.Hooks.Hook do
  @moduledoc """
  Normalized agent hook declaration.

  Hooks are declared in user config as maps or keyword lists, then normalized
  by `MingaAgent.Config.resolve/0` into this struct. Only `:pre_tool_use` is
  executable today, but the event field is explicit so later lifecycle events
  can share the same config shape.
  """

  @default_timeout_ms 30_000

  @typedoc "Supported hook event names."
  @type event :: :pre_tool_use

  @typedoc "Normalized hook declaration."
  @type t :: %__MODULE__{
          event: event(),
          tool_pattern: String.t(),
          command: String.t(),
          timeout_ms: pos_integer()
        }

  @enforce_keys [:event, :tool_pattern, :command]
  defstruct [:event, :tool_pattern, :command, timeout_ms: @default_timeout_ms]

  @doc "Returns the default per-hook timeout in milliseconds."
  @spec default_timeout_ms() :: pos_integer()
  def default_timeout_ms, do: @default_timeout_ms

  @doc "Normalizes a user config hook declaration into a `%Hook{}`."
  @spec normalize(term()) :: {:ok, t()} | {:error, String.t()}
  def normalize(raw) when is_list(raw) do
    raw |> Map.new() |> normalize()
  end

  def normalize(raw) when is_map(raw) do
    with {:ok, event} <- normalize_event(fetch(raw, :event)),
         {:ok, tool_pattern} <- normalize_tool_pattern(raw),
         {:ok, command} <- normalize_command(fetch(raw, :command)),
         {:ok, timeout_ms} <- normalize_timeout(fetch(raw, :timeout_ms)) do
      {:ok,
       %__MODULE__{
         event: event,
         tool_pattern: tool_pattern,
         command: command,
         timeout_ms: timeout_ms
       }}
    end
  end

  def normalize(_raw), do: {:error, "agent hook must be a map or keyword list"}

  @doc "Returns true when this hook applies to the event and tool name."
  @spec matches?(t(), event(), String.t()) :: boolean()
  def matches?(%__MODULE__{event: event, tool_pattern: pattern}, event, tool_name)
      when is_binary(tool_name) do
    match_tool_pattern?(pattern, tool_name)
  end

  def matches?(%__MODULE__{}, _event, _tool_name), do: false

  @spec normalize_event(term()) :: {:ok, event()} | {:error, String.t()}
  defp normalize_event(nil), do: {:error, "agent hook requires :event"}
  defp normalize_event(:pre_tool_use), do: {:ok, :pre_tool_use}
  defp normalize_event(:PreToolUse), do: {:ok, :pre_tool_use}
  defp normalize_event("PreToolUse"), do: {:ok, :pre_tool_use}
  defp normalize_event("pre_tool_use"), do: {:ok, :pre_tool_use}
  defp normalize_event(other), do: {:error, "unsupported agent hook event: #{inspect(other)}"}

  @spec normalize_tool_pattern(map()) :: {:ok, String.t()} | {:error, String.t()}
  defp normalize_tool_pattern(raw) do
    raw
    |> fetch(:tool_pattern)
    |> fallback(fetch(raw, :tool))
    |> normalize_non_empty_string("agent hook requires :tool_pattern or :tool")
  end

  @spec normalize_command(term()) :: {:ok, String.t()} | {:error, String.t()}
  defp normalize_command(value),
    do: normalize_non_empty_string(value, "agent hook requires :command")

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
