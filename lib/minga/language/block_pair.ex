defmodule Minga.Language.BlockPair do
  @moduledoc """
  Language-owned block auto-close metadata.

  Tree-sitter tells Minga where syntax scopes and structural matches are. This metadata tells Insert mode which language keywords may be auto-closed when the user presses Enter after an opener.
  """

  @typedoc "How the opener should be matched against the current line."
  @type match :: :line_head | :line_suffix

  @type t :: %__MODULE__{
          opener: String.t(),
          closer: String.t(),
          match: match()
        }

  @enforce_keys [:opener, :closer, :match]
  defstruct [:opener, :closer, :match]

  @doc "Creates a block auto-close metadata entry."
  @spec new(String.t(), String.t(), match()) :: t()
  def new(opener, closer, match)
      when is_binary(opener) and is_binary(closer) and match in [:line_head, :line_suffix] do
    %__MODULE__{opener: opener, closer: closer, match: match}
  end

  @doc "Returns block auto-close metadata for a language name."
  @spec for_language(atom()) :: [t()]
  def for_language(:elixir), do: Minga.Language.Elixir.block_pairs()
  def for_language(:ruby), do: Minga.Language.Ruby.block_pairs()
  def for_language(:bash), do: Minga.Language.Bash.block_pairs()
  def for_language(_language), do: []
end
