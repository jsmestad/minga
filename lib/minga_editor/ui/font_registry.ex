defmodule MingaEditor.UI.FontRegistry do
  @moduledoc """
  Maps font family names to protocol font IDs (0-255).

  Font ID 0 is always the primary font (configured via `:font_family`).
  IDs 1-255 are assigned on demand when a Face with a non-nil `font_family`
  is first rendered. The Emit stage sends `register_font` protocol commands
  for pending registrations so the GUI frontend can load the corresponding FontFace instances.

  The registry is process-local state owned by `MingaEditor.Renderer.Server`.
  Render snapshots receive the current registry just before the pipeline runs,
  and the renderer stores the updated registry after emit. It resets when the
  renderer restarts or the font config changes.
  """

  @process_key :emit_font_registry

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

  @doc "Runs a function with this registry installed for render-local font resolution."
  @spec with_process_registry(t(), (-> result)) :: result when result: term()
  def with_process_registry(%__MODULE__{} = font_registry, fun) when is_function(fun, 0) do
    previous = Process.get(@process_key, :__minga_unset__)
    Process.put(@process_key, font_registry)

    try do
      fun.()
    after
      if previous == :__minga_unset__ do
        Process.delete(@process_key)
      else
        Process.put(@process_key, previous)
      end
    end
  end

  @doc "Returns the active render-local font registry, if one is installed."
  @spec process_registry() :: t() | nil
  def process_registry do
    case Process.get(@process_key) do
      %__MODULE__{} = registry -> registry
      _ -> nil
    end
  end

  @doc "Returns the render-local font registry, or the supplied fallback."
  @spec current_process_registry(t()) :: t()
  def current_process_registry(%__MODULE__{} = fallback) do
    process_registry() || fallback
  end

  @doc "Stores the render-local font registry."
  @spec put_process_registry(t()) :: t()
  def put_process_registry(%__MODULE__{} = registry) do
    Process.put(@process_key, registry)
    registry
  end
end
