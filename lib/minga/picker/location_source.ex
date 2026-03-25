defmodule Minga.Picker.LocationSource do
  @moduledoc """
  Picker source for navigating a list of file locations.

  Used by find-references, workspace symbols, call hierarchy, and any
  feature that produces a list of `{file_path, line, col, label}` items.

  The caller opens the picker with a context map containing a `:locations`
  key (list of location tuples) and an optional `:title` key.

  ## Usage

      locations = [
        {"/path/to/file.ex", 10, 4, "def my_function(arg)"},
        {"/path/to/other.ex", 25, 8, "  my_function(value)"}
      ]

      PickerUI.open(state, LocationSource, %{locations: locations, title: "References"})
  """

  @behaviour Minga.Picker.Source

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.Commands
  alias Minga.Editor.State, as: EditorState
  alias Minga.Picker.Item
  alias Minga.Picker.Source

  @impl true
  @spec title() :: String.t()
  def title, do: "Locations"

  @impl true
  @spec preview?() :: boolean()
  def preview?, do: true

  @impl true
  @spec candidates(term()) :: [Item.t()]
  def candidates(%{picker_ui: %{context: %{locations: locations}}}) when is_list(locations) do
    Enum.map(locations, &format_location/1)
  end

  def candidates(_state), do: []

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: {path, line, col}}, state) do
    jump_to_location(state, path, line, col)
  end

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(state) do
    Source.restore_or_keep(state)
  end

  # ── Private ────────────────────────────────────────────────────────────────

  @spec format_location({String.t(), non_neg_integer(), non_neg_integer(), String.t()}) ::
          Item.t()
  defp format_location({path, line, col, label}) do
    display_path = shorten_path(path)
    line_num = line + 1
    col_num = col + 1

    %Item{
      id: {path, line, col},
      label: "#{display_path}:#{line_num}:#{col_num}",
      description: String.trim(label),
      two_line: true
    }
  end

  @spec jump_to_location(EditorState.t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          EditorState.t()
  defp jump_to_location(state, path, line, col) do
    # Set jump mark before navigating
    state = set_jump_mark(state)

    current_path =
      case state.workspace.buffers.active do
        nil -> nil
        buf -> BufferServer.file_path(buf)
      end

    state =
      if path == current_path do
        state
      else
        open_or_switch_to_file(state, path)
      end

    case state.workspace.buffers.active do
      nil -> state
      buf -> BufferServer.move_to(buf, {line, col})
    end

    state
  end

  @spec open_or_switch_to_file(EditorState.t(), String.t()) :: EditorState.t()
  defp open_or_switch_to_file(state, file_path) do
    idx =
      Enum.find_index(state.workspace.buffers.list, fn buf ->
        try do
          BufferServer.file_path(buf) == file_path
        catch
          :exit, _ -> false
        end
      end)

    case idx do
      nil ->
        case Commands.start_buffer(file_path) do
          {:ok, pid} -> Commands.add_buffer(state, pid)
          {:error, _reason} -> %{state | status_msg: "Could not open #{file_path}"}
        end

      i ->
        EditorState.switch_buffer(state, i)
    end
  end

  @spec set_jump_mark(EditorState.t()) :: EditorState.t()
  defp set_jump_mark(%{workspace: %{buffers: %{active: buf}}} = state) when is_pid(buf) do
    pos = BufferServer.cursor(buf)
    %{state | workspace: %{state.workspace | vim: %{state.workspace.vim | last_jump_pos: pos}}}
  end

  defp set_jump_mark(state), do: state

  @spec shorten_path(String.t()) :: String.t()
  defp shorten_path(path) do
    case Minga.Project.root() do
      nil -> path
      root -> Path.relative_to(path, root)
    end
  end
end
