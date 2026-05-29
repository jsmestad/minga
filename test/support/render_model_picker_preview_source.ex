defmodule Minga.Test.RenderModelPickerPreviewSource do
  @moduledoc false

  @spec gui_preview?() :: true
  def gui_preview?, do: true

  @spec preview(MingaEditor.UI.Picker.Item.t(), term()) :: [
          [{String.t(), non_neg_integer(), boolean()}]
        ]
  def preview(%MingaEditor.UI.Picker.Item{label: label}, _context) do
    [[{"preview: #{label}", 0xABCDEF, true}]]
  end
end
