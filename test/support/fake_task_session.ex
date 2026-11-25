defmodule Minga.Test.FakeTaskSession do
  @moduledoc """
  A stand-in agent session for tests and storyboards that need tasks in the tasks drawer without a provider.

  `start/2` starts one under the test supervisor and has it tell the editor about itself the way a real session tells a new subscriber, then replays the events that put it in the requested state. Answering its approval replies `:ok` and resolves the approval the way `MingaAgent.Session` does, and the answer is reported to `:observer` as `{:fake_task_answered, pid, decision}`.

  Seeds, as `{title, state}`: `:needs_you`, `:working`, `:waiting`, `:stopped`, `:failed`, `:done`, `{:working, subagents: [titles]}`, or `:opened`, a conversation that was opened and never prompted, so it has no goal and is not a task (its title is unused).
  """

  use GenServer

  alias MingaAgent.Event.ToolEnd
  alias MingaAgent.ToolApproval.Preview
  alias MingaAgent.ToolApproval.Public
  alias MingaAgent.ToolApproval.Target

  @typedoc "The state a fake task starts in."
  @type seed ::
          :needs_you
          | :working
          | :waiting
          | :stopped
          | :failed
          | :done
          | :opened
          | {:working, keyword()}

  @doc "Starts a fake task titled `title` in `seed`, attached to `editor`. Options: `:observer`."
  @spec start(pid(), String.t(), seed(), keyword()) :: pid()
  def start(editor, title, seed, opts \\ []) do
    id = {__MODULE__, System.unique_integer([:positive])}

    pid =
      ExUnit.Callbacks.start_supervised!(
        %{
          id: id,
          start: {GenServer, :start_link, [__MODULE__, {editor, Keyword.get(opts, :observer)}]}
        },
        []
      )

    send(editor, {:agent_event, pid, {:credentials_status, true}})
    Enum.each(events(pid, title, seed), &send(editor, {:agent_event, pid, &1}))
    pid
  end

  @doc "The approval a `:needs_you` fake task asks for."
  @spec approval(pid()) :: Public.t()
  def approval(pid) do
    Public.new(
      Target.new("fake-#{inspect(pid)}", "request-1", "call-1"),
      "write_file",
      %{"path" => "test/minga_agent/usage_limit_test.exs"},
      Preview.new(:diff, "Create test/minga_agent/usage_limit_test.exs +86", [
        "+ defmodule MingaAgent.UsageLimitTest do"
      ])
    )
  end

  @spec events(pid(), String.t(), seed()) :: [term()]
  defp events(_pid, _title, :opened), do: []

  # Stopped by the user mid-turn: the session reports :stopped until the next turn starts.
  defp events(_pid, title, :stopped),
    do: [{:title_changed, title}, {:status_changed, :thinking}, {:status_changed, :stopped}]

  defp events(pid, title, :needs_you),
    do: [
      {:title_changed, title},
      {:status_changed, :tool_executing},
      {:approval_pending, approval(pid)}
    ]

  defp events(_pid, title, :working),
    do: [
      {:title_changed, title},
      {:status_changed, :tool_executing},
      {:stop_target_changed, {"fake", "request-1"}},
      {:tool_started, "edit-1", "edit_file", %{}}
    ]

  defp events(_pid, title, {:working, subagents: titles}) do
    starts =
      titles
      |> Enum.with_index()
      |> Enum.map(fn {task, index} ->
        {:tool_started, "sub-#{index}", "subagent", %{"task" => task}}
      end)

    [
      {:title_changed, title},
      {:status_changed, :tool_executing},
      {:stop_target_changed, {"fake", "request-1"}} | starts
    ]
  end

  defp events(_pid, title, :waiting),
    do: [
      {:title_changed, title},
      {:status_changed, :thinking},
      {:retry_scheduled, 40_000, "HTTP 429"}
    ]

  defp events(_pid, title, :failed) do
    [
      {:title_changed, title},
      {:status_changed, :tool_executing},
      {:tool_started, "test-1", "shell", %{}},
      {:tool_ended,
       %ToolEnd{
         tool_call_id: "test-1",
         name: "shell",
         outcome: :error,
         is_error: true,
         result:
           "1) test resume keeps the queued inputs\n   test/minga_agent/session_test.exs:142\n** (MatchError) no match of right hand side value"
       }},
      {:error, "Test run crashed"}
    ]
  end

  defp events(_pid, title, :done) do
    [
      {:title_changed, title},
      {:status_changed, :tool_executing},
      {:tool_started, "edit-1", "edit_file", %{}},
      {:tool_ended, %ToolEnd{tool_call_id: "edit-1", name: "edit_file", outcome: :complete}},
      {:status_changed, :idle}
    ]
  end

  @impl true
  def init({editor, observer}), do: {:ok, %{editor: editor, observer: observer}}

  @impl true
  def handle_call({:respond_to_approval, target, decision}, _from, state) do
    send(state.editor, {:agent_event, self(), {:approval_resolved, target, decision}})
    if state.observer, do: send(state.observer, {:fake_task_answered, self(), decision})
    {:reply, :ok, state}
  end

  def handle_call(:abort, _from, state) do
    send(state.editor, {:agent_event, self(), {:status_changed, :idle}})
    {:reply, :ok, state}
  end

  def handle_call(:continue, _from, state) do
    send(state.editor, {:agent_event, self(), {:status_changed, :thinking}})
    if state.observer, do: send(state.observer, {:fake_task_continued, self()})
    {:reply, :ok, state}
  end

  def handle_call({:stop_turn, target}, _from, state) do
    send(state.editor, {:agent_event, self(), {:stop_target_changed, nil}})
    send(state.editor, {:agent_event, self(), {:status_changed, :stopped}})
    if state.observer, do: send(state.observer, {:fake_task_stopped, self(), target})
    {:reply, :ok, state}
  end

  def handle_call(_request, _from, state), do: {:reply, {:error, :unsupported}, state}
end
