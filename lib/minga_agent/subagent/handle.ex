defmodule MingaAgent.Subagent.Handle do
  @moduledoc """
  Stable runtime handle for a background sub-agent session.

  The handle is owned by `MingaAgent.SessionManager` and projected by editor shells for status and navigation. The public, stable identifier is `session_id`; `pid` is kept for in-process routing only.
  """

  @type status :: :running | :completed | :failed | :cancelled | :interrupted

  @typedoc "A file change produced by a child worktree."
  @type change :: {:added | :modified | :deleted, String.t()}

  @enforce_keys [:session_id, :pid, :task, :started_at]
  defstruct [
    :session_id,
    :pid,
    :parent_session_id,
    :parent_pid,
    :task,
    :model,
    :started_at,
    :worktree_path,
    :worktree_base_sha,
    status: :running,
    result: nil,
    completed_at: nil,
    generation: 1,
    changes: nil
  ]

  @type t :: %__MODULE__{
          session_id: String.t(),
          pid: pid(),
          parent_session_id: String.t() | nil,
          parent_pid: pid() | nil,
          task: String.t(),
          model: String.t() | nil,
          started_at: DateTime.t(),
          worktree_path: String.t() | nil,
          worktree_base_sha: String.t() | nil,
          status: status(),
          result: String.t() | nil,
          completed_at: DateTime.t() | nil,
          generation: pos_integer(),
          changes: [change()] | nil
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

  @doc "Transitions the handle to completed status with a result."
  @spec complete(t(), String.t()) :: t()
  def complete(%__MODULE__{status: :running} = handle, result) when is_binary(result) do
    %{handle | status: :completed, result: result, completed_at: DateTime.utc_now()}
  end

  @doc "Transitions the handle to failed status with an inspected reason."
  @spec fail(t(), term()) :: t()
  def fail(%__MODULE__{status: :running} = handle, reason) do
    %{handle | status: :failed, result: inspect(reason), completed_at: DateTime.utc_now()}
  end

  @doc "Marks a running handle as interrupted (lost during restart)."
  @spec interrupt(t(), term()) :: t()
  def interrupt(%__MODULE__{status: :running} = handle, reason) do
    %{handle | status: :interrupted, result: inspect(reason), completed_at: DateTime.utc_now()}
  end

  @doc "Increments the generation counter after a session restart."
  @spec next_generation(t()) :: t()
  def next_generation(%__MODULE__{generation: gen} = handle) do
    %{handle | generation: gen + 1}
  end

  @doc "Sets the worktree metadata on a handle."
  @spec with_worktree(t(), String.t(), String.t()) :: t()
  def with_worktree(%__MODULE__{} = handle, path, base_sha)
      when is_binary(path) and is_binary(base_sha) do
    %{handle | worktree_path: path, worktree_base_sha: base_sha}
  end

  @doc "Records the collected change manifest on a finalized handle."
  @spec with_changes(t(), [change()]) :: t()
  def with_changes(%__MODULE__{} = handle, changes) when is_list(changes) do
    %{handle | changes: changes}
  end

  @doc "Returns a copy of the handle with a different pid."
  @spec with_pid(t(), pid()) :: t()
  def with_pid(%__MODULE__{} = handle, pid) when is_pid(pid) do
    %{handle | pid: pid}
  end

  @doc "Returns a copy of the handle with a different parent pid."
  @spec with_parent_pid(t(), pid() | nil) :: t()
  def with_parent_pid(%__MODULE__{} = handle, parent_pid)
      when is_pid(parent_pid) or is_nil(parent_pid) do
    %{handle | parent_pid: parent_pid}
  end

  @doc "Returns a copy of the handle with a different session ID."
  @spec with_session_id(t(), String.t()) :: t()
  def with_session_id(%__MODULE__{} = handle, session_id) when is_binary(session_id) do
    %{handle | session_id: session_id}
  end

  @doc "Returns a copy of the handle with a different parent session ID."
  @spec with_parent_session_id(t(), String.t() | nil) :: t()
  def with_parent_session_id(%__MODULE__{} = handle, session_id)
      when is_binary(session_id) or is_nil(session_id) do
    %{handle | parent_session_id: session_id}
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
