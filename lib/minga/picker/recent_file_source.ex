defmodule Minga.Picker.RecentFileSource do
  @moduledoc """
  Picker source for recently opened files in the current project.

  Lists files from `Minga.Project.recent_files/0`, most recently opened first.
  Selecting a file opens it (or switches to it if already in a buffer).
  """

  @behaviour Minga.Picker.Source

  alias Minga.Picker.Item

  alias Minga.Editor.State, as: EditorState
  alias Minga.Language.Filetype
  alias Minga.Picker.Source
  alias Minga.Project
  alias Minga.UI.Devicon

  @impl true
  @spec title() :: String.t()
  def title, do: "Recent files"

  @impl true
  @spec preview?() :: boolean()
  def preview?, do: true

  @impl true
  @spec candidates(term()) :: [Item.t()]
  def candidates(_context) do
    files = Project.recent_files()

    Enum.map(files, fn rel_path ->
      filename = Path.basename(rel_path)
      dir = Path.dirname(rel_path)
      ft = Filetype.detect(filename)
      {icon, color} = Devicon.icon_and_color(ft)
      dir_display = if dir == ".", do: "", else: dir

      %Item{
        id: rel_path,
        label: "#{icon} #{filename}",
        description: dir_display,
        icon_color: color,
        two_line: true
      }
    end)
  catch
    :exit, _ -> []
  end

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: rel_path}, state) do
    root = project_root()
    abs_path = Path.join(root, rel_path)

    case EditorState.find_buffer_by_path(state, abs_path) do
      nil ->
        case EditorState.start_buffer(abs_path) do
          {:ok, pid} ->
            EditorState.add_buffer(state, pid)

          {:error, reason} ->
            Minga.Log.error(:editor, "Failed to open file: #{inspect(reason)}")
            state
        end

      idx ->
        EditorState.switch_buffer(state, idx)
    end
  end

  @impl true
  def on_cancel(state), do: Source.restore_or_keep(state)

  # ── Private ─────────────────────────────────────────────────────────────────

  defdelegate project_root, to: Minga.Project, as: :resolve_root
end
