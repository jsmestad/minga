defmodule Minga.Extension.Diagnostics do
  @moduledoc """
  Sanctioned diagnostics surface for extensions.

  Publish line-level findings (linters, analyzers, advisory agents) through
  Minga's diagnostics pipeline — gutter signs, hover, navigation, picker —
  without importing core internals. Findings are namespaced under the
  extension's own source and clamped to `:hint` severity; they render as a
  distinct amber `?` sign so users don't confuse advice with compiler output.

  `uri` accepts either a `file://` URI or an absolute path.

  This is a compile-time stub. At runtime, the real module in Minga's BEAM
  VM provides the implementation.
  """

  @typedoc "A line-level finding: a zero-indexed `line` and the `concern` text to show."
  @type finding :: %{line: non_neg_integer(), concern: String.t()}

  @spec publish(atom(), String.t(), [finding()]) :: :ok
  def publish(_extension_name, _uri, _findings), do: raise("minga_sdk is compile-time only")

  @spec clear(atom(), String.t()) :: :ok
  def clear(_extension_name, _uri), do: raise("minga_sdk is compile-time only")

  @spec clear_all(atom()) :: :ok
  def clear_all(_extension_name), do: raise("minga_sdk is compile-time only")
end
