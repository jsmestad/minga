defmodule MingaEditor.Commands.Git do
  @moduledoc """
  Git commands: status panel, remote operations (push/pull/fetch), diff view,
  branch picker, hunk navigation, stage, revert, preview, and blame.
  """

  @behaviour Minga.Command.Provider

  alias Minga.Buffer
  alias Minga.Core.Diff
  alias Minga.Core.DiffView
  alias MingaEditor.Commands
  alias MingaEditor.PickerUI
  alias MingaEditor.State, as: EditorState
  alias Minga.Git
  alias MingaEditor.Workspace.State, as: WorkspaceState
  alias Minga.Language
  alias MingaEditor.UI.Picker.GitChangedSource

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
    {:git_blame_toggle, "Toggle blame", true},
    {:git_commit_execute, "Commit", false},
    {:git_commit_abort, "Abort commit", false}
  ]

  @spec execute(state(), atom()) :: state()

  # ── Status panel toggle ────────────────────────────────────────────────────

  def execute(state, :git_status_toggle) do
    if state.workspace.keymap_scope == :git_status do
      state = EditorState.update_workspace(state, &WorkspaceState.set_keymap_scope(&1, :editor))
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
    PickerUI.open(state, MingaEditor.UI.Picker.GitBranchSource)
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
      hunks = Git.hunks(git_pid)

      case Diff.next_hunk_line(hunks, cursor_line) do
        nil -> EditorState.set_status(state, "No next hunk")
        line -> jump_to_line(state, buf, line)
      end
    end)
  end

  def execute(state, :prev_git_hunk) do
    with_git_buffer(state, fn git_pid, buf ->
      {cursor_line, _col} = Buffer.cursor(buf)
      hunks = Git.hunks(git_pid)

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

      case Git.hunk_at(git_pid, cursor_line) do
        nil -> EditorState.set_status(state, "No hunk at cursor")
        hunk -> do_stage_hunk(state, git_pid, buf, hunk)
      end
    end)
  end

  # ── Revert hunk ────────────────────────────────────────────────────────────

  def execute(state, :git_revert_hunk) do
    with_git_buffer(state, fn git_pid, buf ->
      {cursor_line, _col} = Buffer.cursor(buf)

      case Git.hunk_at(git_pid, cursor_line) do
        nil ->
          EditorState.set_status(state, "No hunk at cursor")

        hunk ->
          {content, _cursor} = Buffer.content_and_cursor(buf)
          current_lines = String.split(content, "\n")
          reverted_lines = Git.revert_hunk(current_lines, hunk)
          reverted_content = Enum.join(reverted_lines, "\n")

          Buffer.replace_content(buf, reverted_content)
          Git.Buffer.update(git_pid, reverted_content)
          EditorState.set_status(state, "Hunk reverted")
      end
    end)
  end

  # ── Preview hunk ───────────────────────────────────────────────────────────

  def execute(state, :git_preview_hunk) do
    with_git_buffer(state, fn git_pid, buf ->
      {cursor_line, _col} = Buffer.cursor(buf)

      case Git.hunk_at(git_pid, cursor_line) do
        nil -> EditorState.set_status(state, "No hunk at cursor")
        hunk -> EditorState.set_status(state, format_hunk_preview(hunk))
      end
    end)
  end

  # ── Toggle blame annotations ───────────────────────────────────────────────

  def execute(state, :git_blame_toggle) do
    with_git_buffer(state, fn git_pid, buf ->
      Git.Buffer.toggle_blame(git_pid)
      enabled = Git.Buffer.blame_enabled?(git_pid)

      if enabled do
        apply_blame_annotations(state, git_pid, buf)
      else
        Buffer.batch_decorations(buf, fn decs ->
          Minga.Core.Decorations.remove_group(decs, :git_blame)
        end)

        EditorState.set_status(state, "Blame annotations disabled")
      end
    end)
  end

  # ── Commit message buffer ─────────────────────────────────────────────────

  def execute(state, :git_commit_execute) do
    case EditorState.git_commit_meta(state) do
      nil ->
        EditorState.set_status(state, "No commit in progress")

      %{git_root: git_root, amend: amend, buffer_pid: buf_pid} ->
        {content, _cursor} = Buffer.content_and_cursor(buf_pid)
        message = strip_commit_comments(content)

        if String.trim(message) == "" do
          state = close_commit_buffer(state, buf_pid)
          EditorState.set_status(state, "Aborting commit due to empty message")
        else
          result =
            if amend do
              Git.commit_amend(git_root, message)
            else
              Git.commit(git_root, message)
            end

          state = close_commit_buffer(state, buf_pid)
          handle_commit_result(state, result, git_root, amend)
        end
    end
  end

  def execute(state, :git_commit_abort) do
    case EditorState.git_commit_meta(state) do
      nil ->
        EditorState.set_status(state, "No commit in progress")

      %{buffer_pid: buf_pid} ->
        state = close_commit_buffer(state, buf_pid)
        EditorState.set_status(state, "Commit aborted")
    end
  end

  # ── Private ────────────────────────────────────────────────────────────────

  # Mutual exclusivity: close file tree when opening git status.
  @spec close_file_tree_if_open(state()) :: state()
  defp close_file_tree_if_open(%{workspace: %{file_tree: %{tree: nil}}} = state), do: state
  defp close_file_tree_if_open(state), do: Commands.FileTree.close(state)

  @spec open_diff_view(state(), pid(), pid()) :: state()
  defp open_diff_view(state, git_pid, buf) do
    git_root = Git.Buffer.git_root(git_pid)
    rel_path = Git.Buffer.relative_path(git_pid)
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

  Called by `MingaEditor.handle_info/2` when a `{:git_remote_result, ref, result}`
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

        state
        |> EditorState.clear_git_remote_op()
        |> EditorState.set_status(status_msg)

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
        state
        |> EditorState.clear_git_remote_op()
        |> EditorState.set_status("Git operation failed unexpectedly")

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

        state
        |> EditorState.set_git_remote_op(
          {ref, task_monitor, {git_root, success_msg, error_prefix}}
        )
        |> EditorState.set_status(progress_msg)

      :not_git ->
        EditorState.set_status(state, "Not in a git repository")
    end
  end

  @spec refresh_repo(String.t()) :: :ok
  defp refresh_repo(git_root) do
    case Git.lookup_repo(git_root) do
      nil -> :ok
      pid -> Git.refresh_repo(pid)
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
    case Git.lookup_repo(git_root) do
      nil ->
        EditorState.set_status(state, "Git.Repo not available")

      repo_pid ->
        entries = Git.repo_status(repo_pid)
        summary = Git.repo_summary(repo_pid)

        panel_data = %{
          repo_state: :normal,
          branch: summary.branch || "",
          ahead: summary.ahead,
          behind: summary.behind,
          entries: entries
        }

        # Mutual exclusivity: close file tree when opening git status
        state = close_file_tree_if_open(state)

        state =
          EditorState.update_workspace(state, &WorkspaceState.set_keymap_scope(&1, :git_status))

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
    git_root = Git.Buffer.git_root(git_pid)
    rel_path = Git.Buffer.relative_path(git_pid)
    {content, _cursor} = Buffer.content_and_cursor(buf)
    base_lines = get_base_lines(git_pid)
    current_lines = String.split(content, "\n")

    patch = Diff.generate_patch(rel_path, base_lines, current_lines, hunk)

    case Git.stage_patch(git_root, patch) do
      :ok ->
        Git.Buffer.invalidate_base(git_pid, content)
        EditorState.set_status(state, "Hunk staged")

      {:error, reason} ->
        EditorState.set_status(state, "Stage failed: #{reason}")
    end
  end

  @spec with_git_buffer(state(), (pid(), pid() -> state())) :: state()
  defp with_git_buffer(%{workspace: %{buffers: %{active: buf}}} = state, fun)
       when is_pid(buf) do
    case Git.tracking_pid(buf) do
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

  # ── Commit buffer helpers ─────────────────────────────────────────────────

  @spec strip_commit_comments(String.t()) :: String.t()
  defp strip_commit_comments(content) do
    content
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Enum.join("\n")
    |> String.trim()
  end

  @spec close_commit_buffer(state(), pid()) :: state()
  defp close_commit_buffer(state, buf_pid) do
    # Restore scope: if git status panel is open, go back to git_status; otherwise editor
    restore_scope =
      if EditorState.git_status_panel(state) != nil,
        do: :git_status,
        else: :editor

    state = EditorState.clear_git_commit(state)
    state = EditorState.transition_mode(state, :normal)

    state =
      EditorState.update_workspace(state, &WorkspaceState.set_keymap_scope(&1, restore_scope))

    # Remove the commit buffer from the buffer list
    buffers = state.workspace.buffers
    buf_list = buffers.list
    idx = Enum.find_index(buf_list, &(&1 == buf_pid))

    # Stop the buffer process
    try do
      GenServer.stop(buf_pid, :normal)
    catch
      :exit, _ -> :ok
    end

    case idx do
      nil ->
        state

      i ->
        new_list = List.delete_at(buf_list, i)
        new_idx = min(max(i - 1, 0), max(length(new_list) - 1, 0))
        new_active = Enum.at(new_list, new_idx)

        put_in(state.workspace.buffers, %{
          buffers
          | list: new_list,
            active_index: new_idx,
            active: new_active
        })
        |> EditorState.sync_active_window_buffer()
    end
  end

  @spec handle_commit_result(
          state(),
          {:ok, String.t()} | {:error, String.t()},
          String.t(),
          boolean()
        ) ::
          state()
  defp handle_commit_result(state, {:ok, short_hash}, git_root, amend) do
    refresh_repo(git_root)
    verb = if amend, do: "Amended", else: "Committed"
    EditorState.set_status(state, "#{verb} [#{short_hash}]")
  end

  defp handle_commit_result(state, {:error, reason}, _git_root, _amend) do
    MingaEditor.log_to_messages("Commit failed: #{reason}")
    EditorState.set_status(state, "Commit failed: #{reason}")
  end

  # ── Blame annotation helpers ──────────────────────────────────────────────

  @spec apply_blame_annotations(state(), pid(), pid()) :: state()
  defp apply_blame_annotations(state, git_pid, buf) do
    case Git.Buffer.blame_data(git_pid) do
      nil ->
        EditorState.set_status(state, "Blame data unavailable")

      blame_data when map_size(blame_data) == 0 ->
        EditorState.set_status(state, "Blame annotations enabled (no data)")

      blame_data ->
        alias Minga.Core.Decorations

        Buffer.batch_decorations(buf, fn decs ->
          decs = Decorations.remove_group(decs, :git_blame)

          Enum.reduce(blame_data, decs, fn {line, info}, acc ->
            text = format_blame_annotation(info)

            {_id, acc} =
              Decorations.add_annotation(acc, line, text,
                kind: :inline_text,
                fg: 0x6B7280,
                group: :git_blame,
                priority: -10
              )

            acc
          end)
        end)

        EditorState.set_status(state, "Blame annotations enabled")
    end
  end

  @spec format_blame_annotation(Minga.Git.blame_info()) :: String.t()
  defp format_blame_annotation(%{author: author, date: date, summary: summary}) do
    text = "#{author} (#{date}): #{summary}"

    if String.length(text) > 60 do
      String.slice(text, 0, 57) <> "..."
    else
      text
    end
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
