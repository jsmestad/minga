defmodule MingaEditor.Agent.QueueSurface do
  @moduledoc "Owns the conversation's queue projection, selected row, and return focus. The Session owns queued inputs."

  alias MingaAgent.Session
  alias MingaAgent.Session.QueuedInputSummary
  alias MingaEditor.Agent.PromptInput

  @type return_focus :: :composer | :transcript
  @type t :: %__MODULE__{
          origin: PromptInput.submission_owner() | nil,
          contents: Session.queue_contents() | :unavailable | nil,
          selected_id: pos_integer() | nil,
          focus: :unfocused | {:focused, return_focus()},
          recall: reference() | nil
        }

  defstruct origin: nil, contents: nil, selected_id: nil, focus: :unfocused, recall: nil

  @doc "Names the focused queue in the modeline and conversation."
  @spec buffer_name() :: String.t()
  def buffer_name, do: "*minga-queue*"

  @doc "Clears a projection when the active saved conversation changes."
  @spec bind(t(), PromptInput.submission_owner() | nil) :: t()
  def bind(%__MODULE__{origin: origin} = surface, origin), do: surface
  def bind(%__MODULE__{}, origin), do: %__MODULE__{origin: origin}

  @doc "Installs a read for the exact conversation, keeping the cursor on the same input when it still exists."
  @spec refresh(t(), PromptInput.submission_owner(), Session.queue_contents()) :: t()
  def refresh(%__MODULE__{origin: origin} = surface, origin, %{pending: pending} = contents)
      when not is_nil(origin) do
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
    do: {:closed, return, %{surface | focus: :unfocused, recall: nil}}

  def close(%__MODULE__{focus: :unfocused}), do: :not_focused

  @doc "Correlates a linked draft recall while this queue still owns focus."
  @spec begin_recall(t(), reference()) :: t()
  def begin_recall(%__MODULE__{focus: {:focused, _}} = surface, ref),
    do: %{surface | recall: ref}

  def begin_recall(%__MODULE__{focus: :unfocused} = surface, _ref), do: surface

  @spec finish_recall(t(), reference()) :: {:queue_recall, t()} | :not_requested
  def finish_recall(%__MODULE__{recall: ref} = surface, ref),
    do: {:queue_recall, %{surface | recall: nil}}

  def finish_recall(%__MODULE__{}, _ref), do: :not_requested

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

  @doc "Selects the exact displayed revision. A delayed click on a superseded row changes nothing."
  @spec select(t(), QueuedInputSummary.identity()) :: {:ok, t()} | :stale_row
  def select(%__MODULE__{contents: %{pending: pending}} = surface, {id, _} = identity) do
    if Enum.any?(pending, &(&1.identity == identity)),
      do: {:ok, %{surface | selected_id: id}},
      else: :stale_row
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
      %QueuedInputSummary{identity: {next, _}} = Enum.at(pending, index) || List.last(pending)
      next
    end
  end

  defp refreshed_selection(%__MODULE__{}, [%QueuedInputSummary{identity: {first, _}} | _]),
    do: first

  @spec matches_id?(QueuedInputSummary.t(), pos_integer() | nil) :: boolean()
  defp matches_id?(%QueuedInputSummary{identity: {id, _}}, selected_id), do: id == selected_id
end
