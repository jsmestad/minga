defmodule MingaEditor.RenderModel.UI.AgentChatBuilderTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Agent.Transcript
  alias MingaEditor.Agent.UIState
  alias MingaAgent.ToolApproval
  alias MingaAgent.ToolCall
  alias Minga.Config.Options
  alias Minga.Editing.Scroll
  alias Minga.Frontend.Adapter.GUI.AgentChatMessageCodec
  alias MingaEditor.Agent.UIState.Panel
  alias MingaEditor.Agent.UIState.TranscriptProjection
  alias MingaEditor.Frontend.Emit.Context
  alias Minga.RenderModel.UI.AgentChat.MarkdownBlock
  alias MingaEditor.UI.Theme
  alias MingaEditor.RenderModel.UI.AgentChatBuilder
  alias MingaEditor.Shell.Traditional
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Window

  test "build/1 sends cached display message pairs to resident agent transcript" do
    session = fake_session_pid()
    old_message = {:assistant, "old pinned"}
    hidden_message = {:user, "hidden"}
    visible_message = {:assistant, "visible"}
    message_ids = [{101, old_message}, {102, hidden_message}, {103, visible_message}]

    panel =
      synced_panel([old_message, hidden_message, visible_message],
        display_start_index: 2,
        message_ids: message_ids,
        pinned_ids: MapSet.new([101]),
        styled_messages: [nil, nil, nil, nil]
      )

    model =
      context(session, panel)
      |> AgentChatBuilder.build()

    assert model.visible?

    summaries = Enum.map(model.resident_messages, &message_summary/1)

    assert [
             {101, :assistant, "old pinned"},
             {_, :system, "── pinned ──"},
             {_, :system, "── 2 earlier messages hidden ──"},
             {103, :assistant, "visible"},
             {_, :system, "Agent UI registry online"}
           ] = summaries

    refute {:user, "hidden"} in Enum.map(summaries, fn {_id, type, text} -> {type, text} end)
  end

  test "build/1 carries the composer input focus for transcript scroll gating (#2654)" do
    session = fake_session_pid()
    panel = synced_panel([{:assistant, "hi"}])

    focused = context(session, %{panel | input_focused: true}) |> AgentChatBuilder.build()
    unfocused = context(session, %{panel | input_focused: false}) |> AgentChatBuilder.build()

    assert focused.input_focused
    refute unfocused.input_focused
  end

  test "build/1 emits semantic assistant markdown blocks in resident transcript when cache has them" do
    session = fake_session_pid()

    blocks = [
      MarkdownBlock.code_block(123, "elixir", "Elixir", nil, true, [
        [{"IO.puts(:hi)", 0x98BE65, 0x21242B, 0x10}]
      ])
    ]

    panel =
      synced_panel([{:assistant, "```elixir\nIO.puts(:hi)\n```"}],
        styled_messages: [
          %{styled_lines: [[{"fallback", 0xBBC2CF, 0, 0}]], markdown_blocks: blocks}
        ],
        styled_fingerprint:
          TranscriptProjection.styled_cache_fingerprint(Theme.Fallback.theme().syntax)
      )

    model =
      context(session, panel, theme: Theme.Fallback.theme())
      |> AgentChatBuilder.build()

    assert [{1, {:assistant_markdown, ^blocks}} | _] = model.resident_messages
  end

  test "build/1 ignores stale styled cache when theme syntax changes" do
    session = fake_session_pid()
    old_theme = Theme.Fallback.theme()
    new_theme = %{old_theme | syntax: Map.put(old_theme.syntax, "variable", fg: 0x12_34_56)}

    panel =
      synced_panel([{:assistant, "cached answer"}],
        styled_messages: [[{"cached answer", 0x98BE65, 0, 0}]],
        styled_fingerprint: TranscriptProjection.styled_cache_fingerprint(old_theme.syntax)
      )

    model =
      context(session, panel, theme: new_theme)
      |> AgentChatBuilder.build()

    assert {1, {:assistant, "cached answer"}} = hd(model.resident_messages)
  end

  test "build/1 keeps the full transcript resident for local frontend scrolling (#2654)" do
    session = fake_session_pid()

    panel =
      synced_panel(
        [
          {:assistant, "first"},
          {:assistant, "second"},
          {:assistant, "third"}
        ],
        scroll: Scroll.new(2) |> Scroll.update_metrics(5, 1),
        styled_messages: [nil, nil, nil]
      )

    model =
      context(session, panel)
      |> AgentChatBuilder.build()

    assert [
             {1, :assistant, "first"},
             {2, :assistant, "second"},
             {3, :assistant, "third"},
             {_, :system, "Agent UI registry online"}
           ] = Enum.map(model.resident_messages, &message_summary/1)

    # transcript_epoch is a stable, non-nil change token for the session.
    assert is_integer(model.transcript_epoch)
  end

  test "select_resident_messages/2 applies the configured wire-byte cap before the adapter" do
    messages = [
      {1, {:user, "first"}},
      {2, {:user, "second"}},
      {3, {:user, "third"}}
    ]

    {selected, truncated?} = AgentChatBuilder.select_resident_messages(messages, 37)

    assert selected == [{2, {:user, "second"}}, {3, {:user, "third"}}]
    assert truncated?
  end

  test "build/1 applies the configured resident byte cap and marks omitted messages" do
    options_server = start_supervised!({Options, name: nil})
    previous_options_server = Process.put(:minga_config_options, options_server)

    on_exit(fn ->
      if is_nil(previous_options_server) do
        Process.delete(:minga_config_options)
      else
        Process.put(:minga_config_options, previous_options_server)
      end
    end)

    session = fake_session_pid()
    panel = synced_panel([{:assistant, "first"}, {:assistant, "second"}])
    uncapped = context(session, panel) |> AgentChatBuilder.build()
    retained = Enum.take(uncapped.resident_messages, -2)

    retained_bytes =
      Enum.reduce(retained, 0, fn message, total ->
        total + AgentChatMessageCodec.resident_entry_size(message)
      end)

    assert :ok = Minga.Config.set(:agent_transcript_resident_max_bytes, retained_bytes)

    capped = context(session, panel) |> AgentChatBuilder.build()

    assert capped.resident_messages == retained
    assert capped.resident_truncated?
  end

  test "build/1 sends connect-provider empty state for first-run no-credential sessions" do
    session = fake_session_pid()

    panel =
      synced_panel([{:system, "Session started", :info}],
        empty_state: :credentials_missing
      )

    model =
      context(session, panel)
      |> AgentChatBuilder.build()

    assert [{_, :system, text}, {_, :system, "Agent UI registry online"}] =
             Enum.map(model.resident_messages, &message_summary/1)

    assert text =~ "Connect a provider"
    assert text =~ "/auth anthropic <key>"
    assert text =~ "/login"
    refute text =~ "Session started"
  end

  test "build/1 sends pick-model empty state for first-run sessions without a model" do
    session = fake_session_pid()
    panel = synced_panel([{:system, "Session started", :info}], empty_state: :no_model)

    model =
      context(session, panel)
      |> AgentChatBuilder.build()

    assert [{_, :system, text}, {_, :system, "Agent UI registry online"}] =
             Enum.map(model.resident_messages, &message_summary/1)

    assert text =~ "Pick a model"
    assert text =~ "/model"
    assert text =~ "SPC a m"
    refute text =~ "Session started"
  end

  test "build/1 keeps normal first-run display for ready sessions" do
    session = fake_session_pid()
    panel = synced_panel([{:system, "Session started", :info}])

    model =
      context(session, panel)
      |> AgentChatBuilder.build()

    assert [{_, :system, "Session started"}, {_, :system, "Agent UI registry online"}] =
             Enum.map(model.resident_messages, &message_summary/1)
  end

  test "build/1 resolves tool calls with clean summaries and inline diff previews" do
    session = fake_session_pid()

    tool_call =
      ToolCall.new("tc-1", "edit_file", %{
        "path" => "lib/app.ex",
        "old_text" => "old",
        "new_text" => "new"
      })

    panel = synced_panel([{:tool_call, tool_call}], styled_messages: [nil])

    model =
      context(session, panel)
      |> AgentChatBuilder.build()

    assert {1, {:tool_call, view}} = List.first(model.resident_messages)
    assert view.name == "edit_file"
    assert view.summary == "lib/app.ex"
    assert view.preview_kind == :diff
    assert "file: lib/app.ex" in view.preview_lines
    assert "-old" in view.preview_lines
    assert "+new" in view.preview_lines
  end

  test "build/1 omits raw inspected preview lines for completed read-only tool calls" do
    session = fake_session_pid()

    read_only_calls = [
      {"read_file", %{"path" => "lib/app.ex"}, "lib/app.ex"},
      {"grep", %{"pattern" => "defmodule", "path" => "lib"}, "defmodule in lib"},
      {"find", %{"name" => "*.ex", "path" => "lib"}, "*.ex in lib"},
      {"list_directory", %{"path" => "lib"}, "lib"}
    ]

    panel =
      read_only_calls
      |> Enum.map(fn {name, args, _summary} ->
        {:tool_call, ToolCall.new("tc-#{name}", name, args) |> ToolCall.complete("ok")}
      end)
      |> synced_panel(styled_messages: List.duplicate(nil, Enum.count(read_only_calls)))

    model =
      context(session, panel)
      |> AgentChatBuilder.build()

    views = for {_id, {:tool_call, view}} <- model.resident_messages, do: view

    assert Enum.map(views, & &1.summary) ==
             Enum.map(read_only_calls, fn {_name, _args, summary} -> summary end)

    assert Enum.all?(views, &(&1.preview_lines == []))
  end

  test "build/1 uses captured write_file previews instead of recomputing current disk state" do
    session = fake_session_pid()
    path = "/tmp/minga-agent-chat-write-preview.txt"

    tool_call =
      ToolCall.new("tc-write", "write_file", %{"path" => path, "content" => "new\n"})
      |> ToolCall.set_preview(ToolApproval.build_file_diff_preview(path, "old\n", "new\n"))
      |> ToolCall.complete("wrote file")

    panel = synced_panel([{:tool_call, tool_call}], styled_messages: [nil])

    model =
      context(session, panel)
      |> AgentChatBuilder.build()

    assert {1, {:tool_call, view}} = List.first(model.resident_messages)
    assert view.name == "write_file"
    assert view.summary == path
    assert view.preview_kind == :diff
    assert "file: #{path}" in view.preview_lines
    assert "-old" in view.preview_lines
    assert "+new" in view.preview_lines
  end

  test "build/1 does not invent write_file transcript previews from current disk state" do
    session = fake_session_pid()
    path = "/tmp/minga-agent-chat-write-preview.txt"

    tool_call =
      ToolCall.new("tc-write", "write_file", %{"path" => path, "content" => "new\n"})
      |> ToolCall.complete("wrote file")

    panel = synced_panel([{:tool_call, tool_call}], styled_messages: [nil])

    model =
      context(session, panel)
      |> AgentChatBuilder.build()

    assert {1, {:tool_call, view}} = List.first(model.resident_messages)
    assert view.name == "write_file"
    assert view.summary == path
    assert view.preview_kind == :target
    assert view.preview_lines == []
  end

  defp message_summary({id, {:assistant, text}}), do: {id, :assistant, text}
  defp message_summary({id, {:system, text, _level}}), do: {id, :system, text}
  defp message_summary({id, {:user, text}}), do: {id, :user, text}
  defp message_summary({id, {kind, _, _}}), do: {id, kind, nil}

  defp synced_panel(messages, opts \\ []) do
    {panel_opts, transcript_opts} =
      Keyword.split(opts, [:scroll, :styled_messages, :styled_fingerprint])

    display = Transcript.display(messages, transcript_opts)

    Panel.new()
    |> Panel.cache_transcript_display(display, Keyword.get(panel_opts, :styled_messages),
      styled_fingerprint: Keyword.get(panel_opts, :styled_fingerprint)
    )
    |> maybe_set_panel_scroll(Keyword.get(panel_opts, :scroll))
  end

  defp maybe_set_panel_scroll(panel, nil), do: panel
  defp maybe_set_panel_scroll(panel, scroll), do: Panel.set_scroll(panel, scroll)

  defp context(session, panel, opts \\ []) do
    tab = Tab.new_agent(1, "Agent")
    {tab_bar, workspace} = TabBar.add_workspace(TabBar.new(tab), "Agent", session)
    tab_bar = TabBar.move_tab_to_workspace(tab_bar, tab.id, workspace.id)
    window = Window.new_agent_chat(1, 24, 80)

    %Context{
      port_manager: self(),
      capabilities: nil,
      theme: Keyword.get(opts, :theme),
      font_registry: nil,
      windows: %Windows{map: %{1 => window}, active: 1},
      layout: nil,
      shell: Traditional,
      shell_state:
        TraditionalState.install_tab_bar(
          TraditionalState.replace_agent(%TraditionalState{}, %AgentState{}),
          tab_bar
        ),
      agent_ui: %UIState{panel: panel},
      viewport: Viewport.new(24, 80),
      editing: VimState.new()
    }
  end

  defp fake_session_pid do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> send(pid, :stop) end)
    pid
  end
end
