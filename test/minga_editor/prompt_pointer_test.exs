defmodule MingaEditor.PromptPointerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Minga.Mode.CommandState
  alias MingaEditor.Frontend.Protocol.GUI
  alias Minga.Protocol.Opcodes
  alias MingaEditor.Handlers.GuiActionHandler
  alias MingaEditor.KeyDispatch
  alias MingaEditor.MinibufferData
  alias MingaEditor.PromptUI
  alias MingaEditor.RenderModel.UI.MinibufferBuilder
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Prompt, as: PromptState
  alias MingaEditor.Target

  defmodule Handler do
    @behaviour MingaEditor.UI.Prompt.Handler

    @impl true
    def label, do: "Private input: "

    @impl true
    def on_submit(_text, state), do: state

    @impl true
    def on_submit(text, state, context) do
      send(context.owner, {:submitted, text, context, state.shell_runtime.state.modal})
      state
    end

    @impl true
    def on_cancel(state, context) do
      send(context.owner, {:cancelled, context, state.shell_runtime.state.modal})
      state
    end
  end

  test "semantic buttons submit original live input and context exactly once in non-command modes" do
    for mode <- [:normal, :insert] do
      context = %{owner: self(), private: "private callback context", mode: mode}
      opened = open(mode, context, "original")
      offered = offer(opened)
      assert offered.generation > 0 and offered.generation <= 0xFFFFFFFF
      assert Enum.map(offered.candidates, & &1.id) == ["Submit", "Cancel"]
      assert Enum.map(offered.candidates, & &1.annotation) == ["Enter", "Escape"]

      edited = PromptUI.insert_text(opened, " live")
      assert offer(edited).generation == offered.generation
      target = target(offered.generation, "Submit")
      assert {:ok, {:prompt, generation, "Submit"}} = Target.resolve(edited, target)
      assert generation == offered.generation
      closed = GuiActionHandler.dispatch(edited, target)
      assert_received {:submitted, "original live", ^context, :none}
      refute PromptUI.open?(closed)
      assert closed.shell_runtime.state.modal == :none

      capture_log(fn -> GuiActionHandler.dispatch(closed, target) end)
      assert PromptUI.activate(closed, generation, "Submit") == closed
      refute_received {:submitted, _, _, _}
      refute_received {:cancelled, _, _}
    end
  end

  test "replacement with identical label and text rejects every old action without touching live input" do
    context = %{owner: self(), private: "original context"}
    original = open(:insert, context, "same text")
    old = offer(original)
    replacement_context = %{owner: self(), private: "replacement context"}

    for prior <- [original, PromptUI.close(original)] do
      replacement =
        PromptUI.open(prior, Handler,
          default: "same text",
          context: replacement_context
        )

      current = offer(replacement)
      refute current.generation == old.generation
      assert current.input == old.input
      assert current.prompt == old.prompt

      for id <- ["Submit", "Cancel"] do
        assert Target.resolve(replacement, target(old.generation, id)) ==
                 {:error, :stale_generation}

        assert PromptUI.activate(replacement, old.generation, id) == replacement

        capture_log(fn ->
          rejected = GuiActionHandler.dispatch(replacement, target(old.generation, id))
          assert rejected.shell_runtime.state.modal == replacement.shell_runtime.state.modal
        end)
      end

      refute_received {:submitted, _, _, _}
      refute_received {:cancelled, _, _}

      closed = GuiActionHandler.dispatch(replacement, target(current.generation, "Submit"))
      assert_received {:submitted, "same text", ^replacement_context, :none}
      refute PromptUI.open?(closed)
      refute_received {:cancelled, _, _}
    end
  end

  test "pointer Cancel equals Escape, drops active input, and invokes cancel once" do
    context = %{owner: self(), private: "cancel context"}
    opened = open(:normal, context, "discard this input")
    offered = offer(opened)
    clicked = GuiActionHandler.dispatch(opened, target(offered.generation, "Cancel"))
    assert_received {:cancelled, ^context, :none}
    {escaped, nil} = PromptUI.handle_key(opened, 27, 0)
    assert_received {:cancelled, ^context, :none}
    assert clicked == escaped
    assert clicked.shell_runtime.state.modal == :none
    refute :erlang.term_to_binary(clicked) =~ "discard this input"
    refute :erlang.term_to_binary(clicked) =~ "cancel context"
    assert PromptUI.activate(clicked, offered.generation, "Cancel") == clicked
    refute_received {:cancelled, _, _}
    refute_received {:submitted, _, _, _}
  end

  test "unoffered actions and generation zero never activate prompts or relax command resolution" do
    context = %{owner: self()}
    prompt = open(:normal, context, "private")
    generation = offer(prompt).generation
    assert PromptUI.activate(prompt, generation, "write") == prompt
    assert PromptUI.activate(prompt, 0, "Submit") == prompt
    assert Target.resolve(prompt, target(generation, "write")) == {:error, :not_found}
    assert Target.resolve(prompt, target(0, "Submit")) == {:error, :stale_generation}

    assert PromptState.resolve_activation(%PromptState{}, generation, "Submit") ==
             {:error, :not_found}

    command = base(:command) |> KeyDispatch.refresh_command_completion()
    offered = offer(command)
    candidate = hd(offered.candidates)

    assert Target.resolve(command, target(offered.generation, candidate.id)) ==
             {:ok, {:command_completion, candidate.label}}

    assert Target.resolve(command, target(offered.generation, "Submit")) == {:error, :not_found}

    workspace =
      SessionState.transition_mode(command.workspace, :command, CommandState.new("changed"))

    assert Target.resolve(
             %{command | workspace: workspace},
             target(offered.generation, candidate.id)
           ) ==
             {:error, :stale_generation}

    refute_received {:submitted, _, _, _}
    refute_received {:cancelled, _, _}
  end

  defp base(mode) do
    workspace = SessionState.transition_mode(%SessionState{}, mode)
    %EditorState{frontend: %MingaEditor.State.Frontend{port_manager: nil}, workspace: workspace}
  end

  defp open(mode, context, text) do
    PromptUI.open(base(mode), Handler, default: text, context: context)
  end

  defp offer(state), do: state |> MinibufferData.from_state() |> MinibufferBuilder.build()

  defp target(generation, id) do
    {:ok, target} =
      GUI.decode_gui_action(
        Opcodes.gui_action_semantic_item_activate(),
        <<4, 1, generation::32, byte_size(id)::16, id::binary>>
      )

    target
  end
end
