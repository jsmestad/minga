defmodule Minga.Mode.TextObjectKeys do
  @moduledoc "Vim text-object suffixes shared by Visual and Operator-Pending mode."

  @type object ::
          :word
          | :paragraph
          | :sentence
          | {:quote, String.t()}
          | {:paren, String.t(), String.t()}
          | {:structural, :function | :class | :parameter | :block}

  @objects %{
    ?w => :word,
    ?p => :paragraph,
    ?s => :sentence,
    ?" => {:quote, "\""},
    ?' => {:quote, "'"},
    ?( => {:paren, "(", ")"},
    ?) => {:paren, "(", ")"},
    ?[ => {:paren, "[", "]"},
    ?] => {:paren, "[", "]"},
    ?{ => {:paren, "{", "}"},
    ?} => {:paren, "{", "}"},
    ?f => {:structural, :function},
    ?c => {:structural, :class},
    ?a => {:structural, :parameter},
    ?b => {:structural, :block}
  }

  @doc "Checks whether a codepoint is a text-object suffix."
  @spec suffix?(term()) :: boolean()
  defguard suffix?(key) when is_map_key(@objects, key)

  @doc "Returns the object for a known suffix."
  @spec fetch!(char()) :: object()
  def fetch!(key), do: Map.fetch!(@objects, key)
end
