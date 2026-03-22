defmodule Minga.Editor.Commands.Git do
  @moduledoc """
  Git hunk operations: navigation, stage, revert, preview, and blame.
  """

  @behaviour Minga.Command.Provider

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.Commands
  alias Minga.Editor.PickerUI
  alias Minga.Editor.State, as: EditorState
  alias Minga.Git
  alias Minga.Git.Buffer, as: GitBuffer
  alias Minga.Git.Diff
  alias Minga.Git.DiffView
  alias Minga.Git.Repo
  alias Minga.Git.Tracker, as: GitTracker
  alias Minga.Picker.GitChangedSource

  @type state :: EditorState.t()

  @command_specs [
    {:git_status_toggle, "Git status", false},
    {:git_changed_files, "Changed files", false},
    {:git_branch_picker, "Switch branch", false},
    {:git_push, "Push", false},
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
    if state.keymap_scope == :git_status do
      %{state | keymap_scope: :editor, git_status_panel: nil}
    else
      open_git_status_panel(state)
    end
  end

  # ── Changed files picker ────────────────────────────────────────────────────

  def execute(state, :git_changed_files) do
    PickerUI.open(state, GitChangedSource)
  end

  def execute(state, :git_branch_picker) do
    PickerUI.open(state, Minga.Picker.GitBranchSource)
  end

  def execute(state, :git_push) do
    git_remote_action(state, &Git.push/1, "Pushing...", "Pushed", "Push failed")
  end

  def execute(state, :git_fetch) do
    git_remote_action(state, &Git.fetch_remotes/1, "Fetching...", "Fetched", "Fetch failed")
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
      {cursor_line, _col} = BufferServer.cursor(buf)
      hunks = GitBuffer.hunks(git_pid)

      case Diff.next_hunk_line(hunks, cursor_line) do
        nil -> %{state | status_msg: "No next hunk"}
        line -> jump_to_line(state, buf, line)
      end
    end)
  end

  def execute(state, :prev_git_hunk) do
    with_git_buffer(state, fn git_pid, buf ->
      {cursor_line, _col} = BufferServer.cursor(buf)
      hunks = GitBuffer.hunks(git_pid)

      case Diff.prev_hunk_line(hunks, cursor_line) do
        nil -> %{state | status_msg: "No previous hunk"}
        line -> jump_to_line(state, buf, line)
      end
    end)
  end

  # ── Stage hunk ─────────────────────────────────────────────────────────────

  def execute(state, :git_stage_hunk) do
    with_git_buffer(state, fn git_pid, buf ->
      {cursor_line, _col} = BufferServer.cursor(buf)

      case GitBuffer.hunk_at(git_pid, cursor_line) do
        nil -> %{state | status_msg: "No hunk at cursor"}
        hunk -> do_stage_hunk(state, git_pid, buf, hunk)
      end
    end)
  end

  # ── Revert hunk ────────────────────────────────────────────────────────────

  def execute(state, :git_revert_hunk) do
    with_git_buffer(state, fn git_pid, buf ->
      {cursor_line, _col} = BufferServer.cursor(buf)

      case GitBuffer.hunk_at(git_pid, cursor_line) do
        nil ->
          %{state | status_msg: "No hunk at cursor"}

        hunk ->
          {content, _cursor} = BufferServer.content_and_cursor(buf)
          current_lines = String.split(content, "\n")
          reverted_lines = Diff.revert_hunk(current_lines, hunk)
          reverted_content = Enum.join(reverted_lines, "\n")

          BufferServer.replace_content(buf, reverted_content)
          GitBuffer.update(git_pid, reverted_content)
          %{state | status_msg: "Hunk reverted"}
      end
    end)
  end

  # ── Preview hunk ───────────────────────────────────────────────────────────

  def execute(state, :git_preview_hunk) do
    with_git_buffer(state, fn git_pid, buf ->
      {cursor_line, _col} = BufferServer.cursor(buf)

      case GitBuffer.hunk_at(git_pid, cursor_line) do
        nil -> %{state | status_msg: "No hunk at cursor"}
        hunk -> %{state | status_msg: format_hunk_preview(hunk)}
      end
    end)
  end

  # ── Blame line ─────────────────────────────────────────────────────────────

  def execute(state, :git_blame_line) do
    with_git_buffer(state, fn git_pid, buf ->
      {cursor_line, _col} = BufferServer.cursor(buf)
      git_root = GitBuffer.git_root(git_pid)
      rel_path = GitBuffer.relative_path(git_pid)

      case Git.blame_line(git_root, rel_path, cursor_line) do
        {:ok, blame_text} -> %{state | status_msg: blame_text}
        :error -> %{state | status_msg: "Blame unavailable"}
      end
    end)
  end

  # ── Private ────────────────────────────────────────────────────────────────

  @spec open_diff_view(state(), pid(), pid()) :: state()
  defp open_diff_view(state, git_pid, buf) do
    git_root = GitBuffer.git_root(git_pid)
    rel_path = GitBuffer.relative_path(git_pid)
    {current_content, _cursor} = BufferServer.content_and_cursor(buf)

    base_content =
      case Git.show_head(git_root, rel_path) do
        {:ok, content} -> content
        :error -> ""
      end

    diff_result = DiffView.build(base_content, current_content)
    filename = Path.basename(rel_path)
    filetype = Minga.Filetype.detect(filename)

    case BufferServer.start_link(
           content: diff_result.text,
           buffer_type: :nofile,
           read_only: true,
           buffer_name: "#{filename} [diff]",
           filetype: filetype
         ) do
      {:ok, diff_buf} ->
        state = Commands.add_buffer(state, diff_buf)
        %{state | status_msg: "Diff: #{filename} (#{length(diff_result.hunk_lines)} hunks)"}

      {:error, reason} ->
        %{state | status_msg: "Failed to open diff: #{inspect(reason)}"}
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
  defp git_remote_action(state, operation, _progress_msg, success_msg, error_prefix) do
    case Git.root_for(Minga.Project.resolve_root()) do
      {:ok, git_root} ->
        # Run synchronously for now; async with progress feedback is a future enhancement
        case operation.(git_root) do
          :ok ->
            refresh_repo(git_root)
            %{state | status_msg: success_msg}

          {:error, reason} ->
            %{state | status_msg: "#{error_prefix}: #{reason}"}
        end

      :not_git ->
        %{state | status_msg: "Not in a git repository"}
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
      :not_git -> %{state | status_msg: "Not in a git repository"}
    end
  end

  @spec open_git_status_for_root(state(), String.t()) :: state()
  defp open_git_status_for_root(state, git_root) do
    case Repo.lookup(git_root) do
      nil ->
        %{state | status_msg: "Git.Repo not available"}

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

        %{state | keymap_scope: :git_status, git_status_panel: panel_data}
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
    {content, _cursor} = BufferServer.content_and_cursor(buf)
    base_lines = get_base_lines(git_pid)
    current_lines = String.split(content, "\n")

    patch = Diff.generate_patch(rel_path, base_lines, current_lines, hunk)

    case Git.stage_patch(git_root, patch) do
      :ok ->
        GitBuffer.invalidate_base(git_pid, content)
        %{state | status_msg: "Hunk staged"}

      {:error, reason} ->
        %{state | status_msg: "Stage failed: #{reason}"}
    end
  end

  @spec with_git_buffer(state(), (pid(), pid() -> state())) :: state()
  defp with_git_buffer(%{buffers: %{active: buf}} = state, fun)
       when is_pid(buf) do
    case GitTracker.lookup(buf) do
      nil ->
        %{state | status_msg: "Not in a git repository"}

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
    BufferServer.move_to(buf, {line, 0})
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
