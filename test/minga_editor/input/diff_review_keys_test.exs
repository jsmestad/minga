defmodule MingaEditor.Input.DiffReviewKeysTest do
  @moduledoc """
  Dispatches Diff Review keys through the Editor's real input router.

  Proves the CUA chords and the Vim keys step through and decide staged hunks only while the review has focus, and never type into the composer or the editor buffer.
  """
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Editing.Scroll
  alias Minga.Test.RecordingFrontend
  alias MingaEditor.Agent.DiffReview
  alias MingaEditor.Agent.PromptBuffer
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.View.Preview
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.Input.Router
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.Workflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.VimState

  @ctrl 0x02
  @alt 0x04
  @cmd 0x08

  @alt_down {57_353, @alt}
  @alt_up {57_352, @alt}

  describe "CUA" do
    test "Alt+Down and Alt+Up step between conflicts without typing" do
      state = reviewing(:cua)
      first = current_hunk(state)

      next = press(state, @alt_down)
      refute current_hunk(next) == first
      assert press(next, @alt_up) |> current_hunk() == first

      for after_key <- [next, press(next, @alt_up)], do: assert_nothing_typed(after_key)
    end

    test "Cmd or Ctrl with Enter uses the Agent version and with Backspace keeps mine" do
      for modifier <- [@cmd, @ctrl] do
        accepted = press(reviewing(:cua), {13, modifier})
        assert DiffReview.resolution_at(review(accepted), 0) == :accepted
        assert_nothing_typed(accepted)

        rejected = press(reviewing(:cua), {127, modifier})
        assert DiffReview.resolution_at(review(rejected), 0) == :rejected
        assert_nothing_typed(rejected)
      end
    end

    test "bare y and x do not decide a hunk in CUA" do
      for char <- [?y, ?x] do
        state = press(reviewing(:cua), {char, 0})
        assert DiffReview.resolution_at(review(state), 0) == nil
        assert_nothing_typed(state)
      end
    end

    test "focusing the composer over the review withdraws the review chords" do
      reviewing = reviewing(:cua)

      composing =
        Workflow.install_agent_ui(
          reviewing,
          PromptBuffer.set_input_focused(reviewing.workspace.agent_ui, true)
        )

      # The keymap context is derived from what has focus, so the composer keeps
      # its own meaning for these chords (see AgentDiffReviewKeysTest).
      refute UIState.diff_review_focused?(composing.workspace.agent_ui)
      assert UIState.diff_review_focused?(reviewing.workspace.agent_ui)
    end
  end

  describe "Vim" do
    test "y uses the Agent version and x keeps mine while the review has focus" do
      accepted = press(reviewing(:vim), {?y, 0})
      assert DiffReview.resolution_at(review(accepted), 0) == :accepted
      assert_nothing_typed(accepted)

      rejected = press(reviewing(:vim), {?x, 0})
      assert DiffReview.resolution_at(review(rejected), 0) == :rejected
      assert_nothing_typed(rejected)
    end

    test "]c steps to the next conflict" do
      state = reviewing(:vim)
      next = state |> press({?], 0}) |> press({?c, 0})
      refute current_hunk(next) == current_hunk(state)
    end

    test "the CUA chords are not Vim review keys" do
      state = reviewing(:vim)
      after_key = press(state, {13, @cmd})
      assert DiffReview.resolution_at(review(after_key), 0) == nil
      assert current_hunk(press(state, @alt_down)) == current_hunk(state)
    end
  end

  test "ordinary comparisons do not claim the legacy decision keys" do
    for {model, keys} <- [{:vim, [{?x, 0}, {?X, 0}]}, {:cua, [{13, @cmd}, {127, @cmd}]}] do
      comparison = DiffReview.new("note.txt", "before", "after")
      state = show_review(base_state(model), comparison)

      refute UIState.diff_review_focused?(state.workspace.agent_ui)
      assert review(Enum.reduce(keys, state, &press(&2, &1))) == comparison
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp press(state, {cp, mods}), do: Router.dispatch(state, cp, mods)

  defp review(state), do: Preview.diff_review(state.workspace.agent_ui.view.preview)

  defp current_hunk(state), do: review(state).current_hunk_index

  defp assert_nothing_typed(state) do
    assert PromptBuffer.prompt_text(state.workspace.agent_ui) == ""
    assert BufferProcess.content(state.workspace.buffers.active) == "hello world"
  end

  # A full Agent tab whose body shows a staged fork-conflict review with two
  # conflicts, focus on the review and an empty composer.
  defp reviewing(editing_model) do
    review =
      DiffReview.from_fork_snapshot("note.txt", {self(), 2, 1}, [
        {:conflict, ["Agent A"], ["Human A"], []},
        {:resolved, ["unchanged"]},
        {:conflict, ["Agent B"], ["Human B"], []}
      ])

    state = show_review(base_state(editing_model), review)
    assert UIState.diff_review_focused?(state.workspace.agent_ui)
    state
  end

  defp show_review(state, review) do
    ui =
      state.workspace.agent_ui
      |> UIState.replace_preview(Preview.set_diff(Preview.new(), review))
      |> UIState.set_focus(:file_viewer)

    Workflow.install_agent_ui(state, ui)
  end

  defp base_state(editing_model) do
    buf = start_supervised!({BufferProcess, content: "hello world"}, id: make_ref())
    prompt_buf = start_supervised!({BufferProcess, content: ""}, id: make_ref())
    frontend = start_supervised!({RecordingFrontend, owner: self()}, id: make_ref())
    # A private sidebar registry, so a sidebar another test opens cannot claim keys.
    sidebars = Module.concat(__MODULE__, "Sidebar#{System.unique_integer([:positive])}")
    start_supervised!({Sidebar, name: sidebars, notify: false})

    agent_ui =
      %UIState{
        panel: %UIState.Panel{
          visible: false,
          input_focused: false,
          scroll: Scroll.new(),
          spinner_frame: 0,
          provider_name: "anthropic",
          model_name: "claude-sonnet-4",
          thinking_level: "medium",
          prompt_buffer: prompt_buf
        }
      }
      |> UIState.activate(nil, nil)

    %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: frontend},
      extension_surfaces: %MingaEditor.State.ExtensionSurfaces{sidebar_registry: sidebars},
      workspace: %MingaEditor.Session.State{
        editing: VimState.new(),
        buffers: %Buffers{active: buf, list: [buf]},
        keymap_scope: :agent,
        agent_ui: agent_ui
      },
      interaction: MingaEditor.State.Interaction.new(editing_model: editing_model),
      shell_runtime:
        Runtime.new(
          Runtime.default_entry(),
          MingaEditor.Shell.Traditional.State.install_tab_bar(
            MingaEditor.Shell.Traditional.State.replace_agent(
              %MingaEditor.Shell.Traditional.State{},
              %AgentState{}
            ),
            TabBar.new(Tab.new_agent(1, "Agent"))
          )
        )
    }
  end
end
