defmodule Minga.Session.Pane do
  @moduledoc """
  One window of a saved session layout: the file it shows, its cursor and its scroll.

  A pane belongs to a `Minga.Session.Layout` leaf. Two panes may name the same file, because two windows can show one buffer at different places.
  """

  @typedoc "A saved window."
  @type t :: %__MODULE__{
          file: String.t(),
          cursor_line: non_neg_integer(),
          cursor_col: non_neg_integer(),
          top: non_neg_integer()
        }

  @enforce_keys [:file]
  defstruct file: nil,
            cursor_line: 0,
            cursor_col: 0,
            top: 0

  @doc "Encodes the pane as a JSON-ready map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = pane) do
    %{
      "file" => pane.file,
      "cursor_line" => pane.cursor_line,
      "cursor_col" => pane.cursor_col,
      "top" => pane.top
    }
  end

  @doc "Decodes a pane from its JSON map. Returns `:error` without a file path."
  @spec from_map(term()) :: {:ok, t()} | :error
  def from_map(%{"file" => file} = map) when is_binary(file) and file != "" do
    {:ok,
     %__MODULE__{
       file: file,
       cursor_line: non_neg(map["cursor_line"]),
       cursor_col: non_neg(map["cursor_col"]),
       top: non_neg(map["top"])
     }}
  end

  def from_map(_other), do: :error

  @spec non_neg(term()) :: non_neg_integer()
  defp non_neg(value) when is_integer(value) and value >= 0, do: value
  defp non_neg(_value), do: 0
end
