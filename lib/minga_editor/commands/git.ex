defmodule MingaEditor.Commands.Git do
  @moduledoc """
  Git commands: status panel, remote operations (push/pull/fetch), diff view,
  branch picker, hunk navigation, stage, revert, preview, and blame.
  """

  use MingaEditor.Commands.Provider

  alias Minga.Buffer
  alias Minga.Core.Diff
  alias Minga.Core.DiffView
  alias Minga.Core.Face
  alias MingaEditor.Commands
  alias MingaEditor.Layout
  alias MingaEditor.PickerUI
  alias MingaEditor.State, as: EditorState
  alias Minga.Git
  alias MingaEditor.Session.State, as: SessionState
  alias Minga.Language
  alias MingaEditor.UI.Picker.GitChangedSource

  @type state :: EditorState.t()

  @git_toast_duration_ms 3_000
  @pull_retry_markers [
    "non-fast-forward",
    "fetch first",
    "remote contains work",
    "tip of your current branch is behind"
  ]

  @command_specs [
    {:git_status_toggle, "Git status", false},
    {:git_changed_files, "Changed files", false},
    {:git_branch_picker, "Switch branch", false},
    {:git_push, "Push", false},
    {:git_pull, "Pull", false},
    {:git_fetch, "Fetch", false},
    {:git_pull_and_retry, "Pull and retry push", false},
    {:git_diff_file, "View diff", true},
    {:next_git_hunk, "Next git hunk", true},
    {:prev_git_hunk, "Previous git hunk", true},
    {:git_stage_hunk, "Stage hunk", true},
    {:git_stage_file, "Stage current file", true},
    {:git_unstage_file, "Unstage current file", true},
    {:git_revert_hunk, "Revert hunk", true},
    {:git_preview_hunk, "Preview hunk", true},
    {:git_blame_line, "Blame line", true},
    {:git_commit_open, "Open commit panel", false},
    {:git_amend_open, "Open amend panel", false},
    {:git_diff_toggle_staged, "Toggle diff staged/unstaged", true},
    {:git_generate_commit_message, "Generate AI commit message", false}
  ]

  @spec execute(state(), atom()) :: state()

  # ── Status panel toggle ────────────────────────────────────────────────────

  def execute(state, :git_status_toggle) do
    if state.workspace.keymap_scope == :git_status do
      state
      |> EditorState.update_workspace(&SessionState.set_keymap_scope(&1, :editor))
      |> EditorState.close_git_status_panel()
      |> Layout.invalidate()
      |> EditorState.invalidate_all_windows()
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

  def execute(state, :git_pull_and_retry) do
    git_remote_action(
      state,
      &pull_then_push/1,
      "Pulling and retrying…",
      "Pushed",
      "Pull and retry failed"
    )
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

  # ── AI commit message ──────────────────────────────────────────────────────

  def execute(state, :git_generate_commit_message) do
    generate_commit_message(state)
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
    active_buf = state.workspace.buffers.active

    case EditorState.diff_view_info(state, active_buf) do
      nil -> stage_hunk_from_source_buffer(state)
      diff_info -> stage_hunk_from_diff_view(state, active_buf, diff_info)
    end
  end

  # ── Stage / unstage file ────────────────────────────────────────────────────

  def execute(state, :git_stage_file) do
    with_git_buffer(state, fn git_pid, _buf ->
      git_root = Git.Buffer.git_root(git_pid)
      rel_path = Git.Buffer.relative_path(git_pid)

      case Git.stage(git_root, rel_path) do
        :ok ->
          refresh_repo(git_root)
          EditorState.set_status(state, "Staged: #{rel_path}")

        {:error, reason} ->
          EditorState.set_status(state, "Stage failed: #{reason}")
      end
    end)
  end

  def execute(state, :git_unstage_file) do
    with_git_buffer(state, fn git_pid, _buf ->
      git_root = Git.Buffer.git_root(git_pid)
      rel_path = Git.Buffer.relative_path(git_pid)

      case Git.unstage(git_root, rel_path) do
        :ok ->
          refresh_repo(git_root)
          EditorState.set_status(state, "Unstaged: #{rel_path}")

        {:error, reason} ->
          EditorState.set_status(state, "Unstage failed: #{reason}")
      end
    end)
  end

  # ── Commit / amend ────────────────────────────────────────────────────────

  def execute(state, :git_commit_open) do
    state =
      if state.workspace.keymap_scope != :git_status do
        open_git_status_panel(state)
      else
        state
      end

    MingaEditor.PromptUI.open(state, MingaEditor.UI.Prompt.GitCommit)
  end

  def execute(state, :git_amend_open) do
    state =
      if state.workspace.keymap_scope != :git_status do
        open_git_status_panel(state)
      else
        state
      end

    default_msg = git_status_last_commit_message(state)

    MingaEditor.PromptUI.open(state, MingaEditor.UI.Prompt.GitAmend, default: default_msg)
  end

  # ── Revert hunk ────────────────────────────────────────────────────────────

  def execute(state, :git_revert_hunk) do
    active_buf = state.workspace.buffers.active

    case EditorState.diff_view_info(state, active_buf) do
      nil -> revert_hunk_from_source_buffer(state)
      diff_info -> revert_hunk_from_diff_view(state, active_buf, diff_info)
    end
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
           filetype: filetype,
           options_server: EditorState.options_server(state)
         ) do
      {:ok, diff_buf} ->
        apply_diff_decorations(diff_buf, diff_result.line_metadata, state.theme)

        diff_info = %{
          source_buf: nil,
          git_root: git_root,
          rel_path: rel_path,
          staged: staged,
          line_metadata: diff_result.line_metadata,
          hunk_lines: diff_result.hunk_lines
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
           filetype: filetype,
           options_server: EditorState.options_server(state)
         ) do
      {:ok, diff_buf} ->
        apply_diff_decorations(diff_buf, diff_result.line_metadata, state.theme)

        diff_info = %{
          source_buf: buf,
          git_root: git_root,
          rel_path: rel_path,
          staged: staged,
          line_metadata: diff_result.line_metadata,
          hunk_lines: diff_result.hunk_lines
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
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: Minga.Core.Decorations.t()
  defp apply_line_decoration(
         decs,
         %{type: :added} = meta,
         line_idx,
         added_bg,
         _removed_bg,
         added_word_bg,
         _removed_word_bg,
         _fold_fg
       ) do
    {_id, decs} =
      Minga.Core.Decorations.add_highlight(decs, {line_idx, 0}, {line_idx, 9999},
        style: Face.new(bg: added_bg),
        priority: 1,
        group: :diff
      )

    apply_word_highlights(decs, line_idx, meta[:word_changes], added_word_bg)
  end

  defp apply_line_decoration(
         decs,
         %{type: :removed} = meta,
         line_idx,
         _added_bg,
         removed_bg,
         _added_word_bg,
         removed_word_bg,
         _fold_fg
       ) do
    {_id, decs} =
      Minga.Core.Decorations.add_highlight(decs, {line_idx, 0}, {line_idx, 9999},
        style: Face.new(bg: removed_bg),
        priority: 1,
        group: :diff
      )

    apply_word_highlights(decs, line_idx, meta[:word_changes], removed_word_bg)
  end

  defp apply_line_decoration(
         decs,
         %{type: :fold},
         line_idx,
         _added_bg,
         _removed_bg,
         _added_word_bg,
         _removed_word_bg,
         fold_fg
       ) do
    {_id, decs} =
      Minga.Core.Decorations.add_highlight(decs, {line_idx, 0}, {line_idx, 9999},
        style: Face.new(fg: fold_fg, italic: true),
        priority: 1,
        group: :diff
      )

    decs
  end

  defp apply_line_decoration(
         decs,
         _meta,
         _line_idx,
         _added_bg,
         _removed_bg,
         _added_word_bg,
         _removed_word_bg,
         _fold_fg
       ),
       do: decs

  @spec blend_color(non_neg_integer(), non_neg_integer(), float()) :: non_neg_integer()
  defp blend_color(source_color, target_color, alpha) do
    source_r = Bitwise.bsr(source_color, 16) |> Bitwise.band(0xFF)
    source_g = Bitwise.bsr(source_color, 8) |> Bitwise.band(0xFF)
    source_b = Bitwise.band(source_color, 0xFF)

    target_r = Bitwise.bsr(target_color, 16) |> Bitwise.band(0xFF)
    target_g = Bitwise.bsr(target_color, 8) |> Bitwise.band(0xFF)
    target_b = Bitwise.band(target_color, 0xFF)

    r = round(source_r * alpha + target_r * (1.0 - alpha))
    g = round(source_g * alpha + target_g * (1.0 - alpha))
    b = round(source_b * alpha + target_b * (1.0 - alpha))

    Bitwise.bsl(r, 16) + Bitwise.bsl(g, 8) + b
  end

  @spec apply_word_highlights(
          Minga.Core.Decorations.t(),
          non_neg_integer(),
          [Diff.char_range()] | nil,
          non_neg_integer()
        ) :: Minga.Core.Decorations.t()
  defp apply_word_highlights(decs, _line_idx, nil, _word_bg), do: decs
  defp apply_word_highlights(decs, _line_idx, [], _word_bg), do: decs

  defp apply_word_highlights(decs, line_idx, word_changes, word_bg) do
    Enum.reduce(word_changes, decs, fn {start_col, end_col}, acc ->
      {_id, acc} =
        Minga.Core.Decorations.add_highlight(acc, {line_idx, start_col}, {line_idx, end_col},
          style: Face.new(bg: word_bg),
          priority: 2,
          group: :diff_word
        )

      acc
    end)
  end

  @doc "Returns `{current_hunk, total_hunks}` for the cursor position in a diff view."
  @spec diff_hunk_position(state(), pid(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()} | nil
  def diff_hunk_position(state, buf, cursor_line) do
    case EditorState.diff_view_info(state, buf) do
      nil ->
        nil

      %{hunk_lines: []} ->
        nil

      %{hunk_lines: hunk_lines} ->
        total = length(hunk_lines)
        current = hunk_position_for_cursor(hunk_lines, cursor_line)
        {current, total}
    end
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
      line_metadata: diff_result.line_metadata,
      hunk_lines: diff_result.hunk_lines
    }

    EditorState.register_diff_view(state, diff_buf, diff_info)
  end

  @spec apply_diff_decorations_to(
          Minga.Core.Decorations.t(),
          [DiffView.line_meta()],
          MingaEditor.UI.Theme.t()
        ) :: Minga.Core.Decorations.t()
  defp apply_diff_decorations_to(decs, line_metadata, theme) do
    added_bg = blend_color(theme.git.added_fg, theme.editor.bg, 0.15)
    removed_bg = blend_color(theme.git.deleted_fg, theme.editor.bg, 0.15)
    added_word_bg = blend_color(theme.git.added_fg, theme.editor.bg, 0.35)
    removed_word_bg = blend_color(theme.git.deleted_fg, theme.editor.bg, 0.35)
    fold_fg = theme.gutter.fg

    line_metadata
    |> Enum.with_index()
    |> Enum.reduce(decs, fn {meta, line_idx}, decs ->
      apply_line_decoration(
        decs,
        meta,
        line_idx,
        added_bg,
        removed_bg,
        added_word_bg,
        removed_word_bg,
        fold_fg
      )
    end)
  end

  @doc """
  Handles the result of an async git remote operation.

  Called by `MingaEditor.handle_info/2` when a `{:git_remote_result, ref, result}`
  message arrives. Matches the ref against the in-flight operation to ignore stale
  results, then updates the status bar, toast banner, and cached git repo.
  """
  @spec handle_remote_result(state(), reference(), :ok | {:error, String.t()}) :: state()
  def handle_remote_result(state, ref, result) do
    case state.git_remote_op do
      {^ref, task_monitor, {git_root, success_msg, error_prefix}} ->
        Process.demonitor(task_monitor, [:flush])

        refresh_repo(git_root)
        {status_msg, toast} = remote_result_feedback(result, success_msg, error_prefix)

        state
        |> EditorState.clear_git_remote_op()
        |> EditorState.set_status(status_msg)
        |> EditorState.set_git_toast(with_dismiss_ref(toast))

      _ ->
        # Stale result from a superseded operation; ignore
        state
    end
  end

  @spec remote_result_feedback(:ok | {:error, String.t()}, String.t(), String.t()) ::
          {String.t(), MingaEditor.Shell.Traditional.State.git_toast()}
  defp remote_result_feedback(:ok, success_msg, _error_prefix) do
    {success_msg, %{message: success_msg, level: :success, action: nil}}
  end

  defp remote_result_feedback({:error, reason}, _success_msg, error_prefix) do
    error_msg = "#{error_prefix}: #{reason}"
    action = push_rejection_action(error_prefix, reason)
    {error_msg, %{message: error_msg, level: :error, action: action}}
  end

  @spec push_rejection_action(String.t(), String.t()) :: :pull_and_retry | nil
  defp push_rejection_action("Push failed", reason) do
    lowered = String.downcase(reason)

    if Enum.any?(@pull_retry_markers, &String.contains?(lowered, &1)) do
      :pull_and_retry
    else
      nil
    end
  end

  defp push_rejection_action(_error_prefix, _reason), do: nil

  @spec with_dismiss_ref(map()) :: map()
  defp with_dismiss_ref(toast) do
    Map.put(toast, :dismiss_ref, schedule_toast_dismissal())
  end

  @spec schedule_toast_dismissal() :: reference()
  defp schedule_toast_dismissal do
    dismiss_ref = make_ref()
    Process.send_after(self(), {:dismiss_git_toast, dismiss_ref}, @git_toast_duration_ms)
    dismiss_ref
  end

  @spec pull_then_push(String.t()) :: :ok | {:error, String.t()}
  defp pull_then_push(git_root) do
    case Git.pull(git_root) do
      :ok -> Git.push(git_root)
      {:error, reason} -> {:error, "pull failed: #{reason}"}
    end
  end

  @doc """
  Handles the `:DOWN` message for an async git remote process.

  A normal exit can arrive before the explicit remote-result message, so it
  leaves the operation in flight. Abnormal exits clear the operation and show an
  error so future remote operations are not permanently blocked. Called by the
  Editor's `:DOWN` handler.
  """
  @spec handle_remote_task_down(state(), reference(), term()) :: state() | :not_matched
  def handle_remote_task_down(state, monitor_ref, :normal) do
    case state.git_remote_op do
      {_, ^monitor_ref, _} -> state
      _ -> :not_matched
    end
  end

  def handle_remote_task_down(state, monitor_ref, reason) do
    case state.git_remote_op do
      {_, ^monitor_ref, {git_root, _, _}} ->
        refresh_repo(git_root)
        message = "Git operation failed unexpectedly: #{format_down_reason(reason)}"
        Minga.Log.warning(:editor, "Git remote task failed: #{inspect(reason)}")

        state
        |> EditorState.clear_git_remote_op()
        |> EditorState.set_status(message)
        |> EditorState.set_git_toast(
          with_dismiss_ref(%{message: message, level: :error, action: nil})
        )

      _ ->
        :not_matched
    end
  end

  @spec format_down_reason(term()) :: String.t()
  defp format_down_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp format_down_reason(reason) do
    inspect(reason, charlists: :as_lists, limit: 5)
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

        {_, monitor_ref} =
          spawn_monitor(fn ->
            result = operation.(git_root)
            send(editor_pid, {:git_remote_result, ref, result})
          end)

        state
        |> EditorState.clear_git_toast()
        |> EditorState.set_git_remote_op(
          {ref, monitor_ref, {git_root, success_msg, error_prefix}}
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
    project_root = Minga.Project.resolve_root()

    case Git.root_for(project_root) do
      {:ok, git_root} -> open_git_status_for_root(state, git_root)
      :not_git -> open_not_git_status_panel(state, project_root)
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
          entries: entries,
          entry_base_path: Minga.Project.resolve_root(),
          last_commit_message: summary.last_commit_message
        }

        # Mutual exclusivity: close file tree when opening git status
        state = close_file_tree_if_open(state)

        state =
          EditorState.update_workspace(state, &SessionState.set_keymap_scope(&1, :git_status))

        state
        |> EditorState.set_git_status_panel(panel_data)
        |> Layout.invalidate()
        |> EditorState.invalidate_all_windows()
    end
  end

  @spec open_not_git_status_panel(state(), String.t()) :: state()
  defp open_not_git_status_panel(state, project_root) do
    panel_data = %{
      repo_state: :not_a_repo,
      branch: "",
      ahead: 0,
      behind: 0,
      entries: [],
      entry_base_path: project_root,
      last_commit_message: ""
    }

    state = close_file_tree_if_open(state)

    state =
      EditorState.update_workspace(state, &SessionState.set_keymap_scope(&1, :git_status))

    state
    |> EditorState.set_git_status_panel(panel_data)
    |> Layout.invalidate()
    |> EditorState.invalidate_all_windows()
  end

  @spec git_status_last_commit_message(state()) :: String.t()
  defp git_status_last_commit_message(state) do
    case EditorState.git_status_panel(state) do
      nil -> ""
      panel -> Map.get(panel, :last_commit_message, "")
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

  @spec stage_hunk_from_source_buffer(state()) :: state()
  defp stage_hunk_from_source_buffer(state) do
    with_git_buffer(state, fn git_pid, buf -> stage_hunk_at_cursor(state, git_pid, buf) end)
  end

  @spec stage_hunk_at_cursor(state(), pid(), pid()) :: state()
  defp stage_hunk_at_cursor(state, git_pid, buf) do
    {cursor_line, _col} = Buffer.cursor(buf)

    case Git.hunk_at(git_pid, cursor_line) do
      nil -> EditorState.set_status(state, "No hunk at cursor")
      hunk -> do_stage_hunk(state, git_pid, buf, hunk)
    end
  end

  @spec revert_hunk_from_source_buffer(state()) :: state()
  defp revert_hunk_from_source_buffer(state) do
    with_git_buffer(state, fn git_pid, buf -> revert_hunk_at_cursor(state, git_pid, buf) end)
  end

  @spec revert_hunk_at_cursor(state(), pid(), pid()) :: state()
  defp revert_hunk_at_cursor(state, git_pid, buf) do
    {cursor_line, _col} = Buffer.cursor(buf)

    case Git.hunk_at(git_pid, cursor_line) do
      nil -> EditorState.set_status(state, "No hunk at cursor")
      hunk -> do_revert_hunk(state, git_pid, buf, hunk)
    end
  end

  @spec do_revert_hunk(state(), pid(), pid(), Diff.hunk()) :: state()
  defp do_revert_hunk(state, git_pid, buf, hunk) do
    {content, _cursor} = Buffer.content_and_cursor(buf)
    current_lines = String.split(content, "\n")
    reverted_lines = Git.revert_hunk(current_lines, hunk)
    reverted_content = Enum.join(reverted_lines, "\n")

    Buffer.replace_content(buf, reverted_content)
    Git.Buffer.update(git_pid, reverted_content)
    EditorState.set_status(state, "Hunk reverted")
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

  @spec stage_hunk_from_diff_view(state(), pid(), EditorState.diff_view_info()) :: state()
  defp stage_hunk_from_diff_view(state, diff_buf, %{staged: true}) do
    _ = diff_buf
    EditorState.set_status(state, "Cannot stage from a staged diff view")
  end

  defp stage_hunk_from_diff_view(state, diff_buf, diff_info) do
    %{hunk_lines: hunk_lines} = diff_info
    {cursor_line, _col} = Buffer.cursor(diff_buf)

    case find_diff_view_hunk_index(hunk_lines, diff_info.line_metadata, cursor_line) do
      nil -> EditorState.set_status(state, "No hunk at cursor")
      hunk_idx -> stage_diff_view_hunk(state, diff_buf, diff_info, hunk_idx)
    end
  end

  @spec stage_diff_view_hunk(state(), pid(), EditorState.diff_view_info(), non_neg_integer()) ::
          state()
  defp stage_diff_view_hunk(state, diff_buf, diff_info, hunk_idx) do
    current_content = current_content_for_diff(diff_info)
    {base_lines, current_lines, hunks} = diff_view_lines(diff_info, current_content)

    if stale_diff_view?(diff_buf, diff_info, base_lines, current_lines, hunks) do
      state
      |> refresh_diff_view_content(diff_buf, diff_info)
      |> EditorState.set_status("Diff view changed; retry hunk action")
    else
      case Enum.at(hunks, hunk_idx) do
        nil ->
          EditorState.set_status(state, "Hunk no longer exists")

        hunk ->
          apply_diff_view_stage(
            state,
            diff_buf,
            diff_info,
            hunk_idx,
            {base_lines, current_lines, hunks, current_content},
            hunk
          )
      end
    end
  end

  @spec apply_diff_view_stage(
          state(),
          pid(),
          EditorState.diff_view_info(),
          non_neg_integer(),
          {[String.t()], [String.t()], [Diff.hunk()], String.t()},
          Diff.hunk()
        ) :: state()
  defp apply_diff_view_stage(
         state,
         diff_buf,
         diff_info,
         hunk_idx,
         {base_lines, current_lines, hunks, current_content},
         hunk
       ) do
    %{git_root: git_root, rel_path: rel_path} = diff_info
    patch = Diff.generate_patch(rel_path, base_lines, current_lines, hunk)

    case Git.stage_patch(git_root, patch) do
      :ok ->
        invalidate_source_git_buffer(diff_info, current_content)
        {position, total} = {hunk_idx + 1, length(hunks)}

        state
        |> refresh_diff_view_content(diff_buf, diff_info)
        |> EditorState.set_status("Hunk #{position}/#{total} staged")

      {:error, reason} ->
        EditorState.set_status(state, "Stage failed: #{reason}")
    end
  end

  @spec revert_hunk_from_diff_view(state(), pid(), EditorState.diff_view_info()) :: state()
  defp revert_hunk_from_diff_view(state, _diff_buf, %{source_buf: nil}) do
    EditorState.set_status(state, "Cannot revert: diff opened from status panel")
  end

  defp revert_hunk_from_diff_view(state, _diff_buf, %{staged: true}) do
    EditorState.set_status(state, "Cannot revert from a staged diff view")
  end

  defp revert_hunk_from_diff_view(state, diff_buf, diff_info) do
    %{hunk_lines: hunk_lines} = diff_info
    {cursor_line, _col} = Buffer.cursor(diff_buf)

    case find_diff_view_hunk_index(hunk_lines, diff_info.line_metadata, cursor_line) do
      nil -> EditorState.set_status(state, "No hunk at cursor")
      hunk_idx -> revert_diff_view_hunk(state, diff_buf, diff_info, hunk_idx)
    end
  end

  @spec revert_diff_view_hunk(state(), pid(), EditorState.diff_view_info(), non_neg_integer()) ::
          state()
  defp revert_diff_view_hunk(state, diff_buf, %{source_buf: source_buf} = diff_info, hunk_idx) do
    {current_content, _cursor} = Buffer.content_and_cursor(source_buf)
    {base_lines, current_lines, hunks} = diff_view_lines(diff_info, current_content)

    if stale_diff_view?(diff_buf, diff_info, base_lines, current_lines, hunks) do
      state
      |> refresh_diff_view_content(diff_buf, diff_info)
      |> EditorState.set_status("Diff view changed; retry hunk action")
    else
      case Enum.at(hunks, hunk_idx) do
        nil ->
          EditorState.set_status(state, "Hunk no longer exists")

        hunk ->
          apply_diff_view_revert(
            state,
            diff_buf,
            diff_info,
            hunk_idx,
            {base_lines, current_lines, hunks},
            hunk
          )
      end
    end
  end

  @spec apply_diff_view_revert(
          state(),
          pid(),
          EditorState.diff_view_info(),
          non_neg_integer(),
          {[String.t()], [String.t()], [Diff.hunk()]},
          Diff.hunk()
        ) :: state()
  defp apply_diff_view_revert(
         state,
         diff_buf,
         diff_info,
         hunk_idx,
         {_base_lines, current_lines, hunks},
         hunk
       ) do
    reverted_lines = Diff.revert_hunk(current_lines, hunk)
    reverted_content = Enum.join(reverted_lines, "\n")
    %{source_buf: source_buf} = diff_info

    Buffer.replace_content(source_buf, reverted_content)

    git_pid = Git.tracking_pid(source_buf)
    if git_pid, do: Git.Buffer.update(git_pid, reverted_content)

    {position, total} = {hunk_idx + 1, length(hunks)}

    state
    |> refresh_diff_view_content(diff_buf, diff_info)
    |> EditorState.set_status("Hunk #{position}/#{total} reverted")
  end

  @spec stale_diff_view?(
          pid(),
          EditorState.diff_view_info(),
          [String.t()],
          [String.t()],
          [Diff.hunk()]
        ) :: boolean()
  defp stale_diff_view?(diff_buf, diff_info, base_lines, current_lines, hunks) do
    fresh = DiffView.build_from_hunks(base_lines, current_lines, hunks)
    {displayed_text, _cursor} = Buffer.content_and_cursor(diff_buf)

    displayed_text != fresh.text or diff_info.line_metadata != fresh.line_metadata or
      diff_info.hunk_lines != fresh.hunk_lines
  end

  @spec diff_view_lines(EditorState.diff_view_info(), String.t()) ::
          {[String.t()], [String.t()], [Diff.hunk()]}
  defp diff_view_lines(%{git_root: git_root, rel_path: rel_path}, current_content) do
    base_lines = git_root |> head_content(rel_path) |> split_lines()
    current_lines = split_lines(current_content)
    {base_lines, current_lines, Diff.diff_lines(base_lines, current_lines)}
  end

  @spec hunk_position_for_cursor([non_neg_integer()], non_neg_integer()) :: non_neg_integer()
  defp hunk_position_for_cursor(hunk_lines, cursor_line) do
    sorted = Enum.sort(hunk_lines)

    case Enum.find_index(sorted, fn line -> cursor_line <= line end) do
      nil -> length(sorted)
      idx -> idx + 1
    end
  end

  @spec find_diff_view_hunk_index(
          [non_neg_integer()],
          [DiffView.line_meta()],
          non_neg_integer()
        ) :: non_neg_integer() | nil
  defp find_diff_view_hunk_index([], _line_metadata, _cursor_line), do: nil

  defp find_diff_view_hunk_index(hunk_lines, line_metadata, cursor_line) do
    case Enum.at(line_metadata, cursor_line) do
      %{type: type} when type in [:added, :removed] ->
        find_hunk_ending_at_or_after(hunk_lines, cursor_line)

      _ ->
        nil
    end
  end

  @spec find_hunk_ending_at_or_after([non_neg_integer()], non_neg_integer()) ::
          non_neg_integer() | nil
  defp find_hunk_ending_at_or_after(hunk_lines, cursor_line) do
    hunk_lines
    |> Enum.sort()
    |> Enum.find_index(fn line -> cursor_line <= line end)
  end

  @spec current_content_for_diff(EditorState.diff_view_info()) :: String.t()
  defp current_content_for_diff(%{source_buf: nil, git_root: git_root, rel_path: rel_path}) do
    abs_path = Path.join(git_root, rel_path)

    case File.read(abs_path) do
      {:ok, content} -> content
      {:error, _} -> ""
    end
  end

  defp current_content_for_diff(%{source_buf: source_buf}) do
    {content, _cursor} = Buffer.content_and_cursor(source_buf)
    content
  end

  @spec invalidate_source_git_buffer(EditorState.diff_view_info(), String.t()) :: :ok
  defp invalidate_source_git_buffer(%{source_buf: nil}, _content), do: :ok

  defp invalidate_source_git_buffer(%{source_buf: source_buf}, content) do
    case Git.tracking_pid(source_buf) do
      nil -> :ok
      git_pid -> Git.Buffer.invalidate_base(git_pid, content)
    end
  end

  @spec refresh_diff_view_content(state(), pid(), EditorState.diff_view_info()) :: state()
  defp refresh_diff_view_content(state, diff_buf, %{staged: false} = diff_info) do
    %{git_root: git_root, rel_path: rel_path} = diff_info
    current_content = current_content_for_diff(diff_info)
    base_content = head_content(git_root, rel_path)

    diff_result = DiffView.build(base_content, current_content)

    Buffer.replace_content_with_decorations(
      diff_buf,
      diff_result.text,
      fn _decs ->
        decs = Minga.Core.Decorations.new()
        apply_diff_decorations_to(decs, diff_result.line_metadata, state.theme)
      end
    )

    updated_info = %{
      diff_info
      | line_metadata: diff_result.line_metadata,
        hunk_lines: diff_result.hunk_lines
    }

    EditorState.register_diff_view(state, diff_buf, updated_info)
  end

  @spec split_lines(String.t()) :: [String.t()]
  defp split_lines(""), do: []
  defp split_lines(content), do: String.split(content, "\n")

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

  @spec generate_commit_message(state()) :: state()
  defp generate_commit_message(%{git_commit_gen_ref: ref} = state)
       when ref != nil do
    EditorState.set_status(state, "Commit message generation already in progress")
  end

  defp generate_commit_message(state) do
    case resolve_git_root() do
      nil -> EditorState.set_status(state, "Not in a git repository")
      git_root -> generate_from_staged_diff(state, git_root)
    end
  end

  @spec generate_from_staged_diff(state(), String.t()) :: state()
  defp generate_from_staged_diff(state, git_root) do
    case Git.diff(git_root, staged: true) do
      {:ok, ""} ->
        EditorState.set_status(state, "Nothing staged to generate a message for")

      {:ok, diff} ->
        spawn_commit_message_task(state, diff)

      {:error, reason} ->
        EditorState.set_status(state, "Failed to read staged diff: #{reason}")
    end
  end

  @spec spawn_commit_message_task(state(), String.t()) :: state()
  defp spawn_commit_message_task(state, diff) do
    case MingaEditor.Git.CommitMessageGenerator.generate(diff, self()) do
      {:ok, _pid} ->
        ref = make_ref()
        timeout = MingaEditor.Git.CommitMessageGenerator.timeout_ms()
        Process.send_after(self(), :git_generate_timeout, timeout)

        state
        |> Map.put(:git_commit_gen_ref, ref)
        |> EditorState.set_status("Generating commit message…")

      {:error, reason} ->
        EditorState.set_status(state, "AI generation failed: #{inspect(reason)}")
    end
  end

  @spec resolve_git_root() :: String.t() | nil
  defp resolve_git_root do
    root = Minga.Project.resolve_root()

    case Git.root_for(root) do
      {:ok, git_root} -> git_root
      :not_git -> nil
    end
  end

  commands(@command_specs)
end
