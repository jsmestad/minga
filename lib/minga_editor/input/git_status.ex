defmodule MingaEditor.Input.GitStatus do
  @moduledoc """
  Input handler for the TUI git status panel.

  When the git status panel is active (`:git_status` scope), this handler
  intercepts keys and routes them through the git status keymap scope.
  Navigation (j/k), operations (s/u/d), and close (q/Esc) are handled here.
  """

  @behaviour MingaEditor.Input.Handler

  @type state :: MingaEditor.Input.Handler.handler_state()

  alias Minga.Buffer
  alias MingaEditor.Commands
  alias MingaEditor.State, as: EditorState
  alias Minga.Git
  alias MingaEditor.Input
  alias MingaEditor.Layout
  alias MingaEditor.Shell.Traditional.GitStatus.TuiState
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias Minga.Keymap
  alias MingaEditor.PromptUI
  alias MingaEditor.UI.Prompt.GitCommit, as: CommitPrompt
  alias MingaEditor.Workspace.State, as: WorkspaceState

  @impl true
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  def handle_key(%{workspace: %{keymap_scope: :git_status}} = state, cp, mods) do
    if Input.key_sequence_pending?(state) do
      # Multi-key sequence in progress; delegate to mode FSM
      {:passthrough, state}
    else
      key = {cp, mods}

      binding_state = Minga.Editing.binding_state(state)

      case Keymap.resolve_scoped_key(
             :git_status,
             binding_state,
             key,
             EditorState.keymap_context(state)
           ) do
        {:command, cmd} ->
          {:handled, execute_command(state, cmd)}

        {:prefix, _node} ->
          # Let the mode FSM handle multi-key sequences (e.g., "cc")
          {:passthrough, state}

        :not_found ->
          {:passthrough, state}
      end
    end
  end

  def handle_key(state, _cp, _mods), do: {:passthrough, state}

  @impl true
  def handle_mouse(state, _row, _col, _button, _mods, _event_type, _click_count) do
    {:passthrough, state}
  end

  # ── Command execution ──────────────────────────────────────────────────

  @spec execute_command(EditorState.t(), atom()) :: EditorState.t()
  defp execute_command(state, :git_status_next) do
    update_tui_state(state, &TuiState.next/2)
  end

  defp execute_command(state, :git_status_prev) do
    update_tui_state(state, fn tui, _entries -> TuiState.prev(tui) end)
  end

  defp execute_command(state, :git_status_next_section) do
    update_tui_state(state, &TuiState.next_section/2)
  end

  defp execute_command(state, :git_status_prev_section) do
    update_tui_state(state, &TuiState.prev_section/2)
  end

  defp execute_command(state, :git_status_toggle_section) do
    update_tui_state(state, &TuiState.toggle_current_section/2)
  end

  defp execute_command(state, :git_status_stage) do
    with_selected_file(state, fn entry, git_root ->
      if entry.staged do
        Git.unstage(git_root, entry.path)
      else
        Git.stage(git_root, entry.path)
      end

      refresh_repo(git_root)
      msg = if entry.staged, do: "Unstaged #{entry.path}", else: "Staged #{entry.path}"
      EditorState.set_status(state, msg)
    end)
  end

  defp execute_command(state, :git_status_unstage) do
    with_selected_file(state, fn entry, git_root ->
      Git.unstage(git_root, entry.path)
      refresh_repo(git_root)
      EditorState.set_status(state, "Unstaged #{entry.path}")
    end)
  end

  defp execute_command(state, :git_status_stage_all) do
    case resolve_git_root() do
      nil ->
        EditorState.set_status(state, "Not in a git repository")

      git_root ->
        Git.stage(git_root, ".")
        refresh_repo(git_root)
        EditorState.set_status(state, "Staged all changes")
    end
  end

  defp execute_command(state, :git_status_unstage_all) do
    case resolve_git_root() do
      nil ->
        EditorState.set_status(state, "Not in a git repository")

      git_root ->
        Git.unstage_all(git_root)
        refresh_repo(git_root)
        EditorState.set_status(state, "Unstaged all")
    end
  end

  defp execute_command(state, :git_status_open_file) do
    with_selected_file(state, fn entry, git_root ->
      abs_path = Path.join(git_root, entry.path)

      closed_state = close_panel(state)

      open_file_in_editor(closed_state, abs_path)
    end)
  end

  defp execute_command(state, :git_status_open_diff) do
    with_selected_file(state, fn entry, git_root ->
      open_diff_for_entry(state, git_root, entry)
    end)
  end

  defp execute_command(state, :git_status_discard) do
    with_selected_file(state, fn entry, git_root ->
      update_tui_state(state, fn tui, _entries ->
        TuiState.request_discard(tui, entry, git_root)
      end)
    end)
  end

  defp execute_command(state, :git_status_confirm_discard) do
    case get_discard_confirmation(state) do
      {entry, git_root} ->
        result = Git.discard(git_root, entry.path)
        refresh_repo(git_root)

        status_msg =
          case result do
            :ok ->
              "Discarded #{entry.path}"

            {:error, reason} ->
              msg = "Discard failed: #{reason}"
              MingaEditor.log_to_messages(msg)
              msg
          end

        state
        |> update_tui_state(fn tui, _entries -> TuiState.clear_discard_confirmation(tui) end)
        |> EditorState.set_status(status_msg)

      nil ->
        state
    end
  end

  defp execute_command(state, :git_status_cancel_discard) do
    update_tui_state(state, fn tui, _entries -> TuiState.clear_discard_confirmation(tui) end)
  end

  defp execute_command(state, :git_status_push) do
    case resolve_git_root() do
      nil ->
        EditorState.set_status(state, "Not in a git repository")

      git_root ->
        do_git_remote_op(state, git_root, &Git.push/1, "Pushing…", "Pushed", "Push failed")
    end
  end

  defp execute_command(state, :git_status_pull) do
    case resolve_git_root() do
      nil ->
        EditorState.set_status(state, "Not in a git repository")

      git_root ->
        do_git_remote_op(state, git_root, &Git.pull/1, "Pulling…", "Pulled", "Pull failed")
    end
  end

  defp execute_command(state, :git_status_fetch) do
    case resolve_git_root() do
      nil ->
        EditorState.set_status(state, "Not in a git repository")

      git_root ->
        do_git_remote_op(
          state,
          git_root,
          &Git.fetch_remotes/1,
          "Fetching…",
          "Fetched",
          "Fetch failed"
        )
    end
  end

  defp execute_command(state, :git_status_amend) do
    case resolve_git_root() do
      nil ->
        EditorState.set_status(state, "Not in a git repository")

      _git_root ->
        update_tui_state(state, fn tui, _entries -> TuiState.toggle_amend(tui) end)
    end
  end

  defp execute_command(state, :git_status_start_commit) do
    PromptUI.open(state, CommitPrompt)
  end

  defp execute_command(state, :git_status_close) do
    close_panel(state)
  end

  defp execute_command(state, _cmd), do: state

  # ── TUI state helpers ──────────────────────────────────────────────────

  @spec close_panel(EditorState.t()) :: EditorState.t()
  defp close_panel(state) do
    state
    |> EditorState.update_workspace(&WorkspaceState.set_keymap_scope(&1, :editor))
    |> EditorState.close_git_status_panel()
    |> Layout.invalidate()
    |> EditorState.invalidate_all_windows()
  end

  @spec open_diff_for_entry(EditorState.t(), String.t(), Git.StatusEntry.t()) :: EditorState.t()
  defp open_diff_for_entry(state, git_root, %Git.StatusEntry{} = entry) do
    closed_state = close_panel(state)

    open_diff_in_editor(closed_state, git_root, entry)
  end

  @spec open_diff_in_editor(EditorState.t(), String.t(), Git.StatusEntry.t()) :: EditorState.t()
  defp open_diff_in_editor(state, git_root, %Git.StatusEntry{} = entry) do
    abs_path = Path.join(git_root, entry.path)

    case content_for_entry(git_root, abs_path, entry) do
      {:ok, current_content} ->
        Commands.Git.open_diff_for_path(state, git_root, entry.path, abs_path, current_content,
          staged: entry.staged
        )

      {:error, message} ->
        EditorState.set_status(state, message)
    end
  end

  @spec content_for_entry(String.t(), String.t(), Git.StatusEntry.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp content_for_entry(_git_root, _abs_path, %Git.StatusEntry{status: :deleted}) do
    {:ok, ""}
  end

  defp content_for_entry(git_root, _abs_path, %Git.StatusEntry{path: rel_path, staged: true}) do
    case Git.show_staged(git_root, rel_path) do
      {:ok, content} -> {:ok, content}
      :error -> {:error, "Could not read staged file: #{rel_path}"}
    end
  end

  defp content_for_entry(_git_root, abs_path, %Git.StatusEntry{}) do
    case File.read(abs_path) do
      {:ok, current_content} -> {:ok, current_content}
      {:error, reason} -> {:error, "Could not read file: #{inspect(reason)}"}
    end
  end

  @spec get_discard_confirmation(EditorState.t()) :: {Git.StatusEntry.t(), String.t()} | nil
  defp get_discard_confirmation(state) do
    case EditorState.git_status_panel(state) do
      nil -> nil
      _panel -> git_status_tui_state(state).discard_confirmation
    end
  end

  @spec do_git_remote_op(
          EditorState.t(),
          String.t(),
          (String.t() -> :ok | {:error, String.t()}),
          String.t(),
          String.t(),
          String.t()
        ) :: EditorState.t()
  defp do_git_remote_op(state, git_root, operation, _progress_msg, success_msg, error_prefix) do
    # For now, just run synchronously. Could be improved with async later.
    case operation.(git_root) do
      :ok ->
        refresh_repo(git_root)
        EditorState.set_status(state, success_msg)

      {:error, reason} ->
        error_msg = "#{error_prefix}: #{reason}"
        MingaEditor.log_to_messages(error_msg)
        EditorState.set_status(state, error_msg)
    end
  end

  @spec open_file_in_editor(EditorState.t(), String.t()) :: EditorState.t()
  defp open_file_in_editor(state, abs_path) do
    idx =
      Enum.find_index(state.workspace.buffers.list, fn buf ->
        try do
          Buffer.file_path(buf) == abs_path
        catch
          :exit, _ -> false
        end
      end)

    case idx do
      nil ->
        case Commands.start_buffer(abs_path) do
          {:ok, pid} -> Commands.add_buffer(state, pid)
          {:error, _} -> EditorState.set_status(state, "Could not open #{abs_path}")
        end

      i ->
        EditorState.switch_buffer(state, i)
    end
  end

  @spec update_tui_state(EditorState.t(), (TuiState.t(), [Git.StatusEntry.t()] -> TuiState.t())) ::
          EditorState.t()
  defp update_tui_state(%{shell_state: %{git_status_panel: nil}} = state, _fun), do: state

  defp update_tui_state(state, fun) do
    panel = EditorState.git_status_panel(state)
    entries = Map.get(panel, :entries) || []
    tui = git_status_tui_state(state)

    updated =
      fun.(tui, entries)
      |> TuiState.clamp_cursor(entries)

    EditorState.update_shell_state(state, &ShellState.set_git_status_tui_state(&1, updated))
  end

  @spec with_selected_file(EditorState.t(), (Git.StatusEntry.t(), String.t() -> EditorState.t())) ::
          EditorState.t()
  defp with_selected_file(state, fun) do
    case resolve_git_root() do
      nil ->
        EditorState.set_status(state, "Not in a git repository")

      git_root ->
        panel = EditorState.git_status_panel(state)
        entries = Map.get(panel || %{}, :entries) || []
        tui = git_status_tui_state(state)

        case TuiState.selected_file(tui, entries) do
          %Git.StatusEntry{} = entry -> fun.(entry, git_root)
          nil -> state
        end
    end
  end

  @spec refresh_repo(String.t()) :: :ok
  defp refresh_repo(git_root) do
    case Git.lookup_repo(git_root) do
      nil -> :ok
      pid -> Git.refresh_repo(pid)
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

  @spec git_status_tui_state(EditorState.t()) :: TuiState.t()
  defp git_status_tui_state(%{shell_state: %{git_status_tui_state: %TuiState{} = tui}}), do: tui
  defp git_status_tui_state(_state), do: TuiState.new()
end
