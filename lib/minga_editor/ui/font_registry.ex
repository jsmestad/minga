defmodule MingaEditor.UI.FontRegistry do
  @moduledoc """
  Maps font family names to protocol font IDs (0-255).

  Font ID 0 is always the primary font (configured via `:font_family`).
  IDs 1-255 are assigned on demand when a Face with a non-nil `font_family`
  is first rendered. The Emit stage sends `register_font` protocol commands
  for pending registrations so the GUI frontend can load the corresponding FontFace instances.

  `MingaEditor.Renderer.Server` owns the long-lived registry. Each render passes
  the immutable value through composition and emission, then the renderer stores
  the completed result. It resets when the renderer restarts or the font config changes.
  """

  @enforce_keys [:families, :next_id]
  defstruct families: %{},
            next_id: 1,
            pending: %{}

  @type t :: %__MODULE__{
          families: %{String.t() => non_neg_integer()},
          next_id: non_neg_integer(),
          pending: %{non_neg_integer() => String.t()}
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
          updated = %{
            reg
            | families: Map.put(reg.families, family, id),
              next_id: id + 1,
              pending: Map.put(reg.pending, id, family)
          }

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

  @doc "Returns font registrations that have been allocated but not emitted yet."
  @spec pending_registrations(t()) :: [{non_neg_integer(), String.t()}]
  def pending_registrations(%__MODULE__{pending: pending}) do
    pending
    |> Enum.sort_by(fn {id, _family} -> id end)
  end

  @doc "Marks all pending font registrations as emitted."
  @spec mark_registered(t()) :: t()
  def mark_registered(%__MODULE__{} = registry), do: %{registry | pending: %{}}

  @doc "Requires every allocated fallback font to be emitted in the next recovery keyframe."
  @spec require_reregistration(t()) :: t()
  def require_reregistration(%__MODULE__{} = registry) do
    pending = Map.new(registry.families, fn {family, id} -> {id, family} end)
    %{registry | pending: pending}
  end
end
