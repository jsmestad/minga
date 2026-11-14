defmodule MingaEditor.Agent.PromptAccessibilityTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Frontend.Adapter.GUI.WindowEncoder
  alias Minga.Mode.VisualState
  alias MingaEditor.Agent.PromptBuffer
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.UIState.Panel
  alias MingaEditor.Agent.View.PromptRenderWindow
  alias MingaEditor.Agent.ViewContext
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Handlers.GuiActionHandler
  alias MingaEditor.Input.AgentPanel
  alias MingaEditor.RenderModel.Window.VisualRow
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Renderer.TextPresentations
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Render
  alias MingaEditor.State.Windows
  alias MingaEditor.UI.Theme
  alias MingaEditor.VimState
  alias MingaEditor.Window

  test "the real encoded two-row natural draft names an enabled source-backed Agent prompt" do
    text = String.duplicate("ordinary text ", 16) <> "x"
    assert byte_size(text) == 225
    ui = prompt(text)
    Buffer.move_to(ui.panel.prompt_buffer, {0, byte_size(text)})
    {model, lease} = present(ui, 120, 1_001)
    assert length(model.rows) == 2
    metadata = encoded_accessibility(model)
    assert metadata.label == "Agent prompt"
    assert metadata.generation == lease.presentation_id
    assert metadata.generation == model.text_presentation_id
    assert metadata.generation > 0
    assert metadata.cursor == {1, String.length(Enum.at(model.rows, 1).text)}
    {:windowed, entries} = lease.rows
    {row, utf16} = metadata.cursor
    assert VisualRow.source_position(elem(entries, row), utf16) == {:ok, {0, byte_size(text)}}
  end

  test "encoded insertion cursor uses source UTF-16, not display cells or UTF-8 bytes" do
    text = "é界é👩‍💻z"
    ui = prompt(text)
    byte = byte_size("é界é")
    Buffer.move_to(ui.panel.prompt_buffer, {0, byte})
    {model, lease} = present(ui, 3, 1_002)
    assert {model.cursor_row, model.cursor_col} == {1, 1}
    assert encoded_accessibility(model).cursor == {1, 2}
    {:windowed, entries} = lease.rows
    assert VisualRow.source_position(elem(entries, 1), 2) == {:ok, {0, byte}}
  end

  test "exact-width insertion cursor maps the empty continuation back to source end" do
    ui = prompt("é界")
    Buffer.move_to(ui.panel.prompt_buffer, {0, byte_size("é界")})
    {model, lease} = present(ui, 3, 1_003)
    assert Enum.map(model.rows, & &1.text) == ["é界", ""]
    assert encoded_accessibility(model).cursor == {1, 0}
    {:windowed, entries} = lease.rows
    assert VisualRow.source_position(elem(entries, 1), 0) == {:ok, {0, byte_size("é界")}}
  end

  test "encoded Unicode selection ranges clip to retained rows and survive modal caret suppression" do
    text = "é界é👩‍💻z"
    ui = prompt(text)
    ui = UIState.replace_panel(ui, Panel.fit_prompt(ui.panel, 3, 2))
    Buffer.move_to(ui.panel.prompt_buffer, {0, byte_size("é界é👩‍💻")})

    editing =
      VimState.transition(VimState.new(), :visual, %VisualState{
        visual_type: :char,
        visual_anchor: {0, byte_size("é")}
      })

    {model, _lease} = present(ui, 80, 1_004, editing: editing)
    assert Enum.map(model.rows, & &1.text) == ["é👩‍💻", "z"]
    metadata = encoded_accessibility(model)
    assert metadata.selection_ranges == [{0, 0, 7}, {1, 0, 1}]
    assert metadata.cursor == {1, 0}

    {modal, _lease} = present(ui, 80, 1_005, editing: editing, cursor_eligible: false)
    modal_metadata = encoded_accessibility(modal)
    assert modal_metadata.cursor == nil
    assert modal_metadata.selection_ranges == metadata.selection_ranges
    assert modal_metadata.label == "Agent prompt"
    assert modal_metadata.generation > 0
  end

  test "line selection includes visible empty source rows and trailing newline" do
    ui = prompt("a\n\nb\n")
    ui = UIState.replace_panel(ui, Panel.fit_prompt(ui.panel, 10, 2))
    Buffer.move_to(ui.panel.prompt_buffer, {3, 0})

    editing =
      VimState.transition(VimState.new(), :visual, %VisualState{
        visual_type: :line,
        visual_anchor: {0, 0}
      })

    {model, _lease} = present(ui, 80, 1_006, editing: editing)
    assert Enum.map(model.rows, & &1.text) == ["b", ""]
    assert encoded_accessibility(model).selection_ranges == [{0, 0, 1}, {1, 0, 0}]
    assert encoded_accessibility(model).cursor == {1, 0}
  end

  test "paste-pill accessibility selects replacement text using the retained source map" do
    ui = prompt("") |> PromptBuffer.insert_paste("one\ntwo\nthree")
    source_end = byte_size(PromptBuffer.input_text(ui))
    Buffer.move_to(ui.panel.prompt_buffer, {0, source_end})

    editing =
      VimState.transition(VimState.new(), :visual, %VisualState{
        visual_type: :char,
        visual_anchor: {0, 0}
      })

    {model, lease} = present(ui, 40, 1_007, editing: editing)
    [row] = model.rows
    refute String.contains?(row.text, "\0")
    units = utf16_length(row.text)
    metadata = encoded_accessibility(model)
    assert metadata.selection_ranges == [{0, 0, units}]
    assert metadata.cursor == {0, units}
    {:windowed, entries} = lease.rows
    entry = elem(entries, 0)
    assert VisualRow.source_position(entry, 0, :start) == {:ok, {0, 0}}
    assert VisualRow.source_position(entry, units, :end) == {:ok, {0, source_end}}
  end

  test "encoded focus generation admits only the active current prompt owner and subsequent typing uses that source" do
    state = TestHelpers.base_state(content: "ordinary editor buffer")
    editor = state.workspace.buffers.active
    ui = prompt("draft")
    windows = Windows.set_map(state.workspace.windows, %{1 => Window.new_agent_chat(1, 24, 80)})

    workspace =
      state.workspace
      |> SessionState.set_windows(windows)
      |> SessionState.set_buffers(Buffers.set_active_override(state.workspace.buffers, nil))
      |> SessionState.set_agent_ui(ui)
      |> SessionState.set_keymap_scope(:agent)
      |> SessionState.transition_mode(:insert)

    state = %{state | workspace: workspace}
    {model, lease} = present(ui, 40, 1_008)
    generation = encoded_accessibility(model).generation
    registry = TextPresentations.acknowledge(TextPresentations.new(), [lease])

    state = %{
      state
      | render: Render.connect_renderer(state.render, self(), TextPresentations.reader(registry))
    }

    blurred = %{
      state
      | workspace:
          SessionState.set_agent_ui(state.workspace, PromptBuffer.set_input_focused(ui, false))
    }

    refute Map.has_key?(blurred.workspace.windows.map, 65_534)
    assert GuiActionHandler.dispatch(blurred, {:focus_window, 65_534, generation}) == blurred
    assert {:ok, registry} = TextPresentations.activate(registry, 65_534, generation)
    assert GuiActionHandler.dispatch(blurred, {:focus_window, 65_534, generation + 1}) == blurred
    focused = GuiActionHandler.dispatch(blurred, {:focus_window, 65_534, generation})
    assert focused.workspace.agent_ui.panel.input_focused
    assert focused.workspace.agent_ui.panel.prompt_buffer == lease.buffer
    assert focused.workspace.windows.active == 1
    assert focused.workspace.buffers.active == nil
    assert {:handled, typed} = AgentPanel.handle_key(focused, ?X, 0)
    assert String.contains?(PromptBuffer.input_text(typed.workspace.agent_ui), "X")
    assert Buffer.content(editor) == "ordinary editor buffer"

    replacement = prompt("replacement") |> PromptBuffer.set_input_focused(false)
    replaced = %{focused | workspace: SessionState.set_agent_ui(focused.workspace, replacement)}
    assert GuiActionHandler.dispatch(replaced, {:focus_window, 65_534, generation}) == replaced
    _registry = TextPresentations.discard(registry, 65_534, generation)
    assert GuiActionHandler.dispatch(blurred, {:focus_window, 65_534, generation}) == blurred
  end

  defp prompt(text) do
    %UIState{}
    |> PromptBuffer.ensure()
    |> UIState.toggle()
    |> PromptBuffer.set_input_focused(true)
    |> PromptBuffer.set_prompt_text(text)
  end

  defp present(ui, width, generation, opts \\ []) do
    ctx = %ViewContext{
      ui_state: ui,
      capabilities: Capabilities.default(),
      theme: Theme.get!(:doom_one),
      editing: Keyword.get(opts, :editing, VimState.transition(VimState.new(), :insert)),
      buffers: nil
    }

    PromptRenderWindow.build_presented(ctx, width, nil,
      presentation_id: generation,
      cursor_eligible: Keyword.get(opts, :cursor_eligible, true),
      project_files: [],
      project_root: nil
    )
  end

  defp encoded_accessibility(model) do
    [<<0x80, size::32, payload::binary-size(size)>> | _metadata] = WindowEncoder.encode(model)
    <<count::8, sections::binary>> = payload

    {sections, <<>>} =
      Enum.map_reduce(1..count, sections, fn _,
                                             <<id::8, length::32, data::binary-size(length),
                                               rest::binary>> ->
        {{id, data}, rest}
      end)

    {0x0C, payload} = List.keyfind(sections, 0x0C, 0)
    <<generation::64, cursor_row::16, cursor_utf16::32, range_count::16, rest::binary>> = payload

    {ranges, rest} =
      Enum.map_reduce(1..range_count//1, rest, fn _,
                                                  <<row::16, start_utf16::32, end_utf16::32,
                                                    tail::binary>> ->
        {{row, start_utf16, end_utf16}, tail}
      end)

    <<label_size::16, label::binary-size(label_size)>> = rest

    %{
      generation: generation,
      label: label,
      cursor: if(cursor_row == 0xFFFF, do: nil, else: {cursor_row, cursor_utf16}),
      selection_ranges: ranges
    }
  end

  defp utf16_length(text),
    do: div(byte_size(:unicode.characters_to_binary(text, :utf8, {:utf16, :little})), 2)
end
