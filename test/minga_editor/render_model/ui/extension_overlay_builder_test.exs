defmodule MingaEditor.RenderModel.UI.ExtensionOverlayBuilderTest do
  # Uses the process-global extension overlay registry.
  use ExUnit.Case, async: false

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Extension.Overlay
  alias Minga.RenderModel.UI.ExtensionOverlay
  alias Minga.RenderModel.UI.ExtensionOverlay.Entry
  alias MingaEditor.RenderModel.UI.ExtensionOverlayBuilder

  import MingaEditor.RenderPipeline.TestHelpers

  setup do
    Overlay.remove_all(:builder_test)
    Overlay.remove_all(:builder_other)

    on_exit(fn ->
      Overlay.remove_all(:builder_test)
      Overlay.remove_all(:builder_other)
    end)

    :ok
  end

  describe "build/1" do
    test "builds extension overlay model with no overlays" do
      ctx = build_minimal_context()

      model = ExtensionOverlayBuilder.build(ctx)

      assert %ExtensionOverlay{} = model
      assert model.entries == []
    end

    test "maps matching visible overlays and filters wrong-buffer or offscreen overlays" do
      ctx = build_minimal_context(viewport_top: 2)
      active_buffer = ctx.buffers.active
      other_buffer = start_supervised!({BufferProcess, content: "other"})

      :ok =
        Overlay.set(:builder_test, :visible, active_buffer,
          position: {4, 7},
          content: "AI",
          style: %{},
          shape: :not_supported
        )

      :ok =
        Overlay.set(:builder_test, :offscreen, active_buffer, position: {99, 0}, content: "off")

      :ok =
        Overlay.set(:builder_other, :wrong_buffer, other_buffer,
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

  defp build_minimal_context(opts \\ []) do
    state = gui_state()
    ctx = MingaEditor.Frontend.Emit.Context.from_editor_state(state)
    viewport_top = Keyword.get(opts, :viewport_top, 0)
    window = Map.fetch!(ctx.windows.map, ctx.windows.active)
    window = %{window | render_cache: %{window.render_cache | last_viewport_top: viewport_top}}
    windows = %{ctx.windows | map: Map.put(ctx.windows.map, ctx.windows.active, window)}
    %{ctx | windows: windows}
  end
end
