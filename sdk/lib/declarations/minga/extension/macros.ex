defmodule Minga.Extension.Macros do
  @moduledoc false

  @doc """
  Declares a typed config option for this extension.

  Shared between `Extension.Agent` and `Extension.Editor` so both surfaces
  can declare options without import conflicts when used together.
  """
  defmacro option(name, type, opts) do
    quote do
      @__extension_options__ {
        unquote(name),
        unquote(type),
        Keyword.fetch!(unquote(opts), :default),
        Keyword.fetch!(unquote(opts), :description)
      }
    end
  end
end
