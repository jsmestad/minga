defmodule MingaEditor.State.ModalOverlay.CommandCompletion do
  @moduledoc """
  Modal-overlay payload for the ex-command completion popup.

  Unlike the LSP `:completion` variant, this overlay is a rendering-oriented
  state container. The command mode FSM owns all key routing; this payload
  holds pre-computed candidate data so the TUI renderer avoids recomputing
  fuzzy scores during rendering.

  Opened when entering command mode, updated on each keystroke, and closed
  on mode exit. No trigger lifecycle or tab ownership needed since command
  mode is inherently single-context.
  """

  alias MingaEditor.MinibufferData

  @type t :: %__MODULE__{
          candidates: [MinibufferData.candidate()],
          selected: non_neg_integer(),
          filter_text: String.t(),
          total: non_neg_integer()
        }

  defstruct candidates: [],
            selected: 0,
            filter_text: "",
            total: 0

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      candidates: Keyword.get(opts, :candidates, []),
      selected: Keyword.get(opts, :selected, 0),
      filter_text: Keyword.get(opts, :filter_text, ""),
      total: Keyword.get(opts, :total, 0)
    }
  end

  @spec update(t(), keyword()) :: t()
  def update(%__MODULE__{} = payload, opts) do
    %{
      payload
      | candidates: Keyword.get(opts, :candidates, payload.candidates),
        selected: Keyword.get(opts, :selected, payload.selected),
        filter_text: Keyword.get(opts, :filter_text, payload.filter_text),
        total: Keyword.get(opts, :total, payload.total)
    }
  end
end
