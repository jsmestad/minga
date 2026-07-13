defmodule MingaEditor.State.WhichKey do
  @moduledoc "Pure lifecycle owner for delayed which-key presentation."

  @type generation :: non_neg_integer()
  @type t :: %__MODULE__{
          generation: generation(),
          node: Minga.Keymap.Bindings.node_t() | nil,
          timer: reference() | nil,
          show: boolean(),
          prefix_keys: [String.t()],
          page: non_neg_integer()
        }

  defstruct generation: 0,
            node: nil,
            timer: nil,
            show: false,
            prefix_keys: [],
            page: 0

  @doc "Begins a new hidden which-key generation."
  @spec begin(t(), Minga.Keymap.Bindings.node_t(), [String.t()]) :: t()
  def begin(%__MODULE__{} = whichkey, node, prefix_keys) do
    %__MODULE__{generation: whichkey.generation + 1, node: node, prefix_keys: prefix_keys}
  end

  @doc "Advances a leader prefix with a new generation while preserving visibility."
  @spec progress(t(), Minga.Keymap.Bindings.node_t(), [String.t()]) :: t()
  def progress(%__MODULE__{} = whichkey, node, prefix_keys) do
    %__MODULE__{
      generation: whichkey.generation + 1,
      node: node,
      prefix_keys: prefix_keys,
      show: whichkey.show
    }
  end

  @doc "Records the timer handle only for the current active generation."
  @spec record_timer(t(), generation(), reference()) :: t()
  def record_timer(%__MODULE__{node: nil} = whichkey, _generation, _timer), do: whichkey

  def record_timer(%__MODULE__{generation: generation} = whichkey, generation, timer)
      when is_reference(timer),
      do: %{whichkey | timer: timer}

  def record_timer(%__MODULE__{} = whichkey, _generation, _timer), do: whichkey

  @doc "Reveals only the matching active generation."
  @spec reveal(t(), generation()) :: t()
  def reveal(%__MODULE__{node: nil} = whichkey, _generation), do: whichkey

  def reveal(%__MODULE__{generation: generation} = whichkey, generation),
    do: %{whichkey | show: true, timer: nil}

  def reveal(%__MODULE__{} = whichkey, _generation), do: whichkey

  @doc "Dismisses which-key while retaining its monotonic generation."
  @spec dismiss(t()) :: t()
  def dismiss(%__MODULE__{} = whichkey) do
    %__MODULE__{generation: whichkey.generation}
  end

  @doc "Moves to the next display page."
  @spec next_page(t()) :: t()
  def next_page(%__MODULE__{} = whichkey), do: %{whichkey | page: whichkey.page + 1}

  @doc "Moves to the previous display page."
  @spec previous_page(t()) :: t()
  def previous_page(%__MODULE__{} = whichkey), do: %{whichkey | page: max(whichkey.page - 1, 0)}

  @doc "Returns whether a leader prefix is active."
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{node: node}), do: not is_nil(node)

  @doc "Returns whether the popup is visible."
  @spec visible?(t()) :: boolean()
  def visible?(%__MODULE__{show: show}), do: show
end
