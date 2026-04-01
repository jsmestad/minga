defmodule MingaEditor.UI.Devicon do
  @moduledoc """
  Delegate to `Minga.Language.Devicon`.

  This module was moved to Layer 0 as part of Wave 6 boundary cleanup.
  All functionality is delegated to the canonical location. Existing
  callers in MingaEditor.* continue to work without changes.
  """

  defdelegate icon(filetype), to: Minga.Language.Devicon
  defdelegate color(filetype), to: Minga.Language.Devicon
  defdelegate icon_and_color(filetype), to: Minga.Language.Devicon
end
