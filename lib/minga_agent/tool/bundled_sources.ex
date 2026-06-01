defmodule MingaAgent.Tool.BundledSources do
  @moduledoc """
  Stable source identifiers and reserved names for bundled tool packs.

  This module is metadata only. Core registry code can reserve names without depending on a concrete bundled pack implementation, and packs can use the same source identifiers when registering their specs.
  """

  @read_only_source {:bundle, :read_only_tools}
  @read_only_tool_names ~w(find grep list_directory fetch_url)
  @lsp_source {:bundle, :lsp_tools}
  @lsp_tool_names ~w(diagnostics definition references hover document_symbols workspace_symbols rename code_actions)

  @typedoc "Known bundled tool-pack source identifier."
  @type source :: {:bundle, :read_only_tools} | {:bundle, :lsp_tools}

  @doc "Returns the bundled read-only tool pack source."
  @spec read_only_source() :: {:bundle, :read_only_tools}
  def read_only_source, do: @read_only_source

  @doc "Returns the stable tool names owned by the bundled read-only pack."
  @spec read_only_tool_names() :: [String.t()]
  def read_only_tool_names, do: @read_only_tool_names

  @doc "Returns the bundled LSP tool pack source."
  @spec lsp_source() :: {:bundle, :lsp_tools}
  def lsp_source, do: @lsp_source

  @doc "Returns the stable tool names owned by the bundled LSP pack."
  @spec lsp_tool_names() :: [String.t()]
  def lsp_tool_names, do: @lsp_tool_names

  @doc "Returns all bundled tool names that remain reserved even if their pack is disabled."
  @spec reserved_names() :: [String.t()]
  def reserved_names, do: @read_only_tool_names ++ @lsp_tool_names

  @doc "Returns true when the source is a known bundled tool-pack source."
  @spec known_source?(term()) :: boolean()
  def known_source?(@read_only_source), do: true
  def known_source?(@lsp_source), do: true
  def known_source?(_source), do: false

  @doc "Returns the bundled source that owns a reserved tool name."
  @spec reserved_source_for(String.t()) :: {:ok, source()} | :error
  def reserved_source_for(name) when name in @read_only_tool_names, do: {:ok, @read_only_source}
  def reserved_source_for(name) when name in @lsp_tool_names, do: {:ok, @lsp_source}
  def reserved_source_for(_name), do: :error
end
