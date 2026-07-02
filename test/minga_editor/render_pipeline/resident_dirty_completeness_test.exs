defmodule MingaEditor.RenderPipeline.ResidentDirtyCompletenessTest do
  @moduledoc """
  AC 2 dirty-set completeness for the residence content digest (#2658).

  With full-document residence the content frame-emit gate reads the incremental
  `content_digest` instead of hashing the whole rows list. The correctness risk is
  a *missed* source: a change that alters an off-screen resident row's rendered
  content but fails to move the digest, dropping a needed frame and stranding a
  stale row. This suite drives the real subsystems that bake into resident row
  content (buffer text edits and decoration-driven spans, the class that carries
  search matches and diagnostic underlines) against an off-screen row and asserts
  the digest moves, so the emit fires.

  Overlay- and gutter-only sources (selection, git signs, diagnostic signs,
  diagnostic inline ranges) are deliberately *not* asserted here: they are
  viewport-windowed fields of the window model, unchanged by this ticket, and an
  off-screen change to them correctly produces no resident re-emit (nothing
  visible changed). They ride the ordinary content fingerprint when they enter the
  viewport. See the ticket handoff for the source-by-source routing.
  """

  # Mutates the global Config option server (:resident_store_max_lines) and drives
  # buffer subsystems, so the module runs serially.
  use ExUnit.Case, async: false

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Config
  alias Minga.Core.Face
  alias MingaEditor.Layout
  alias MingaEditor.RenderPipeline
  alias MingaEditor.RenderPipeline.Content
  alias MingaEditor.RenderPipeline.Scroll
  alias MingaEditor.State, as: EditorState

  import MingaEditor.RenderPipeline.TestHelpers

  @line_count 300
  # A row well below the top-of-file viewport: resident, never rasterized into the
  # visible slice, so a naive viewport-only gate would miss a change to it.
  @off_screen_line 250

  setup do
    original = Config.get(:resident_store_max_lines)
    Config.set(:resident_store_max_lines, 1_000_000)
    on_exit(fn -> Config.set(:resident_store_max_lines, original) end)
    :ok
  end

  defp resident_state do
    state = gui_state(content: long_content(@line_count), rows: 12, cols: 60, filetype: :text)
    BufferProcess.set_option(state.workspace.buffers.active, :wrap, false)
    state
  end

  defp build_frame(state) do
    state = EditorState.sync_active_window_cursor(state)
    state = RenderPipeline.compute_layout(state)
    layout = Layout.get(state)
    {scrolls, state} = Scroll.scroll_windows(state, layout)
    {contents, _cursor, state} = Content.build_content(state, scrolls)
    model = contents |> List.first() |> Map.fetch!(:models) |> List.first()
    {model, state}
  end

  defp warm(state) do
    {_model, state} = build_frame(state)
    {model, state} = build_frame(state)
    {model.content_digest, state}
  end

  # Each case mutates exactly one off-screen resident row through a real subsystem.
  # `:buffer_text_edit` is a text change; `:decoration_span` is the decoration
  # highlight class that search matches and diagnostic underlines flow through.
  defp mutate(:buffer_text_edit, buffer) do
    BufferProcess.move_to(buffer, {@off_screen_line, 0})
    BufferProcess.insert_text(buffer, "Z")
  end

  defp mutate(:decoration_span, buffer) do
    BufferProcess.add_highlight(
      buffer,
      {@off_screen_line, 0},
      {@off_screen_line, 4},
      style: Face.new(bg: 0x00FF00)
    )
  end

  for name <- [:buffer_text_edit, :decoration_span] do
    test "an off-screen #{name} moves the content digest so the frame emits" do
      name = unquote(name)

      state = resident_state()
      {before_digest, state} = warm(state)
      refute is_nil(before_digest)

      mutate(name, state.workspace.buffers.active)

      {after_model, _state} = build_frame(state)

      assert after_model.content_digest != before_digest,
             "#{name}: digest did not move for an off-screen resident row (dropped frame / stale row)"
    end
  end

  test "a no-op frame after warm-up does not move the digest (no spurious emit)" do
    state = resident_state()
    {before_digest, state} = warm(state)

    {after_model, _state} = build_frame(state)

    assert after_model.content_digest == before_digest
  end
end
