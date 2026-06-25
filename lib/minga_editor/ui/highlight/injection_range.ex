defmodule MingaEditor.UI.Highlight.InjectionRange do
  @moduledoc """
  Delegate to `Minga.Language.Highlight.InjectionRange`.

  This module was moved to Layer 0 as part of Wave 6 boundary cleanup.
  """

  @spec new(term(), term(), term()) :: term()
  def new(start_byte, end_byte, language),
    do: Minga.Language.Highlight.InjectionRange.new(start_byte, end_byte, language)
end
