defmodule MingaEditor.Mouse.Target.Text do
  @moduledoc "A source-backed text target resolved from an immutable frontend presentation."

  alias MingaEditor.Window

  @enforce_keys [:window_id, :buffer, :source_version, :line, :byte]
  defstruct @enforce_keys

  @type position :: {line :: non_neg_integer(), byte :: non_neg_integer()}
  @type t :: %__MODULE__{
          window_id: Window.id(),
          buffer: pid(),
          source_version: non_neg_integer(),
          line: non_neg_integer(),
          byte: non_neg_integer()
        }

  @spec new(map()) :: t()
  def new(attrs), do: struct!(__MODULE__, attrs)

  @spec position(t()) :: position()
  def position(%__MODULE__{line: line, byte: byte}), do: {line, byte}
end
