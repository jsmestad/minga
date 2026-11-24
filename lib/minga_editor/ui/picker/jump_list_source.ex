defmodule MingaEditor.UI.Picker.JumpListSource do
  @moduledoc """
  Picker source for the jump list (`SPC s j`).

  Lists the places jumps started from, newest first, with the line's text. The row the `⌃O` / `⌃I` walk is at is marked current. Picking a row jumps there and moves the walk to it, so `⌃O` and `⌃I` continue from the picked place.
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias Minga.Buffer
  alias MingaEditor.Commands.Marks
  alias MingaEditor.JumpList
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.Source

  @impl true
  @spec title() :: String.t()
  def title, do: "Jump list"

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(%Context{editing: %{jump_list: %JumpList{} = jump_list}, buffers: buffers}) do
    {entries, walk_index} = JumpList.entries(jump_list)
    open = MapSet.new(buffers.list)

    entries
    |> Enum.with_index()
    |> Enum.filter(fn {{buffer, _pos}, _index} -> MapSet.member?(open, buffer) end)
    |> Enum.reverse()
    |> Enum.map(fn {{buffer, position}, index} -> item(buffer, position, index, walk_index) end)
  end

  def candidates(_context), do: []

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: index}, state) when is_integer(index),
    do: Marks.jump_to_index(state, index)

  def on_select(_item, state), do: state

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(state), do: Source.restore_or_keep(state)

  @spec item(pid(), Buffer.position(), non_neg_integer(), non_neg_integer()) :: Item.t()
  defp item(buffer, {line, col}, index, walk_index) do
    %Item{
      id: index,
      label: "#{buffer_name(buffer)}:#{line + 1}:#{col + 1}",
      description: line_text(buffer, line),
      active: index == walk_index
    }
  end

  @spec buffer_name(pid()) :: String.t()
  defp buffer_name(buffer) do
    case Buffer.file_path(buffer) do
      nil -> Buffer.buffer_name(buffer) || "[No Name]"
      path -> Path.basename(path)
    end
  catch
    :exit, _ -> "[closed]"
  end

  @spec line_text(pid(), non_neg_integer()) :: String.t()
  defp line_text(buffer, line) do
    case Buffer.lines(buffer, line, 1) do
      [text | _] -> String.trim(text)
      _ -> ""
    end
  catch
    :exit, _ -> ""
  end
end
