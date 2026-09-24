defmodule MingaEditor.Renderer.TextPresentationsTest do
  use ExUnit.Case, async: true

  alias Minga.Core.Decorations
  alias Minga.RenderModel.Window.Row
  alias MingaEditor.Mouse.TextEvent
  alias MingaEditor.Mouse.Target.Text, as: TextTarget
  alias MingaEditor.RenderModel.Window.ResidentStore
  alias MingaEditor.RenderModel.Window.SourceOffsetMap
  alias MingaEditor.RenderModel.Window.VisualRow
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.RenderPipeline.WindowIntent
  alias MingaEditor.Renderer.RenderWindow
  alias MingaEditor.Renderer.WindowCache
  alias MingaEditor.Window
  alias MingaEditor.Renderer.TextPresentation
  alias MingaEditor.Renderer.TextPresentations
  alias MingaEditor.State.Windows

  test "acknowledging a newer candidate does not retire the older visible presentation" do
    first = presentation(1, 101, 3, "first")
    second = presentation(1, 102, 3, "second")

    registry = TextPresentations.acknowledge(TextPresentations.new(), [first])
    assert {:ok, registry} = TextPresentations.activate(registry, 1, first.presentation_id)

    registry = TextPresentations.acknowledge(registry, [second])

    assert {:ok, %TextTarget{line: 3, byte: 2}} =
             TextPresentations.resolve(registry, event(first, 2))

    assert {:error, :inactive} = TextPresentations.resolve(registry, event(second, 2))
  end

  test "active and discarded transitions apply to their exact presentation ids" do
    first = presentation(1, 101, 3, "first")
    second = presentation(1, 102, 4, "second")

    registry = TextPresentations.acknowledge(TextPresentations.new(), [first, second])
    assert {:ok, registry} = TextPresentations.activate(registry, 1, first.presentation_id)
    assert {:ok, registry} = TextPresentations.activate(registry, 1, second.presentation_id)
    registry = TextPresentations.discard(registry, 1, first.presentation_id)

    assert {:ok, %TextTarget{line: 4}} =
             TextPresentations.resolve(registry, event(second, 1))

    registry = TextPresentations.discard(registry, 1, second.presentation_id)
    assert {:error, :inactive} = TextPresentations.resolve(registry, event(second, 1))
  end

  test "row rank must match the row id retained in the immutable payload" do
    presentation = presentation(3, 301, 8, "hello")
    registry = TextPresentations.acknowledge(TextPresentations.new(), [presentation])
    assert {:ok, registry} = TextPresentations.activate(registry, 3, presentation.presentation_id)

    bad = %{event(presentation, 1) | row_id: 999}
    assert {:error, :row_id_mismatch} = TextPresentations.resolve(registry, bad)
  end

  test "wrapped Unicode targets resolve through the retained row without rebuilding layout" do
    presentation = wrapped_unicode_presentation()
    registry = TextPresentations.acknowledge(TextPresentations.new(), [presentation])
    assert {:ok, registry} = TextPresentations.activate(registry, 7, presentation.presentation_id)

    assert {:ok, %TextTarget{line: 11, byte: 5}} =
             TextPresentations.resolve(registry, event(presentation, 4))
  end

  test "cursor-only frames reuse an immutable identity while source changes allocate a new id" do
    first = presentation(3, 301, 8, "hello")

    reused =
      TextPresentation.retain(
        first,
        first.window_id,
        first.buffer,
        first.source_version,
        first.identity,
        first.rows
      )

    changed =
      TextPresentation.retain(
        first,
        first.window_id,
        first.buffer,
        first.source_version + 1,
        {:changed_source, first.identity},
        first.rows
      )

    assert reused.presentation_id == first.presentation_id
    refute changed.presentation_id == first.presentation_id
  end

  test "a pending buffer replacement leaves the visible lease until ordered activation and discard" do
    old = presentation(5, 501, 2, "hello")

    replacement_buffer =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    replacement = presentation(5, 502, 4, "other", replacement_buffer)

    registry = TextPresentations.acknowledge(TextPresentations.new(), [old])
    assert {:ok, registry} = TextPresentations.activate(registry, 5, old.presentation_id)
    registry = TextPresentations.acknowledge(registry, [replacement])

    assert {:ok, %TextTarget{buffer: buffer, line: 2}} =
             TextPresentations.resolve(registry, event(old, 1))

    assert buffer == old.buffer
    assert {:error, :inactive} = TextPresentations.resolve(registry, event(replacement, 1))

    assert {:ok, registry} = TextPresentations.activate(registry, 5, replacement.presentation_id)
    registry = TextPresentations.discard(registry, 5, old.presentation_id)

    assert {:ok, %TextTarget{buffer: ^replacement_buffer, line: 4}} =
             TextPresentations.resolve(registry, event(replacement, 1))

    send(replacement_buffer, :stop)
  end

  test "connection reset discards every admitted lease" do
    presentation = presentation(5, 501, 2, "hello")
    registry = TextPresentations.acknowledge(TextPresentations.new(), [presentation])
    assert {:ok, registry} = TextPresentations.activate(registry, 5, presentation.presentation_id)

    reset = TextPresentations.reset(registry)
    assert {:error, :inactive} = TextPresentations.resolve(reset, event(presentation, 1))
  end

  test "viewport-only presentation reuses the published resident graph" do
    store = resident_store(256, 255)
    first = resident_presentation(store, :first)
    second = resident_presentation(store, :viewport_only)

    registry = TextPresentations.acknowledge(TextPresentations.new(), [first])
    assert TextPresentations.last_publication_nodes(registry) > 0

    registry = TextPresentations.acknowledge(registry, [second])
    assert TextPresentations.last_publication_nodes(registry) == 0
  end

  test "65,536-row middle splice resolves the shifted suffix with bounded publication" do
    store = resident_store(65_536, 65_535)
    first = resident_presentation(store, :before_splice)
    registry = TextPresentations.acknowledge(TextPresentations.new(), [first])

    inserted = ResidentStore.entry(:inserted, 1, :opaque)
    changed = ResidentStore.insert_at(store, 32_768, inserted)
    shifted = resident_presentation(changed, :after_splice)
    registry = TextPresentations.acknowledge(registry, [shifted])

    assert TextPresentations.last_publication_nodes(registry) <= 128
    assert {:ok, registry} = TextPresentations.activate(registry, 1, shifted.presentation_id)

    event = resident_event(shifted, 65_536, 65_535)
    assert {:ok, %TextTarget{line: 65_536}} = TextPresentations.resolve(registry, event)
  end

  test "shared resident children remain valid when leases release in either order" do
    Enum.each([:base_first, :changed_first], fn release_order ->
      base_store = resident_store(256, 255)

      changed_store =
        ResidentStore.replace_at(base_store, 0, ResidentStore.entry(0, 999, :opaque))

      base = resident_presentation(base_store, {:base, release_order})
      changed = resident_presentation(changed_store, {:changed, release_order})

      registry = TextPresentations.acknowledge(TextPresentations.new(), [base, changed])

      {discarded, retained} =
        case release_order do
          :base_first -> {base, changed}
          :changed_first -> {changed, base}
        end

      assert {:ok, registry} =
               TextPresentations.activate(registry, 1, retained.presentation_id)

      registry =
        TextPresentations.discard(registry, 1, discarded.presentation_id)

      assert {:ok, %TextTarget{line: 255}} =
               TextPresentations.resolve(registry, resident_event(retained, 255, 255))
    end)
  end

  test "current root survives lease discard and full reset removes the graph" do
    store = resident_store(128, 127)
    first = resident_presentation(store, :first)
    registry = TextPresentations.acknowledge(TextPresentations.new(), [first])
    initial_nodes = TextPresentations.last_publication_nodes(registry)

    registry = TextPresentations.discard(registry, 1, first.presentation_id)
    replacement = resident_presentation(store, :same_current_root)
    registry = TextPresentations.acknowledge(registry, [replacement])
    assert TextPresentations.last_publication_nodes(registry) == 0

    registry = TextPresentations.reset(registry)
    registry = TextPresentations.acknowledge(registry, [replacement])
    assert TextPresentations.last_publication_nodes(registry) == initial_nodes
  end

  test "repeated acknowledgement does not leak a lease pin through normal window cleanup" do
    store = resident_store(128, 127)
    presentation = resident_presentation(store, :same_candidate)
    registry = TextPresentations.acknowledge(TextPresentations.new(), [presentation])
    initial_nodes = TextPresentations.last_publication_nodes(registry)

    registry = TextPresentations.acknowledge(registry, [presentation])
    registry = TextPresentations.discard(registry, 1, presentation.presentation_id)
    registry = TextPresentations.acknowledge_output(registry, output_without_windows())

    replacement = resident_presentation(store, :republished_after_cleanup)
    registry = TextPresentations.acknowledge(registry, [replacement])
    assert TextPresentations.last_publication_nodes(registry) == initial_nodes
  end

  test "same window switching to non-text releases its current root after visible lease discard" do
    store = resident_store(128, 127)
    presentation = resident_presentation(store, :before_empty_view)
    registry = TextPresentations.acknowledge(TextPresentations.new(), [presentation])
    initial_nodes = TextPresentations.last_publication_nodes(registry)
    assert {:ok, registry} = TextPresentations.activate(registry, 1, presentation.presentation_id)

    state = TestHelpers.base_state()
    input = Input.from_editor_state(state)
    window = state.workspace.windows.map |> Map.fetch!(1) |> Window.show_empty_state()
    empty = RenderWindow.materialize(1, WindowIntent.from_window(window), %WindowCache{})
    output = %{input | windows: Windows.set_map(input.windows, %{1 => empty})}
    registry = TextPresentations.acknowledge_output(registry, output)

    assert {:ok, %TextTarget{line: 127}} =
             TextPresentations.resolve(registry, resident_event(presentation, 127, 127))

    registry = TextPresentations.discard(registry, 1, presentation.presentation_id)
    replacement = resident_presentation(store, :after_empty_view)
    registry = TextPresentations.acknowledge(registry, [replacement])
    assert TextPresentations.last_publication_nodes(registry) == initial_nodes
  end

  test "shared child graphs reclaim fully after both release orders" do
    Enum.each([:base_first, :changed_first], fn release_order ->
      base_store = resident_store(256, 255)

      changed_store =
        ResidentStore.replace_at(base_store, 0, ResidentStore.entry(0, 999, :opaque))

      base = resident_presentation(base_store, {:reclaim_base, release_order})
      changed = resident_presentation(changed_store, {:reclaim_changed, release_order})
      registry = TextPresentations.acknowledge(TextPresentations.new(), [base])
      base_nodes = TextPresentations.last_publication_nodes(registry)
      registry = TextPresentations.acknowledge(registry, [changed])

      ordered = if release_order == :base_first, do: [base, changed], else: [changed, base]

      registry =
        Enum.reduce(ordered, registry, fn presentation, acc ->
          TextPresentations.discard(acc, 1, presentation.presentation_id)
        end)

      registry = TextPresentations.acknowledge_output(registry, output_without_windows())
      republished = resident_presentation(base_store, {:republished, release_order})
      registry = TextPresentations.acknowledge(registry, [republished])
      assert TextPresentations.last_publication_nodes(registry) == base_nodes
    end)
  end

  test "buffer cleanup releases lease and current graph roots" do
    store = resident_store(128, 127)
    presentation = resident_presentation(store, :before_buffer_down)
    registry = TextPresentations.acknowledge(TextPresentations.new(), [presentation])
    initial_nodes = TextPresentations.last_publication_nodes(registry)
    assert {:ok, registry} = TextPresentations.activate(registry, 1, presentation.presentation_id)

    registry = TextPresentations.drop_buffer(registry, self())

    assert {:error, :inactive} =
             TextPresentations.resolve(registry, resident_event(presentation, 127, 127))

    replacement = resident_presentation(store, :after_buffer_down)
    registry = TextPresentations.acknowledge(registry, [replacement])
    assert TextPresentations.last_publication_nodes(registry) == initial_nodes
  end

  defp presentation(window_id, row_id, line, text, buffer \\ self()) do
    row = %Row{
      row_id: row_id,
      row_type: :normal,
      buf_line: line,
      text: text,
      spans: [],
      content_hash: Row.compute_hash(text, [])
    }

    visual =
      VisualRow.new(
        row,
        SourceOffsetMap.new(text, text, Decorations.new(), line),
        0,
        byte_size(text),
        0
      )

    TextPresentation.new(window_id, buffer, 7, {:identity, row_id}, {:windowed, {visual}})
  end

  defp wrapped_unicode_presentation do
    source = "a😀bc"
    row_text = "  😀bc"

    row = %Row{
      row_id: 701,
      row_type: :wrap_continuation,
      buf_line: 11,
      text: row_text,
      spans: [],
      content_hash: Row.compute_hash(row_text, [])
    }

    map =
      source
      |> SourceOffsetMap.new(source, Decorations.new(), 11)
      |> SourceOffsetMap.slice(1, byte_size(source), 1, 5)

    visual = VisualRow.new(row, map, 1, 5, 2)
    TextPresentation.new(7, self(), 9, {:wrapped_unicode, 701}, {:windowed, {visual}})
  end

  defp resident_store(size, target_index) do
    entries =
      for index <- 0..(size - 1) do
        payload = if index == target_index, do: visual_row(index, index, "x"), else: :opaque
        ResidentStore.entry(index, index, payload)
      end

    ResidentStore.from_entries(entries)
  end

  defp resident_presentation(store, identity) do
    TextPresentation.new(1, self(), 7, identity, {:resident, store})
  end

  defp resident_event(presentation, row_index, row_id) do
    TextEvent.new(%{
      window_id: presentation.window_id,
      presentation_id: presentation.presentation_id,
      row_index: row_index,
      row_id: row_id,
      utf16_offset: 0,
      button: :left,
      mods: 0,
      event_type: :press,
      click_count: 1,
      scroll_x: 0,
      scroll_y: 0
    })
  end

  defp visual_row(row_id, line, text) do
    row = %Row{
      row_id: row_id,
      row_type: :normal,
      buf_line: line,
      text: text,
      spans: [],
      content_hash: Row.compute_hash(text, [])
    }

    VisualRow.new(
      row,
      SourceOffsetMap.new(text, text, Decorations.new(), line),
      0,
      byte_size(text),
      0
    )
  end

  defp output_without_windows do
    input = TestHelpers.base_state() |> Input.from_editor_state()
    %{input | windows: Windows.set_map(input.windows, %{})}
  end

  defp event(presentation, offset) do
    {%VisualRow{row: row}} = elem(presentation.rows, 1)

    TextEvent.new(%{
      window_id: presentation.window_id,
      presentation_id: presentation.presentation_id,
      row_index: 0,
      row_id: row.row_id,
      utf16_offset: offset,
      button: :left,
      mods: 0,
      event_type: :press,
      click_count: 1,
      scroll_x: 0,
      scroll_y: 0
    })
  end
end
