defmodule MingaEditor.State.WhichKey do
  @moduledoc "Pure lifecycle owner for delayed which-key presentation."

  @type generation :: non_neg_integer()
  @type t :: %__MODULE__{
          generation: generation(),
          node: Minga.Keymap.Bindings.node_t() | nil,
          timer: reference() | nil,
          show: boolean(),
          prefix_keys: [String.t()],
          labels: [String.t()]
        }

  defstruct generation: 0,
            node: nil,
            timer: nil,
            show: false,
            prefix_keys: [],
            labels: []

  @doc "Begins a new hidden which-key generation."
  @spec begin(t(), Minga.Keymap.Bindings.node_t(), [String.t()]) :: t()
  def begin(%__MODULE__{} = whichkey, node, prefix_keys) do
    %__MODULE__{
      generation: whichkey.generation + 1,
      node: node,
      prefix_keys: prefix_keys,
      labels: labels([], node, prefix_keys)
    }
  end

  @doc "Advances a leader prefix with a new generation while preserving visibility."
  @spec progress(t(), Minga.Keymap.Bindings.node_t(), [String.t()]) :: t()
  def progress(%__MODULE__{} = whichkey, node, prefix_keys) do
    %__MODULE__{
      generation: whichkey.generation + 1,
      node: node,
      prefix_keys: prefix_keys,
      labels: labels(whichkey.labels, node, prefix_keys),
      show: whichkey.show
    }
  end

  # One label per prefix key: the group each key opened, for the breadcrumb (`SPC`, `a Minga`).
  # Going back up (Backspace) shortens the prefix, so the kept labels are cut to match.
  @spec labels([String.t()], Minga.Keymap.Bindings.node_t(), [String.t()]) :: [String.t()]
  defp labels(_labels, _node, []), do: []

  defp labels(labels, node, prefix_keys) do
    labels
    |> Enum.take(length(prefix_keys) - 1)
    |> List.insert_at(-1, node_label(node, prefix_keys))
  end

  @spec node_label(Minga.Keymap.Bindings.node_t(), [String.t()]) :: String.t()
  defp node_label(_node, [_leader]), do: ""

  defp node_label(%{description: description}, _prefix) when is_binary(description),
    do: description

  defp node_label(_node, _prefix), do: ""

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

  @doc "Returns whether a leader prefix is active."
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{node: node}), do: not is_nil(node)

  @doc "Returns whether the popup is visible."
  @spec visible?(t()) :: boolean()
  def visible?(%__MODULE__{show: show}), do: show
end
