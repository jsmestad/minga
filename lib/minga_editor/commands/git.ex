defmodule MingaEditor.Commands.Git do
  @moduledoc """
  Git commands: status panel, remote operations (push/pull/fetch), diff view,
  branch picker, hunk navigation, stage, revert, preview, and blame.
  """

  @behaviour Minga.Command.Provider

  alias Minga.Buffer
  alias Minga.Core.Diff
  alias Minga.Core.DiffView
  alias Minga.Core.Face
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
    {:git_blame_line, "Blame line", true},
    {:git_diff_toggle_staged, "Toggle diff staged/unstaged", true}
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

  def execute(state, :git_diff_toggle_staged) do
    active_buf = state.workspace.buffers.active
    toggle_diff_staged(state, active_buf)
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

  # ── Blame line ─────────────────────────────────────────────────────────────

  def execute(state, :git_blame_line) do
    with_git_buffer(state, fn git_pid, buf ->
      {cursor_line, _col} = Buffer.cursor(buf)
      git_root = Git.Buffer.git_root(git_pid)
      rel_path = Git.Buffer.relative_path(git_pid)

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

  @doc """
  Opens a diff view for a file specified by path.

  Used by the git status panel when opening diffs for files that may not
  have an open buffer. Creates a temporary buffer for the current content
  and opens a diff view against HEAD.
  """
  @spec open_diff_for_path(state(), String.t(), String.t(), String.t(), String.t(), keyword()) ::
          state()
  def open_diff_for_path(state, git_root, rel_path, _abs_path, current_content, opts \\ []) do
    base_content = head_content(git_root, rel_path)
    staged = Keyword.get(opts, :staged, false)
    label = if staged, do: "staged", else: "unstaged"

    diff_result = DiffView.build(base_content, current_content)
    filename = Path.basename(rel_path)
    filetype = Language.detect_filetype(filename)

    case Buffer.start_link(
           content: diff_result.text,
           buffer_type: :nofile,
           read_only: true,
           buffer_name: "#{filename} [diff:#{label}]",
           filetype: filetype
         ) do
      {:ok, diff_buf} ->
        apply_diff_decorations(diff_buf, diff_result.line_metadata, state.theme)

        diff_info = %{
          source_buf: nil,
          git_root: git_root,
          rel_path: rel_path,
          staged: staged,
          line_metadata: diff_result.line_metadata
        }

        state
        |> EditorState.register_diff_view(diff_buf, diff_info)
        |> Commands.add_buffer(diff_buf)
        |> EditorState.set_status(
          "Diff (#{label}): #{filename} (#{length(diff_result.hunk_lines)} hunks)"
        )

      {:error, reason} ->
        EditorState.set_status(state, "Failed to open diff: #{inspect(reason)}")
    end
  end

  @spec open_diff_view(state(), pid(), pid()) :: state()
  defp open_diff_view(state, git_pid, buf) do
    open_diff_view(state, git_pid, buf, _staged = false)
  end

  @spec open_diff_view(state(), pid(), pid(), boolean()) :: state()
  defp open_diff_view(state, git_pid, buf, staged) do
    git_root = Git.Buffer.git_root(git_pid)
    rel_path = Git.Buffer.relative_path(git_pid)

    {base_content, current_content} = diff_contents(git_root, rel_path, buf, staged)

    diff_result = DiffView.build(base_content, current_content)
    filename = Path.basename(rel_path)
    filetype = Language.detect_filetype(filename)
    label = if staged, do: "staged", else: "unstaged"

    case Buffer.start_link(
           content: diff_result.text,
           buffer_type: :nofile,
           read_only: true,
           buffer_name: "#{filename} [diff:#{label}]",
           filetype: filetype
         ) do
      {:ok, diff_buf} ->
        apply_diff_decorations(diff_buf, diff_result.line_metadata, state.theme)

        diff_info = %{
          source_buf: buf,
          git_root: git_root,
          rel_path: rel_path,
          staged: staged,
          line_metadata: diff_result.line_metadata
        }

        state
        |> EditorState.register_diff_view(diff_buf, diff_info)
        |> Commands.add_buffer(diff_buf)
        |> EditorState.set_status(
          "Diff (#{label}): #{filename} (#{length(diff_result.hunk_lines)} hunks)"
        )

      {:error, reason} ->
        EditorState.set_status(state, "Failed to open diff: #{inspect(reason)}")
    end
  end

  @spec diff_contents(String.t(), String.t(), pid(), boolean()) :: {String.t(), String.t()}
  defp diff_contents(git_root, rel_path, buf, false) do
    base_content = head_content(git_root, rel_path)
    {current_content, _cursor} = Buffer.content_and_cursor(buf)
    {base_content, current_content}
  end

  defp diff_contents(git_root, rel_path, _buf, true) do
    base_content = head_content(git_root, rel_path)
    {base_content, staged_content(git_root, rel_path)}
  end

  @spec head_content(String.t(), String.t()) :: String.t()
  defp head_content(git_root, rel_path) do
    case Git.show_head(git_root, rel_path) do
      {:ok, content} -> content
      :error -> ""
    end
  end

  @spec staged_content(String.t(), String.t()) :: String.t()
  defp staged_content(git_root, rel_path) do
    case Git.show_staged(git_root, rel_path) do
      {:ok, content} -> content
      :error -> staged_content_fallback(git_root, rel_path)
    end
  end

  @spec staged_content_fallback(String.t(), String.t()) :: String.t()
  defp staged_content_fallback(git_root, rel_path) do
    if staged_deleted?(git_root, rel_path), do: "", else: head_content(git_root, rel_path)
  end

  @spec staged_deleted?(String.t(), String.t()) :: boolean()
  defp staged_deleted?(git_root, rel_path) do
    case Git.status(git_root) do
      {:ok, entries} -> Enum.any?(entries, &staged_deleted_entry?(&1, rel_path))
      {:error, _reason} -> false
    end
  end

  @spec staged_deleted_entry?(Git.StatusEntry.t(), String.t()) :: boolean()
  defp staged_deleted_entry?(
         %Git.StatusEntry{path: path, status: :deleted, staged: true},
         rel_path
       ),
       do: path == rel_path

  defp staged_deleted_entry?(%Git.StatusEntry{}, _rel_path), do: false

  @spec apply_diff_decorations(pid(), [DiffView.line_meta()], MingaEditor.UI.Theme.t()) :: :ok
  defp apply_diff_decorations(diff_buf, line_metadata, theme) do
    Buffer.batch_decorations(diff_buf, fn decs ->
      apply_diff_decorations_to(decs, line_metadata, theme)
    end)
  end

  @spec apply_line_decoration(
          Minga.Core.Decorations.t(),
          DiffView.line_meta(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: Minga.Core.Decorations.t()
  defp apply_line_decoration(decs, %{type: :added}, line_idx, added_bg, _removed_bg, _fold_fg) do
    {_id, decs} =
      Minga.Core.Decorations.add_highlight(decs, {line_idx, 0}, {line_idx, 9999},
        style: Face.new(bg: added_bg),
        priority: 1,
        group: :diff
      )

    decs
  end

  defp apply_line_decoration(decs, %{type: :removed}, line_idx, _added_bg, removed_bg, _fold_fg) do
    {_id, decs} =
      Minga.Core.Decorations.add_highlight(decs, {line_idx, 0}, {line_idx, 9999},
        style: Face.new(bg: removed_bg),
        priority: 1,
        group: :diff
      )

    decs
  end

  defp apply_line_decoration(decs, %{type: :fold}, line_idx, _added_bg, _removed_bg, fold_fg) do
    {_id, decs} =
      Minga.Core.Decorations.add_highlight(decs, {line_idx, 0}, {line_idx, 9999},
        style: Face.new(fg: fold_fg, italic: true),
        priority: 1,
        group: :diff
      )

    decs
  end

  defp apply_line_decoration(decs, _meta, _line_idx, _added_bg, _removed_bg, _fold_fg), do: decs

  @spec tint_color(non_neg_integer(), non_neg_integer(), float()) :: non_neg_integer()
  defp tint_color(fg, bg, alpha) do
    fg_r = Bitwise.bsr(fg, 16) |> Bitwise.band(0xFF)
    fg_g = Bitwise.bsr(fg, 8) |> Bitwise.band(0xFF)
    fg_b = Bitwise.band(fg, 0xFF)

    bg_r = Bitwise.bsr(bg, 16) |> Bitwise.band(0xFF)
    bg_g = Bitwise.bsr(bg, 8) |> Bitwise.band(0xFF)
    bg_b = Bitwise.band(bg, 0xFF)

    r = round(fg_r * alpha + bg_r * (1.0 - alpha))
    g = round(fg_g * alpha + bg_g * (1.0 - alpha))
    b = round(fg_b * alpha + bg_b * (1.0 - alpha))

    Bitwise.bsl(r, 16) + Bitwise.bsl(g, 8) + b
  end

  @spec toggle_diff_staged(state(), pid()) :: state()
  defp toggle_diff_staged(state, active_buf) do
    case EditorState.diff_view_info(state, active_buf) do
      nil ->
        EditorState.set_status(state, "Not a diff view")

      %{source_buf: nil} ->
        EditorState.set_status(state, "Cannot toggle staged: diff opened from status panel")

      %{source_buf: source_buf, staged: staged} ->
        new_staged = not staged
        git_pid = Git.tracking_pid(source_buf)

        if git_pid do
          GenServer.stop(active_buf, :normal)
          state = EditorState.unregister_diff_view(state, active_buf)
          open_diff_view(state, git_pid, source_buf, new_staged)
        else
          EditorState.set_status(state, "Source buffer no longer tracked by git")
        end
    end
  end

  @doc """
  Refreshes all open diff views whose source buffer matches the saved path.

  Called by `MingaEditor.handle_info/2` on `:buffer_saved` events.
  """
  @spec refresh_diff_views_for_buffer(state(), pid()) :: state()
  def refresh_diff_views_for_buffer(state, saved_buf) do
    diff_views = EditorState.diff_views_for_source(state, saved_buf)

    Enum.reduce(diff_views, state, fn {diff_buf,
                                       %{git_root: git_root, rel_path: rel_path, staged: staged}},
                                      acc ->
      refresh_diff_buffer(acc, diff_buf, saved_buf, git_root, rel_path, staged)
    end)
  end

  @spec refresh_diff_buffer(state(), pid(), pid(), String.t(), String.t(), boolean()) :: state()
  defp refresh_diff_buffer(state, diff_buf, source_buf, git_root, rel_path, staged) do
    {base_content, current_content} = diff_contents(git_root, rel_path, source_buf, staged)
    diff_result = DiffView.build(base_content, current_content)

    Buffer.replace_content_with_decorations(
      diff_buf,
      diff_result.text,
      fn _decs ->
        decs = Minga.Core.Decorations.new()
        apply_diff_decorations_to(decs, diff_result.line_metadata, state.theme)
      end
    )

    diff_info = %{
      source_buf: source_buf,
      git_root: git_root,
      rel_path: rel_path,
      staged: staged,
      line_metadata: diff_result.line_metadata
    }

    EditorState.register_diff_view(state, diff_buf, diff_info)
  end

  @spec apply_diff_decorations_to(
          Minga.Core.Decorations.t(),
          [DiffView.line_meta()],
          MingaEditor.UI.Theme.t()
        ) :: Minga.Core.Decorations.t()
  defp apply_diff_decorations_to(decs, line_metadata, theme) do
    added_bg = tint_color(theme.git.added_fg, theme.editor.bg, 0.15)
    removed_bg = tint_color(theme.git.deleted_fg, theme.editor.bg, 0.15)
    fold_fg = theme.gutter.fg

    line_metadata
    |> Enum.with_index()
    |> Enum.reduce(decs, fn {meta, line_idx}, decs ->
      apply_line_decoration(decs, meta, line_idx, added_bg, removed_bg, fold_fg)
    end)
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

        {status_msg, toast} =
          case result do
            :ok ->
              refresh_repo(git_root)

              {success_msg, %{message: success_msg, level: :success, action: nil}}

            {:error, reason} ->
              error_msg = "#{error_prefix}: #{reason}"
              action = push_rejection_action(reason)

              {error_msg, %{message: error_msg, level: :error, action: action}}
          end

        schedule_toast_dismissal()

        state
        |> EditorState.clear_git_remote_op()
        |> EditorState.set_status(status_msg)
        |> EditorState.set_git_toast(toast)

      _ ->
        # Stale result from a superseded operation; ignore
        state
    end
  end

  @spec push_rejection_action(String.t()) :: :pull_and_retry | nil
  defp push_rejection_action(reason) do
    lowered = String.downcase(reason)

    if String.contains?(lowered, "rejected") or String.contains?(lowered, "non-fast-forward") do
      :pull_and_retry
    else
      nil
    end
  end

  @spec schedule_toast_dismissal() :: reference()
  defp schedule_toast_dismissal do
    Process.send_after(self(), :dismiss_git_toast, 3_000)
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
