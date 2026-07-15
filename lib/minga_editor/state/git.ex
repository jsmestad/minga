defmodule MingaEditor.State.Git do
  @moduledoc """
  Correlation state for editor-level Git workflows and diff presentation.

  Repository services own Git data. This value remembers only operations and
  generated-buffer views whose results are still relevant to this editor.
  """

  @type remote_op ::
          {msg_ref :: reference(), task_monitor :: reference(),
           {git_root :: String.t(), success_msg :: String.t(), error_prefix :: String.t()}}
          | nil

  @type diff_view_info :: %{
          required(:source_buf) => pid() | nil,
          required(:git_root) => String.t(),
          required(:rel_path) => String.t(),
          required(:staged) => boolean(),
          required(:line_metadata) => [Minga.Core.DiffView.line_meta()],
          required(:hunk_lines) => [non_neg_integer()],
          optional(:view_mode) => :unified | :side_by_side,
          optional(:pane_width) => pos_integer()
        }

  @type t :: %__MODULE__{
          git_remote_op: remote_op(),
          git_commit_gen_ref: reference() | nil,
          diff_views: %{pid() => diff_view_info()}
        }

  defstruct git_remote_op: nil,
            git_commit_gen_ref: nil,
            diff_views: %{}

  @doc "Records the currently visible remote Git operation."
  @spec report_remote_operation(t(), remote_op()) :: t()
  def report_remote_operation(%__MODULE__{} = git, operation),
    do: %{git | git_remote_op: operation}

  @doc "Clears the completed remote Git operation."
  @spec clear_remote_operation(t()) :: t()
  def clear_remote_operation(%__MODULE__{} = git), do: %{git | git_remote_op: nil}

  @doc "Correlates asynchronous commit-message generation."
  @spec await_commit_generation(t(), reference() | nil) :: t()
  def await_commit_generation(%__MODULE__{} = git, ref)
      when is_reference(ref) or is_nil(ref),
      do: %{git | git_commit_gen_ref: ref}

  @doc "Registers a generated diff buffer and its source content."
  @spec register_diff_view(t(), pid(), diff_view_info()) :: t()
  def register_diff_view(%__MODULE__{} = git, buffer_pid, info)
      when is_pid(buffer_pid) and is_map(info),
      do: %{git | diff_views: Map.put(git.diff_views, buffer_pid, info)}

  @doc "Returns metadata for a generated diff buffer, when registered."
  @spec diff_view_info(t(), pid() | nil) :: diff_view_info() | nil
  def diff_view_info(%__MODULE__{}, nil), do: nil

  def diff_view_info(%__MODULE__{diff_views: diff_views}, buffer_pid) when is_pid(buffer_pid),
    do: Map.get(diff_views, buffer_pid)

  @doc "Returns every generated diff buffer associated with one source buffer."
  @spec diff_views_for_source(t(), pid()) :: [{pid(), diff_view_info()}]
  def diff_views_for_source(%__MODULE__{diff_views: diff_views}, source_buffer)
      when is_pid(source_buffer) do
    Enum.filter(diff_views, fn {_diff_buffer, info} -> info.source_buf == source_buffer end)
  end

  @doc "Drops every generated diff-view reference to a retired buffer."
  @spec retire_buffer(t(), pid()) :: t()
  def retire_buffer(%__MODULE__{} = git, buffer_pid) when is_pid(buffer_pid) do
    diff_views =
      Enum.reject(git.diff_views, fn {view_pid, info} ->
        view_pid == buffer_pid or info.source_buf == buffer_pid
      end)
      |> Map.new()

    %{git | diff_views: diff_views}
  end

  @doc "Drops a generated diff buffer after it retires."
  @spec retire_diff_view(t(), pid()) :: t()
  def retire_diff_view(%__MODULE__{} = git, buffer_pid) when is_pid(buffer_pid),
    do: %{git | diff_views: Map.delete(git.diff_views, buffer_pid)}
end
