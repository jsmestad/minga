defmodule MingaEditor.Agent.PromptInputTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Frontend.Adapter.GUI
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.WindowEncoder
  alias Minga.Protocol.Opcodes
  alias MingaEditor.Agent.PromptBuffer
  alias MingaEditor.Agent.PromptInput
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.View.PromptFrame
  alias MingaEditor.Agent.View.PromptProjection
  alias MingaEditor.Agent.View.PromptRenderWindow
  alias MingaEditor.Agent.ViewContext
  alias MingaEditor.Frontend.Protocol
  alias MingaEditor.Handlers.GuiActionHandler
  alias MingaEditor.Input.AgentPanel
  alias MingaEditor.Mouse
  alias MingaEditor.Mouse.TextEvent
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Renderer.TextInteractionIndex.Reader
  alias MingaEditor.Renderer.TextPresentations
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Render
  alias MingaEditor.State.Windows
  alias MingaEditor.Window

  test "an absent renderer reader admits neither prompt observations nor focus" do
    {state, _regular} = prompt_state("retained draft")
    assert state.render.text_interaction_reader == nil
    assert PromptInput.fit(state, 65_534, 101, 4, 2) == state
    assert PromptInput.scroll(state, 65_534, 101, 1) == state
    assert PromptInput.focus_presentation(state, 65_534, 101) == state
  end

  test "fit and scroll decode exact positive retained-presentation targets" do
    assert Protocol.decode_event(<<0x07, 0x66, 65_534::16, 123::64, 12::16, 3::16>>) ==
             {:ok, {:gui_action, {:agent_prompt_fit, 65_534, 123, 12, 3}}}

    assert Protocol.decode_event(<<0x07, 0x67, 65_534::16, 123::64, -9::signed-32>>) ==
             {:ok, {:gui_action, {:agent_prompt_scroll, 65_534, 123, -9}}}

    for payload <- [
          <<1::16, 123::64, 12::16, 3::16>>,
          <<65_534::16, 0::64, 12::16, 3::16>>,
          <<65_534::16, 123::64, 0::16, 3::16>>,
          <<65_534::16, 123::64, 12::16, 0::16>>,
          <<65_534::16, 123::64, 12::16, 3::16, 0>>
        ] do
      assert {:error, :malformed} = Protocol.decode_event(<<0x07, 0x66, payload::binary>>)
    end

    assert {:error, :malformed} =
             Protocol.decode_event(<<0x07, 0x67, 1::16, 123::64, 1::signed-32>>)
  end

  test "the encoded prompt source lease is registered without a fake WindowTree buffer" do
    {state, regular} = prompt_state("é界abcdef")
    {state, output, model, lease, registry} = present(state, 4, 101)
    refute Map.has_key?(output.windows.map, 65_534)
    assert {:windowed, _rows} = lease.rows
    assert model.text_presentation_id == 101

    assert WindowEncoder.encode_text_presentation(model) ==
             <<Opcodes.gui_text_presentation(), 65_534::16, 101::64>>

    {commands, _cache} = GUI.encode_windows([model], Caches.new())
    assert WindowEncoder.encode_text_presentation(model) in commands
    assert {:ok, registry} = TextPresentations.activate(registry, 65_534, 101)
    reader = TextPresentations.reader(registry)
    assert {:ok, {owner, version}} = Reader.source(reader, 65_534, 101)
    assert owner == state.workspace.agent_ui.panel.prompt_buffer
    assert version == Buffer.version(owner)

    row = Enum.at(model.rows, 1)
    event = event(model, 1, row.row_id, 1)
    assert {:ok, target} = Reader.resolve(reader, event)
    state = Mouse.handle_text_event(state, event, target)
    assert state.workspace.buffers.active == nil
    assert {:handled, state} = AgentPanel.handle_key(state, ?i, 0)
    assert {:handled, state} = AgentPanel.handle_key(state, ?X, 0)
    assert String.contains?(PromptBuffer.input_text(state.workspace.agent_ui), "X")
    assert Buffer.content(regular) == "regular source"
    assert Buffer.cursor(regular) == {0, 0}
  end

  test "initial physical fit admits the published owner lease before text activation without admitting scroll or text" do
    {state, _regular} = prompt_state("long enough to wrap")

    {model, lease} =
      PromptRenderWindow.build_presented(ViewContext.from_editor_state(state), 10, nil,
        presentation_id: 701,
        project_files: [],
        project_root: nil
      )

    registry = TextPresentations.acknowledge(TextPresentations.new(), [lease])
    reader = TextPresentations.reader(registry)
    state = %{state | render: Render.connect_renderer(state.render, self(), reader)}
    assert {:error, :inactive} = Reader.source(reader, 65_534, 701)
    assert {:ok, {owner, _version}} = Reader.retained_source(reader, 65_534, 701)
    assert owner == state.workspace.agent_ui.panel.prompt_buffer
    fitted = PromptInput.fit(state, 65_534, 701, 3, 2)
    assert fitted.workspace.agent_ui.panel.prompt_viewport.fit == {3, 2}
    assert PromptInput.scroll(state, 65_534, 701, 1) == state
    pointer = event(model, 0, hd(model.rows).row_id, 1)
    assert {:error, :inactive} = Reader.resolve(reader, pointer)
    registry = TextPresentations.discard(registry, 65_534, 701)

    assert {:error, :unknown} =
             Reader.retained_source(TextPresentations.reader(registry), 65_534, 701)

    assert PromptInput.fit(state, 65_534, 701, 3, 2) == state
  end

  test "unknown, discarded and replacement-owner observations cannot alter a prompt; inactive scrolling remains rejected" do
    {state, _regular} = prompt_state(String.duplicate("x", 60))
    {state, _output, model, lease, registry} = present(state, 10, 201)
    assert PromptInput.fit(state, 65_534, 999, 2, 2) == state
    assert PromptInput.fit(state, 2, 201, 2, 2) == state
    assert PromptInput.scroll(state, 65_534, 999, 20) == state

    replacement = %UIState{} |> PromptBuffer.ensure() |> PromptBuffer.set_input_focused(true)
    replaced = %{state | workspace: SessionState.set_agent_ui(state.workspace, replacement)}
    assert PromptInput.fit(replaced, 65_534, 201, 2, 2) == replaced
    assert PromptInput.scroll(replaced, 65_534, 201, 20) == replaced
    row = hd(model.rows)
    pointer = event(model, 0, row.row_id, 1)
    assert {:ok, old_target} = Reader.resolve(TextPresentations.reader(registry), pointer)
    assert Mouse.handle_text_event(replaced, pointer, old_target) == replaced

    {_model, pending} =
      PromptRenderWindow.build_presented(ViewContext.from_editor_state(state), 5, nil,
        presentation_id: 202,
        project_files: [],
        project_root: nil
      )

    registry = TextPresentations.acknowledge(registry, [pending])
    assert {:error, :inactive} = Reader.source(TextPresentations.reader(registry), 65_534, 202)
    fitted = PromptInput.fit(state, 65_534, 202, 2, 2)
    assert fitted.workspace.agent_ui.panel.prompt_viewport.fit == {2, 2}
    assert PromptInput.scroll(state, 65_534, 202, 20) == state

    registry = TextPresentations.discard(registry, 65_534, lease.presentation_id)

    discarded = %{
      state
      | render: Render.connect_renderer(state.render, self(), TextPresentations.reader(registry))
    }

    assert PromptInput.fit(discarded, 65_534, 201, 2, 2) == discarded
    assert PromptInput.scroll(discarded, 65_534, 201, 20) == discarded
  end

  test "advertised row overflow rejects the observation without changing learned fit, live draft or cursor" do
    {state, _regular} = prompt_state("é界 retained draft")
    {state, _output, _model, _lease, _registry} = present(state, 10, 801)
    policy = MingaEditor.Frontend.ResourcePolicy.new(1, 0, 0, 2)
    capabilities = %{state.frontend.capabilities | resource_policy: policy}

    state = %{
      state
      | frontend: MingaEditor.State.Frontend.accept_capabilities(state.frontend, capabilities)
    }

    fitted = GuiActionHandler.dispatch(state, {:agent_prompt_fit, 65_534, 801, 4, 2})
    assert fitted.workspace.agent_ui.panel.prompt_viewport.fit == {4, 2}
    prompt = fitted.workspace.agent_ui.panel.prompt_buffer
    content = Buffer.content(prompt)
    cursor = Buffer.cursor(prompt)
    rejected = GuiActionHandler.dispatch(fitted, {:agent_prompt_fit, 65_534, 801, 3, 3})
    assert rejected == fitted
    assert Buffer.content(prompt) == content
    assert Buffer.cursor(prompt) == cursor
  end

  test "zero or version-zero row policy dimensions remain unadvertised" do
    {state, _regular} = prompt_state("draft")
    {state, _output, _model, _lease, _registry} = present(state, 10, 802)

    for policy <- [
          MingaEditor.Frontend.ResourcePolicy.unadvertised(),
          MingaEditor.Frontend.ResourcePolicy.new(0, 0, 0, 1),
          MingaEditor.Frontend.ResourcePolicy.new(1, 0, 0, 0)
        ] do
      capabilities = %{state.frontend.capabilities | resource_policy: policy}

      scoped = %{
        state
        | frontend: MingaEditor.State.Frontend.accept_capabilities(state.frontend, capabilities)
      }

      fitted = GuiActionHandler.dispatch(scoped, {:agent_prompt_fit, 65_534, 802, 4, 8})
      assert fitted.workspace.agent_ui.panel.prompt_viewport.fit == {4, 8}
    end
  end

  test "fit survives edits to its owner and scrolling is bounded without draft or cursor writes" do
    {state, _regular} = prompt_state(String.duplicate("x", 61))
    prompt = state.workspace.agent_ui.panel.prompt_buffer
    Buffer.move_to(prompt, {0, 61})
    {state, _output, _model, _lease, _registry} = present(state, 10, 301)
    state = GuiActionHandler.dispatch(state, {:agent_prompt_fit, 65_534, 301, 4, 2})
    assert state.workspace.agent_ui.panel.prompt_viewport.fit == {4, 2}
    content = Buffer.content(prompt)
    cursor = Buffer.cursor(prompt)
    reading = GuiActionHandler.dispatch(state, {:agent_prompt_scroll, 65_534, 301, -0x7FFFFFFF})
    assert PromptProjection.build(reading.workspace.agent_ui.panel, 80).scroll == 0
    bottom = GuiActionHandler.dispatch(reading, {:agent_prompt_scroll, 65_534, 301, 0x7FFFFFFF})
    projection = PromptProjection.build(bottom.workspace.agent_ui.panel, 80)
    assert projection.scroll == length(projection.rows) - 2
    assert Buffer.content(prompt) == content
    assert Buffer.cursor(prompt) == cursor
    assert {:handled, edited} = AgentPanel.handle_key(reading, ?Z, 0)
    projection = PromptProjection.build(edited.workspace.agent_ui.panel, 80)
    assert projection.columns == 4
    assert projection.visible_rows == 2
    assert projection.scroll > 0
    assert edited.workspace.agent_ui.panel.prompt_viewport.reading == nil
  end

  test "both frontend horizontal arrow encodings move the prompt and restore follow without inserting private-use characters" do
    for {left, right} <- [{0xF702, 0xF703}, {57_350, 57_351}] do
      text = "é界" <> String.duplicate("x", 40)
      {state, regular} = prompt_state(text)
      prompt = state.workspace.agent_ui.panel.prompt_buffer
      Buffer.move_to(prompt, {0, byte_size(text)})
      {state, _output, _model, _lease, _registry} = present(state, 4, 501)
      state = PromptInput.fit(state, 65_534, 501, 4, 2)
      reading = PromptInput.scroll(state, 65_534, 501, -100)
      assert PromptProjection.build(reading.workspace.agent_ui.panel, 80).scroll == 0
      assert {:handled, moved} = AgentPanel.handle_key(reading, left, 0)
      assert Buffer.cursor(prompt) == {0, byte_size(text) - 1}
      assert moved.workspace.agent_ui.panel.prompt_viewport.reading == nil
      assert PromptProjection.build(moved.workspace.agent_ui.panel, 80).scroll > 0
      assert {:handled, moved} = AgentPanel.handle_key(moved, right, 0)
      assert Buffer.cursor(prompt) == {0, byte_size(text)}
      assert moved.workspace.buffers.active == nil
      assert Buffer.content(prompt) == text
      assert Buffer.content(regular) == "regular source"
    end
  end

  test "drag edge scrolling retains the final source cursor and reveals overflow in either direction" do
    for {direction, row_index, cursor_byte, expected_top} <- [{1, 1, 21, 5}, {-1, 0, 17, 2}] do
      text = String.duplicate("x", 48)
      {state, regular} = prompt_state(text)
      prompt = state.workspace.agent_ui.panel.prompt_buffer
      Buffer.move_to(prompt, {0, 23})
      {state, _output, _model, _lease, _registry} = present(state, 4, 901)
      state = PromptInput.fit(state, 65_534, 901, 4, 2)
      {state, _output, model, _lease, registry} = present(state, 4, 902)
      assert Enum.map(model.rows, & &1.visual_index) == [4, 5]
      reader = TextPresentations.reader(registry)
      press = event(model, 1, Enum.at(model.rows, 1).row_id, 3)
      assert {:ok, target} = Reader.resolve(reader, press)
      state = Mouse.handle_text_event(state, press, target)

      drag = %{
        event(model, row_index, Enum.at(model.rows, row_index).row_id, 1)
        | event_type: :drag,
          scroll_y: direction
      }

      assert {:ok, target} = Reader.resolve(reader, drag)
      state = Mouse.handle_text_event(state, drag, target)
      assert Buffer.cursor(prompt) == {0, cursor_byte}
      assert state.workspace.editing.mode_state.visual_anchor == {0, 23}
      panel = state.workspace.agent_ui.panel

      assert panel.prompt_viewport.reading ==
               {{Buffer.version(prompt), {0, cursor_byte}}, {0, expected_top}}

      projection = PromptProjection.build(panel, 4)
      assert projection.scroll == expected_top

      {next, _lease} =
        PromptRenderWindow.build_presented(ViewContext.from_editor_state(state), 4, nil,
          projection: projection,
          project_files: [],
          project_root: nil
        )

      assert Enum.map(next.rows, & &1.visual_index) == [expected_top, expected_top + 1]
      assert next.geometry.viewport.top == 0
      assert next.geometry.viewport.rows == 2
      assert Buffer.content(prompt) == text
      assert Buffer.content(regular) == "regular source"
    end
  end

  test "retained drag, context and shift selection use the prompt source rather than the active editor buffer" do
    {state, regular} = prompt_state("abcdefghijklm")
    {state, _output, model, _lease, registry} = present(state, 4, 601)
    reader = TextPresentations.reader(registry)
    press = event(model, 0, hd(model.rows).row_id, 1)
    assert {:ok, target} = Reader.resolve(reader, press)
    state = Mouse.handle_text_event(state, press, target)

    drag = %{event(model, 2, Enum.at(model.rows, 2).row_id, 2) | event_type: :drag}
    assert {:ok, target} = Reader.resolve(reader, drag)
    state = Mouse.handle_text_event(state, drag, target)
    assert state.workspace.editing.mode == :visual
    assert state.workspace.editing.mode_state.visual_anchor == {0, 1}
    prompt = state.workspace.agent_ui.panel.prompt_buffer
    assert Buffer.cursor(prompt) == {0, 10}

    context = %{event(model, 1, Enum.at(model.rows, 1).row_id, 1) | button: :right}
    assert {:ok, target} = Reader.resolve(reader, context)
    state = Mouse.handle_text_event(state, context, target)
    assert Buffer.cursor(prompt) == {0, 10}
    assert state.workspace.editing.mode_state.visual_anchor == {0, 1}
    shift = %{context | button: :left, mods: 0x01}
    state = Mouse.handle_text_event(state, shift, target)
    assert Buffer.cursor(prompt) == {0, 5}
    assert state.workspace.editing.mode_state.visual_anchor == {0, 1}

    {selected, _lease} =
      PromptRenderWindow.build_presented(ViewContext.from_editor_state(state), 4, nil,
        project_files: [],
        project_root: nil
      )

    assert {selected.selection.start_row, selected.selection.start_col} == {0, 1}
    assert {selected.selection.end_row, selected.selection.end_col} == {1, 2}
    assert state.workspace.buffers.active == nil
    assert Buffer.content(regular) == "regular source"
  end

  test "committed picker ownership suppresses the canonical prompt caret, not its selection" do
    {state, _regular} = prompt_state("composer")
    Buffer.move_to(state.workspace.agent_ui.panel.prompt_buffer, {0, 4})
    visual = %Minga.Mode.VisualState{visual_type: :char, visual_anchor: {0, 1}}
    state = %{state | workspace: SessionState.transition_mode(state.workspace, :visual, visual)}

    {opened, _revision} =
      MingaEditor.PickerUI.open_loading(state, MingaEditor.UI.Picker.AgentModelSource)

    assert opened.workspace.agent_ui.panel.input_focused
    input = opened |> Input.from_editor_state() |> MingaEditor.Layout.put()

    {[content], nil, output} =
      MingaEditor.RenderPipeline.Content.build_agent_chat_content(
        input,
        MingaEditor.Layout.get(input)
      )

    [model] = content.models
    assert output.intent.frame.focus_owner.surface == :picker
    refute model.cursor_visible
    assert model.rows != []
    assert model.selection != nil
    assert model.text_presentation_id > 0
  end

  test "model picker activation cannot restore an inactive regular buffer index" do
    {state, regular} = prompt_state("")
    source = MingaEditor.UI.Picker.AgentModelSource
    {opened, revision} = MingaEditor.PickerUI.open_loading(state, source)
    {:picker, %{picker_ui: picker}} = opened.shell_runtime.state.modal
    assert picker.restore == nil
    selection = MingaAgent.Test.ModelSelectionFixture.selection()

    item = %MingaEditor.UI.Picker.Item{
      id: "selected-route",
      label: "Selected model",
      meta: %{selection: selection}
    }

    candidates = MingaEditor.UI.Picker.Candidate.from_items([item])

    assert {:ok, loaded} =
             MingaEditor.PickerUI.apply_fetch_result(
               opened,
               source,
               revision,
               picker.fetch_identity,
               {:ok, [item], candidates, nil}
             )

    selected = MingaEditor.PickerUI.handle_key(loaded, 13, 0)
    assert selected.workspace.keymap_scope == :agent
    assert selected.workspace.buffers.active == nil
    assert selected.shell_runtime.state.modal == :none
    # Selection reaches the real model callback, which truthfully rejects a missing session.
    assert selected.shell_runtime.state.notice.message =~ "No agent session"
    assert {:handled, typed} = AgentPanel.handle_key(selected, ?X, 0)
    assert PromptBuffer.input_text(typed.workspace.agent_ui) == "X"
    assert Buffer.content(regular) == "regular source"
  end

  test "chat metadata reads the same immutable prompt projection even after a later source edit" do
    {state, _regular} = prompt_state("a\nb\nc\n")
    tab = MingaEditor.State.Tab.new_agent(1, "Agent")

    {bar, workspace} =
      MingaEditor.State.TabBar.new(tab) |> MingaEditor.State.TabBar.add_workspace("Agent", self())

    bar = MingaEditor.State.TabBar.move_tab_to_workspace(bar, tab.id, workspace.id)
    shell = MingaEditor.Shell.Traditional.State.install_tab_bar(state.shell_runtime.state, bar)

    state = %{
      state
      | shell_runtime:
          MingaEditor.Shell.Runtime.install_traditional_state(state.shell_runtime, shell)
    }

    {state, output, model, _lease, _registry} = present(state, 4, 401)
    Buffer.insert_text(state.workspace.agent_ui.panel.prompt_buffer, "later edit")

    chat =
      output
      |> MingaEditor.Frontend.Emit.Context.from_input()
      |> MingaEditor.RenderModel.UI.AgentChatBuilder.build()

    assert chat.visible?
    assert chat.prompt == "a\nb\nc\n"
    assert chat.prompt_visible_rows == model.geometry.viewport.rows
    assert chat.prompt_line_count == length(output.prompt.projection.lines)
    assert {chat.prompt_cursor_line, chat.prompt_cursor_col} == output.prompt.projection.cursor
  end

  defp prompt_state(text) do
    state = TestHelpers.base_state(content: "regular source")
    regular = state.workspace.buffers.active
    Buffer.move_to(regular, {0, 0})

    ui =
      %UIState{}
      |> PromptBuffer.ensure()
      |> UIState.toggle()
      |> PromptBuffer.set_prompt_text(text)
      |> PromptBuffer.set_input_focused(true)

    windows = Windows.set_map(state.workspace.windows, %{1 => Window.new_agent_chat(1, 24, 80)})

    workspace =
      state.workspace
      |> SessionState.set_windows(windows)
      |> SessionState.set_buffers(Buffers.set_active_override(state.workspace.buffers, nil))
      |> SessionState.set_agent_ui(ui)
      |> SessionState.set_keymap_scope(:agent)
      |> SessionState.transition_mode(:insert)

    {%{state | workspace: workspace}, regular}
  end

  defp present(state, columns, generation) do
    projection = PromptProjection.build(state.workspace.agent_ui.panel, columns)

    {model, lease} =
      PromptRenderWindow.build_presented(ViewContext.from_editor_state(state), columns, nil,
        projection: projection,
        presentation_id: generation,
        project_files: [],
        project_root: nil
      )

    frame = %PromptFrame{window: model, presentation: lease, projection: projection}
    output = Input.from_editor_state(state) |> Input.record_prompt(frame)
    registry = TextPresentations.acknowledge_output(TextPresentations.new(), output)
    assert {:ok, registry} = TextPresentations.activate(registry, 65_534, generation)

    state = %{
      state
      | render: Render.connect_renderer(state.render, self(), TextPresentations.reader(registry))
    }

    {state, output, model, lease, registry}
  end

  defp event(model, index, row_id, utf16) do
    TextEvent.new(%{
      window_id: 65_534,
      presentation_id: model.text_presentation_id,
      row_index: index,
      row_id: row_id,
      utf16_offset: utf16,
      button: :left,
      mods: 0,
      event_type: :press,
      click_count: 1,
      scroll_x: 0,
      scroll_y: 0
    })
  end
end
