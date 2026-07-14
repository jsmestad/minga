defmodule MingaEditor.UI.Picker.FileSource do
  @moduledoc """
  Picker source for finding and opening files in the project.

  Lists all files in the project directory using `Minga.Project.FileFind` and opens
  the selected file in a new buffer (or switches to it if already open).
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias Minga.Project.Root
  alias MingaEditor.FileTree.ProjectCache
  alias MingaEditor.State, as: EditorState
  alias Minga.Git
  alias Minga.Language
  alias Minga.Log
  alias Minga.Language.Devicon
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.Source

  @impl true
  @spec title() :: String.t()
  def title, do: "Find file"

  @impl true
  @spec async?() :: boolean()
  def async?, do: true

  @impl true
  @spec preview?() :: boolean()
  def preview?, do: true

  @impl true
  @spec gui_preview?() :: boolean()
  def gui_preview?, do: true

  @impl true
  @spec candidates(Context.t() | nil) :: [Item.t()]
  def candidates(ctx) do
    root = project_root(ctx)

    case resolve_paths(root) do
      {:ok, paths} ->
        frecency_map = build_frecency_map()
        git_status_map = build_git_status_map(root.path)
        score_map = build_score_map(frecency_map, git_status_map)

        paths
        |> Enum.map(&lean_candidate(&1, git_status_map, root))
        |> sort_by_score(score_map)

      {:error, msg} ->
        log_error(msg)
    end
  end

  # The picker reads only the Project-owned cache.
  # A managed `:project_rebuilt` event refreshes an open picker after an empty cache fills.
  # Picker tasks never start recursive inventory.
  @spec resolve_paths(Root.t() | nil) :: {:ok, [String.t()]} | {:error, String.t()}
  defp resolve_paths(nil),
    do: {:error, "No directory workspace active. Open a folder or switch project."}

  defp resolve_paths(%Root{} = root) do
    if ProjectCache.active_root?(root.path) do
      {:ok, ProjectCache.files()}
    else
      {:error, "Directory workspace is no longer active"}
    end
  end

  # Lean candidate: just enough to match (filename label, full-path search text)
  # and to enrich later (git status stashed in `meta`). Icon, color, two-line
  # description, and the status annotation are built in `enrich/1` for the
  # bounded winners only, so a 50k-file repo never materializes 50k rich items.
  @spec lean_candidate(String.t(), %{String.t() => atom()}, Root.t()) :: Item.t()
  defp lean_candidate(path, git_status_map, root) do
    %Item{
      id: path,
      label: Path.basename(path),
      search_text: path,
      meta: %{git: Map.get(git_status_map, path), workspace_root: root}
    }
  end

  @impl true
  @spec enrich([Item.t()]) :: [Item.t()]
  def enrich(items), do: Enum.map(items, &enrich_item/1)

  @spec enrich_item(Item.t()) :: Item.t()
  defp enrich_item(%Item{id: path, meta: meta} = item) do
    filename = Path.basename(path)
    dir = Path.dirname(path)
    ft = Language.detect_filetype(filename)
    {icon, color} = Devicon.icon_and_color(ft)
    dir_display = if dir == ".", do: "", else: dir
    annotation = git_status_annotation(Map.get(meta, :git))

    %{
      item
      | label: "#{icon} #{filename}",
        description: dir_display,
        icon_color: color,
        annotation: annotation
    }
  end

  @spec log_error(String.t()) :: []
  defp log_error(msg) do
    Minga.Log.error(:editor, "find_file: #{msg}")
    []
  end

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: rel_path} = item, state) do
    Log.debug(:editor, "[file_picker] on_select path=#{rel_path}")
    open_selected_file(absolute_path(item, state), state)
  end

  @spec open_selected_file({:ok, String.t()} | :error, term()) :: term()
  defp open_selected_file(:error, state), do: state

  defp open_selected_file({:ok, abs_path}, state) do
    case MingaEditor.Handlers.BufferRegistry.find_buffer_by_path(state, abs_path) do
      nil ->
        case MingaEditor.Commands.start_buffer(abs_path, state.interaction.options_server) do
          {:ok, pid} ->
            Log.debug(:editor, "[file_picker] new buffer pid=#{inspect(pid)}")
            new_state = MingaEditor.Handlers.BufferRegistry.add_buffer(state, pid)
            record_selection(abs_path, state)
            new_state

          {:error, reason} ->
            Minga.Log.error(:editor, "Failed to open file: #{inspect(reason)}")
            state
        end

      idx ->
        new_state = switch_existing_buffer(state, idx)
        record_selection(abs_path, state)
        new_state
    end
  end

  @spec switch_existing_buffer(term(), non_neg_integer()) :: term()
  defp switch_existing_buffer(state, idx) do
    # Prefer existing tabs when opening from normal picker flow so agentic view exits cleanly.
    pid = Enum.at(state.workspace.buffers.list, idx)
    tab = EditorState.find_tab_by_buffer(state, pid)

    Log.debug(
      :editor,
      "[file_picker] existing buffer idx=#{idx} tab=#{inspect(tab && tab.id)}"
    )

    switch_existing_buffer_target(state, idx, tab)
  end

  @spec switch_existing_buffer_target(term(), non_neg_integer(), term()) :: term()
  defp switch_existing_buffer_target(state, idx, _tab)
       when state.buffer_lifecycle.buffer_add_context == :preview do
    MingaEditor.BufferActivation.activate(state, idx)
  end

  defp switch_existing_buffer_target(state, _idx, %{id: tab_id}) do
    EditorState.switch_tab(state, tab_id)
  end

  defp switch_existing_buffer_target(state, idx, _tab) do
    MingaEditor.BufferActivation.activate(state, idx)
  end

  @impl true
  def on_cancel(state), do: Source.restore_or_keep(state)

  @impl true
  @spec actions(Item.t()) :: [MingaEditor.UI.Picker.Source.action_entry()]
  def actions(_item) do
    [{"Open", :open}, {"Delete", :delete}]
  end

  @impl true
  @spec on_action(term(), Item.t(), term()) :: term()
  def on_action(:open, item, state), do: on_select(item, state)

  def on_action(:delete, %Item{} = item, state) do
    delete_selected_file(absolute_path(item, state), state)
  end

  def on_action(_action, _item, state), do: state

  @spec delete_selected_file({:ok, String.t()} | :error, term()) :: term()
  defp delete_selected_file(:error, state), do: state

  defp delete_selected_file({:ok, abs_path}, state) do
    case File.rm(abs_path) do
      :ok ->
        Minga.Log.info(:editor, "Deleted file: #{abs_path}")
        state

      {:error, reason} ->
        Minga.Log.error(:editor, "Failed to delete file: #{inspect(reason)}")
        state
    end
  end

  @impl true
  @spec on_bulk_select([Item.t()], term()) :: term()
  def on_bulk_select(items, state), do: open_items(items, state)

  @impl true
  @spec bulk_actions([Item.t()]) :: [MingaEditor.UI.Picker.Source.action_entry()]
  def bulk_actions(_items), do: [{"Open all marked", :open_marked}]

  @impl true
  @spec on_bulk_action(term(), [Item.t()], term()) :: term()
  def on_bulk_action(:open_marked, items, state), do: open_items(items, state)
  def on_bulk_action(_action, _items, state), do: state

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec open_items([Item.t()], term()) :: term()
  defp open_items(items, state) do
    Enum.reduce(items, state, fn item, acc -> on_select(item, acc) end)
  end

  @spec absolute_path(Item.t(), term()) :: {:ok, String.t()} | :error
  defp absolute_path(%Item{id: rel_path, meta: %{workspace_root: %Root{path: path}}}, _state),
    do: {:ok, Path.expand(rel_path, path)}

  defp absolute_path(%Item{id: rel_path}, state) do
    case selection_root(state) do
      path when is_binary(path) -> {:ok, Path.expand(rel_path, path)}
      nil -> :error
    end
  end

  @spec selection_root(term()) :: String.t() | nil
  defp selection_root(%EditorState{} = state) do
    case EditorState.file_tree_state(state).project_root do
      path when is_binary(path) -> path
      _other -> root_path(active_workspace_root())
    end
  end

  defp selection_root(_state), do: root_path(active_workspace_root())

  @spec root_path(Root.t() | nil) :: String.t() | nil
  defp root_path(%Root{path: path}), do: path
  defp root_path(nil), do: nil

  @spec record_selection(String.t(), term()) :: :ok
  defp record_selection(_abs_path, %{buffer_lifecycle: %{buffer_add_context: :preview}}),
    do: :ok

  defp record_selection(abs_path, _state) do
    Minga.Project.record_file(abs_path)
  catch
    :exit, _ -> :ok
  end

  # Build a map of relative_path → frecency_score from Project.frecency_scores/0.
  @spec build_frecency_map() :: %{String.t() => non_neg_integer()}
  defp build_frecency_map do
    Minga.Project.frecency_scores()
  catch
    :exit, _ -> %{}
  end

  # Build a map of relative_path → git status atom from Git.Repo.
  @spec build_git_status_map(String.t()) :: %{String.t() => atom()}
  defp build_git_status_map(root) do
    with {:ok, git_root} <- Minga.Git.root_for(root),
         repo_pid when is_pid(repo_pid) <- Git.lookup_repo(git_root) do
      Git.Repo.status(repo_pid)
      |> Enum.into(%{}, fn entry -> {entry.path, entry.status} end)
    else
      _ -> %{}
    end
  catch
    :exit, _ -> %{}
  end

  # Combine frecency and git-modified scores. Git-modified files get a flat
  # boost of 5. Both boosts stack: frequently/recently opened AND modified = highest score.
  @spec build_score_map(%{String.t() => non_neg_integer()}, %{String.t() => atom()}) :: %{
          String.t() => non_neg_integer()
        }
  defp build_score_map(frecency_map, git_status_map) do
    all_paths = Map.keys(frecency_map) ++ Map.keys(git_status_map)

    Map.new(Enum.uniq(all_paths), fn path ->
      frecency = Map.get(frecency_map, path, 0)
      git_boost = if Map.has_key?(git_status_map, path), do: 5, else: 0
      {path, frecency + git_boost}
    end)
  end

  # Sort items by combined score (frecency + git-modified), preserving filesystem order for unscored.
  @spec sort_by_score([Item.t()], %{String.t() => non_neg_integer()}) :: [Item.t()]
  defp sort_by_score(items, score_map) when map_size(score_map) == 0, do: items

  defp sort_by_score(items, score_map) do
    Enum.sort_by(items, fn %Item{id: path} ->
      score = Map.get(score_map, path, 0)
      depth = Enum.count(Path.split(path)) - 1
      {-score, depth, path}
    end)
  end

  # Returns a status annotation letter for display in the picker.
  @spec git_status_annotation(atom() | nil) :: String.t() | nil
  defp git_status_annotation(:modified), do: "M"
  defp git_status_annotation(:added), do: "A"
  defp git_status_annotation(:deleted), do: "D"
  defp git_status_annotation(:untracked), do: "?"
  defp git_status_annotation(:renamed), do: "R"
  defp git_status_annotation(:copied), do: "C"
  defp git_status_annotation(:conflict), do: "!"
  defp git_status_annotation(_), do: nil

  @spec project_root(Context.t() | EditorState.t() | nil) :: Root.t() | nil
  defp project_root(%Context{picker_ui: %{context: %{project_root: nil}}}), do: nil
  defp project_root(%Context{picker_ui: %{context: %{project_root: %Root{} = root}}}), do: root
  defp project_root(%Context{file_tree: %{project_root: %Root{} = root}}), do: root
  defp project_root(%EditorState{}), do: active_workspace_root()
  defp project_root(_ctx), do: active_workspace_root()

  @spec active_workspace_root() :: Root.t() | nil
  defp active_workspace_root do
    Minga.Project.workspace_root()
  catch
    :exit, _ -> nil
  end
end
