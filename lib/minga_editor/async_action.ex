defmodule MingaEditor.AsyncAction do
  @moduledoc """
  Runs slow editor work off the `MingaEditor` GenServer's input critical path.

  The single editor process owns input dispatch, GUI action handling, state
  mutation, and pre-render housekeeping. If an action runs slow work (git
  commands, filesystem walks) inline, later keypresses, clicks, and renderer
  writebacks queue behind it. `run/3` keeps that work off the critical path:

  1. The caller does a cheap state transition (e.g. set a "Discarding…" status).
  2. `run/3` hands the slow work to a `Task` and records a per-lane token.
  3. The editor keeps handling input while the Task runs.
  4. When the Task finishes it sends `{:async_action_result, lane, token, result}`
     back to the editor, which applies it only if the token is still the latest
     for that lane (`current?/3`).

  A *lane* identifies a logical resource that can have one meaningful in-flight
  result at a time (e.g. `:git_worktree`, `:file_tree`). Starting newer work on a
  lane supersedes older work: the older token stops being current, so its result
  is dropped instead of overwriting newer state. This is the revision/token
  tagging that makes stale results safe.
  """

  alias MingaEditor.State, as: EditorState

  @typedoc "Identifies the resource a piece of async work feeds back into."
  @type lane :: atom()

  @typedoc """
  Message sent to the editor when async work completes. `result` is whatever
  `work_fun` returned, or `{:error, reason}` if it raised, exited, or threw.
  """
  @type result_message :: {:async_action_result, lane(), reference(), term()}

  @doc """
  Spawns `work_fun` in a `Task` and records its token under `lane`, returning the
  updated state immediately so the caller never blocks on the work.

  `work_fun` is a zero-arity function run in the Task (it must not touch editor
  state). Its return value becomes the `result` in the `{:async_action_result,
  lane, token, result}` message; a raise/exit/throw is captured as
  `{:error, reason}` so a failing action can never crash the editor.
  """
  @spec run(EditorState.t(), lane(), (-> term())) :: EditorState.t()
  def run(%EditorState{} = state, lane, work_fun)
      when is_atom(lane) and is_function(work_fun, 0) do
    token = make_ref()
    editor = self()

    Task.start(fn ->
      send(editor, {:async_action_result, lane, token, safely(work_fun)})
    end)

    EditorState.put_async_token(state, lane, token)
  end

  @doc "Returns whether a result tagged with `token` for `lane` is still current."
  @spec current?(EditorState.t(), lane(), reference()) :: boolean()
  def current?(%EditorState{} = state, lane, token) do
    EditorState.async_token_current?(state, lane, token)
  end

  @spec safely((-> term())) :: term()
  defp safely(work_fun) do
    work_fun.()
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, "async action exited: #{inspect(reason)}"}
    :throw, value -> {:error, "async action threw: #{inspect(value)}"}
  end
end
