defmodule Minga.Frontend.Adapter.GUI.Wire.VimMode do
  @moduledoc "Wire encoding for editor and prompt Vim modes."

  @doc "Encodes a Vim mode as the stable GUI protocol byte."
  @spec encode(atom() | nil) :: non_neg_integer()
  def encode(:normal), do: 0
  def encode(:insert), do: 1
  def encode(:visual), do: 2
  def encode(:visual_line), do: 2
  def encode(:command), do: 3
  def encode(:operator_pending), do: 4
  def encode(:search), do: 5
  def encode(:search_prompt), do: 5
  def encode(:replace), do: 6
  def encode(_mode), do: 0
end
