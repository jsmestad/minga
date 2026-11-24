defmodule MingaEditor.Agent.ReviewHighlightWorkflowTest do
  use ExUnit.Case, async: true

  alias Minga.Language.Highlight.Span
  alias MingaEditor.Agent.DiffReview
  alias MingaEditor.Agent.ReviewHighlights
  alias MingaEditor.Agent.ReviewHighlightWorkflow
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.View.Preview
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState

  setup do
    %{supervisor: start_supervised!(Task.Supervisor)}
  end

  test "requesting returns before any parse finishes; the result is installed only from its message",
       %{supervisor: supervisor} do
    test = self()

    # The stub parser blocks until the test releases it, so a synchronous parse would deadlock here.
    highlighter = fn language, source, _opts ->
      send(test, {:parse_started, self(), language, source})

      receive do
        :release -> {:ok, ["keyword"], [Span.new(0, 3, 0)]}
      end
    end

    state = review_state(DiffReview.new("lib/a.ex", "def old", "def new"))

    state =
      ReviewHighlightWorkflow.request(state, highlighter: highlighter, supervisor: supervisor)

    assert sides(state) == %{old: nil, new: nil}
    assert_receive {:parse_started, old_parser, "elixir", "def old"}
    assert_receive {:parse_started, new_parser, "elixir", "def new"}

    # Rendering again while the parses run neither restarts them nor parses inline.
    assert ReviewHighlightWorkflow.request(state,
             highlighter: highlighter,
             supervisor: supervisor
           ) ==
             state

    send(old_parser, :release)
    assert_receive {:agent_review_highlight, old_key, {:ready, ["keyword"], _spans} = old_result}
    assert {:accepted, state} = ReviewHighlightWorkflow.complete(state, old_key, old_result)
    assert %{old: {^old_key, ["keyword"], _packed}, new: nil} = sides(state)

    send(new_parser, :release)
    assert_receive {:agent_review_highlight, new_key, new_result}
    assert {:accepted, state} = ReviewHighlightWorkflow.complete(state, new_key, new_result)
    assert %{old: {_, _, _}, new: {^new_key, _, _}} = sides(state)
  end

  test "a result for text the review replaced is stale", %{supervisor: supervisor} do
    highlighter = fn _language, _source, _opts -> {:ok, [], []} end
    state = review_state(DiffReview.new("lib/a.ex", "def old", "def new"))

    state =
      ReviewHighlightWorkflow.request(state, highlighter: highlighter, supervisor: supervisor)

    assert_receive {:agent_review_highlight, key, result}
    assert_receive {:agent_review_highlight, _other_key, _other_result}

    state = replace_review(state, DiffReview.new("lib/a.ex", "other old", "other new"))

    state =
      ReviewHighlightWorkflow.request(state, highlighter: highlighter, supervisor: supervisor)

    assert ReviewHighlightWorkflow.complete(state, key, result) == :stale
  end

  test "a crashing parser leaves the review flat instead of pending forever",
       %{supervisor: supervisor} do
    highlighter = fn _language, _source, _opts -> raise "parser crashed" end
    state = review_state(DiffReview.new("lib/a.ex", "def old", "def new"))

    state =
      ReviewHighlightWorkflow.request(state, highlighter: highlighter, supervisor: supervisor)

    assert_receive {:agent_review_highlight, old_key, :unavailable}
    assert_receive {:agent_review_highlight, new_key, :unavailable}
    assert {:accepted, state} = ReviewHighlightWorkflow.complete(state, old_key, :unavailable)
    assert {:accepted, state} = ReviewHighlightWorkflow.complete(state, new_key, :unavailable)
    assert sides(state) == %{old: nil, new: nil}

    # The failure is settled: later frames neither retry nor wait on it.
    assert ReviewHighlightWorkflow.request(state,
             highlighter: highlighter,
             supervisor: supervisor
           ) ==
             state

    refute_received {:agent_review_highlight, _key, _result}
  end

  test "a parse finishing while its tab is stashed is not applied elsewhere and restarts on return",
       %{supervisor: supervisor} do
    test = self()

    highlighter = fn _language, source, _opts ->
      send(test, {:parse_started, self(), source})
      receive do: (:release -> {:ok, ["keyword"], [Span.new(0, 3, 0)]})
    end

    opts = [highlighter: highlighter, supervisor: supervisor]

    state =
      ReviewHighlightWorkflow.request(
        review_state(DiffReview.new("lib/a.ex", "def old", "def new")),
        opts
      )

    assert_receive {:parse_started, parser, "def old"}
    assert_receive {:parse_started, _new_parser, "def new"}

    # Stash this Agent tab the way TabWorkflow does, then show another workspace's review.
    stashed = UIState.suspend_review_highlights(state.workspace.agent_ui)
    other = replace_review(state, DiffReview.new("lib/b.ex", "x = 1", "x = 2"))

    other =
      install_ui(
        other,
        UIState.replace_review_highlights(other.workspace.agent_ui, ReviewHighlights.new())
      )

    other = ReviewHighlightWorkflow.request(other, opts)
    assert_receive {:parse_started, _, "x = 1"}
    assert_receive {:parse_started, _, "x = 2"}

    send(parser, :release)
    assert_receive {:agent_review_highlight, key, result}
    assert ReviewHighlightWorkflow.complete(other, key, result) == :stale

    # Returning to the stashed tab with the same review starts both parses again.
    returned = ReviewHighlightWorkflow.request(install_ui(other, stashed), opts)
    assert_receive {:parse_started, _, "def old"}
    assert_receive {:parse_started, _, "def new"}
    assert {:accepted, returned} = ReviewHighlightWorkflow.complete(returned, key, result)
    assert %{old: {^key, ["keyword"], _spans}} = sides(returned)
  end

  defp install_ui(state, ui),
    do: MingaEditor.Shell.Traditional.Workflow.install_agent_ui(state, ui)

  defp review_state(review) do
    state = %EditorState{
      frontend: %MingaEditor.State.Frontend{backend: :gui, port_manager: nil},
      workspace: %SessionState{agent_ui: UIState.new()},
      shell_runtime:
        Runtime.new(
          Runtime.default_entry(),
          TraditionalState.replace_agent(%TraditionalState{}, %AgentState{})
        )
    }

    replace_review(state, review)
  end

  defp replace_review(state, review) do
    ui = state.workspace.agent_ui
    ui = UIState.replace_preview(ui, Preview.set_diff(ui.view.preview, review))
    MingaEditor.Shell.Traditional.Workflow.install_agent_ui(state, ui)
  end

  defp sides(state), do: ReviewHighlights.sides(state.workspace.agent_ui.view.review_highlights)
end
