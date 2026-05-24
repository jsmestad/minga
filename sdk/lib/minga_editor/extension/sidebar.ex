defmodule MingaEditor.Extension.Sidebar do
  @moduledoc """
  Compile-time SDK stub for source-owned sidebar contributions.

  At runtime, Minga provides the real registry. Extensions use this module to register sidebar metadata, publish cached snapshots, and route semantic sidebar actions through the editor action pipeline.
  """

  @type source :: :builtin | :config | {:extension, atom()}
  @type row :: map()
  @type snapshot :: map()
  @type register_attrs :: map() | keyword()

  @spec register(source(), register_attrs()) :: :ok | {:error, term()}
  def register(_source, _attrs), do: raise("minga_sdk is compile-time only")

  @spec unregister(source(), String.t()) :: :ok | {:error, term()}
  def unregister(_source, _id), do: raise("minga_sdk is compile-time only")

  @spec publish_snapshot(source(), String.t(), snapshot()) :: :ok | {:error, term()}
  def publish_snapshot(_source, _id, _snapshot), do: raise("minga_sdk is compile-time only")

  @spec set_visible(source(), String.t(), boolean()) :: :ok | {:error, term()}
  def set_visible(_source, _id, _visible?), do: raise("minga_sdk is compile-time only")

  @spec set_focused(source(), String.t(), boolean()) :: :ok | {:error, term()}
  def set_focused(_source, _id, _focused?), do: raise("minga_sdk is compile-time only")
end
