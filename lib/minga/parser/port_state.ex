defmodule Minga.Parser.PortState do
  @moduledoc """
  Owned state for the parser Port and its restart policy.

  `Minga.Parser.Manager` owns the process and installs this aggregate, while this
  module is the only constructor and updater of `%PortState{}` values.
  """

  @initial_backoff_ms 100

  defstruct handle: nil,
            parser_path: "",
            ready?: false,
            restart_timestamps: [],
            backoff_ms: @initial_backoff_ms,
            gave_up?: false

  @type t :: %__MODULE__{
          handle: port() | nil,
          parser_path: String.t(),
          ready?: boolean(),
          restart_timestamps: [integer()],
          backoff_ms: pos_integer(),
          gave_up?: boolean()
        }

  @doc "Constructs parser Port state for an executable path."
  @spec new(String.t()) :: t()
  def new(parser_path) when is_binary(parser_path), do: %__MODULE__{parser_path: parser_path}

  @doc "Records a successfully opened parser Port."
  @spec opened(t(), port()) :: t()
  def opened(%__MODULE__{} = state, handle) when is_port(handle),
    do: %{state | handle: handle, ready?: true}

  @doc "Records that the parser Port is closed."
  @spec closed(t()) :: t()
  def closed(%__MODULE__{} = state), do: %{state | handle: nil, ready?: false}

  @doc "Resets bounded restart history for a manual restart."
  @spec reset_restart_policy(t()) :: t()
  def reset_restart_policy(%__MODULE__{} = state) do
    %{state | gave_up?: false, backoff_ms: @initial_backoff_ms, restart_timestamps: []}
  end

  @doc "Records a successful automatic restart and resets backoff."
  @spec restarted(t(), port()) :: t()
  def restarted(%__MODULE__{} = state, handle) when is_port(handle) do
    %{state | handle: handle, ready?: true, backoff_ms: @initial_backoff_ms}
  end

  @doc "Records a scheduled restart attempt and its next backoff."
  @spec scheduled(t(), [integer()], pos_integer()) :: t()
  def scheduled(%__MODULE__{} = state, timestamps, next_backoff_ms)
      when is_list(timestamps) and is_integer(next_backoff_ms) and next_backoff_ms > 0 do
    %{state | restart_timestamps: timestamps, backoff_ms: next_backoff_ms}
  end

  @doc "Records that bounded restart attempts have been exhausted."
  @spec gave_up(t(), [integer()]) :: t()
  def gave_up(%__MODULE__{} = state, timestamps) when is_list(timestamps) do
    %{state | gave_up?: true, restart_timestamps: timestamps}
  end
end
