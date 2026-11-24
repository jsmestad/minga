defmodule MingaEditor.Agent.UIStateTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaAgent.Session.{ConnectionSnapshot, ConnectionTarget}
  alias MingaEditor.Agent.StartFailure
  alias MingaEditor.Agent.StartRequest
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.UIState.Panel

  defp ui_with_input(lines, cursor \\ {0, 0}) do
    ui = UIState.new() |> MingaEditor.Agent.PromptBuffer.ensure()
    BufferProcess.replace_content(ui.panel.prompt_buffer, Enum.join(lines, "\n"))
    BufferProcess.move_to(ui.panel.prompt_buffer, cursor)
    ui
  end

  defp put_history(ui, history, index \\ -1) do
    ui
    |> put_in([Access.key(:panel), Access.key(:prompt_history)], history)
    |> put_in([Access.key(:panel), Access.key(:history_index)], index)
  end

  test "every lifecycle transition preserves the same live draft and prompt cursor" do
    initial = ui_with_input(["unfinished", "café"], {1, 3})
    failure = StartFailure.timed_out(StartRequest.default())
    states = [:starting, {:conversation, self()}, {:failed, failure}, :unavailable]

    for from <- states, to <- states do
      ui = initial |> UIState.restore_chat(from) |> UIState.restore_chat(to)
      assert ui.chat_lifecycle == to
      assert MingaEditor.Agent.PromptBuffer.input_text(ui) == "unfinished\ncafé"
      assert MingaEditor.Agent.PromptBuffer.input_cursor(ui) == {1, 3}
      assert ui.panel.prompt_buffer == initial.panel.prompt_buffer
    end
  end

  test "fail_start installs the classified failure and keeps the draft" do
    failure = StartFailure.timed_out(StartRequest.default())
    failed = UIState.fail_start(ui_with_input(["keep"], {0, 2}), failure)

    assert failed.chat_lifecycle == {:failed, failure}
    assert UIState.start_failure(failed) == failure
    assert MingaEditor.Agent.PromptBuffer.input_text(failed) == "keep"
  end

  test "a provider startup failure offers a provider retry and keeps the draft until ready" do
    session = self()

    starting = %ConnectionSnapshot{
      target: ConnectionTarget.new(session, "session", nil, make_ref()),
      credential_readiness: :configured,
      model_selection: nil,
      provider_phase: :starting,
      operation: :idle,
      problem: nil
    }

    ui = UIState.project_connection(ui_with_input(["keep draft"], {0, 5}), starting)
    assert ui.chat_lifecycle == :starting

    failed = UIState.project_connection(ui, %{starting | problem: {:provider, :startup_failed}})

    assert failed.chat_lifecycle ==
             {:failed,
              %StartFailure{
                headline: "Agent could not start",
                message: "The Agent provider could not start.",
                remedy: {:retry, :provider}
              }}

    assert MingaEditor.Agent.PromptBuffer.input_text(failed) == "keep draft"

    ready = UIState.project_connection(failed, %{starting | provider_phase: :running})

    assert ready.chat_lifecycle == {:conversation, session}
    assert MingaEditor.Agent.PromptBuffer.input_text(ready) == "keep draft"
    assert MingaEditor.Agent.PromptBuffer.input_cursor(ready) == {0, 5}
  end

  describe "model_label/1" do
    test "names the header model from the lifecycle, never Resolving after a failed start" do
      failure = StartFailure.timed_out(StartRequest.default())
      unresolved = Panel.set_model_name(Panel.new(), "unknown")
      configured = Panel.set_model_name(Panel.new(), "gpt-5")

      for {lifecycle, panel, label} <- [
            {:starting, unresolved, "Starting…"},
            {:starting, configured, "gpt-5"},
            {{:failed, failure}, Panel.set_credential_readiness(unresolved, :unconfigured),
             "No model configured"},
            {{:failed, failure}, Panel.set_credential_readiness(unresolved, :configured),
             "Not started"},
            {{:failed, failure}, Panel.set_credential_readiness(configured, :configured),
             "Not started"},
            {:unavailable, configured, "No session"},
            {{:conversation, self()}, configured, "gpt-5"}
          ] do
        ui = UIState.restore_chat(%UIState{panel: panel}, lifecycle)
        assert UIState.model_label(ui) == label, "#{inspect(lifecycle)}"
      end
    end
  end

  describe "start_remedy/1" do
    test "names the remedy only for a failed start" do
      for {lifecycle, remedy} <- [
            {:starting, nil},
            {:unavailable, nil},
            {{:conversation, self()}, nil},
            {{:failed, StartFailure.timed_out(StartRequest.default())}, :retry},
            {{:failed, StartFailure.missing_credentials()}, :set_up_provider}
          ] do
        assert UIState.start_remedy(UIState.restore_chat(UIState.new(), lifecycle)) == remedy
      end
    end
  end

  describe "new/0 and basic state" do
    test "starts hidden with model discovery deferred" do
      ui = UIState.new()

      refute ui.panel.visible
      refute ui.panel.input_focused
      assert ui.panel.prompt_history == []
      assert ui.panel.history_index == -1
      assert MingaEditor.Agent.PromptBuffer.input_text(ui) == ""
      assert MingaEditor.Agent.PromptBuffer.input_lines(ui) == [""]
      assert MingaEditor.Agent.PromptBuffer.input_cursor(ui) == {0, 0}
      assert MingaEditor.Agent.PromptBuffer.input_line_count(ui) == 1
      assert MingaEditor.Agent.PromptBuffer.input_empty?(ui)
      assert ui.panel.credential_readiness == :checking
      assert ui.panel.credentials_configured == false
      assert ui.panel.thinking_level == nil
    end

    test "credential readiness projection retains an unresolved model for every readiness result" do
      panel = Panel.set_model_name(Panel.new(), "unknown")

      for readiness <- [:checking, :configured, :unconfigured] do
        updated = Panel.set_credential_readiness(panel, readiness)
        assert updated.model_name == "unknown"
        assert updated.credential_readiness == readiness
        assert updated.credentials_configured == (readiness == :configured)
      end
    end

    test "model labels distinguish unresolved discovery from confirmed absence" do
      panel = Panel.set_model_name(Panel.new(), "unknown")

      assert Panel.model_label(Panel.set_credential_readiness(panel, :checking)) ==
               "Resolving model…"

      assert Panel.model_label(Panel.set_credential_readiness(panel, :configured)) ==
               "Resolving model…"

      assert Panel.model_label(Panel.set_credential_readiness(panel, :unconfigured)) ==
               "No model configured"

      selected = Panel.set_model_name(panel, "openai:selected")
      assert Panel.model_label(selected) == "openai:selected"
    end

    test "an unresolved model shows the session's explanation once the session reports it" do
      session = self()

      connection = %ConnectionSnapshot{
        target: ConnectionTarget.new(session, "session-1", nil, make_ref()),
        credential_readiness: :configured,
        model_selection: nil,
        provider_phase: :stopped,
        operation: :idle,
        problem: {:resolution, {:model_not_found, "openai:missing"}}
      }

      ui = UIState.project_connection(UIState.new(), connection)

      assert Panel.model_label(ui.panel) ==
               MingaAgent.ModelResolver.message({:model_not_found, "openai:missing"})

      assert Panel.model_label(ui.panel) != "Resolving model…"
    end

    test "a route's provider label names the chat model until another model replaces it" do
      selection =
        MingaAgent.Test.ModelSelectionFixture.selection(
          request_provider: :contributed,
          origin: {:contributed, "claude_bridge", "haiku"},
          model_provider: "claude_bridge",
          model_id: "haiku",
          route_id: "claude_bridge/haiku",
          display_name: "Claude Haiku",
          provider_label: "Claude (subscription)"
        )

      projected = Panel.project_model_selection(Panel.new(), selection)
      assert Panel.chat_model_label(projected) == "Claude (subscription):Claude Haiku"
      assert Panel.model_label(projected) == "Claude Haiku"
      assert projected.provider_name == "claude_bridge"

      assert projected |> Panel.set_model_name("openai:gpt") |> Panel.chat_model_label() ==
               "openai:gpt"

      assert projected |> Panel.project_model_selection(nil) |> Panel.chat_model_label() ==
               Panel.model_label(Panel.project_model_selection(projected, nil))
    end

    test "activation preserves an existing qualified or exact route selection" do
      options = start_supervised!({Minga.Config.Options, name: nil})
      assert {:ok, _} = Minga.Config.Options.set(options, :agent_model, "openai:replacement")

      for model <- ["anthropic:selected", "selected@anthropic", "ms2_selected-route"] do
        panel = Panel.set_model_name(Panel.new(), model)
        assert Panel.ensure_configured_model(panel, options) == panel
      end
    end

    test "activation installs an explicit model for empty and unresolved panels" do
      options = start_supervised!({Minga.Config.Options, name: nil})
      assert {:ok, _} = Minga.Config.Options.set(options, :agent_model, "openai:selected")

      for model <- ["", "unknown", "selected"] do
        panel = Panel.set_model_name(Panel.new(), model)
        updated = Panel.ensure_configured_model(panel, options)
        assert updated.model_name == "openai:selected"
        assert updated.provider_name == "openai"
      end
    end

    test "toggle flips panel visibility" do
      assert UIState.toggle(UIState.new()).panel.visible
      refute UIState.new() |> UIState.toggle() |> UIState.toggle() |> then(& &1.panel.visible)
    end
  end

  describe "prompt editing" do
    test "inserts characters, newlines, and deletes across line boundaries" do
      ui = ui_with_input([""])

      ui =
        ui
        |> MingaEditor.Agent.PromptBuffer.insert_char("h")
        |> MingaEditor.Agent.PromptBuffer.insert_char("i")

      assert MingaEditor.Agent.PromptBuffer.input_lines(ui) == ["hi"]

      BufferProcess.move_to(ui.panel.prompt_buffer, {0, 1})
      ui = MingaEditor.Agent.PromptBuffer.insert_newline(ui)
      assert MingaEditor.Agent.PromptBuffer.input_lines(ui) == ["h", "i"]

      ui = ui_with_input(["ab", "cd"], {1, 0}) |> MingaEditor.Agent.PromptBuffer.delete_char()
      assert MingaEditor.Agent.PromptBuffer.input_lines(ui) == ["abcd"]

      ui = ui_with_input(["hi"], {0, 0}) |> MingaEditor.Agent.PromptBuffer.delete_char()
      assert MingaEditor.Agent.PromptBuffer.input_lines(ui) == ["hi"]
    end

    test "edit operations reset history index" do
      for operation <- [
            &MingaEditor.Agent.PromptBuffer.insert_char(&1, "x"),
            &MingaEditor.Agent.PromptBuffer.insert_newline/1,
            &MingaEditor.Agent.PromptBuffer.delete_char/1
          ] do
        ui =
          ui_with_input(["abc"], {0, 1})
          |> put_in([Access.key(:panel), Access.key(:history_index)], 2)

        assert operation.(ui).panel.history_index == -1
      end
    end

    test "cursor movement reports boundaries and moves within multiline input" do
      assert MingaEditor.Agent.PromptBuffer.move_cursor_up(ui_with_input(["hello"], {0, 0})) ==
               :at_top

      assert MingaEditor.Agent.PromptBuffer.move_cursor_down(ui_with_input(["hello"], {0, 0})) ==
               :at_bottom

      refute MingaEditor.Agent.PromptBuffer.move_cursor_up(ui_with_input(["ab", "cd"], {1, 0})) ==
               :at_top

      refute MingaEditor.Agent.PromptBuffer.move_cursor_down(ui_with_input(["ab", "cd"], {0, 0})) ==
               :at_bottom
    end

    test "focus starts the prompt buffer and unfocus preserves content" do
      ui = UIState.new() |> MingaEditor.Agent.PromptBuffer.set_input_focused(true)
      assert ui.panel.input_focused
      assert is_pid(ui.panel.prompt_buffer)

      ui =
        ui_with_input(["hello"])
        |> MingaEditor.Agent.PromptBuffer.set_input_focused(true)
        |> MingaEditor.Agent.PromptBuffer.set_input_focused(false)

      refute ui.panel.input_focused
      assert MingaEditor.Agent.PromptBuffer.input_lines(ui) == ["hello"]
    end
  end

  describe "input clearing, text access, and history" do
    test "clear_input saves non-empty prompts, resets editing state, and clears paste blocks" do
      ui =
        ui_with_input(["hello", "world"])
        |> put_in([Access.key(:panel), Access.key(:history_index)], 1)
        |> put_in([Access.key(:panel), Access.key(:pasted_blocks)], [
          %{text: "paste", expanded: false}
        ])
        |> MingaEditor.Agent.PromptBuffer.clear_input()

      assert MingaEditor.Agent.PromptBuffer.input_lines(ui) == [""]
      assert MingaEditor.Agent.PromptBuffer.input_text(ui) == ""
      assert ui.panel.prompt_history == ["hello\nworld"]
      assert ui.panel.history_index == -1
      assert ui.panel.pasted_blocks == []
    end

    test "prompt_text substitutes paste placeholders while input_text stays raw" do
      placeholder = <<0>> <> "PASTE:0"

      ui =
        ui_with_input(["before", placeholder, "after"])
        |> put_in([Access.key(:panel), Access.key(:pasted_blocks)], [
          %{text: "line1\nline2\nline3", expanded: false}
        ])

      assert MingaEditor.Agent.PromptBuffer.input_text(ui) == "before\n#{placeholder}\nafter"

      assert MingaEditor.Agent.PromptBuffer.prompt_text(ui) ==
               "before\nline1\nline2\nline3\nafter"
    end

    test "history navigation walks older and newer prompts with clamping" do
      ui = ui_with_input([""]) |> put_history(["first", "second"])

      first = MingaEditor.Agent.PromptBuffer.history_prev(ui)
      assert MingaEditor.Agent.PromptBuffer.input_text(first) == "first"
      assert first.panel.history_index == 0

      second = MingaEditor.Agent.PromptBuffer.history_prev(first)
      assert MingaEditor.Agent.PromptBuffer.input_text(second) == "second"
      assert second.panel.history_index == 1

      assert MingaEditor.Agent.PromptBuffer.history_prev(second).panel.history_index == 1

      newer = MingaEditor.Agent.PromptBuffer.history_next(second)
      assert MingaEditor.Agent.PromptBuffer.input_text(newer) == "first"
      assert newer.panel.history_index == 0

      current = MingaEditor.Agent.PromptBuffer.history_next(newer)
      assert MingaEditor.Agent.PromptBuffer.input_text(current) == ""
      assert current.panel.history_index == -1
    end

    test "save_to_history skips blank input" do
      for text <- ["", "   "] do
        assert text
               |> List.wrap()
               |> ui_with_input()
               |> MingaEditor.Agent.PromptBuffer.save_to_history()
               |> then(& &1.panel.prompt_history) == []
      end

      assert ui_with_input(["hello"])
             |> MingaEditor.Agent.PromptBuffer.save_to_history()
             |> then(& &1.panel.prompt_history) == ["hello"]
    end
  end

  describe "paste handling" do
    test "insert_paste handles empty, direct, collapsed, sanitized, and multiple pastes" do
      ui = ui_with_input([""])
      assert MingaEditor.Agent.PromptBuffer.insert_paste(ui, "") == ui

      assert ui_with_input([""])
             |> MingaEditor.Agent.PromptBuffer.insert_paste("hello")
             |> MingaEditor.Agent.PromptBuffer.input_text() ==
               "hello"

      assert ui_with_input([""])
             |> MingaEditor.Agent.PromptBuffer.insert_paste("line1\nline2")
             |> MingaEditor.Agent.PromptBuffer.input_text() ==
               "line1\nline2"

      assert ui_with_input([""])
             |> MingaEditor.Agent.PromptBuffer.insert_paste("hello" <> <<0>> <> "world")
             |> MingaEditor.Agent.PromptBuffer.input_text() ==
               "helloworld"

      collapsed = ui_with_input([""]) |> MingaEditor.Agent.PromptBuffer.insert_paste("a\nb\nc")
      assert Enum.count(collapsed.panel.pasted_blocks) == 1
      assert hd(collapsed.panel.pasted_blocks).text == "a\nb\nc"
      assert MingaEditor.Agent.PromptBuffer.prompt_text(collapsed) == "a\nb\nc"

      multi = collapsed |> MingaEditor.Agent.PromptBuffer.insert_paste("d\ne\nf")
      assert Enum.count(multi.panel.pasted_blocks) == 2
    end

    test "toggle_paste_expand expands, collapses, and no-ops outside paste blocks" do
      ui =
        ui_with_input([""])
        |> MingaEditor.Agent.PromptBuffer.insert_paste("line1\nline2\nline3")
        |> move_to_placeholder()

      expanded = MingaEditor.Agent.PromptBuffer.toggle_paste_expand(ui)
      assert hd(expanded.panel.pasted_blocks).expanded
      assert MingaEditor.Agent.PromptBuffer.input_line_count(expanded) >= 3

      collapsed =
        expanded
        |> move_cursor_to_placeholder_line()
        |> MingaEditor.Agent.PromptBuffer.toggle_paste_expand()

      refute hd(collapsed.panel.pasted_blocks).expanded

      plain = ui_with_input(["hello"])

      assert MingaEditor.Agent.PromptBuffer.toggle_paste_expand(plain)
             |> MingaEditor.Agent.PromptBuffer.input_lines() ==
               MingaEditor.Agent.PromptBuffer.input_lines(plain)
    end

    test "placeholder helpers parse only paste placeholders" do
      placeholder0 = <<0>> <> "PASTE:0"
      placeholder5 = <<0>> <> "PASTE:5"

      assert UIState.paste_placeholder?(placeholder0)
      refute UIState.paste_placeholder?("hello")
      assert UIState.paste_block_index(placeholder0) == 0
      assert UIState.paste_block_index(placeholder5) == 5
      assert UIState.paste_block_index("hello") == nil
    end
  end

  describe "scrolling and display" do
    test "scrolling updates offset and clear_display resets visible start and scroll" do
      ui = UIState.new() |> UIState.scroll_up(5)
      refute ui.panel.scroll.pinned

      ui =
        put_in(ui.panel.scroll, %{ui.panel.scroll | offset: 10, pinned: false})
        |> UIState.scroll_down(3)

      assert ui.panel.scroll.offset == 13

      cleared = ui |> UIState.scroll_up(10) |> UIState.clear_display(5)
      assert cleared.panel.transcript.display_start == 5
      assert cleared.panel.scroll.offset == 0
    end
  end

  describe "prompt buffer lifecycle" do
    test "ensure_prompt_buffer starts, reuses, and restarts the prompt buffer" do
      ui = UIState.new() |> MingaEditor.Agent.PromptBuffer.ensure()
      first_pid = ui.panel.prompt_buffer
      assert is_pid(first_pid)

      assert MingaEditor.Agent.PromptBuffer.ensure(ui).panel.prompt_buffer == first_pid

      ref = Process.monitor(first_pid)
      GenServer.stop(first_pid)
      assert_receive {:DOWN, ^ref, :process, ^first_pid, _reason}

      restarted = MingaEditor.Agent.PromptBuffer.ensure(ui)
      assert is_pid(restarted.panel.prompt_buffer)
      refute restarted.panel.prompt_buffer == first_pid
    end
  end

  describe "transcript presentation version" do
    test "Panel.bump_message_version increments the projection counter each call" do
      panel = Panel.new()
      assert panel.transcript.version == 0

      assert panel
             |> Panel.bump_message_version()
             |> Panel.bump_message_version()
             |> then(& &1.transcript.version) == 2
    end
  end

  defp move_to_placeholder(ui) do
    line =
      Enum.find_index(
        MingaEditor.Agent.PromptBuffer.input_lines(ui),
        &UIState.paste_placeholder?/1
      )

    BufferProcess.move_to(ui.panel.prompt_buffer, {line, 0})
    ui
  end

  defp move_cursor_to_placeholder_line(ui) do
    line =
      MingaEditor.Agent.PromptBuffer.input_lines(ui)
      |> Enum.find_index(&(String.contains?(&1, "line1") or UIState.paste_placeholder?(&1)))

    BufferProcess.move_to(ui.panel.prompt_buffer, {line || 0, 0})
    ui
  end
end
