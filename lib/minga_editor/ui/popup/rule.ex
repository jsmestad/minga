defmodule MingaEditor.UI.Popup.Rule do
  @moduledoc """
  Delegate to `Minga.Popup.Rule`.

  This module was moved to Layer 0 as part of Wave 6 boundary cleanup.
  Prefer `Minga.Popup.Rule` for new code.
  """

  defdelegate new(pattern, opts \\ []), to: Minga.Popup.Rule
  defdelegate matches?(rule, buffer_name), to: Minga.Popup.Rule
end
