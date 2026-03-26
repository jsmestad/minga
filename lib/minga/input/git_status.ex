defmodule Minga.Input.GitStatus do
  @moduledoc """
  Input handler for the TUI git status panel.

  When the git status panel is active (`:git_status` scope), this handler
  intercepts keys and routes them through the git status keymap scope.
  Navigation (j/k), operations (s/u/d), and close (q/Esc) are handled here.
  """

  @behaviour Minga.Input.Handler

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.Commands
  alias Minga.Editor.State, as: EditorState
  alias Minga.Git
  alias Minga.Git.Repo
  alias Minga.Input
  alias Minga.Input.GitStatus.TuiState
  alias Minga.Keymap.Scope

  @impl true
  @spec handle_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          {:handled, EditorState.t()} | {:passthrough, EditorState.t()}
  def handle_key(%{workspace: %{keymap_scope: :git_status}} = state, cp, mods) do
    if Input.key_sequence_pending?(state) do
      # Multi-key sequence in progress; delegate to mode FSM
      {:passthrough, state}
    else
      key = {cp, mods}

      case Scope.resolve_key(:git_status, :normal, key) do
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
    update_tui_state(state, fn tui ->
      next_idx = min(tui.cursor_index + 1, length(tui.flat_entries) - 1)
      %{tui | cursor_index: max(next_idx, 0)}
    end)
  end

  defp execute_command(state, :git_status_prev) do
    update_tui_state(state, fn tui ->
      %{tui | cursor_index: max(tui.cursor_index - 1, 0)}
    end)
  end

  defp execute_command(state, :git_status_next_section) do
    update_tui_state(state, fn tui ->
      next = find_next_section(tui.flat_entries, tui.cursor_index)
      %{tui | cursor_index: next}
    end)
  end

  defp execute_command(state, :git_status_prev_section) do
    update_tui_state(state, fn tui ->
      prev = find_prev_section(tui.flat_entries, tui.cursor_index)
      %{tui | cursor_index: prev}
    end)
  end

  defp execute_command(state, :git_status_toggle_section) do
    update_tui_state(state, &toggle_current_section/1)
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

  defp execute_command(state, :git_status_discard) do
    with_selected_file(state, fn entry, _git_root ->
      EditorState.set_status(state, "Discard #{entry.path}? (not yet implemented in TUI)")
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

      closed_state =
        %{state | workspace: %{state.workspace | keymap_scope: :editor}}
        |> EditorState.close_git_status_panel()

      open_file_in_editor(closed_state, abs_path)
    end)
  end

  defp execute_command(state, :git_status_start_commit) do
    EditorState.set_status(
      state,
      "Commit message input (use :git-commit <message> in command mode)"
    )
  end

  defp execute_command(state, :git_status_close) do
    state = %{state | workspace: %{state.workspace | keymap_scope: :editor}}
    EditorState.close_git_status_panel(state)
  end

  defp execute_command(state, _cmd), do: state

  # ── TUI state helpers ──────────────────────────────────────────────────

  @spec open_file_in_editor(EditorState.t(), String.t()) :: EditorState.t()
  defp open_file_in_editor(state, abs_path) do
    idx =
      Enum.find_index(state.workspace.buffers.list, fn buf ->
        try do
          BufferServer.file_path(buf) == abs_path
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

  @spec toggle_current_section(TuiState.t()) :: TuiState.t()
  defp toggle_current_section(%TuiState{} = tui) do
    case Enum.at(tui.flat_entries, tui.cursor_index) do
      {:section_header, section, _count} ->
        collapsed = toggle_collapsed(tui.collapsed, section)
        rebuild_flat_entries(%{tui | collapsed: collapsed})

      _ ->
        tui
    end
  end

  @spec toggle_collapsed(%{atom() => true}, atom()) :: %{atom() => true}
  defp toggle_collapsed(collapsed, section) do
    if Map.has_key?(collapsed, section) do
      Map.delete(collapsed, section)
    else
      Map.put(collapsed, section, true)
    end
  end

  @spec update_tui_state(EditorState.t(), (TuiState.t() -> TuiState.t())) :: EditorState.t()
  defp update_tui_state(%{shell_state: %{git_status_panel: nil}} = state, _fun), do: state

  defp update_tui_state(state, fun) do
    panel = EditorState.git_status_panel(state)
    tui = Map.get(panel, :tui_state) || build_initial_tui_state(panel)
    updated = fun.(tui)
    updated_panel = Map.put(panel, :tui_state, updated)
    EditorState.set_git_status_panel(state, updated_panel)
  end

  @spec with_selected_file(EditorState.t(), (Git.StatusEntry.t(), String.t() -> EditorState.t())) ::
          EditorState.t()
  defp with_selected_file(state, fun) do
    case resolve_git_root() do
      nil ->
        EditorState.set_status(state, "Not in a git repository")

      git_root ->
        panel = EditorState.git_status_panel(state)
        tui = Map.get(panel || %{}, :tui_state) || build_initial_tui_state(panel || %{})

        case Enum.at(tui.flat_entries, tui.cursor_index) do
          {:file, _section, entry} -> fun.(entry, git_root)
          _ -> state
        end
    end
  end

  @spec refresh_repo(String.t()) :: :ok
  defp refresh_repo(git_root) do
    case Repo.lookup(git_root) do
      nil -> :ok
      pid -> Repo.refresh(pid)
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

  @spec build_initial_tui_state(map()) :: TuiState.t()
  defp build_initial_tui_state(panel_data) do
    entries = Map.get(panel_data, :entries, [])

    tui = %TuiState{
      cursor_index: 0,
      collapsed: %{},
      flat_entries: [],
      entries: entries
    }

    rebuild_flat_entries(tui)
  end

  @spec rebuild_flat_entries(TuiState.t()) :: TuiState.t()
  defp rebuild_flat_entries(%TuiState{} = tui) do
    sections = [
      {:conflicts, fn e -> e.status == :conflict end},
      {:staged, fn e -> e.staged and e.status != :conflict and e.status != :untracked end},
      {:changes, fn e -> not e.staged and e.status != :conflict and e.status != :untracked end},
      {:untracked, fn e -> e.status == :untracked end}
    ]

    flat =
      Enum.flat_map(sections, fn {section_name, filter_fn} ->
        is_collapsed = Map.has_key?(tui.collapsed, section_name)
        build_section_entries(tui.entries, section_name, filter_fn, is_collapsed)
      end)

    %{tui | flat_entries: flat}
  end

  @spec build_section_entries(
          [Git.StatusEntry.t()],
          atom(),
          (Git.StatusEntry.t() -> boolean()),
          boolean()
        ) :: [TuiState.flat_entry()]
  defp build_section_entries(entries, section_name, filter_fn, is_collapsed) do
    section_entries = Enum.filter(entries, filter_fn)

    case section_entries do
      [] ->
        []

      _ ->
        header = [{:section_header, section_name, length(section_entries)}]

        if is_collapsed do
          header
        else
          file_entries = Enum.map(section_entries, &{:file, section_name, &1})
          header ++ file_entries
        end
    end
  end

  @spec find_next_section([TuiState.flat_entry()], non_neg_integer()) :: non_neg_integer()
  defp find_next_section(flat_entries, current_idx) do
    result =
      flat_entries
      |> Enum.with_index()
      |> Enum.find(fn
        {{:section_header, _, _}, idx} -> idx > current_idx
        _ -> false
      end)

    case result do
      {_, idx} -> idx
      nil -> current_idx
    end
  end

  @spec find_prev_section([TuiState.flat_entry()], non_neg_integer()) :: non_neg_integer()
  defp find_prev_section(flat_entries, current_idx) do
    result =
      flat_entries
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find(fn
        {{:section_header, _, _}, idx} -> idx < current_idx
        _ -> false
      end)

    case result do
      {_, idx} -> idx
      nil -> 0
    end
  end
end
