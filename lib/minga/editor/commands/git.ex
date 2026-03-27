defmodule Minga.Editor.Commands.Git do
  @moduledoc """
  Git commands: status panel, remote operations (push/pull/fetch), diff view,
  branch picker, hunk navigation, stage, revert, preview, and blame.
  """

  @behaviour Minga.Command.Provider

  alias Minga.Buffer
  alias Minga.Editor.Commands
  alias Minga.Editor.PickerUI
  alias Minga.Editor.State, as: EditorState
  alias Minga.Git
  alias Minga.Git.Buffer, as: GitBuffer
  alias Minga.Git.Diff
  alias Minga.Git.DiffView
  alias Minga.Git.Repo
  alias Minga.Git.Tracker, as: GitTracker
  alias Minga.Language
  alias Minga.UI.Picker.GitChangedSource

  @type state :: EditorState.t()

  @command_specs [
    {:git_status_toggle, "Git status", false},
    {:git_changed_files, "Changed files", false},
    {:git_branch_picker, "Switch branch", false},
    {:git_push, "Push", false},
    {:git_pull, "Pull", false},
    {:git_fetch, "Fetch", false},
    {:git_diff_file, "View diff", true},
    {:next_git_hunk, "Next git hunk", true},
    {:prev_git_hunk, "Previous git hunk", true},
    {:git_stage_hunk, "Stage hunk", true},
    {:git_revert_hunk, "Revert hunk", true},
    {:git_preview_hunk, "Preview hunk", true},
    {:git_blame_line, "Blame line", true}
  ]

  @spec execute(state(), atom()) :: state()

  # ── Status panel toggle ────────────────────────────────────────────────────

  def execute(state, :git_status_toggle) do
    if state.workspace.keymap_scope == :git_status do
      state = %{state | workspace: %{state.workspace | keymap_scope: :editor}}
      EditorState.close_git_status_panel(state)
    else
      open_git_status_panel(state)
    end
  end

  # ── Changed files picker ────────────────────────────────────────────────────

  def execute(state, :git_changed_files) do
    PickerUI.open(state, GitChangedSource)
  end

  def execute(state, :git_branch_picker) do
    PickerUI.open(state, Minga.UI.Picker.GitBranchSource)
  end

  def execute(state, :git_push) do
    git_remote_action(state, &Git.push/1, "Pushing…", "Pushed", "Push failed")
  end

  def execute(state, :git_pull) do
    git_remote_action(state, &Git.pull/1, "Pulling…", "Pulled", "Pull failed")
  end

  def execute(state, :git_fetch) do
    git_remote_action(state, &Git.fetch_remotes/1, "Fetching…", "Fetched", "Fetch failed")
  end

  # ── Diff view ──────────────────────────────────────────────────────────────

  def execute(state, :git_diff_file) do
    with_git_buffer(state, fn git_pid, buf ->
      open_diff_view(state, git_pid, buf)
    end)
  end

  # ── Navigation ─────────────────────────────────────────────────────────────

  def execute(state, :next_git_hunk) do
    with_git_buffer(state, fn git_pid, buf ->
      {cursor_line, _col} = Buffer.cursor(buf)
      hunks = GitBuffer.hunks(git_pid)

      case Diff.next_hunk_line(hunks, cursor_line) do
        nil -> EditorState.set_status(state, "No next hunk")
        line -> jump_to_line(state, buf, line)
      end
    end)
  end

  def execute(state, :prev_git_hunk) do
    with_git_buffer(state, fn git_pid, buf ->
      {cursor_line, _col} = Buffer.cursor(buf)
      hunks = GitBuffer.hunks(git_pid)

      case Diff.prev_hunk_line(hunks, cursor_line) do
        nil -> EditorState.set_status(state, "No previous hunk")
        line -> jump_to_line(state, buf, line)
      end
    end)
  end

  # ── Stage hunk ─────────────────────────────────────────────────────────────

  def execute(state, :git_stage_hunk) do
    with_git_buffer(state, fn git_pid, buf ->
      {cursor_line, _col} = Buffer.cursor(buf)

      case GitBuffer.hunk_at(git_pid, cursor_line) do
        nil -> EditorState.set_status(state, "No hunk at cursor")
        hunk -> do_stage_hunk(state, git_pid, buf, hunk)
      end
    end)
  end

  # ── Revert hunk ────────────────────────────────────────────────────────────

  def execute(state, :git_revert_hunk) do
    with_git_buffer(state, fn git_pid, buf ->
      {cursor_line, _col} = Buffer.cursor(buf)

      case GitBuffer.hunk_at(git_pid, cursor_line) do
        nil ->
          EditorState.set_status(state, "No hunk at cursor")

        hunk ->
          {content, _cursor} = Buffer.content_and_cursor(buf)
          current_lines = String.split(content, "\n")
          reverted_lines = Diff.revert_hunk(current_lines, hunk)
          reverted_content = Enum.join(reverted_lines, "\n")

          Buffer.replace_content(buf, reverted_content)
          GitBuffer.update(git_pid, reverted_content)
          EditorState.set_status(state, "Hunk reverted")
      end
    end)
  end

  # ── Preview hunk ───────────────────────────────────────────────────────────

  def execute(state, :git_preview_hunk) do
    with_git_buffer(state, fn git_pid, buf ->
      {cursor_line, _col} = Buffer.cursor(buf)

      case GitBuffer.hunk_at(git_pid, cursor_line) do
        nil -> EditorState.set_status(state, "No hunk at cursor")
        hunk -> EditorState.set_status(state, format_hunk_preview(hunk))
      end
    end)
  end

  # ── Blame line ─────────────────────────────────────────────────────────────

  def execute(state, :git_blame_line) do
    with_git_buffer(state, fn git_pid, buf ->
      {cursor_line, _col} = Buffer.cursor(buf)
      git_root = GitBuffer.git_root(git_pid)
      rel_path = GitBuffer.relative_path(git_pid)

      case Git.blame_line(git_root, rel_path, cursor_line) do
        {:ok, blame_text} -> EditorState.set_status(state, blame_text)
        :error -> EditorState.set_status(state, "Blame unavailable")
      end
    end)
  end

  # ── Private ────────────────────────────────────────────────────────────────

  # Mutual exclusivity: close file tree when opening git status.
  @spec close_file_tree_if_open(state()) :: state()
  defp close_file_tree_if_open(%{workspace: %{file_tree: %{tree: nil}}} = state), do: state
  defp close_file_tree_if_open(state), do: Commands.FileTree.close(state)

  @spec open_diff_view(state(), pid(), pid()) :: state()
  defp open_diff_view(state, git_pid, buf) do
    git_root = GitBuffer.git_root(git_pid)
    rel_path = GitBuffer.relative_path(git_pid)
    {current_content, _cursor} = Buffer.content_and_cursor(buf)

    base_content =
      case Git.show_head(git_root, rel_path) do
        {:ok, content} -> content
        :error -> ""
      end

    diff_result = DiffView.build(base_content, current_content)
    filename = Path.basename(rel_path)
    filetype = Language.detect_filetype(filename)

    case Buffer.start_link(
           content: diff_result.text,
           buffer_type: :nofile,
           read_only: true,
           buffer_name: "#{filename} [diff]",
           filetype: filetype
         ) do
      {:ok, diff_buf} ->
        state = Commands.add_buffer(state, diff_buf)

        EditorState.set_status(
          state,
          "Diff: #{filename} (#{length(diff_result.hunk_lines)} hunks)"
        )

      {:error, reason} ->
        EditorState.set_status(state, "Failed to open diff: #{inspect(reason)}")
    end
  end

  @doc """
  Handles the result of an async git remote operation.

  Called by `Minga.Editor.handle_info/2` when a `{:git_remote_result, ref, result}`
  message arrives. Matches the ref against the in-flight operation to ignore stale
  results, then updates the status bar and refreshes the git repo.
  """
  @spec handle_remote_result(state(), reference(), :ok | {:error, String.t()}) :: state()
  def handle_remote_result(state, ref, result) do
    case state.git_remote_op do
      {^ref, task_monitor, {git_root, success_msg, error_prefix}} ->
        Process.demonitor(task_monitor, [:flush])

        status_msg =
          case result do
            :ok ->
              refresh_repo(git_root)
              success_msg

            {:error, reason} ->
              "#{error_prefix}: #{reason}"
          end

        EditorState.set_status(%{state | git_remote_op: nil}, status_msg)

      _ ->
        # Stale result from a superseded operation; ignore
        state
    end
  end

  @doc """
  Handles the `:DOWN` message when an async git remote task crashes.

  Clears the in-flight operation so future remote operations aren't
  permanently blocked. Called by the Editor's `:DOWN` handler.
  """
  @spec handle_remote_task_down(state(), reference()) :: state() | :not_matched
  def handle_remote_task_down(state, monitor_ref) do
    case state.git_remote_op do
      {_msg_ref, ^monitor_ref, _context} ->
        EditorState.set_status(%{state | git_remote_op: nil}, "Git operation failed unexpectedly")

      _ ->
        :not_matched
    end
  end

  @spec git_remote_action(
          state(),
          (String.t() -> :ok | {:error, String.t()}),
          String.t(),
          String.t(),
          String.t()
        ) ::
          state()
  defp git_remote_action(state, _operation, _progress_msg, _success_msg, _error_prefix)
       when state.git_remote_op != nil do
    EditorState.set_status(state, "Git operation already in progress")
  end

  defp git_remote_action(state, operation, progress_msg, success_msg, error_prefix) do
    case Git.root_for(Minga.Project.resolve_root()) do
      {:ok, git_root} ->
        ref = make_ref()
        editor_pid = self()

        {:ok, task_pid} =
          Task.start(fn ->
            result = operation.(git_root)
            send(editor_pid, {:git_remote_result, ref, result})
          end)

        task_monitor = Process.monitor(task_pid)

        %{state | git_remote_op: {ref, task_monitor, {git_root, success_msg, error_prefix}}}
        |> EditorState.set_status(progress_msg)

      :not_git ->
        EditorState.set_status(state, "Not in a git repository")
    end
  end

  @spec refresh_repo(String.t()) :: :ok
  defp refresh_repo(git_root) do
    case Repo.lookup(git_root) do
      nil -> :ok
      pid -> Repo.refresh(pid)
    end
  end

  @spec open_git_status_panel(state()) :: state()
  defp open_git_status_panel(state) do
    case Git.root_for(Minga.Project.resolve_root()) do
      {:ok, git_root} -> open_git_status_for_root(state, git_root)
      :not_git -> EditorState.set_status(state, "Not in a git repository")
    end
  end

  @spec open_git_status_for_root(state(), String.t()) :: state()
  defp open_git_status_for_root(state, git_root) do
    case Repo.lookup(git_root) do
      nil ->
        EditorState.set_status(state, "Git.Repo not available")

      repo_pid ->
        entries = Repo.status(repo_pid)
        summary = Repo.summary(repo_pid)

        panel_data = %{
          repo_state: :normal,
          branch: summary.branch || "",
          ahead: summary.ahead,
          behind: summary.behind,
          entries: entries
        }

        # Mutual exclusivity: close file tree when opening git status
        state = close_file_tree_if_open(state)

        state = %{state | workspace: %{state.workspace | keymap_scope: :git_status}}
        EditorState.set_git_status_panel(state, panel_data)
    end
  end

  @spec format_hunk_preview(Diff.hunk()) :: String.t()
  defp format_hunk_preview(%{type: :added, count: count}) do
    "+#{count} added line(s)"
  end

  defp format_hunk_preview(%{type: :deleted, old_lines: old_lines}) do
    preview = old_lines |> Enum.take(3) |> Enum.join(" | ")
    truncated = if length(old_lines) > 3, do: " ...", else: ""
    "-#{length(old_lines)} deleted: #{preview}#{truncated}"
  end

  defp format_hunk_preview(%{type: :modified, old_lines: old_lines, count: count}) do
    preview = old_lines |> Enum.take(3) |> Enum.join(" | ")
    truncated = if length(old_lines) > 3, do: " ...", else: ""
    "~#{count} modified (was #{length(old_lines)} lines): #{preview}#{truncated}"
  end

  @spec do_stage_hunk(state(), pid(), pid(), Diff.hunk()) :: state()
  defp do_stage_hunk(state, git_pid, buf, hunk) do
    git_root = GitBuffer.git_root(git_pid)
    rel_path = GitBuffer.relative_path(git_pid)
    {content, _cursor} = Buffer.content_and_cursor(buf)
    base_lines = get_base_lines(git_pid)
    current_lines = String.split(content, "\n")

    patch = Diff.generate_patch(rel_path, base_lines, current_lines, hunk)

    case Git.stage_patch(git_root, patch) do
      :ok ->
        GitBuffer.invalidate_base(git_pid, content)
        EditorState.set_status(state, "Hunk staged")

      {:error, reason} ->
        EditorState.set_status(state, "Stage failed: #{reason}")
    end
  end

  @spec with_git_buffer(state(), (pid(), pid() -> state())) :: state()
  defp with_git_buffer(%{workspace: %{buffers: %{active: buf}}} = state, fun)
       when is_pid(buf) do
    case GitTracker.lookup(buf) do
      nil ->
        EditorState.set_status(state, "Not in a git repository")

      git_pid ->
        try do
          fun.(git_pid, buf)
        catch
          :exit, _ -> state
        end
    end
  end

  defp with_git_buffer(state, _fun), do: state

  @spec jump_to_line(state(), pid(), non_neg_integer()) :: state()
  defp jump_to_line(state, buf, line) do
    Buffer.move_to(buf, {line, 0})
    state
  end

  @spec get_base_lines(pid()) :: [String.t()]
  defp get_base_lines(git_pid) do
    # Access the base_lines from the git buffer's state
    :sys.get_state(git_pid).base_lines
  end

  @impl Minga.Command.Provider
  def __commands__ do
    Enum.map(@command_specs, fn {name, desc, requires_buffer} ->
      %Minga.Command{
        name: name,
        description: desc,
        requires_buffer: requires_buffer,
        execute: fn state -> execute(state, name) end
      }
    end)
  end
end
