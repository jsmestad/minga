defmodule MingaEditor.Shell.Traditional.Chrome.GUI do
  @moduledoc """
  GUI chrome builder.

  Builds structured chrome data for the SwiftUI frontend. All chrome (tab bar,
  file tree, picker, which-key, completion, minibuffer, status bar, separators)
  is handled natively by SwiftUI via dedicated protocol opcodes. This module
  produces only the structured data; no cell-grid draws are generated.
  Metal-rendered overlays (hover, signature help, float popups) are the
  exception.
  """

  alias Minga.RenderModel.Cursor
  alias MingaEditor.Layout
  alias MingaEditor.MinibufferData
  alias MingaEditor.RenderPipeline.Chrome
  alias MingaEditor.RenderPipeline.Scroll.WindowScroll
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.StatusBar.Data, as: StatusBarData

  @typedoc "Internal editor state."
  @type state :: EditorState.t() | MingaEditor.RenderPipeline.Input.t()

  @doc """
  Builds GUI chrome: status bar data and minibuffer data (for SwiftUI
  encoding via 0x76 and 0x7F opcodes), and Metal-rendered overlays
  (hover, signature help, float popups).
  """
  @spec build(
          state(),
          Layout.t(),
          %{MingaEditor.Window.id() => WindowScroll.t()},
          Cursor.t() | nil
        ) :: Chrome.t()
  def build(state, _layout, _scrolls, _cursor_info) do
    # Compute status bar data (used by the GUI adapter to encode the 0x76 opcode).
    # No cell rendering for the GUI — SwiftUI owns the status bar surface.
    status_bar_data = status_bar_data(state)

    # Split separators are sent via the dedicated 0x84 opcode by the GUI adapter. No cell-grid draws needed.

    # Structured minibuffer data for native SwiftUI rendering (0x7F opcode).
    # No cell-grid fallback; the SwiftUI MinibufferView is the only path.
    minibuffer_data = MinibufferData.from_state(state)

    %Chrome{
      status_bar_data: status_bar_data,
      minibuffer_data: minibuffer_data,
      modeline_click_regions: [],
      tab_bar_click_regions: [],
      # All overlays (hover 0x81, signature 0x82, float popups 0x83) are sent via
      # dedicated GUI opcodes; none go through the cell-grid overlay path. The
      # empty list keeps the picker-cursor resolution in Compose a no-op.
      overlays: []
    }
  end

  @spec status_bar_data(state()) :: StatusBarData.t() | nil
  defp status_bar_data(%MingaEditor.RenderPipeline.Input{
         intent: %{frame: %{status_bar_data: data}}
       }),
       do: data

  defp status_bar_data(state), do: StatusBarData.from_state(state)
end
