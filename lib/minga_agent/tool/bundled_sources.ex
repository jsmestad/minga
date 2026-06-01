defmodule MingaAgent.Tool.BundledSources do
  @moduledoc """
  Stable source identifiers and reserved names for bundled tool packs.

  This module is metadata only. Core registry code can reserve names without depending on a concrete bundled pack implementation, and packs can use the same source identifiers when registering their specs.
  """

  @read_only_source {:bundle, :read_only_tools}
  @read_only_tool_names ~w(find grep list_directory fetch_url)

  @typedoc "Bundled tool-pack source identifier."
  @type source :: {:bundle, atom()}

  @doc "Returns the bundled read-only tool pack source."
  @spec read_only_source() :: {:bundle, :read_only_tools}
  def read_only_source, do: @read_only_source

  @doc "Returns the stable tool names owned by the bundled read-only pack."
  @spec read_only_tool_names() :: [String.t()]
  def read_only_tool_names, do: @read_only_tool_names

  @doc "Returns all bundled tool names that remain reserved even if their pack is disabled."
  @spec reserved_names() :: [String.t()]
  def reserved_names, do: @read_only_tool_names
end
