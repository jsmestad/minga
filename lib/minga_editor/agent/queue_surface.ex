defmodule MingaEditor.Agent.QueueSurface do
  @moduledoc "Owns the conversation's queue projection, selected row, and return focus. The Session owns queued inputs."

  alias Minga.Keymap.Bindings
  alias MingaAgent.Session
  alias MingaAgent.Session.QueuedInputSummary
  alias MingaEditor.Agent.PromptInput

  @type return_focus :: :composer | :transcript
  @type removal_prefix :: {Bindings.node_t(), QueuedInputSummary.identity() | nil}
  @type t :: %__MODULE__{
          origin: PromptInput.submission_owner() | nil,
          contents: Session.queue_contents() | :unavailable | nil,
          selected_id: pos_integer() | nil,
          focus: :unfocused | {:focused, return_focus()},
          removal_prefix: removal_prefix() | nil,
          edit_request: reference() | nil
        }

  defstruct origin: nil,
            contents: nil,
            selected_id: nil,
            focus: :unfocused,
            removal_prefix: nil,
            edit_request: nil

  @doc "Names the focused queue in the modeline and conversation."
  @spec buffer_name() :: String.t()
  def buffer_name, do: "*minga-queue*"

  @doc "Clears a projection when the active saved conversation changes."
  @spec bind(t(), PromptInput.submission_owner() | nil) :: t()
  def bind(%__MODULE__{origin: origin} = surface, origin), do: surface
  def bind(%__MODULE__{}, origin), do: %__MODULE__{origin: origin}

  @doc "Installs a read for the exact conversation, keeping the cursor on the same input when it still exists."
  @spec refresh(t(), PromptInput.submission_owner(), Session.queue_contents()) :: t()
  def refresh(
        %__MODULE__{origin: {_, _, _} = origin} = surface,
        origin,
        %{pending: pending} = contents
      ) do
    %{surface | contents: contents, selected_id: refreshed_selection(surface, pending)}
  end

  def refresh(%__MODULE__{} = surface, _origin, _contents), do: surface

  @spec read_failed(t()) :: t()
  def read_failed(%__MODULE__{contents: nil} = surface), do: %{surface | contents: :unavailable}
  def read_failed(%__MODULE__{} = surface), do: surface

  @doc "Focuses the queue without replacing the original return focus when it is already open."
  @spec open(t(), return_focus()) :: t()
  def open(%__MODULE__{origin: nil} = surface, _return), do: surface

  def open(%__MODULE__{focus: :unfocused} = surface, return),
    do: %{surface | focus: {:focused, return}}

  def open(%__MODULE__{focus: {:focused, _}} = surface, _return), do: surface

  @doc "Leaves the queue, returning the focus it replaced. Queued rows stay visible."
  @spec close(t()) :: {:closed, return_focus(), t()} | :not_focused
  def close(%__MODULE__{focus: {:focused, return}} = surface),
    do: {:closed, return, %{surface | focus: :unfocused, removal_prefix: nil, edit_request: nil}}

  def close(%__MODULE__{focus: :unfocused}), do: :not_focused

  @doc "Captures the selected revision with the first key of a removal."
  @spec arm_removal(t(), Bindings.node_t()) :: t()
  def arm_removal(%__MODULE__{} = surface, prefix) do
    identity =
      case selected(surface) do
        %QueuedInputSummary{identity: identity} -> identity
        nil -> nil
      end

    %{surface | removal_prefix: {prefix, identity}}
  end

  @doc "Retires a partial removal without retargeting it to a new selection."
  @spec cancel_removal(t()) :: t()
  def cancel_removal(%__MODULE__{removal_prefix: nil} = surface), do: surface

  def cancel_removal(%__MODULE__{} = surface), do: %{surface | removal_prefix: nil}

  @doc "Correlates an Enter action while this queue still owns focus."
  @spec begin_edit(t(), reference()) :: t()
  def begin_edit(%__MODULE__{focus: {:focused, _}} = surface, ref),
    do: %{surface | edit_request: ref}

  def begin_edit(%__MODULE__{focus: :unfocused} = surface, _ref), do: surface

  @spec finish_edit(t(), reference()) :: {:current, t()} | :stale
  def finish_edit(%__MODULE__{edit_request: ref} = surface, ref) when is_reference(ref),
    do: {:current, %{surface | edit_request: nil}}

  def finish_edit(%__MODULE__{}, _ref), do: :stale

  @spec focused?(t()) :: boolean()
  def focused?(%__MODULE__{focus: {:focused, _}}), do: true
  def focused?(%__MODULE__{focus: :unfocused}), do: false

  @spec visible?(t()) :: boolean()
  def visible?(%__MODULE__{focus: {:focused, _}}), do: true
  def visible?(%__MODULE__{contents: %{pending: [_ | _]}}), do: true
  def visible?(%__MODULE__{contents: %{removed: [_ | _]}}), do: true
  def visible?(%__MODULE__{}), do: false

  @spec selected(t()) :: QueuedInputSummary.t() | nil
  def selected(%__MODULE__{contents: %{pending: pending}, selected_id: id}),
    do: Enum.find(pending, &matches_id?(&1, id))

  def selected(%__MODULE__{}), do: nil

  @doc "Finds the exact displayed pending row without changing the selection."
  @spec pending_row(t(), QueuedInputSummary.identity() | nil) :: QueuedInputSummary.t() | nil
  def pending_row(%__MODULE__{contents: %{pending: pending}}, {_, _} = identity),
    do: Enum.find(pending, &(&1.identity == identity))

  def pending_row(%__MODULE__{}, _identity), do: nil

  @doc "Selects the exact displayed revision. A delayed click on a superseded row changes nothing."
  @spec select(t(), QueuedInputSummary.identity()) :: {:ok, t()} | :stale_row
  def select(%__MODULE__{} = surface, {id, _} = identity) do
    case pending_row(surface, identity) do
      %QueuedInputSummary{} -> {:ok, %{surface | selected_id: id}}
      nil -> :stale_row
    end
  end

  def select(%__MODULE__{}, _identity), do: :stale_row

  @doc "Moves through pending rows without wrapping. The removed list is not an input queue."
  @spec move(t(), :previous | :next) :: t()
  def move(%__MODULE__{contents: %{pending: pending}, selected_id: id} = surface, direction) do
    offset = if direction == :previous, do: -1, else: 1

    with index when is_integer(index) <- Enum.find_index(pending, &matches_id?(&1, id)),
         next when next >= 0 <- index + offset,
         %QueuedInputSummary{identity: {next_id, _}} <- Enum.at(pending, next) do
      %{surface | selected_id: next_id}
    else
      _edge -> surface
    end
  end

  def move(%__MODULE__{} = surface, _direction), do: surface

  @spec refreshed_selection(t(), [QueuedInputSummary.t()]) :: pos_integer() | nil
  defp refreshed_selection(_surface, []), do: nil

  defp refreshed_selection(%__MODULE__{contents: %{pending: previous}, selected_id: id}, pending) do
    if Enum.any?(pending, &matches_id?(&1, id)) do
      id
    else
      index = Enum.find_index(previous, &matches_id?(&1, id)) || 0
      id_at_or_last(pending, index)
    end
  end

  defp refreshed_selection(%__MODULE__{}, [%QueuedInputSummary{identity: {first, _}} | _]),
    do: first

  @spec id_at_or_last([QueuedInputSummary.t(), ...], non_neg_integer()) :: pos_integer()
  defp id_at_or_last([%QueuedInputSummary{identity: {id, _}} | tail], index) do
    if index == 0 or tail == [], do: id, else: id_at_or_last(tail, index - 1)
  end

  @spec matches_id?(QueuedInputSummary.t(), pos_integer() | nil) :: boolean()
  defp matches_id?(%QueuedInputSummary{identity: {id, _}}, selected_id), do: id == selected_id
end
