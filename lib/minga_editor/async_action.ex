defmodule MingaEditor.AsyncAction do
  @moduledoc """
  Runs slow editor work off the `MingaEditor` GenServer's input critical path,
  serializing the work per *lane* so a resource that tolerates only one in-flight
  operation at a time (e.g. the git index) never has two operations racing.

  The single editor process owns input dispatch, GUI action handling, state
  mutation, and pre-render housekeeping. If an action runs slow work (git
  commands, filesystem walks) inline, later keypresses, clicks, and renderer
  writebacks queue behind it. `run/3` keeps that work off the critical path:

  1. The caller does a cheap state transition (e.g. set a "Discarding…" status).
  2. `run/3` starts the work in a `Task` if the lane is idle, or appends it to the
     lane's FIFO queue if a previous op is still running.
  3. The editor keeps handling input while the Task runs.
  4. When the Task finishes it sends `{:async_action_result, lane, token, result}`
     back to the editor, which applies it (when `current?/3`) and then `advance/2`s
     the lane: the next queued op starts, or the lane goes idle.

  A *lane* identifies a serialized resource. Operations on one lane run strictly
  one at a time, in the order they were requested. This is the load-bearing
  invariant for mutating resources: two `git add`/`git reset` calls can never
  fight over `.git/index.lock`, because the second only starts once the first has
  finished and its result has been applied. Latest-wins (drop the older op) would
  be wrong here — the older op's mutation already ran; serialization runs every
  requested op exactly once, in order.

  `safely/1` captures a raise/exit/throw in the work function as `{:error,
  reason}` so a failing action can never crash the editor; the lane still
  advances afterwards, so one bad op cannot wedge the queue.
  """

  alias MingaEditor.State, as: EditorState

  @typedoc "Identifies the serialized resource a piece of async work feeds back into."
  @type lane :: atom()

  @typedoc "A zero-arity function run in a Task; its return value becomes the result."
  @type work :: (-> term())

  @typedoc """
  Message sent to the editor when async work completes. `result` is whatever
  `work_fun` returned, or `{:error, reason}` if it raised, exited, or threw.
  """
  @type result_message :: {:async_action_result, lane(), reference(), term()}

  @doc """
  Schedules `work_fun` on `lane`, returning the updated state immediately so the
  caller never blocks on the work.

  If the lane is idle the work starts now; if an operation is already in flight
  the work is appended to the lane's FIFO queue and starts when the in-flight op
  (and anything ahead of it) completes. `work_fun` is run in the Task and must
  not touch editor state. Its return value becomes the `result` in the
  `{:async_action_result, lane, token, result}` message; a raise/exit/throw is
  captured as `{:error, reason}`.
  """
  @spec run(EditorState.t(), lane(), work()) :: EditorState.t()
  def run(%EditorState{} = state, lane, work_fun)
      when is_atom(lane) and is_function(work_fun, 0) do
    lane_state = EditorState.get_async_lane(state, lane)

    case lane_state.running do
      nil ->
        start(state, lane, work_fun, lane_state.queue)

      _running ->
        EditorState.put_async_lane(state, lane, %{
          lane_state
          | queue: Enum.concat(lane_state.queue, [work_fun])
        })
    end
  end

  @doc "Returns whether `token` is the operation currently in flight on `lane`."
  @spec current?(EditorState.t(), lane(), reference()) :: boolean()
  def current?(%EditorState{} = state, lane, token) do
    EditorState.get_async_lane(state, lane).running == token
  end

  @doc """
  Advances `lane` after its in-flight result has been applied: starts the next
  queued operation, or marks the lane idle when the queue is empty. Call this
  exactly once per applied result so the serial chain keeps draining.
  """
  @spec advance(EditorState.t(), lane()) :: EditorState.t()
  def advance(%EditorState{} = state, lane) do
    lane_state = EditorState.get_async_lane(state, lane)

    case lane_state.queue do
      [] -> EditorState.delete_async_lane(state, lane)
      [next | rest] -> start(state, lane, next, rest)
    end
  end

  @spec start(EditorState.t(), lane(), work(), [work()]) :: EditorState.t()
  defp start(state, lane, work_fun, queue) do
    token = make_ref()
    editor = self()

    Task.start(fn ->
      send(editor, {:async_action_result, lane, token, safely(work_fun)})
    end)

    EditorState.put_async_lane(state, lane, %{running: token, queue: queue})
  end

  @spec safely(work()) :: term()
  defp safely(work_fun) do
    work_fun.()
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, "async action exited: #{inspect(reason)}"}
    :throw, value -> {:error, "async action threw: #{inspect(value)}"}
  end
end
