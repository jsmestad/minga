defmodule MingaEditor.State.ModalOverlay.Prompt do
  @moduledoc """
  Modal-overlay payload for the prompt variant.

  Wraps the existing `MingaEditor.State.Prompt` struct with the metadata the
  ModalOverlay sum type carries for every variant: `opened_at` (monotonic
  millisecond timestamp) and `owner`. Built-in prompts use `:global`;
  extension prompts carry the source that opened them.
  """

  alias MingaEditor.State.Prompt, as: PromptState

  @type owner :: :global | Minga.Extension.CallbackInvoker.source()

  @type t :: %__MODULE__{
          prompt_ui: PromptState.t(),
          owner: owner(),
          opened_at: integer()
        }

  @enforce_keys [:prompt_ui]
  defstruct prompt_ui: %PromptState{}, owner: :global, opened_at: 0

  @doc """
  Builds a prompt payload wrapping the given `prompt_ui` state.
  """
  @spec new(PromptState.t(), keyword()) :: t()
  def new(%PromptState{} = prompt_ui, opts \\ []) do
    %__MODULE__{
      prompt_ui: prompt_ui,
      owner: Keyword.get(opts, :owner, :global),
      opened_at: Keyword.get(opts, :opened_at, 0)
    }
  end

  @doc """
  Replaces the inner `prompt_ui` state on the payload, preserving `owner`
  and `opened_at`. The only sanctioned way to update the inner state from
  outside this module (Rule 2: state ownership).
  """
  @spec put_prompt_ui(t(), PromptState.t()) :: t()
  def put_prompt_ui(%__MODULE__{} = payload, %PromptState{} = prompt_ui) do
    %{payload | prompt_ui: prompt_ui}
  end

  @doc "Removes private input from a render-only prompt payload."
  @spec render_snapshot(t()) :: t()
  def render_snapshot(%__MODULE__{prompt_ui: prompt} = payload) do
    case PromptState.render_snapshot(prompt) do
      ^prompt -> payload
      snapshot -> %{payload | prompt_ui: snapshot}
    end
  end
end
