defmodule MingaEditor.RenderModel.UI.ExtensionOverlayBuilderTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Extension.Overlay
  alias Minga.RenderModel.UI.ExtensionOverlay
  alias Minga.RenderModel.UI.ExtensionOverlay.Entry
  alias MingaEditor.RenderModel.UI.ExtensionOverlayBuilder

  import MingaEditor.RenderPipeline.TestHelpers

  setup do
    table = Module.concat(__MODULE__, "Overlay#{System.unique_integer([:positive])}")
    start_supervised!({Overlay, name: table})
    %{table: table}
  end

  describe "build/1" do
    test "builds extension overlay model with no overlays", %{table: table} do
      ctx = build_minimal_context(table)

      model = ExtensionOverlayBuilder.build(ctx)

      assert %ExtensionOverlay{} = model
      assert model.entries == []
    end

    test "maps matching visible overlays and filters wrong-buffer or offscreen overlays", %{
      table: table
    } do
      ctx = build_minimal_context(table, viewport_top: 2)
      active_buffer = ctx.workspace.buffers.active
      other_buffer = start_supervised!({BufferProcess, content: "other"})

      :ok =
        Overlay.set(table, :builder_test, :visible, active_buffer,
          position: {4, 7},
          content: "AI",
          style: %{},
          shape: :not_supported
        )

      :ok =
        Overlay.set(table, :builder_test, :offscreen, active_buffer,
          position: {99, 0},
          content: "off"
        )

      :ok =
        Overlay.set(table, :builder_other, :wrong_buffer, other_buffer,
          position: {4, 0},
          content: "wrong"
        )

      model = ExtensionOverlayBuilder.build(ctx)

      assert %ExtensionOverlay{entries: [%Entry{} = entry]} = model
      assert entry.extension == "builder_test"
      assert entry.overlay_id == "visible"
      assert entry.window_id == ctx.windows.active
      assert entry.row == 2
      assert entry.col == 7
      assert entry.shape == :indicator
      assert entry.fg == 0x51AFEF
      assert entry.opacity == 102
      assert entry.content == "AI"
    end
  end

  defp build_minimal_context(table, opts \\ []) do
    state = gui_state(extension_overlay_registry: table)
    ctx = MingaEditor.Frontend.Emit.Context.from_editor_state(state)
    viewport_top = Keyword.get(opts, :viewport_top, 0)
    window = Map.fetch!(ctx.windows.map, ctx.windows.active)
    render_cache = %{window.render_cache | last_viewport_top: viewport_top}

    window = %{
      window
      | viewport: MingaEditor.Viewport.put_top(window.viewport, viewport_top),
        render_cache: render_cache
    }

    windows = %{ctx.windows | map: Map.put(ctx.windows.map, ctx.windows.active, window)}
    %{ctx | windows: windows}
  end
end
