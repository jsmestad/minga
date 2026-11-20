defmodule Minga.LSP.HoverContent do
  @moduledoc "Decodes LSP hover contents without choosing how to present them."

  @doc """
  Returns Markdown from MarkupContent, MarkedString, or lists of hover contents.

  A `kind` takes precedence over `language`; language-tagged snippets keep their fences even when empty. Unsupported shapes contribute no text. A matched `language` must support string interpolation.
  """
  @spec markdown(term()) :: String.t()
  def markdown(%{"kind" => _, "value" => value}) when is_binary(value), do: String.trim(value)

  def markdown(%{"language" => language, "value" => value}) when is_binary(value) do
    "```#{language}\n#{String.trim(value)}\n```"
  end

  def markdown(text) when is_binary(text), do: String.trim(text)

  def markdown(items) when is_list(items) do
    parts = for item <- items, text = markdown(item), text != "", do: text
    Enum.join(parts, "\n\n")
  end

  def markdown(_), do: ""
end
