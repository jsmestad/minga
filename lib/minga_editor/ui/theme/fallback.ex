defmodule MingaEditor.UI.Theme.Fallback do
  @moduledoc """
  Minimal fallback theme that always loads regardless of which extensions are enabled.

  This theme uses a neutral dark palette designed to be readable without being opinionated. It exists so the editor always has a working theme even when every bundled theme pack is disabled or fails to load.
  """

  alias MingaEditor.UI.Theme.Builder
  alias MingaEditor.UI.Theme.Palette

  @palette Palette.new(%{
             variant: :dark,
             bg: 0x1E1E1E,
             fg: 0xD4D4D4,
             surface: 0x252526,
             overlay: 0x1A1A1A,
             muted: 0x6A6A6A,
             subtle: 0x333333,
             accent: 0x569CD6,
             highlight: 0x569CD6,
             selection_bg: 0x264F78,
             error: 0xF44747,
             warning: 0xCCA700,
             info: 0x4EC9B0,
             success: 0x6A9955,
             match: 0x4EC9B0,
             link: 0x569CD6,
             border: 0x474747,
             contrast_fg: 0x1E1E1E,
             builtin: 0xDCDCAA,
             functions: 0xDCDCAA,
             keywords: 0x569CD6,
             methods: 0xDCDCAA,
             operators: 0xD4D4D4,
             constants: 0xB5CEA8,
             strings: 0xCE9178,
             numbers: 0xB5CEA8,
             type: 0x4EC9B0,
             variables: 0x9CDCFE,
             comments: 0x6A9955
           })

  @doc "Returns the fallback theme struct."
  @spec theme() :: MingaEditor.UI.Theme.t()
  def theme, do: Builder.from_palette(:minga_default, @palette)
end
