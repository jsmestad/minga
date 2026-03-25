defmodule Minga.Picker.FileSource do
  @moduledoc """
  Picker source for finding and opening files in the project.

  Lists all files in the project directory using `Minga.FileFind` and opens
  the selected file in a new buffer (or switches to it if already open).
  """

  @behaviour Minga.Picker.Source

  alias Minga.Devicon
  alias Minga.Editor.State, as: EditorState
  alias Minga.Git.Repo, as: GitRepo
  alias Minga.Language.Filetype
  alias Minga.Log
  alias Minga.Picker.Item
  alias Minga.Picker.Source

  @impl true
  @spec title() :: String.t()
  def title, do: "Find file"

  @impl true
  @spec preview?() :: boolean()
  def preview?, do: true

  @impl true
  @spec candidates(term()) :: [Item.t()]
  def candidates(_context) do
    root = project_root()

    case Minga.FileFind.list_files(root) do
      {:ok, paths} ->
        recency_map = build_recency_map()
        git_status_map = build_git_status_map()
        score_map = build_score_map(recency_map, git_status_map)

        paths
        |> Enum.map(&format_file_candidate(&1, git_status_map))
        |> sort_by_score(score_map)

      {:error, msg} ->
        log_error(msg)
    end
  end

  @spec format_file_candidate(String.t(), %{String.t() => atom()}) :: Item.t()
  defp format_file_candidate(path, git_status_map) do
    filename = Path.basename(path)
    dir = Path.dirname(path)
    ft = Filetype.detect(filename)
    {icon, color} = Devicon.icon_and_color(ft)
    dir_display = if dir == ".", do: "", else: dir

    annotation = git_status_annotation(Map.get(git_status_map, path))

    %Item{
      id: path,
      label: "#{icon} #{filename}",
      description: dir_display,
      icon_color: color,
      annotation: annotation,
      two_line: true
    }
  end

  @spec log_error(String.t()) :: []
  defp log_error(msg) do
    Minga.Log.error(:editor, "find_file: #{msg}")
    []
  end

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: rel_path}, state) do
    abs_path = Path.expand(rel_path)

    Log.debug(:editor, "[file_picker] on_select path=#{rel_path}")

    case EditorState.find_buffer_by_path(state, abs_path) do
      nil ->
        case EditorState.start_buffer(abs_path) do
          {:ok, pid} ->
            Log.debug(:editor, "[file_picker] new buffer pid=#{inspect(pid)}")
            EditorState.add_buffer(state, pid)

          {:error, reason} ->
            Minga.Log.error(:editor, "Failed to open file: #{inspect(reason)}")
            state
        end

      idx ->
        # If the buffer already has a tab, switch to that tab instead
        # of just changing the buffer index. This correctly leaves
        # agentic view when opening a file from an agent tab.
        pid = Enum.at(state.workspace.buffers.list, idx)
        tab = EditorState.find_tab_by_buffer(state, pid)

        Log.debug(
          :editor,
          "[file_picker] existing buffer idx=#{idx} tab=#{inspect(tab && tab.id)}"
        )

        if tab do
          EditorState.switch_tab(state, tab.id)
        else
          EditorState.switch_buffer(state, idx)
        end
    end
  end

  @impl true
  def on_cancel(state), do: Source.restore_or_keep(state)

  @impl true
  @spec actions(Item.t()) :: [Minga.Picker.Source.action_entry()]
  def actions(_item) do
    [{"Open", :open}, {"Delete", :delete}]
  end

  @impl true
  @spec on_action(atom(), Item.t(), term()) :: term()
  def on_action(:open, item, state), do: on_select(item, state)

  def on_action(:delete, %Item{id: rel_path}, state) do
    abs_path = Path.expand(rel_path)

    case File.rm(abs_path) do
      :ok ->
        Minga.Log.info(:editor, "Deleted file: #{abs_path}")
        state

      {:error, reason} ->
        Minga.Log.error(:editor, "Failed to delete file: #{inspect(reason)}")
        state
    end
  end

  def on_action(_action, _item, state), do: state

  # ── Private ─────────────────────────────────────────────────────────────────

  # Build a map of relative_path → recency_score from Project.recent_files.
  # Most recently opened files get the highest score.
  @spec build_recency_map() :: %{String.t() => non_neg_integer()}
  defp build_recency_map do
    recent = Minga.Project.recent_files()
    total = length(recent)

    recent
    |> Enum.with_index()
    |> Enum.into(%{}, fn {path, idx} ->
      # Most recent = highest score. Score decays linearly.
      {path, total - idx}
    end)
  catch
    :exit, _ -> %{}
  end

  # Build a map of relative_path → git status atom from Git.Repo.
  @spec build_git_status_map() :: %{String.t() => atom()}
  defp build_git_status_map do
    root = project_root()

    with {:ok, git_root} <- Minga.Git.root_for(root),
         repo_pid when is_pid(repo_pid) <- GitRepo.lookup(git_root) do
      GitRepo.status(repo_pid)
      |> Enum.into(%{}, fn entry -> {entry.path, entry.status} end)
    else
      _ -> %{}
    end
  catch
    :exit, _ -> %{}
  end

  # Combine recency and git-modified scores. Git-modified files get a flat
  # boost of 5. Recently opened files get position-based score (N..1).
  # Both boosts stack: recently opened AND modified = highest score.
  @spec build_score_map(%{String.t() => non_neg_integer()}, %{String.t() => atom()}) :: %{
          String.t() => non_neg_integer()
        }
  defp build_score_map(recency_map, git_status_map) do
    all_paths = Map.keys(recency_map) ++ Map.keys(git_status_map)

    Map.new(Enum.uniq(all_paths), fn path ->
      recency = Map.get(recency_map, path, 0)
      git_boost = if Map.has_key?(git_status_map, path), do: 5, else: 0
      {path, recency + git_boost}
    end)
  end

  # Sort items by combined score (recent + git-modified), preserving filesystem order for unscored.
  @spec sort_by_score([Item.t()], %{String.t() => non_neg_integer()}) :: [Item.t()]
  defp sort_by_score(items, score_map) when map_size(score_map) == 0, do: items

  defp sort_by_score(items, score_map) do
    Enum.sort_by(items, fn %Item{id: path} ->
      score = Map.get(score_map, path, 0)
      {-score, path}
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

  defdelegate project_root, to: Minga.Project, as: :resolve_root
end
