defmodule MingaEditor.Renderer.TextPresentationsTest do
  use ExUnit.Case, async: true

  alias Minga.Core.Decorations
  alias Minga.RenderModel.Window.Row
  alias MingaEditor.Mouse.TextEvent
  alias MingaEditor.Mouse.Target.Text, as: TextTarget
  alias MingaEditor.RenderModel.Window.SourceOffsetMap
  alias MingaEditor.RenderModel.Window.VisualRow
  alias MingaEditor.Renderer.TextPresentation
  alias MingaEditor.Renderer.TextPresentations

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
