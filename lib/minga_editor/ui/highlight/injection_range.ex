defmodule MingaEditor.UI.Highlight.InjectionRange do
  @moduledoc """
  Delegate to `Minga.Language.Highlight.InjectionRange`.

  This module was moved to Layer 0 as part of Wave 6 boundary cleanup.
  """

  defdelegate new(start_byte, end_byte, language), to: Minga.Language.Highlight.InjectionRange
end
