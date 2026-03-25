defmodule Minga.UI.Picker.GitChangedSource do
  @moduledoc """
  Picker source for navigating files with uncommitted git changes.

  Shows only files with a non-clean git status (modified, added, deleted,
  untracked, etc.) with status annotations. Accessible via `SPC g f`.
  """

  @behaviour Minga.UI.Picker.Source

  alias Minga.Editor.State, as: EditorState
  alias Minga.Git.Repo, as: GitRepo
  alias Minga.Language.Filetype
  alias Minga.Log
  alias Minga.UI.Devicon
  alias Minga.UI.Picker.Item
  alias Minga.UI.Picker.Source

  @impl true
  @spec title() :: String.t()
  def title, do: "Changed Files"

  @impl true
  @spec preview?() :: boolean()
  def preview?, do: true

  @impl true
  @spec candidates(term()) :: [Item.t()]
  def candidates(_context) do
    root = Minga.Project.resolve_root()

    case Minga.Git.root_for(root) do
      {:ok, git_root} -> build_candidates(git_root)
      :not_git -> []
    end
  catch
    :exit, _ -> []
  end

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: rel_path}, state) do
    root = Minga.Project.resolve_root()
    abs_path = Path.join(root, rel_path)

    Log.debug(:editor, "[git_changed_picker] on_select path=#{rel_path}")

    case EditorState.find_buffer_by_path(state, abs_path) do
      nil ->
        case EditorState.start_buffer(abs_path) do
          {:ok, pid} ->
            EditorState.add_buffer(state, pid)

          {:error, reason} ->
            Log.error(:editor, "Failed to open file: #{inspect(reason)}")
            state
        end

      idx ->
        pid = Enum.at(state.workspace.buffers.list, idx)
        tab = EditorState.find_tab_by_buffer(state, pid)

        if tab do
          EditorState.switch_tab(state, tab.id)
        else
          EditorState.switch_buffer(state, idx)
        end
    end
  end

  @impl true
  def on_cancel(state), do: Source.restore_or_keep(state)

  # ── Private ────────────────────────────────────────────────────────────

  @spec build_candidates(String.t()) :: [Item.t()]
  defp build_candidates(git_root) do
    case GitRepo.lookup(git_root) do
      nil ->
        []

      repo_pid ->
        GitRepo.status(repo_pid)
        |> Enum.map(&format_entry/1)
    end
  end

  @spec format_entry(Minga.Git.StatusEntry.t()) :: Item.t()
  defp format_entry(entry) do
    filename = Path.basename(entry.path)
    dir = Path.dirname(entry.path)
    ft = Filetype.detect(filename)
    {icon, color} = Devicon.icon_and_color(ft)
    dir_display = if dir == ".", do: "", else: dir
    annotation = status_annotation(entry.status)

    %Item{
      id: entry.path,
      label: "#{icon} #{filename}",
      description: dir_display,
      icon_color: color,
      annotation: annotation,
      two_line: true
    }
  end

  @spec status_annotation(atom()) :: String.t()
  defp status_annotation(:modified), do: "M"
  defp status_annotation(:added), do: "A"
  defp status_annotation(:deleted), do: "D"
  defp status_annotation(:untracked), do: "?"
  defp status_annotation(:renamed), do: "R"
  defp status_annotation(:copied), do: "C"
  defp status_annotation(:conflict), do: "!"
  defp status_annotation(_), do: ""
end
