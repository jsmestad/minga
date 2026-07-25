defmodule MingaEditor.Session.Save do
  @moduledoc """
  Typed, coalescing persistence for one stable editor-session file.

  The expanded session-file path is the scheduler resource identity. One save
  may run while at most one follow-up waits, and newer snapshots coalesce over
  that queued request so timer bursts stay bounded while preserving the final
  durable state. `MingaEditor.EffectScheduler` executes `run/1` under its
  generation-owned `Task.Supervisor`.

  Saves have no EditorState correlation requirement because the immutable
  snapshot and destination fully describe the write. Superseded queued work is
  canceled by scheduler policy and stale/canceled outcomes are harmless.
  Worker and admission failures retain the existing session-save warning; no
  failure mutates editor state or requests a render.
  """

  @behaviour MingaEditor.Effect

  alias Minga.Session
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.Effect.Request
  alias MingaEditor.EffectScheduler
  alias MingaEditor.State, as: EditorState

  @enforce_keys [:snapshot, :opts, :session_file]
  defstruct [:snapshot, :opts, :session_file]

  @type t :: %__MODULE__{
          snapshot: Session.snapshot(),
          opts: keyword(),
          session_file: String.t()
        }

  @doc "Builds a one-follow-up coalescing request keyed by the session file."
  @spec request(Session.snapshot(), keyword()) :: Request.t()
  def request(snapshot, opts) when is_list(opts) do
    session_file = opts |> Session.session_file() |> Path.expand()
    effect = %__MODULE__{snapshot: snapshot, opts: opts, session_file: session_file}
    Request.new(effect, {:editor_session, session_file}, Policy.coalescing(1))
  end

  @doc "Schedules a save and applies the normal warning policy on admission failure."
  @spec schedule(EditorState.t(), Session.snapshot(), keyword()) :: EditorState.t()
  def schedule(%EditorState{effect_scheduler: nil} = state, snapshot, opts) do
    fail_admission(state, request(snapshot, opts), :scheduler_unavailable)
  end

  def schedule(%EditorState{} = state, snapshot, opts) do
    request = request(snapshot, opts)

    case EffectScheduler.schedule(state.effect_scheduler, request) do
      {:ok, _request_id, _disposition} -> state
      {:error, reason} -> fail_admission(state, request, reason)
    end
  catch
    :exit, reason ->
      fail_admission(state, request(snapshot, opts), {:scheduler_unavailable, reason})
  end

  @impl true
  @spec run(t()) :: {:ok, :saved} | {:error, term()}
  def run(%__MODULE__{snapshot: snapshot, opts: opts}) do
    case Session.save(snapshot, opts) do
      :ok -> {:ok, :saved}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  @spec apply(EditorState.t(), Outcome.t()) :: {EditorState.t(), Outcome.t()}
  def apply(%EditorState{} = state, %Outcome{value: {:failed, reason}} = outcome) do
    Minga.Log.warning(:editor, "Session save failed: #{inspect(reason)}")
    {state, outcome}
  end

  def apply(%EditorState{} = state, %Outcome{} = outcome), do: {state, outcome}

  @impl true
  @spec render?(Outcome.t()) :: boolean()
  def render?(%Outcome{}), do: false

  @spec fail_admission(EditorState.t(), Request.t(), term()) :: EditorState.t()
  defp fail_admission(state, request, reason) do
    {state, _outcome} =
      __MODULE__.apply(state, Outcome.failed(request, {:admission_failed, reason}))

    state
  end
end
