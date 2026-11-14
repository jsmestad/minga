defmodule MingaEditor.Agent.View.PromptProjectionTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Core.Unicode
  alias MingaEditor.Agent.PromptBuffer
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.UIState.Panel
  alias MingaEditor.Agent.View.PromptProjection
  alias MingaEditor.Agent.View.PromptRenderWindow
  alias MingaEditor.Agent.ViewContext
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.RenderModel.Window.VisualRow
  alias MingaEditor.Renderer.TextPresentation
  alias MingaEditor.UI.Theme
  alias MingaEditor.VimState

  test "ordinary wrapping and long words preserve every source byte, including repeated whitespace" do
    for text <- ["one two three four", "abcdefghijklmnop", "ab   cd  ef", "a\n\nb\n"] do
      panel = panel(text)
      projection = PromptProjection.build(panel, 4)
      assert Enum.map_join(projection.rows, & &1.text) == String.replace(text, "\n", "")

      for {line, logical} <- Enum.with_index(String.split(text, "\n")) do
        rows = Enum.filter(projection.rows, &(&1.logical_line == logical))
        assert Enum.map_join(rows, & &1.text) == line
        assert Enum.map(rows, & &1.visual_index) == Enum.to_list(0..(length(rows) - 1))
      end
    end
  end

  test "Unicode byte positions, display cells and retained UTF-16 input have distinct mappings" do
    text = "é界é👩‍💻z"
    panel = panel(text)
    projection = PromptProjection.build(panel, 3)
    assert Enum.map(projection.rows, & &1.text) == ["é界", "é👩‍💻", "z"]
    assert PromptProjection.position(projection, {0, byte_size("é界")}) == {1, 0}
    assert PromptProjection.position(projection, {0, byte_size("é界é")}) == {1, 1}
    assert PromptProjection.position(projection, {0, byte_size(text)}) == {2, 1}

    {model, lease} =
      PromptRenderWindow.build_presented(context(panel), 3, nil,
        project_files: [],
        project_root: nil
      )

    assert model.row_store_mode == :windowed
    assert model.geometry.viewport.total_lines == 1
    assert model.geometry.viewport.total_visual_rows == 3
    row = Enum.at(model.rows, 1)

    for {utf16_offset, expected_byte} <- [{1, byte_size("é界")}, {2, byte_size("é界é")}] do
      assert {:ok, target} = TextPresentation.resolve(lease, 1, row.row_id, utf16_offset)
      assert target.buffer == panel.prompt_buffer
      assert target.byte == expected_byte
      assert target.line == 0
    end
  end

  test "explicit and trailing newlines retain empty source-backed rows" do
    panel = panel("a\n\n")
    Buffer.move_to(panel.prompt_buffer, {2, 0})
    projection = PromptProjection.build(panel, 8)

    assert Enum.map(projection.rows, &{&1.logical_line, &1.visual_index, &1.text}) == [
             {0, 0, "a"},
             {1, 0, ""},
             {2, 0, ""}
           ]

    assert projection.visible_rows == 3
    assert PromptProjection.position(projection, {2, 0}) == {2, 0}
  end

  test "an exact-width insertion caret has its own valid continuation row" do
    panel = panel("é界")
    Buffer.move_to(panel.prompt_buffer, {0, byte_size("é界")})

    {model, lease} =
      PromptRenderWindow.build_presented(context(panel), 3, nil,
        project_files: [],
        project_root: nil
      )

    assert Enum.map(model.rows, & &1.text) == ["é界", ""]
    assert {model.cursor_row, model.cursor_col} == {1, 0}
    assert model.cursor_visible
    [_, row] = model.rows
    assert {:ok, target} = TextPresentation.resolve(lease, 1, row.row_id, 0)
    assert target.byte == byte_size("é界")
  end

  test "cursor relocation preserves exact-width rows and a bottom-anchored pointer's word" do
    text = "keyboard commands multiline"
    panel = panel(text) |> Panel.fit_prompt(9, 8)
    Buffer.move_to(panel.prompt_buffer, {0, byte_size(text)})
    projection = PromptProjection.build(panel, 80)
    rect = {20 - projection.visible_rows, 3, projection.columns, projection.visible_rows}

    {model, lease} =
      PromptRenderWindow.build_presented(context(panel), 80, rect,
        projection: projection,
        presentation_id: 101,
        project_files: [],
        project_root: nil
      )

    assert Enum.map(model.rows, & &1.text) == ["keyboard ", "commands ", "multiline", ""]
    assert {model.cursor_row, model.cursor_col} == {3, 0}
    point_row = elem(model.rect, 0) + 2
    row = Enum.at(model.rows, 2)
    assert {:ok, target} = TextPresentation.resolve(lease, 2, row.row_id, 4)
    assert target.byte == byte_size("keyboard commands ") + 4

    for cursor <- [{0, target.byte}, {0, 0}, {0, byte_size(text)}] do
      Buffer.move_to(panel.prompt_buffer, cursor)
      next_projection = PromptProjection.build(panel, 80)
      assert next_projection.rows == projection.rows
      assert next_projection.visible_rows == 4
      assert next_projection.columns == 9

      rect =
        {20 - next_projection.visible_rows, 3, next_projection.columns,
         next_projection.visible_rows}

      {next, retained} =
        PromptRenderWindow.build_presented(context(panel), 80, rect,
          projection: next_projection,
          previous_presentation: lease,
          presentation_id: 102,
          project_files: [],
          project_root: nil
        )

      assert next.rect == model.rect
      assert next.geometry == model.geometry
      assert next.rows == model.rows
      assert retained.presentation_id == lease.presentation_id
      point_index = point_row - elem(next.rect, 0)
      pointed_row = Enum.at(next.rows, point_index)
      assert pointed_row.text == "multiline"

      assert {:ok, pointed} =
               TextPresentation.resolve(retained, point_index, pointed_row.row_id, 4)

      assert {pointed.line, pointed.byte} == {target.line, target.byte}
    end

    assert Buffer.content(panel.prompt_buffer) == text
  end

  test "only document EOF reserves a continuation; explicit newlines never gain inter-line blanks" do
    cases = [
      {"", 4, [{0, 0, ""}], {0, 0}, {0, 0}, {0, 0}, {0, 0}},
      {"abcd\nefgh", 4, [{0, 0, "abcd"}, {1, 0, "efgh"}, {1, 1, ""}], {0, 4}, {0, 4}, {1, 4},
       {2, 0}},
      {"abcd\nefgh\n", 4, [{0, 0, "abcd"}, {1, 0, "efgh"}, {2, 0, ""}], {1, 4}, {1, 4}, {2, 0},
       {2, 0}},
      {"abcd\n\n", 4, [{0, 0, "abcd"}, {1, 0, ""}, {2, 0, ""}], {0, 4}, {0, 4}, {2, 0}, {2, 0}},
      {"abcd\nx", 4, [{0, 0, "abcd"}, {1, 0, "x"}], {0, 4}, {0, 4}, {1, 1}, {1, 1}},
      {"é界\né界", 3, [{0, 0, "é界"}, {1, 0, "é界"}, {1, 1, ""}], {0, byte_size("é界")}, {0, 3},
       {1, byte_size("é界")}, {2, 0}},
      {"👩‍💻x\né界", 3, [{0, 0, "👩‍💻x"}, {1, 0, "é界"}, {1, 1, ""}], {0, byte_size("👩‍💻x")}, {0, 3},
       {1, byte_size("é界")}, {2, 0}}
    ]

    for {text, columns, expected, interior, interior_position, eof, eof_position} <- cases do
      panel = panel(text)
      initial = PromptProjection.build(panel, columns)

      assert Enum.map(initial.rows, &{&1.logical_line, &1.visual_index, &1.text}) == expected

      for cursor <- [{0, 0}, interior, eof] do
        Buffer.move_to(panel.prompt_buffer, cursor)
        projection = PromptProjection.build(panel, columns)
        assert projection.rows == initial.rows
        assert projection.visible_rows == length(expected)
        assert PromptProjection.position(projection, interior) == interior_position
        assert PromptProjection.position(projection, eof) == eof_position
      end
    end
  end

  test "stable EOF capacity obeys physical columns and the eight-row cap during cursor follow" do
    text = String.duplicate("x", 32)

    for capacity <- [2, 8] do
      panel = panel(text) |> Panel.fit_prompt(4, capacity)
      initial = PromptProjection.build(panel, 80)

      for cursor <- [{0, 0}, {0, byte_size(text)}, {0, 5}] do
        Buffer.move_to(panel.prompt_buffer, cursor)
        projection = PromptProjection.build(panel, 80)
        assert projection.rows == initial.rows
        assert projection.visible_rows == capacity
        assert projection.columns == 4
        assert PromptProjection.position(projection, {0, byte_size(text)}) == {8, 0}
      end
    end
  end

  test "a full-width collapsed pill retains its EOF row and replacement source map away from EOF" do
    ui = %UIState{} |> PromptBuffer.ensure() |> PromptBuffer.insert_paste("one\ntwo\nthree")
    text = "󰆏 [pasted 3 lines]"
    columns = Unicode.display_width(text)
    source_end = byte_size(PromptBuffer.input_text(ui))
    panel = Panel.fit_prompt(ui.panel, columns, 8)
    initial = PromptProjection.build(panel, 80)

    for byte <- [0, source_end] do
      Buffer.move_to(panel.prompt_buffer, {0, byte})
      projection = PromptProjection.build(panel, 80)
      assert projection.rows == initial.rows

      {model, lease} =
        PromptRenderWindow.build_presented(context(panel), 80, nil,
          projection: projection,
          project_files: [],
          project_root: nil
        )

      assert Enum.map(model.rows, & &1.text) == [text, ""]
      [_, row] = model.rows
      assert {:ok, target} = TextPresentation.resolve(lease, 1, row.row_id, 0)
      assert {target.line, target.byte} == {0, source_end}
    end
  end

  test "interior full-width EOL keeps a visible right-edge caret and its own source line" do
    panel = panel("é界\ntail")
    Buffer.move_to(panel.prompt_buffer, {0, byte_size("é界")})

    {model, lease} =
      PromptRenderWindow.build_presented(context(panel), 3, nil,
        project_files: [],
        project_root: nil
      )

    assert Enum.map(model.rows, & &1.text) == ["é界", "tai", "l"]
    assert {model.cursor_row, model.cursor_col} == {0, 3}
    assert model.cursor_col == model.geometry.viewport.cols
    assert model.cursor_visible
    assert model.accessibility_cursor == {0, 2}
    [first, following, _] = model.rows

    # Modal pointer hits select the final grapheme; the insertion caret retains the UTF-16 EOL boundary above.
    assert {:ok, target} = TextPresentation.resolve(lease, 0, first.row_id, 2)
    assert {target.line, target.byte} == {0, byte_size("é")}
    assert {:ok, next_line} = TextPresentation.resolve(lease, 1, following.row_id, 0)
    assert {next_line.line, next_line.byte} == {1, 0}
  end

  test "height grows from one through eight then honors narrower physical capacity" do
    for count <- 1..10 do
      panel = panel(Enum.map_join(1..count, "\n", fn _ -> "x" end))
      assert PromptProjection.build(panel, 40).visible_rows == min(count, 8)
      fitted = Panel.fit_prompt(panel, 2, 3)
      assert PromptProjection.build(fitted, 40).visible_rows == min(count, 3)
    end

    panel = panel(String.duplicate("x", 35)) |> Panel.fit_prompt(4, 2)
    Buffer.move_to(panel.prompt_buffer, {0, 35})
    projection = PromptProjection.build(panel, 80)
    assert projection.columns == 4
    assert projection.visible_rows == 2
    assert projection.scroll == 7

    {model, _lease} =
      PromptRenderWindow.build_presented(context(panel), 80, nil,
        project_files: [],
        project_root: nil
      )

    assert model.geometry.viewport.top == 0
    assert model.geometry.viewport.visual_row_offset == 7
    assert Enum.map(model.rows, & &1.visual_index) == [7, 8]
    assert {model.cursor_row, model.cursor_col} == {1, 3}
  end

  test "scroll reading leaves the cursor untouched and edits or reverse movement restore follow" do
    panel = panel(String.duplicate("x", 35)) |> Panel.fit_prompt(4, 2)
    Buffer.move_to(panel.prompt_buffer, {0, 35})
    projection = PromptProjection.build(panel, 80)
    marker = {projection.version, projection.cursor}
    reading = Panel.scroll_prompt(panel, marker, PromptProjection.anchor(projection, 0))
    assert PromptProjection.build(reading, 80).scroll == 0
    assert Buffer.cursor(panel.prompt_buffer) == {0, 35}

    {model, _} =
      PromptRenderWindow.build_presented(context(reading), 80, nil,
        project_files: [],
        project_root: nil
      )

    refute model.cursor_visible

    Buffer.move_to(panel.prompt_buffer, {0, 1})
    assert PromptProjection.build(reading, 80).scroll == 0
    Buffer.move_to(panel.prompt_buffer, {0, 35})
    Buffer.insert_text(panel.prompt_buffer, "!")
    assert PromptProjection.build(reading, 80).scroll > 0
    assert PromptProjection.build(reading, 80).columns == 4
  end

  test "selections crossing a wrapped viewport clip to display rows and preserve Unicode byte anchors" do
    panel = panel("é界abcdeé界abcde") |> Panel.fit_prompt(4, 2)
    Buffer.move_to(panel.prompt_buffer, {0, byte_size("é界abcdeé界abcde")})

    editing =
      VimState.transition(VimState.new(), :visual, %Minga.Mode.VisualState{
        visual_type: :char,
        visual_anchor: {0, byte_size("é")}
      })

    ctx = %{context(panel) | editing: editing}

    {model, _} =
      PromptRenderWindow.build_presented(ctx, 80, nil, project_files: [], project_root: nil)

    assert model.selection.start_row == 0
    assert model.selection.start_col == 0
    assert model.selection.end_row < 2
    assert model.cursor_row < 2
    resized = Panel.fit_prompt(panel, 7, 3)

    {wider, _} =
      PromptRenderWindow.build_presented(%{ctx | ui_state: %UIState{panel: resized}}, 80, nil,
        project_files: [],
        project_root: nil
      )

    assert wider.geometry.viewport.cols == 7
    assert wider.selection != nil
    assert Buffer.content(panel.prompt_buffer) == "é界abcdeé界abcde"
  end

  test "paste pills wrap with canonical styling and replacement source mapping and expand into actual source" do
    ui = %UIState{} |> PromptBuffer.ensure() |> PromptBuffer.insert_paste("one\ntwo\nthree")
    panel = Panel.fit_prompt(ui.panel, 5, 8)

    {model, lease} =
      PromptRenderWindow.build_presented(context(panel), 80, nil,
        project_files: [],
        project_root: nil
      )

    assert Enum.all?(model.rows, &(not String.contains?(&1.text, "\0")))
    assert Enum.map_join(model.rows, & &1.text) == "󰆏 [pasted 3 lines]"
    assert Enum.all?(model.rows, &(Unicode.display_width(&1.text) <= 5))
    {:windowed, rows} = lease.rows

    for entry <- Tuple.to_list(rows) do
      assert {:ok, {0, byte}} = VisualRow.source_position(entry, 1)
      assert byte in [0, byte_size(PromptBuffer.input_text(ui))]
    end

    expanded = PromptBuffer.toggle_paste_expand(ui)
    assert PromptBuffer.input_text(expanded) == "one\ntwo\nthree"
    assert PromptProjection.build(expanded.panel, 40).visible_rows == 3
  end

  test "collapsed paste insertion splits Unicode at the authoritative byte cursor" do
    ui = %UIState{} |> PromptBuffer.ensure() |> PromptBuffer.set_prompt_text("é界tail")
    Buffer.move_to(ui.panel.prompt_buffer, {0, byte_size("é界")})
    pasted = PromptBuffer.insert_paste(ui, "one\ntwo\nthree")
    assert PromptBuffer.input_lines(pasted) == ["é界", "\0PASTE:0", "tail"]
    assert PromptBuffer.prompt_text(pasted) == "é界\none\ntwo\nthree\ntail"
  end

  test "logical up and down cannot reactivate an old reading anchor after returning to the same cursor" do
    panel = panel("a\nb\nc") |> Panel.fit_prompt(4, 2)
    Buffer.move_to(panel.prompt_buffer, {2, 0})
    projection = PromptProjection.build(panel, 80)
    reading = Panel.scroll_prompt(panel, {projection.version, projection.cursor}, {0, 0})
    ui = %UIState{panel: reading}
    assert PromptProjection.build(reading, 80).scroll == 0
    assert %UIState{} = up = PromptBuffer.move_cursor_up(ui)
    assert up.panel.prompt_viewport.reading == nil
    assert %UIState{} = down = PromptBuffer.move_cursor_down(up)
    assert Buffer.cursor(panel.prompt_buffer) == {2, 0}
    assert down.panel.prompt_viewport.reading == nil
    assert down.panel.prompt_viewport.fit == {4, 2}
    assert PromptProjection.build(down.panel, 80).scroll == 1
  end

  defp panel(text) do
    {:ok, buffer} = Buffer.start_link(content: text)
    Buffer.move_to(buffer, {0, 0})
    %Panel{prompt_buffer: buffer, visible: true, input_focused: true}
  end

  defp context(panel) do
    %ViewContext{
      ui_state: %UIState{panel: panel},
      capabilities: Capabilities.default(),
      theme: Theme.get!(:doom_one),
      editing: VimState.transition(VimState.new(), :insert),
      buffers: nil
    }
  end
end
