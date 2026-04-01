defmodule MingaEditor.UI.Picker.RecentFileSource do
  @moduledoc """
  Picker source for recently opened files in the current project.

  Lists files from `Minga.Project.recent_files/0`, most recently opened first.
  Selecting a file opens it (or switches to it if already in a buffer).
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias Minga.Language
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item

  alias MingaEditor.State, as: EditorState
  alias Minga.Project
  alias MingaEditor.UI.Devicon
  alias MingaEditor.UI.Picker.Source

  @impl true
  @spec title() :: String.t()
  def title, do: "Recent files"

  @impl true
  @spec preview?() :: boolean()
  def preview?, do: true

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(_ctx) do
    files = Project.recent_files()

    Enum.map(files, fn rel_path ->
      filename = Path.basename(rel_path)
      dir = Path.dirname(rel_path)
      ft = Language.detect_filetype(filename)
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
