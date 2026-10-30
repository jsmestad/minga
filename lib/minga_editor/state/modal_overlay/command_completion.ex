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

  `generation` identifies the current candidate presentation. The modal workflow
  replaces it on input/candidate changes and reopen, but not selection changes.
  Use `ModalWorkflow.new_command_completion_payload/2` for live presentations;
  generation zero is reserved for data without a live modal owner.
  """

  alias MingaEditor.MinibufferData

  @type t :: %__MODULE__{
          candidates: [MinibufferData.candidate()],
          generation: non_neg_integer(),
          selected: non_neg_integer(),
          filter_text: String.t(),
          total: non_neg_integer()
        }

  defstruct candidates: [],
            generation: 0,
            selected: 0,
            filter_text: "",
            total: 0

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      candidates: Keyword.get(opts, :candidates, []),
      generation: Keyword.get(opts, :generation, 0),
      selected: Keyword.get(opts, :selected, 0),
      filter_text: Keyword.get(opts, :filter_text, ""),
      total: Keyword.get(opts, :total, 0)
    }
  end
end
