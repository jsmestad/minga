defmodule MingaEditor.UI.Highlight.InjectionRange do
  @moduledoc """
  A tree-sitter injection range marking an embedded language region.

  When a file contains multiple languages (e.g., HTML with embedded JavaScript,
  Elixir with HEEx templates), tree-sitter reports injection ranges that map
  byte offsets to the injected language name. These flow from the parser Port
  through the protocol layer and are stored on editor state for comment
  toggling and other language-aware operations.
  """

  @typedoc "An injection range."
  @type t :: %__MODULE__{
          start_byte: non_neg_integer(),
          end_byte: non_neg_integer(),
          language: String.t()
        }

  @enforce_keys [:start_byte, :end_byte, :language]
  defstruct start_byte: 0,
            end_byte: 0,
            language: ""

  @doc "Creates a new injection range."
  @spec new(non_neg_integer(), non_neg_integer(), String.t()) :: t()
  def new(start_byte, end_byte, language)
      when is_integer(start_byte) and is_integer(end_byte) and is_binary(language) do
    %__MODULE__{
      start_byte: start_byte,
      end_byte: end_byte,
      language: language
    }
  end
end
