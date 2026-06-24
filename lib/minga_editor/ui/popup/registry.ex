defmodule MingaEditor.UI.Popup.Registry do
  @moduledoc """
  Delegate to `Minga.Popup.Registry`.

  This module was moved to Layer 0 as part of Wave 6 boundary cleanup.
  All functionality is delegated to the canonical location.
  """

  @spec init() :: term()
  def init, do: Minga.Popup.Registry.init()
  @spec init(term()) :: term()
  def init(table_name), do: Minga.Popup.Registry.init(table_name)
  @spec register(term()) :: term()
  def register(rule), do: Minga.Popup.Registry.register(rule)
  @spec register(term(), term()) :: term()
  def register(rule, table), do: Minga.Popup.Registry.register(rule, table)
  @spec unregister(term()) :: term()
  def unregister(pattern), do: Minga.Popup.Registry.unregister(pattern)
  @spec unregister(term(), term()) :: term()
  def unregister(pattern, table), do: Minga.Popup.Registry.unregister(pattern, table)
  @spec clear() :: term()
  def clear, do: Minga.Popup.Registry.clear()
  @spec clear(term()) :: term()
  def clear(table), do: Minga.Popup.Registry.clear(table)
  @spec match(term()) :: term()
  def match(buffer_name), do: Minga.Popup.Registry.match(buffer_name)
  @spec match(term(), term()) :: term()
  def match(buffer_name, table), do: Minga.Popup.Registry.match(buffer_name, table)
  @spec list() :: term()
  def list, do: Minga.Popup.Registry.list()
  @spec list(term()) :: term()
  def list(table), do: Minga.Popup.Registry.list(table)
end
