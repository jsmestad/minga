defmodule MingaEditor.UI.Popup.Registry do
  @moduledoc """
  Delegate to `Minga.Popup.Registry`.

  This module was moved to Layer 0 as part of Wave 6 boundary cleanup.
  All functionality is delegated to the canonical location.
  """

  defdelegate init(), to: Minga.Popup.Registry
  defdelegate init(table_name), to: Minga.Popup.Registry
  defdelegate register(rule), to: Minga.Popup.Registry
  defdelegate register(rule, table), to: Minga.Popup.Registry
  defdelegate unregister(pattern), to: Minga.Popup.Registry
  defdelegate unregister(pattern, table), to: Minga.Popup.Registry
  defdelegate clear(), to: Minga.Popup.Registry
  defdelegate clear(table), to: Minga.Popup.Registry
  defdelegate match(buffer_name), to: Minga.Popup.Registry
  defdelegate match(buffer_name, table), to: Minga.Popup.Registry
  defdelegate list(), to: Minga.Popup.Registry
  defdelegate list(table), to: Minga.Popup.Registry
end
