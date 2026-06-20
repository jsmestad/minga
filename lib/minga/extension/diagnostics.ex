defmodule Minga.Extension.Diagnostics do
  @moduledoc """
  Sanctioned diagnostics surface for extensions.

  Lets an extension publish line-level findings (linters, analyzers,
  advisory agents) through the core diagnostics pipeline — gutter signs,
  hover, navigation, and the picker — without importing core internals.

  Findings are namespaced under the extension's own source (`:"ext:<name>"`),
  so an extension can never publish under or clear another producer's
  diagnostics (LSP, compiler). Severity is clamped to `:hint`: advice must
  never outrank a compiler error in the gutter. Because the source carries
  the `ext:` prefix, these render as a distinct, themeable advisory sign
  (`:diag_advisory`) rather than a normal hint.

  `uri` accepts either a `file://` URI or an absolute path.
  """

  alias Minga.Diagnostics
  alias Minga.Diagnostics.Diagnostic
  alias Minga.LSP.SyncServer

  @typedoc "A line-level finding: a zero-indexed `line` and the `concern` text to show."
  @type finding :: %{line: non_neg_integer(), concern: String.t()}

  @doc """
  Publishes `findings` for `uri`, replacing this extension's previous
  findings for that URI.
  """
  @spec publish(atom(), String.t(), [finding()]) :: :ok
  def publish(extension_name, uri, findings)
      when is_atom(extension_name) and is_binary(uri) and is_list(findings) do
    Diagnostics.publish(
      source(extension_name),
      normalize_uri(uri),
      Enum.map(findings, &to_diagnostic(&1, extension_name))
    )
  end

  @doc "Clears this extension's findings for a single URI."
  @spec clear(atom(), String.t()) :: :ok
  def clear(extension_name, uri) when is_atom(extension_name) and is_binary(uri) do
    Diagnostics.clear(source(extension_name), normalize_uri(uri))
  end

  @doc "Clears all of this extension's findings across every URI."
  @spec clear_all(atom()) :: :ok
  def clear_all(extension_name) when is_atom(extension_name) do
    Diagnostics.clear_source(source(extension_name))
  end

  @spec source(atom()) :: atom()
  defp source(extension_name), do: :"ext:#{extension_name}"

  @spec to_diagnostic(finding(), atom()) :: Diagnostic.t()
  defp to_diagnostic(%{line: line, concern: concern}, extension_name)
       when is_integer(line) and line >= 0 and is_binary(concern) do
    %Diagnostic{
      range: %{start_line: line, start_col: 0, end_line: line, end_col: 0},
      severity: :hint,
      message: concern,
      source: "ext:#{extension_name}",
      encoding: :utf8
    }
  end

  @spec normalize_uri(String.t()) :: String.t()
  defp normalize_uri("file://" <> _ = uri), do: uri
  defp normalize_uri(path), do: SyncServer.path_to_uri(path)
end
