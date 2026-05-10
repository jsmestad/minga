defmodule MingaAgent.Subagent.Handle do
  @moduledoc """
  Stable runtime handle for a background sub-agent session.

  The handle is owned by `MingaAgent.SessionManager` and projected by editor shells for status and navigation. The public, stable identifier is `session_id`; `pid` is kept for in-process routing only.
  """

  @enforce_keys [:session_id, :pid, :task, :started_at]
  defstruct [
    :session_id,
    :pid,
    :parent_session_id,
    :parent_pid,
    :task,
    :model,
    :started_at
  ]

  @type t :: %__MODULE__{
          session_id: String.t(),
          pid: pid(),
          parent_session_id: String.t() | nil,
          parent_pid: pid() | nil,
          task: String.t(),
          model: String.t() | nil,
          started_at: DateTime.t()
        }

  @doc "Creates a background sub-agent handle."
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      session_id: Keyword.fetch!(opts, :session_id),
      pid: Keyword.fetch!(opts, :pid),
      parent_session_id: Keyword.get(opts, :parent_session_id),
      parent_pid: Keyword.get(opts, :parent_pid),
      task: Keyword.fetch!(opts, :task),
      model: Keyword.get(opts, :model),
      started_at: Keyword.get(opts, :started_at, DateTime.utc_now())
    }
  end

  @doc "Returns the stable public handle string."
  @spec id(t()) :: String.t()
  def id(%__MODULE__{session_id: session_id}), do: session_id

  @doc "Returns a short display label for UI surfaces."
  @spec label(t()) :: String.t()
  def label(%__MODULE__{session_id: session_id, task: task}) do
    trimmed = task |> String.split("\n") |> hd() |> String.trim()

    if trimmed == "" do
      session_id
    else
      "#{session_id}: #{truncate(trimmed, 40)}"
    end
  end

  @spec truncate(String.t(), pos_integer()) :: String.t()
  defp truncate(text, max_len) do
    if String.length(text) > max_len do
      String.slice(text, 0, max_len - 3) <> "..."
    else
      text
    end
  end
end
