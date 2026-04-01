defmodule MingaEditor.UI.FontRegistry do
  @moduledoc """
  Maps font family names to protocol font IDs (0-255).

  Font ID 0 is always the primary font (configured via `:font_family`).
  IDs 1-255 are assigned on demand when a Face with a non-nil `font_family`
  is first rendered. The registry sends `register_font` protocol commands
  to the GUI frontend so it can load the corresponding FontFace instances.

  The registry is process-local state stored in the Editor GenServer's state.
  It resets when the editor restarts or the font config changes.
  """

  @enforce_keys [:families, :next_id]
  defstruct families: %{},
            next_id: 1

  @type t :: %__MODULE__{
          families: %{String.t() => non_neg_integer()},
          next_id: non_neg_integer()
        }

  @doc "Creates a new empty font registry."
  @spec new() :: t()
  def new, do: %__MODULE__{families: %{}, next_id: 1}

  @doc """
  Returns the font_id for a font family, allocating a new ID if needed.

  Returns `{font_id, updated_registry, new?}` where `new?` is true if
  a new ID was allocated (caller should send `register_font` to the GUI).

  The primary font (ID 0) is never registered here; it's set via `set_font`.
  """
  @spec get_or_register(t(), String.t()) :: {non_neg_integer(), t(), boolean()}
  def get_or_register(%__MODULE__{} = reg, family) when is_binary(family) do
    case Map.get(reg.families, family) do
      nil ->
        id = reg.next_id

        if id > 255 do
          # Too many fonts registered; fall back to primary (0).
          {0, reg, false}
        else
          updated = %{reg | families: Map.put(reg.families, family, id), next_id: id + 1}
          {id, updated, true}
        end

      id ->
        {id, reg, false}
    end
  end

  @doc "Returns the font_id for a family, or 0 if not registered."
  @spec lookup(t(), String.t()) :: non_neg_integer()
  def lookup(%__MODULE__{families: families}, family) do
    Map.get(families, family, 0)
  end
end
