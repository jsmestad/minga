defmodule Minga.Frontend.Adapter.GUI.TasksDrawerEncoder do
  @moduledoc """
  Encodes the tasks drawer (`Minga.RenderModel.UI.TasksDrawer`) as `gui_tasks_drawer`.

  Bytes come from the schema-generated encoder; this module maps the semantic model to the schema's shape (a state as its design-token wire byte, row flags as bits) and skips a frame whose drawer did not change.
  """

  import Bitwise

  alias Minga.Design.Tokens
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire.Writer
  alias Minga.Protocol.Encode
  alias Minga.RenderModel.UI.EmptyList
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.TasksDrawer
  alias Minga.RenderModel.UI.TasksDrawer.Row

  @command :gui_tasks_drawer
  @opcode Opcodes.gui_tasks_drawer()

  @flag_last 0x01
  @flag_selected 0x02

  @doc "The command for a changed drawer, or nil when it is unchanged since the last frame."
  @spec encode(TasksDrawer.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%TasksDrawer{} = model, %Caches{} = caches) do
    fingerprint = :erlang.phash2(model)

    if fingerprint == caches.last_tasks_drawer_fp do
      {nil, caches}
    else
      {encode_command(model), %{caches | last_tasks_drawer_fp: fingerprint}}
    end
  end

  @doc "The `gui_tasks_drawer` command for a drawer model."
  @spec encode_command(TasksDrawer.t()) :: binary()
  def encode_command(%TasksDrawer{} = model) do
    payload = model |> to_wire() |> Encode.encode_gui_tasks_drawer() |> :erlang.iolist_to_binary()

    @command
    |> Writer.new()
    |> Writer.uint8(:opcode, @opcode)
    |> Writer.payload32(:payload, payload)
    |> Writer.finish()
  end

  @spec to_wire(TasksDrawer.t()) :: map()
  defp to_wire(%TasksDrawer{visible?: false}) do
    %{
      visible: 0,
      focused: 0,
      name: "",
      title: "",
      note: "",
      counts: [],
      hints: [],
      rows: [],
      view: 0,
      view_title: "",
      view_lines: [],
      view_offset: 0,
      prompt: "",
      has_empty: 0,
      empty: empty(nil)
    }
  end

  defp to_wire(%TasksDrawer{} = model) do
    %{
      visible: 1,
      focused: if(model.focused?, do: 1, else: 0),
      name: model.name,
      title: model.title,
      note: model.note,
      counts:
        Enum.map(model.counts, fn {state, count} ->
          %{state: Tokens.state_wire(state), count: count}
        end),
      hints: Enum.map(model.hints, &hint/1),
      rows: Enum.map(model.rows, &row/1),
      view: view_byte(model.view),
      view_title: model.view_title,
      view_lines: Enum.map(model.view_lines, &%{text: &1}),
      view_offset: model.view_offset,
      prompt: model.prompt,
      has_empty: if(model.empty, do: 1, else: 0),
      empty: empty(model.empty)
    }
  end

  # The empty state's next steps; a drawer with tasks sends an all-zero empty_list behind has_empty = 0.
  @spec empty(EmptyList.t() | nil) :: map()
  defp empty(nil), do: %{glyph: "", title: "", why: "", selected: 0, actions: []}

  defp empty(%EmptyList{} = empty) do
    %{
      glyph: empty.glyph,
      title: empty.title,
      why: empty.why,
      selected: empty.selected,
      actions: Enum.map(empty.actions, &%{id: &1.id, key: &1.key, label: &1.label})
    }
  end

  @spec row(Row.t()) :: map()
  defp row(%Row{} = row) do
    %{
      id: row.id,
      depth: row.depth,
      flags: flag(row.last?, @flag_last) ||| flag(row.selected?, @flag_selected),
      state: state_wire(row.state),
      title: row.title,
      words: row.words,
      age: row.age,
      detail: Enum.map(row.detail, &%{text: &1}),
      actions: Enum.map(row.actions, &hint/1)
    }
  end

  @spec view_byte(:list | :diff | :output) :: 0..2
  defp view_byte(:list), do: 0
  defp view_byte(:diff), do: 1
  defp view_byte(:output), do: 2

  @spec hint(TasksDrawer.hint()) :: map()
  defp hint({key, label}), do: %{key: key, label: label}

  @spec state_wire(Tokens.state_id() | nil) :: non_neg_integer()
  defp state_wire(nil), do: 0
  defp state_wire(state), do: Tokens.state_wire(state)

  @spec flag(boolean(), non_neg_integer()) :: non_neg_integer()
  defp flag(true, bit), do: bit
  defp flag(false, _bit), do: 0
end
