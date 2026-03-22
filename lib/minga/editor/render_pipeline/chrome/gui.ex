defmodule Minga.Editor.RenderPipeline.Chrome.GUI do
  @moduledoc """
  GUI chrome builder.

  Builds non-content UI draws for the Metal/SwiftUI frontend. Most chrome
  (tab bar, file tree, picker, which-key, completion) is handled natively
  by SwiftUI and excluded here. Only Metal-rendered elements are included:
  modeline (for splits), minibuffer, separators, and hover/signature overlays.
  """

  alias Minga.Editor.DisplayList.{Cursor, Overlay}
  alias Minga.Editor.Layout
  alias Minga.Editor.MinibufferData
  alias Minga.Editor.Renderer.Regions
  alias Minga.Editor.RenderPipeline.Chrome
  alias Minga.Editor.RenderPipeline.Scroll.WindowScroll
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.StatusBar.Data, as: StatusBarData

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @doc """
  Builds GUI chrome: status bar data (for SwiftUI encoding), horizontal separators
  in the Metal surface, minibuffer, and Metal-rendered overlays (hover, signature
  help, float popups). SwiftUI handles tab bar, file tree, picker, which-key,
  and completion natively.
  """
  @spec build(
          state(),
          Layout.t(),
          %{Minga.Editor.Window.id() => WindowScroll.t()},
          Cursor.t() | nil
        ) :: Chrome.t()
  def build(state, layout, _scrolls, _cursor_info) do
    # Compute status bar data (used by Emit.GUI to encode the 0x76 opcode).
    # No cell rendering for the GUI — SwiftUI owns the status bar surface.
    status_bar_data = StatusBarData.from_state(state)

    # Split separators are sent via the dedicated 0x84 opcode in
    # Emit.GUI.build_metal_commands. No cell-grid draws needed.

    # Structured minibuffer data for native SwiftUI rendering (0x7F opcode).
    # No cell-grid fallback; the SwiftUI MinibufferView is the only path.
    minibuffer_data = MinibufferData.from_state(state)

    # Overlays: all sent via dedicated GUI opcodes (0x81, 0x82, 0x83).
    # Picker, which-key, and completion are handled by SwiftUI.
    overlays = build_overlays(state)

    # Region definitions
    regions = Regions.define_regions(layout)

    %Chrome{
      status_bar_draws: [],
      status_bar_data: status_bar_data,
      minibuffer_data: minibuffer_data,
      modeline_click_regions: [],
      tab_bar: [],
      tab_bar_click_regions: [],
      minibuffer: [],
      separators: [],
      file_tree: [],
      agent_panel: [],
      overlays: overlays,
      regions: regions
    }
  end

  # ── Overlays ──────────────────────────────────────────────────────────────

  @spec build_overlays(state()) :: [Overlay.t()]
  defp build_overlays(_state) do
    # All overlays are now sent via dedicated GUI opcodes:
    # - Hover popup: 0x81
    # - Signature help: 0x82
    # - Float popups: 0x83
    # No overlay draws go through the cell-grid path for GUI frontends.
    []
  end
end
