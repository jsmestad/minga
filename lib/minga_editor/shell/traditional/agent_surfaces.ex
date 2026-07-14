defmodule MingaEditor.Shell.Traditional.AgentSurfaces do
  @moduledoc """
  Pure owner of Traditional agent presentation and inline session surfaces.

  The full agent presentation cache and both per-buffer inline stores are
  replaced only through this owner. Inline completion and cancellation match
  the originating session or buffer, so delayed events cannot update a
  replacement surface.
  """

  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.InlineAsk
  alias MingaEditor.State.InlineEdit

  @type t :: %__MODULE__{
          presentation: AgentState.t(),
          asks: InlineAsk.store(),
          edits: InlineEdit.store()
        }

  defstruct presentation: %AgentState{}, asks: %{}, edits: %{}

  @doc "Returns the full agent presentation cache."
  @spec presentation(t()) :: AgentState.t()
  def presentation(%__MODULE__{presentation: presentation}), do: presentation

  @doc "Replaces the full agent presentation cache."
  @spec replace_presentation(t(), AgentState.t()) :: t()
  def replace_presentation(%__MODULE__{} = surfaces, %AgentState{} = presentation),
    do: %{surfaces | presentation: presentation}

  @doc "Returns the inline ask store."
  @spec asks(t()) :: InlineAsk.store()
  def asks(%__MODULE__{asks: asks}), do: asks

  @doc "Returns the inline edit store."
  @spec edits(t()) :: InlineEdit.store()
  def edits(%__MODULE__{edits: edits}), do: edits

  @doc "Activates or replaces the inline ask for its buffer."
  @spec activate_ask(t(), InlineAsk.t()) :: t()
  def activate_ask(%__MODULE__{} = surfaces, %InlineAsk{} = ask),
    do: %{surfaces | asks: InlineAsk.put(surfaces.asks, ask)}

  @doc "Replaces a current inline ask after an input transition."
  @spec replace_ask(t(), InlineAsk.t()) :: t()
  def replace_ask(%__MODULE__{} = surfaces, %InlineAsk{} = ask),
    do: activate_ask(surfaces, ask)

  @doc "Completes the matching inline ask session."
  @spec complete_ask(t(), pid()) :: t()
  def complete_ask(%__MODULE__{} = surfaces, session_pid) when is_pid(session_pid),
    do: update_ask_session(surfaces, session_pid, &InlineAsk.answered/1)

  @doc "Fails the matching inline ask session."
  @spec fail_ask(t(), pid(), String.t()) :: t()
  def fail_ask(%__MODULE__{} = surfaces, session_pid, message)
      when is_pid(session_pid) and is_binary(message),
      do: update_ask_session(surfaces, session_pid, &InlineAsk.fail(&1, message))

  @doc "Appends output only to the matching inline ask session."
  @spec append_ask_response(t(), pid(), String.t()) :: t()
  def append_ask_response(%__MODULE__{} = surfaces, session_pid, delta)
      when is_pid(session_pid) and is_binary(delta),
      do: update_ask_session(surfaces, session_pid, &InlineAsk.append_response(&1, delta))

  @doc "Cancels the inline ask for a buffer and returns its session pid."
  @spec cancel_ask(t(), pid() | nil) :: {t(), pid() | nil}
  def cancel_ask(%__MODULE__{} = surfaces, buffer_pid) do
    {asks, session_pid} = InlineAsk.dismiss(surfaces.asks, buffer_pid)
    {%{surfaces | asks: asks}, session_pid}
  end

  @doc "Activates or replaces the inline edit for its buffer."
  @spec activate_edit(t(), InlineEdit.t()) :: t()
  def activate_edit(%__MODULE__{} = surfaces, %InlineEdit{} = edit),
    do: %{surfaces | edits: InlineEdit.put(surfaces.edits, edit)}

  @doc "Replaces a current inline edit after an input transition."
  @spec replace_edit(t(), InlineEdit.t()) :: t()
  def replace_edit(%__MODULE__{} = surfaces, %InlineEdit{} = edit),
    do: activate_edit(surfaces, edit)

  @doc "Completes the matching inline edit session."
  @spec complete_edit(t(), pid()) :: t()
  def complete_edit(%__MODULE__{} = surfaces, session_pid) when is_pid(session_pid),
    do: update_edit_session(surfaces, session_pid, &InlineEdit.proposed/1)

  @doc "Fails the matching inline edit session."
  @spec fail_edit(t(), pid(), String.t()) :: t()
  def fail_edit(%__MODULE__{} = surfaces, session_pid, message)
      when is_pid(session_pid) and is_binary(message),
      do: update_edit_session(surfaces, session_pid, &InlineEdit.fail(&1, message))

  @doc "Appends output only to the matching inline edit session."
  @spec append_edit_proposal(t(), pid(), String.t()) :: t()
  def append_edit_proposal(%__MODULE__{} = surfaces, session_pid, delta)
      when is_pid(session_pid) and is_binary(delta),
      do: update_edit_session(surfaces, session_pid, &InlineEdit.append_proposal(&1, delta))

  @doc "Cancels the inline edit for a buffer and returns its session pid."
  @spec cancel_edit(t(), pid() | nil) :: {t(), pid() | nil}
  def cancel_edit(%__MODULE__{} = surfaces, buffer_pid) do
    {edits, session_pid} = InlineEdit.dismiss(surfaces.edits, buffer_pid)
    {%{surfaces | edits: edits}, session_pid}
  end

  @spec update_ask_session(t(), pid(), (InlineAsk.t() -> InlineAsk.t())) :: t()
  defp update_ask_session(%__MODULE__{} = surfaces, session_pid, update) do
    case matching_ask(surfaces.asks, session_pid) do
      {buffer_pid, ask} -> %{surfaces | asks: Map.put(surfaces.asks, buffer_pid, update.(ask))}
      nil -> surfaces
    end
  end

  @spec update_edit_session(t(), pid(), (InlineEdit.t() -> InlineEdit.t())) :: t()
  defp update_edit_session(%__MODULE__{} = surfaces, session_pid, update) do
    case matching_edit(surfaces.edits, session_pid) do
      {buffer_pid, edit} ->
        %{surfaces | edits: Map.put(surfaces.edits, buffer_pid, update.(edit))}

      nil ->
        surfaces
    end
  end

  @spec matching_ask(InlineAsk.store(), pid()) :: {pid(), InlineAsk.t()} | nil
  defp matching_ask(asks, session_pid) do
    Enum.find(asks, fn
      {_buffer_pid, %InlineAsk{session_pid: ^session_pid}} -> true
      _entry -> false
    end)
  end

  @spec matching_edit(InlineEdit.store(), pid()) :: {pid(), InlineEdit.t()} | nil
  defp matching_edit(edits, session_pid) do
    Enum.find(edits, fn
      {_buffer_pid, %InlineEdit{session_pid: ^session_pid}} -> true
      _entry -> false
    end)
  end
end
