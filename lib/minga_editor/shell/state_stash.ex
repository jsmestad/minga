defmodule MingaEditor.Shell.StateStash do
  @moduledoc """
  Stashed shell state tied to the exact shell registry identity that produced it.

  Shell state is only safe to restore into the same registered shell id, module, and source. Extension shell ids can be unregistered and later reused, so the registry generation is part of the identity as well.
  """

  alias MingaEditor.Shell.Entry

  @enforce_keys [:id, :module, :source, :generation, :state]
  defstruct [:id, :module, :source, :generation, :state]

  @type t :: %__MODULE__{
          id: atom(),
          module: module(),
          source: Entry.source(),
          generation: non_neg_integer(),
          state: MingaEditor.Shell.shell_state()
        }

  @type transformation :: {:updated, MingaEditor.Shell.shell_state()} | :unchanged
  @type transform_result :: {:updated, t()} | {:unchanged, t()} | :mismatch
  @type transform_result(context) ::
          {:updated, t(), context} | {:unchanged, t(), context} | {:mismatch, context}

  @doc "Stores shell state with the registry identity that produced it."
  @spec new(Entry.t(), MingaEditor.Shell.shell_state()) :: t()
  def new(%Entry{} = entry, state) do
    %__MODULE__{
      id: entry.id,
      module: entry.module,
      source: entry.source,
      generation: entry.generation,
      state: state
    }
  end

  @doc "Returns true when the stash belongs to the current registry entry."
  @spec matches?(t(), Entry.t()) :: boolean()
  def matches?(%__MODULE__{} = stash, %Entry{} = entry) do
    stash.id == entry.id and stash.module == entry.module and stash.source == entry.source and
      stash.generation == entry.generation
  end

  @doc "Restores stored state only when the current registry entry has the same identity."
  @spec restore(t(), Entry.t()) :: {:ok, MingaEditor.Shell.shell_state()} | :mismatch
  def restore(%__MODULE__{} = stash, %Entry{} = entry) do
    if matches?(stash, entry), do: {:ok, stash.state}, else: :mismatch
  end

  @doc "Transforms stored state only when the current registry entry has the same identity."
  @spec transform(t(), Entry.t(), (MingaEditor.Shell.shell_state() -> transformation())) ::
          transform_result()
  def transform(%__MODULE__{} = stash, %Entry{} = entry, fun) when is_function(fun, 1) do
    case transform(stash, entry, nil, fn state, nil -> {fun.(state), nil} end) do
      {:updated, updated, nil} -> {:updated, updated}
      {:unchanged, unchanged, nil} -> {:unchanged, unchanged}
      {:mismatch, nil} -> :mismatch
    end
  end

  @doc "Transforms stored state with caller context after validating registry identity."
  @spec transform(
          t(),
          Entry.t(),
          context,
          (MingaEditor.Shell.shell_state(), context -> {transformation(), context})
        ) :: transform_result(context)
        when context: term()
  def transform(%__MODULE__{} = stash, %Entry{} = entry, context, fun)
      when is_function(fun, 2) do
    if matches?(stash, entry) do
      apply_transformation(stash, context, fun.(stash.state, context))
    else
      {:mismatch, context}
    end
  end

  @spec apply_transformation(t(), context, {transformation(), context}) ::
          transform_result(context)
        when context: term()
  defp apply_transformation(%__MODULE__{} = stash, _old_context, {:unchanged, context}) do
    {:unchanged, stash, context}
  end

  defp apply_transformation(%__MODULE__{} = stash, _context, {{:updated, state}, context}) do
    {:updated, %__MODULE__{stash | state: state}, context}
  end
end
