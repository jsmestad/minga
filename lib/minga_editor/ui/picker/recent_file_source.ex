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

  alias Minga.Project
  alias Minga.Language.Devicon
  alias MingaEditor.UI.Picker.Source

  @impl true
  @spec title() :: String.t()
  def title, do: "Recent files"

  @impl true
  @spec preview?() :: boolean()
  def preview?, do: true

  @impl true
  @spec gui_preview?() :: boolean()
  def gui_preview?, do: true

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
        icon_color: color
      }
    end)
  catch
    :exit, _ -> []
  end

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: rel_path}, state) do
    open_recent_file(project_root(), rel_path, state)
  end

  @spec open_recent_file(String.t() | nil, String.t(), term()) :: term()
  defp open_recent_file(nil, _rel_path, state), do: state

  defp open_recent_file(root, rel_path, state) do
    abs_path = Path.join(root, rel_path)

    case MingaEditor.Handlers.BufferRegistry.open_or_activate_path(state, abs_path) do
      {:ok, new_state, _pid, _status} ->
        new_state

      {:error, reason} ->
        Minga.Log.error(:editor, "Failed to open file: #{inspect(reason)}")
        state
    end
  end

  @impl true
  def on_cancel(state), do: Source.restore_or_keep(state)

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec project_root() :: String.t() | nil
  def project_root, do: Minga.Project.resolve_root()
end
