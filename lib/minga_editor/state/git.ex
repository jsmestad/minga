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

  @doc "Drops a generated diff buffer after it retires."
  @spec retire_diff_view(t(), pid()) :: t()
  def retire_diff_view(%__MODULE__{} = git, buffer_pid) when is_pid(buffer_pid),
    do: %{git | diff_views: Map.delete(git.diff_views, buffer_pid)}
end
