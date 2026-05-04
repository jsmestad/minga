defmodule MingaEditor.State.ModalOverlay.Completion do
  @moduledoc """
  Modal-overlay payload for the completion menu.

  The completion menu is logically per-tab: it tracks the cursor position of
  the buffer that triggered it. The `owner` field carries the tab identifier
  so the tab-switch hook (`ModalOverlay.dismiss_if_stale/1`) can auto-dismiss
  completion that no longer belongs to the active tab.

  ## Trigger lifecycle

  The completion trigger (debounce/pending-ref machinery) is part of the
  modal's lifecycle: it only matters while completion is being driven, and
  resets when completion dismisses. Carrying the trigger on the payload —
  rather than as an independent field on workspace state — keeps the
  modal's lifecycle self-contained and removes a per-tab field that other
  callers had to know about.
  """

  alias Minga.Editing.Completion
  alias MingaEditor.CompletionTrigger

  @typedoc """
  Identifier of the tab that triggered completion.

  Tab IDs are the keys of `MingaEditor.State.TabBar`'s tab map. We accept
  any term so callers do not need to depend on TabBar's id type directly.
  """
  @type owner :: term()

  @typedoc """
  The user-visible completion menu, or `nil` while a request is pending.

  `nil` represents the brief window between the trigger firing an LSP
  request and the response arriving. The render layer paints nothing
  while completion is `nil`; the modal exists so the trigger's debounce/
  pending-ref state has a home.
  """
  @type completion_or_nil :: Completion.t() | nil

  @type t :: %__MODULE__{
          completion: completion_or_nil(),
          trigger: CompletionTrigger.t(),
          owner: owner(),
          opened_at: integer()
        }

  @enforce_keys [:owner]
  defstruct [
    :owner,
    completion: nil,
    trigger: nil,
    opened_at: 0
  ]

  @doc """
  Builds a completion payload bound to `owner` (typically a tab id).

  Pass `:completion` to seed an already-resolved completion menu, or
  omit to open a payload that just tracks the trigger lifecycle while
  an LSP request is in flight.
  """
  @spec new(owner(), keyword()) :: t()
  def new(owner, opts \\ []) do
    %__MODULE__{
      completion: Keyword.get(opts, :completion),
      trigger: Keyword.get(opts, :trigger, CompletionTrigger.new()),
      owner: owner,
      opened_at: Keyword.get(opts, :opened_at, System.monotonic_time(:millisecond))
    }
  end

  @doc """
  Replaces the inner `Completion.t()` on the payload, preserving owner,
  trigger, and opened_at. The only sanctioned way to update completion
  state from outside this module (Rule 2: state ownership).
  """
  @spec put_completion(t(), completion_or_nil()) :: t()
  def put_completion(%__MODULE__{} = payload, completion)
      when is_struct(completion, Completion) or is_nil(completion) do
    %{payload | completion: completion}
  end

  @doc """
  Replaces the inner trigger on the payload. The only sanctioned way to
  update the trigger from outside this module.
  """
  @spec put_trigger(t(), CompletionTrigger.t()) :: t()
  def put_trigger(%__MODULE__{} = payload, trigger) do
    %{payload | trigger: trigger}
  end
end
