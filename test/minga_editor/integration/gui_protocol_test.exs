defmodule Minga.Integration.GUIProtocolTest do
  @moduledoc """
  Integration tests for the BEAM to Swift GUI protocol round-trip.

  Spawns the headless Swift test harness as an Erlang Port, sends encoded
  GUI protocol opcodes, and asserts the harness decoded them correctly by
  checking its JSON output.
  """

  # async: false: spawns the headless Swift test harness as a real OS process via Port.open/2
  use ExUnit.Case, async: false

  alias Minga.Frontend.Adapter.GUI.BreadcrumbEncoder
  alias Minga.Frontend.Adapter.GUI
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.CompletionEncoder
  alias Minga.Frontend.Adapter.GUI.FileTreeEncoder
  alias Minga.Frontend.Adapter.GUI.PickerEncoder
  alias Minga.Frontend.Adapter.GUI.ThemeEncoder
  alias Minga.Frontend.Adapter.GUI.WhichKeyEncoder
  alias Minga.Frontend.Adapter.GUI.TabBarEncoder
  alias Minga.Frontend.Adapter.GUI.StatusBarEncoder
  alias Minga.Frontend.Adapter.GUI.WindowEncoder
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.Completion
  alias Minga.RenderModel.UI.FileTree
  alias Minga.RenderModel.UI.FileTree.Editing
  alias Minga.RenderModel.UI.FileTree.Flags
  alias Minga.RenderModel.UI.FileTree.Row
  alias Minga.RenderModel.UI.EmptyList
  alias Minga.RenderModel.UI.Picker, as: PickerModel
  alias Minga.RenderModel.UI.TabBar
  alias Minga.RenderModel.UI.TabBar.Tab
  alias Minga.RenderModel.UI.StatusBar
  alias Minga.RenderModel.UI.StatusBar.Agent
  alias Minga.RenderModel.UI.StatusBar.Cursor
  alias Minga.RenderModel.UI.StatusBar.Data
  alias Minga.RenderModel.UI.StatusBar.Diagnostics
  alias Minga.RenderModel.UI.StatusBar.File, as: StatusFile
  alias Minga.RenderModel.UI.StatusBar.Git
  alias Minga.RenderModel.UI.StatusBar.Indent
  alias Minga.RenderModel.UI.StatusBar.Language
  alias Minga.RenderModel.UI.StatusBar.Segment
  alias Minga.RenderModel.UI.StatusBar.Selection
  alias Minga.Test.GUIHarness
  alias MingaEditor.RenderModel.UI.BreadcrumbBuilder
  alias MingaEditor.RenderModel.UI.ThemeBuilder

  @harness_path Path.join(:code.priv_dir(:minga), "minga-test-harness")

  @moduletag :swift_harness

  setup_all do
    unless File.exists?(@harness_path) do
      flunk("Test harness not found at #{@harness_path}. Run: mix swift.harness")
    end

    {:ok, harness} = start_supervised({GUIHarness, path: @harness_path})
    %{harness: harness}
  end

  defp round_trip(harness, command, expected_type) do
    GUIHarness.round_trip!(harness, command, expected_type)
  end

  test "command completion round-trips the generation and candidate identities", %{
    harness: harness
  } do
    alias Minga.Frontend.Adapter.GUI.MinibufferEncoder
    alias Minga.RenderModel.UI.Minibuffer
    alias Minga.RenderModel.UI.Minibuffer.Candidate

    model = %Minibuffer{
      visible?: true,
      generation: 0xFFFFFFFE,
      prompt: ":",
      input: "w",
      candidates: [
        %Candidate{id: "write", label: "write", description: "Save the file"},
        %Candidate{id: "wq", label: "wq", description: "Save and quit"}
      ],
      total_candidates: 2
    }

    decoded = round_trip(harness, MinibufferEncoder.encode_command(model), "gui_minibuffer")
    assert decoded["generation"] == model.generation
    assert Enum.map(decoded["candidates"], & &1["id"]) == ["write", "wq"]
  end

  test "timeline round-trips path-bound identities independently of display indices", %{
    harness: harness
  } do
    alias Minga.Frontend.Adapter.GUI.EditTimelineEncoder
    alias Minga.RenderModel.UI.EditTimeline

    model = %EditTimeline{
      visible?: true,
      generation: 0xFFFFFFFD,
      entries: [
        %EditTimeline.Entry{
          entry_id: "file-a/tool-α/0",
          index: 0,
          tool_name: "edit",
          timestamp_delta: 0
        },
        %EditTimeline.Entry{
          entry_id: "file-a/tool-β/1",
          index: 1,
          tool_name: "write",
          timestamp_delta: 25
        }
      ]
    }

    {encoded, _caches} = EditTimelineEncoder.encode(model, %Caches{})
    decoded = round_trip(harness, encoded, "gui_edit_timeline")
    assert decoded["generation"] == model.generation

    assert Enum.map(decoded["entries"], & &1["entry_id"]) ==
             Enum.map(model.entries, & &1.entry_id)
  end

  test "resident approval round-trips its immutable UTF-8 target through the Swift decoder", %{
    harness: harness
  } do
    alias Minga.Frontend.Adapter.GUI.AgentTranscriptEncoder
    alias Minga.RenderModel.UI.AgentChat
    alias Minga.RenderModel.UI.AgentChat.ApprovalView

    session_id = "session/" <> String.duplicate("会", 512)
    request_id = "admitted-request/" <> String.duplicate("é", 1_024)
    tool_call_id = "tool/" <> String.duplicate("🛠", 768)
    message_id = 0xFEDCBA98

    approval = %ApprovalView{
      name: "edit_file",
      summary: "lib/équipe.ex",
      session_id: session_id,
      request_id: request_id,
      tool_call_id: tool_call_id,
      preview_kind: :diff,
      preview_lines: ["file: lib/équipe.ex", "-ancien café", "+新しい 🛠"]
    }

    model = %AgentChat{
      visible?: true,
      transcript_epoch: 37,
      resident_messages: [
        {55, {:user, "Review the proposed change"}},
        {message_id, {:approval_tool_call, approval}}
      ]
    }

    {encoded, _caches} = AgentTranscriptEncoder.encode(model, Caches.new())
    decoded = round_trip(harness, encoded, "gui_agent_transcript")

    assert decoded["mode"] == 0
    assert decoded["epoch"] == 37
    assert decoded["truncated"] == false
    assert decoded["trim_front"] == 0
    assert decoded["base_count"] == 0
    assert decoded["message_ids"] == [55, message_id]

    assert decoded["approvals"] == [
             %{
               "beam_id" => message_id,
               "name" => "edit_file",
               "summary" => "lib/équipe.ex",
               "tool_call_id" => tool_call_id,
               "session_id" => session_id,
               "request_id" => request_id,
               "preview_kind" => 1,
               "preview_lines" => ["file: lib/équipe.ex", "-ancien café", "+新しい 🛠"]
             }
           ]
  end

  describe "resident semantic production encoder round-trip" do
    test "keyframe preserves positive row revision and all absolute semantic layers", %{
      harness: harness
    } do
      semantics = resident_semantic_fixture()

      decoded =
        round_trip(
          harness,
          WindowEncoder.encode_resident_semantics(semantics),
          "gui_resident_semantics"
        )

      assert decoded["mode"] == 0
      assert decoded["base_revision"] == 0
      assert decoded["row_revision"] == 7
      assert decoded["row_count"] == 120
      assert decoded["first_row_id"] == "11"
      assert decoded["last_row_id"] == "22"
      assert decoded["cursor"] == %{"eligible" => true, "row" => 88, "col" => 5}
      assert decoded["cursorline"] == %{"row" => 88, "bg" => 0x223344}
      assert decoded["selection"]["start_row"] == 76
      assert decoded["selection"]["end_row"] == 88
      assert decoded["guide_cols"] == [2, 4]

      assert decoded["guide_replacements"] == [
               %{
                 "start" => 0,
                 "end" => 120,
                 "runs" => [%{"start" => 0, "end" => 120, "level" => 2}]
               }
             ]

      assert decoded["diagnostic_mode"] == "replace"

      assert decoded["diagnostics"] == [
               %{
                 "start_row" => 84,
                 "start_col" => 8,
                 "end_row" => 85,
                 "end_col" => 18,
                 "severity" => 0
               }
             ]

      assert decoded["annotation_mode"] == "replace"
      assert hd(decoded["annotations"])["text"] == "resident αβ"
    end

    test "delta round-trips diagnostic and annotation ranges after row splices", %{
      harness: harness
    } do
      alias Minga.RenderModel.Window.ResidentSemantics
      semantics = resident_semantic_fixture()

      header = %{
        semantics.header
        | mode: :delta,
          base_revision: 3,
          revision: 4,
          target_row_revision: 8
      }

      semantics = %{
        semantics
        | header: header,
          row_splices: [
            %ResidentSemantics.RowSplice{start_row: 90, delete_count: 1, insert_count: 1}
          ],
          guide_replacements: [],
          diagnostics:
            {:replace_ranges,
             [%ResidentSemantics.DiagnosticReplace{start_row: 84, end_row: 85, diagnostics: []}]},
          annotations:
            {:replace_ranges,
             [%ResidentSemantics.AnnotationReplace{start_row: 82, end_row: 83, annotations: []}]}
      }

      decoded =
        round_trip(
          harness,
          WindowEncoder.encode_resident_semantics(semantics),
          "gui_resident_semantics"
        )

      assert decoded["mode"] == 1
      assert decoded["base_revision"] == 3
      assert decoded["row_revision"] == 8
      assert decoded["row_splices"] == [%{"start" => 90, "delete" => 1, "insert" => 1}]
      assert decoded["diagnostic_mode"] == "ranges"
      assert decoded["diagnostic_ranges"] == [%{"start" => 84, "end" => 85, "count" => 0}]
      assert decoded["annotation_mode"] == "ranges"
      assert decoded["annotation_ranges"] == [%{"start" => 82, "end" => 83, "count" => 0}]
    end
  end

  defp resident_semantic_fixture do
    alias Minga.RenderModel.Window.{Annotation, DiagnosticRange, ResidentSemantics}

    %ResidentSemantics{
      header: %ResidentSemantics.Header{
        window_id: 1,
        content_epoch: 42,
        mode: :keyframe,
        base_revision: 0,
        revision: 3,
        target_row_revision: 7,
        row_count: 120,
        first_row_id: 11,
        last_row_id: 22
      },
      cursor: %ResidentSemantics.Cursor{eligible: true, row: 88, col: 5},
      cursorline: %ResidentSemantics.Cursorline{row: 88, bg_rgb: 0x223344},
      selection: %ResidentSemantics.Selection{
        type: :char,
        start_row: 76,
        start_col: 0,
        end_row: 88,
        end_col: 6
      },
      tab_width: 2,
      active_guide_col: 2,
      guide_cols: [2, 4],
      row_splices: [],
      guide_replacements: [
        %ResidentSemantics.GuideReplace{
          start_row: 0,
          end_row: 120,
          runs: [%ResidentSemantics.GuideRun{start_row: 0, end_row: 120, level: 2}]
        }
      ],
      diagnostics:
        {:replace,
         [
           %DiagnosticRange{
             start_row: 84,
             start_col: 8,
             end_row: 85,
             end_col: 18,
             severity: :error
           }
         ]},
      annotations:
        {:replace,
         [
           %Annotation{
             row: 82,
             kind: :inline_pill,
             fg: 0xFFFFFF,
             bg: 0x334455,
             text: "resident αβ"
           }
         ]}
    }
  end

  # Encodes agent-chat chrome through the core semantic encoder, accepting the
  # data-map shape these round-trip tests use.
  defp encode_gui_agent_chat(data) do
    alias Minga.Frontend.Adapter.GUI.AgentChatEncoder
    alias Minga.Frontend.Adapter.GUI.Caches
    alias Minga.RenderModel.UI.AgentChat

    model =
      case data do
        %{visible: false} ->
          %AgentChat{visible?: false}

        %{visible: true} = d ->
          %AgentChat{
            visible?: true,
            lifecycle: Map.get(d, :lifecycle, :conversation),
            lifecycle_headline: Map.get(d, :lifecycle_headline, ""),
            draft_note: Map.get(d, :draft_note, ""),
            status: Map.get(d, :status, :idle),
            model_name: Map.get(d, :model, ""),
            thinking_level: Map.get(d, :thinking_level, ""),
            prompt: Map.get(d, :prompt, ""),
            draft_attachment_count: Map.get(d, :draft_attachment_count, 0),
            draft_attachment_offer: Map.get(d, :draft_attachment_offer),
            pending_question: Map.get(d, :pending_question),
            stop_target: Map.get(d, :stop_target),
            continue_target: Map.get(d, :continue_target)
          }
      end

    {binary, _caches} = AgentChatEncoder.encode(model, Caches.new())
    binary
  end

  defp encode_gui_tasks_drawer(model) do
    {binary, _caches} =
      Minga.Frontend.Adapter.GUI.TasksDrawerEncoder.encode(
        model,
        Minga.Frontend.Adapter.GUI.Caches.new()
      )

    binary
  end

  defp encode_gui_agent_help(model) do
    {binary, _caches} =
      Minga.Frontend.Adapter.GUI.AgentHelpEncoder.encode(
        model,
        Minga.Frontend.Adapter.GUI.Caches.new()
      )

    binary
  end

  describe "GUI chrome opcode round-trip" do
    test "Agent availability, its reason and its remedy decode independently of the existing draft",
         %{harness: harness} do
      retry = %Minga.RenderModel.UI.AgentChat.StartRemedy{
        kind: :retry,
        label: "Retry",
        key_hint: "r"
      }

      setup = %Minga.RenderModel.UI.AgentChat.StartRemedy{
        kind: :set_up_provider,
        label: "Set up provider",
        key_hint: "s"
      }

      for {lifecycle, label, reason, remedy, action, key} <- [
            {:conversation, "conversation", "", 0, "", ""},
            {:starting, "starting", "", 0, "", ""},
            {{:failed, "Could not connect to café.", retry}, "failed",
             "Could not connect to café.", 1, "Retry", "r"},
            {{:failed, "No Agent provider is set up yet.", setup}, "failed",
             "No Agent provider is set up yet.", 2, "Set up provider", "s"},
            {{:failed, "The composer is unavailable.", nil}, "failed",
             "The composer is unavailable.", 0, "", ""},
            {:unavailable, "unavailable", "", 0, "", ""}
          ] do
        command =
          encode_gui_agent_chat(%{
            visible: true,
            prompt: "unfinished",
            lifecycle: lifecycle,
            lifecycle_headline: "Agent héadline",
            draft_note: "Your draft is saved. SPC a n starts a new session."
          })

        decoded = round_trip(harness, command, "gui_agent_chat")

        assert %{
                 "visible" => true,
                 "prompt" => "unfinished",
                 "lifecycle" => ^label,
                 "lifecycle_reason" => ^reason,
                 "lifecycle_remedy" => ^remedy,
                 "lifecycle_action_label" => ^action,
                 "lifecycle_key_hint" => ^key
               } = decoded

        # A live conversation sends no lifecycle section, so no notice copy.
        {headline, note} =
          if lifecycle == :conversation,
            do: {"", ""},
            else: {"Agent héadline", "Your draft is saved. SPC a n starts a new session."}

        assert %{"lifecycle_headline" => ^headline, "lifecycle_note" => ^note} = decoded
      end
    end

    test "a failed start's needs-you status decodes as its own status", %{harness: harness} do
      command = encode_gui_agent_chat(%{visible: true, status: :needs_you})
      assert %{"status" => 6} = round_trip(harness, command, "gui_agent_chat")
    end

    test "Agent chat reports saved attachments without changing the draft text", %{
      harness: harness
    } do
      for {count, offer} <- [{2, 90_000_000_000}, {0, 90_000_000_001}, {0, nil}] do
        wire_offer = offer || 0

        cmd =
          encode_gui_agent_chat(%{
            visible: true,
            prompt: "Keep this draft",
            draft_attachment_count: count,
            draft_attachment_offer: offer
          })

        assert %{
                 "visible" => true,
                 "prompt" => "Keep this draft",
                 "draft_attachment_count" => ^count,
                 "draft_attachment_offer" => ^wire_offer
               } =
                 round_trip(harness, cmd, "gui_agent_chat")
      end
    end

    test "Agent chat carries the maximal question without overwriting the draft", %{
      harness: harness
    } do
      draft = %{visible: true, prompt: "Keep this draft"}
      offer = 90_000_000_001
      question = String.duplicate("é", 2_048)
      plain = encode_gui_agent_chat(draft)
      pending = encode_gui_agent_chat(Map.put(draft, :pending_question, {offer, question}))

      assert byte_size(pending) - byte_size(plain) == 4_109

      assert %{
               "question_offer" => ^offer,
               "question_prompt" => ^question,
               "prompt" => "Keep this draft"
             } =
               round_trip(harness, pending, "gui_agent_chat")

      assert %{"question_offer" => 0, "question_prompt" => ""} =
               round_trip(harness, plain, "gui_agent_chat")
    end

    test "Agent chat distinguishes Stop and Continue for the displayed turn", %{harness: harness} do
      draft = %{visible: true, prompt: "Keep this draft"}
      working = Map.merge(draft, %{status: :thinking, stop_target: {"session-a", "turn-b"}})
      stopped = Map.merge(draft, %{status: :stopped, continue_target: {"session-a", "turn-b"}})

      assert %{
               "stop_session_id" => "session-a",
               "stop_request_id" => "turn-b",
               "continue_request_id" => "",
               "prompt" => "Keep this draft"
             } = round_trip(harness, encode_gui_agent_chat(working), "gui_agent_chat")

      assert %{
               "continue_session_id" => "session-a",
               "continue_request_id" => "turn-b",
               "stop_request_id" => "",
               "prompt" => "Keep this draft"
             } = round_trip(harness, encode_gui_agent_chat(stopped), "gui_agent_chat")

      assert %{"stop_request_id" => "", "continue_request_id" => ""} =
               round_trip(harness, encode_gui_agent_chat(draft), "gui_agent_chat")
    end

    test "gui_theme encodes and decodes correctly", %{harness: harness} do
      model =
        :doom_one
        |> MingaEditor.UI.Theme.get!()
        |> ThemeBuilder.build()

      {cmd, _caches} = ThemeEncoder.encode(model, Caches.new())
      assert cmd != nil

      decoded = round_trip(harness, cmd, "gui_theme")

      assert decoded["type"] == "gui_theme"
      assert is_list(decoded["slots"])
      assert Enum.count(decoded["slots"]) > 20

      # Verify a specific slot (editor_bg = slot 0x01)
      editor_bg_slot = Enum.find(decoded["slots"], fn s -> s["slot"] == 1 end)
      assert editor_bg_slot != nil
      assert is_integer(editor_bg_slot["r"])
      assert is_integer(editor_bg_slot["g"])
      assert is_integer(editor_bg_slot["b"])
    end

    test "gui_tab_bar encodes and decodes correctly", %{harness: harness} do
      model = %TabBar{
        visible?: true,
        active_tab_id: 1,
        tabs: [
          %Tab{id: 1, workspace_id: 1, kind: :file, label: "editor.ex", icon: ""},
          %Tab{
            id: 2,
            workspace_id: 2,
            kind: :agent,
            label: "Agent",
            icon: "󰚩",
            agent_status: :thinking
          }
        ]
      }

      cmd = TabBarEncoder.encode_command(model)
      decoded = round_trip(harness, cmd, "gui_tab_bar")

      assert decoded["type"] == "gui_tab_bar"
      assert decoded["active_index"] == 0
      assert Enum.count(decoded["tabs"]) == 2

      [t1, t2] = decoded["tabs"]
      assert t1["id"] == 1
      assert t1["label"] == "editor.ex"
      assert t1["is_active"] == true
      assert t1["is_agent"] == false
      assert t2["id"] == 2
      assert t2["is_agent"] == true
      assert t2["agent_status"] == 1
    end

    test "gui_breadcrumb encodes and decodes correctly", %{harness: harness} do
      model =
        BreadcrumbBuilder.build("/home/user/project/lib/foo.ex", "/home/user/project")

      {cmd, _caches} = BreadcrumbEncoder.encode(model, Caches.new())

      decoded = round_trip(harness, cmd, "gui_breadcrumb")

      assert decoded["type"] == "gui_breadcrumb"
      assert decoded["segments"] == ["lib", "foo.ex"]
    end

    test "a notice's next steps round-trip after the message, and a plain message carries none",
         %{
           harness: harness
         } do
      action = %EmptyList.Action{id: "agent_inline_ask", key: "SPC a ?", label: "ask Minga"}

      model = %StatusBar{
        content_kind: :buffer,
        data: %Data{mode: :normal, message: "No code actions at 3:7", message_actions: [action]}
      }

      decoded = round_trip(harness, StatusBarEncoder.encode_command(model), "gui_status_bar")

      assert decoded["message"] == "No code actions at 3:7"

      assert decoded["message_actions"] == [
               %{"id" => "agent_inline_ask", "key" => "SPC a ?", "label" => "ask Minga"}
             ]

      plain = %{model | data: %{model.data | message_actions: []}}

      assert round_trip(harness, StatusBarEncoder.encode_command(plain), "gui_status_bar")[
               "message_actions"
             ] == []
    end

    test "gui_status_bar buffer variant encodes and decodes correctly", %{harness: harness} do
      model = %StatusBar{
        content_kind: :buffer,
        data: %Data{
          mode: :normal,
          safe_mode?: true,
          dirty?: true,
          cursor: %Cursor{line: 41, col: 9, line_count: 200},
          diagnostics: %Diagnostics{
            counts: {2, 4, 1, 0},
            hint: "✖ undefined function foo/0 [ElixirLS]"
          },
          language: %Language{lsp_status: :ready, parser_status: :available},
          git: %Git{branch: "main", diff_summary: {5, 3, 1}},
          file: %StatusFile{name: "foo.ex", filetype: :elixir, icon: "", icon_color: 0xA074C4},
          message: "Wrote foo.ex",
          recording: {true, "q"},
          indent: %Indent{type: :spaces, size: 2},
          selection: %Selection{mode: :chars, size: 42},
          agent: %Agent{agent_status: :thinking, active_tool_name: "read_file"},
          modeline_segments: %{
            left: [
              %Segment{
                id: :mode,
                text: "NORMAL",
                fg: 0xBBC2CF,
                bg: 0x51AFEF,
                style: [bold: true]
              },
              %Segment{
                id: :minga,
                text: "Minga working 2/3",
                fg: 0xC678DD,
                bg: 0x282C34,
                target: :toggle_agent_split,
                drop: 5,
                compact: "2/3",
                state: :working,
                key: "SPC a v",
                label: "Minga is working, step 2 of 3"
              }
            ],
            right: [
              %Segment{
                id: :filetype,
                text: "Elixir",
                fg: 0xC678DD,
                bg: 0x282C34,
                target: :set_language,
                drop: 2
              }
            ]
          }
        }
      }

      cmd = StatusBarEncoder.encode_command(model)
      decoded = round_trip(harness, cmd, "gui_status_bar")

      assert decoded["type"] == "gui_status_bar"
      # content_kind 0 = buffer
      assert decoded["content_kind"] == 0
      assert decoded["mode"] == 0
      assert decoded["safe_mode"] == true
      # 1-indexed in the wire format (cursor_line is 0-indexed internally, +1 encoded)
      assert decoded["cursor_line"] == 42
      assert decoded["cursor_col"] == 10
      assert decoded["line_count"] == 200
      assert decoded["git_branch"] == "main"
      assert decoded["message"] == "Wrote foo.ex"
      assert decoded["filetype"] == "elixir"
      # Extended fields (TUI modeline parity)
      assert decoded["info_count"] == 1
      assert decoded["hint_count"] == 0
      assert decoded["macro_recording"] == 17
      assert decoded["parser_status"] == 0
      assert decoded["agent_status"] == 1
      assert decoded["active_tool_name"] == "read_file"
      assert decoded["git_added"] == 5
      assert decoded["git_modified"] == 3
      assert decoded["git_deleted"] == 1
      assert decoded["filename"] == "foo.ex"
      assert decoded["diagnostic_hint"] == "✖ undefined function foo/0 [ElixirLS]"
      assert decoded["indent_type"] == 0
      assert decoded["indent_size"] == 2

      assert [
               %{
                 "name" => "mode",
                 "text" => "NORMAL",
                 "attrs" => 1,
                 "command" => "",
                 "drop" => 0
               },
               %{
                 "name" => "minga",
                 "text" => "Minga working 2/3",
                 "command" => "toggle_agent_split",
                 "drop" => 5,
                 "compact" => "2/3",
                 "state" => "working",
                 "key" => "SPC a v",
                 "label" => "Minga is working, step 2 of 3"
               }
             ] = decoded["modeline_left_segments"]

      assert [%{"text" => "Elixir", "command" => "set_language", "drop" => 2, "compact" => nil}] =
               decoded["modeline_right_segments"]

      assert decoded["selection_mode"] == 1
      assert decoded["selection_size"] == 42
    end

    test "conflict status preserves the exact action offer in Swift", %{harness: harness} do
      review = %StatusBar.Review{
        path: "/project/é/shared.ex",
        freshness: :stale,
        conflict_index: 2,
        keep_mine_key: "Cmd+Backspace",
        use_agent_key: "Cmd+Enter",
        generation: 43,
        item_id: "review:hunk-é/2"
      }

      model = %StatusBar{content_kind: :agent, data: %Data{}, review: review}
      decoded = round_trip(harness, StatusBarEncoder.encode_command(model), "gui_status_bar")

      assert decoded["review"] == %{
               "path" => "/project/é/shared.ex",
               "freshness" => 1,
               "conflict_index" => 2,
               "keep_mine_key" => "Cmd+Backspace",
               "use_agent_key" => "Cmd+Enter",
               "generation" => 43,
               "item_id" => "review:hunk-é/2"
             }
    end

    test "gui_status_bar agent variant encodes and decodes correctly", %{harness: harness} do
      model = %StatusBar{
        content_kind: :agent,
        data: %Data{
          mode: :normal,
          safe_mode?: true,
          dirty?: true,
          cursor: %Cursor{line: 10, col: 5, line_count: 100},
          diagnostics: %Diagnostics{
            counts: {1, 2, 0, 1},
            hint: "⚠ unused variable [ElixirLS]"
          },
          language: %Language{lsp_status: :ready, parser_status: :available},
          git: %Git{branch: "feat/agent", diff_summary: {3, 2, 0}},
          file: %StatusFile{name: "editor.ex", filetype: :elixir, icon: "", icon_color: 0xA074C4},
          recording: false,
          indent: %Indent{type: :tabs, size: 4},
          selection: %Selection{mode: :lines, size: 3},
          agent: %Agent{
            model_name: "claude-3-5-sonnet",
            session_status: :thinking,
            message_count: 7,
            agent_status: :thinking,
            active_tool_name: "shell"
          }
        }
      }

      cmd = StatusBarEncoder.encode_command(model)
      decoded = round_trip(harness, cmd, "gui_status_bar")

      assert decoded["type"] == "gui_status_bar"
      # content_kind 1 = agent
      assert decoded["content_kind"] == 1
      assert decoded["mode"] == 0
      assert decoded["safe_mode"] == true
      assert decoded["model_name"] == "claude-3-5-sonnet"
      assert decoded["message_count"] == 7
      # Background buffer fields are now populated
      assert decoded["cursor_line"] == 11
      assert decoded["cursor_col"] == 6
      assert decoded["line_count"] == 100
      assert decoded["git_branch"] == "feat/agent"
      assert decoded["filetype"] == "elixir"
      assert decoded["error_count"] == 1
      assert decoded["warning_count"] == 2
      assert decoded["hint_count"] == 1
      assert decoded["active_tool_name"] == "shell"
      assert decoded["git_added"] == 3
      assert decoded["git_modified"] == 2
      assert decoded["git_deleted"] == 0
      assert decoded["filename"] == "editor.ex"
      assert decoded["diagnostic_hint"] == "⚠ unused variable [ElixirLS]"
      assert decoded["indent_type"] == 1
      assert decoded["indent_size"] == 4
      assert decoded["selection_mode"] == 2
      assert decoded["selection_size"] == 3
    end

    test "gui_agent_help groups round-trip independently of chat", %{harness: harness} do
      model = %Minga.RenderModel.UI.AgentHelp{
        visible?: true,
        groups: [
          {"Navigation", [{"j / k", "Scroll down / up"}, {"gg / G", "Top / bottom"}]},
          {"Copy", [{"y", "Copy code block"}]}
        ]
      }

      cmd = encode_gui_agent_help(model)
      decoded = round_trip(harness, cmd, "gui_agent_help")

      assert decoded["type"] == "gui_agent_help"
      assert decoded["visible"] == true
      [nav, copy] = decoded["groups"]
      assert nav["title"] == "Navigation"
      assert Enum.count(nav["bindings"]) == 2

      [b1, b2] = nav["bindings"]
      assert b1["key"] == "j / k"
      assert b1["description"] == "Scroll down / up"
      assert b2["key"] == "gg / G"
      assert b2["description"] == "Top / bottom"

      assert copy["title"] == "Copy"
      assert Enum.count(copy["bindings"]) == 1
      assert hd(copy["bindings"])["key"] == "y"
    end

    test "gui_tasks_drawer rows, states, actions and counts round-trip", %{harness: harness} do
      alias Minga.RenderModel.UI.TasksDrawer
      alias Minga.RenderModel.UI.TasksDrawer.Row

      model = %TasksDrawer{
        visible?: true,
        focused?: true,
        note: "Messages hidden · q returns",
        counts: [working: 2, needs_you: 1],
        hints: [{"j/k", "move"}, {"q", "close"}],
        rows: [
          %Row{
            id: "t3",
            state: :needs_you,
            title: "Add tests",
            words: "Needs you · wants to change a file",
            age: "2m",
            detail: ["Create test/a_test.exs +86"],
            actions: [{"y", "Approve once"}, {"n", "Deny"}],
            selected?: true
          },
          %Row{
            id: "t1",
            state: :working,
            title: "Plan limit",
            words: "Running edit_file",
            age: "4m"
          },
          %Row{
            id: "t1.s1",
            depth: 1,
            last?: true,
            state: :working,
            title: "Fact-check",
            words: "Working"
          }
        ]
      }

      decoded = round_trip(harness, encode_gui_tasks_drawer(model), "gui_tasks_drawer")

      assert decoded["visible"] and decoded["focused"]
      assert decoded["name"] == "*minga-tasks*"
      assert decoded["note"] == "Messages hidden · q returns"

      assert decoded["counts"] == [
               %{"state" => "working", "count" => 2},
               %{"state" => "needs_you", "count" => 1}
             ]

      [asking, working, subagent] = decoded["rows"]
      assert asking["selected"] and asking["state"] == "needs_you"
      assert asking["detail"] == ["Create test/a_test.exs +86"]

      assert asking["actions"] == [
               %{"key" => "y", "label" => "Approve once"},
               %{"key" => "n", "label" => "Deny"}
             ]

      refute working["selected"]
      assert subagent["depth"] == 1 and subagent["last"] and subagent["id"] == "t1.s1"
    end

    test "gui_tasks_drawer carries its empty state only when it has no tasks", %{harness: harness} do
      alias Minga.RenderModel.UI.EmptyList

      empty = %EmptyList{
        title: "No one's at the table yet.",
        why: "Give Minga a task.",
        selected: 1,
        actions: [
          %EmptyList.Action{id: "agent_new_task", key: "c", label: "New task"},
          %EmptyList.Action{id: "agent_session_history", key: "SPC a S h", label: "Resume"}
        ]
      }

      decoded =
        round_trip(
          harness,
          encode_gui_tasks_drawer(%Minga.RenderModel.UI.TasksDrawer{
            visible?: true,
            empty: empty
          }),
          "gui_tasks_drawer"
        )

      assert decoded["empty"] == %{
               "title" => "No one's at the table yet.",
               "why" => "Give Minga a task.",
               "selected" => 1,
               "actions" => [
                 %{"id" => "agent_new_task", "key" => "c", "label" => "New task"},
                 %{"id" => "agent_session_history", "key" => "SPC a S h", "label" => "Resume"}
               ]
             }

      with_tasks =
        round_trip(
          harness,
          encode_gui_tasks_drawer(%Minga.RenderModel.UI.TasksDrawer{visible?: true}),
          "gui_tasks_drawer"
        )

      assert with_tasks["empty"] == nil
    end

    test "gui_tasks_drawer hidden frame clears the drawer", %{harness: harness} do
      decoded =
        round_trip(
          harness,
          encode_gui_tasks_drawer(%Minga.RenderModel.UI.TasksDrawer{}),
          "gui_tasks_drawer"
        )

      refute decoded["visible"]
      assert decoded["rows"] == []
    end

    test "gui_agent_help hidden frame clears the Help presentation", %{harness: harness} do
      cmd = encode_gui_agent_help(%Minga.RenderModel.UI.AgentHelp{})
      decoded = round_trip(harness, cmd, "gui_agent_help")

      assert decoded["type"] == "gui_agent_help"
      assert decoded["visible"] == false
      assert decoded["groups"] == []
    end
  end

  describe "gui_gutter_separator" do
    test "round-trips gutter separator col and color", %{harness: harness} do
      cmd = <<Opcodes.gui_gutter_sep(), 4::16, 0x3F, 0x44, 0x4A>>
      decoded = round_trip(harness, cmd, "gui_gutter_separator")

      assert decoded["type"] == "gui_gutter_separator"
      assert decoded["col"] == 4
      assert decoded["r"] == 0x3F
      assert decoded["g"] == 0x44
      assert decoded["b"] == 0x4A
    end
  end

  describe "hidden GUI chrome commands" do
    test "round-trip visible false for hidden overlays", %{harness: harness} do
      alias Minga.Frontend.Adapter.GUI.BottomPanelEncoder
      alias Minga.Frontend.Adapter.GUI.Caches
      alias Minga.RenderModel.UI.BottomPanel

      {bottom_panel_cmd, _caches} =
        BottomPanelEncoder.encode(%BottomPanel{visible?: false}, Caches.new())

      {which_key_cmd, _caches} =
        WhichKeyEncoder.encode(%Minga.RenderModel.UI.WhichKey{visible: false}, Caches.new())

      cases = [
        {"gui_agent_chat", encode_gui_agent_chat(%{visible: false})},
        {"gui_completion", CompletionEncoder.encode_command(%Completion{})},
        {"gui_which_key", which_key_cmd},
        {"gui_picker", <<Opcodes.gui_picker(), 0::8>>},
        {"gui_bottom_panel", bottom_panel_cmd}
      ]

      for {type, command} <- cases do
        decoded = round_trip(harness, command, type)

        assert decoded["type"] == type
        assert decoded["visible"] == false
      end
    end
  end

  describe "gui_gutter" do
    test "round-trips gutter with entries", %{harness: harness} do
      alias Minga.RenderModel.Window
      alias Minga.RenderModel.Window.Gutter
      alias Minga.RenderModel.Window.GutterEntry

      model = %Window{
        window_id: 1,
        content_kind: :buffer,
        rect: {0, 0, 80, 24},
        cursor_row: 0,
        cursor_col: 0,
        cursor_shape: :block,
        rows: [],
        gutter: %Gutter{
          window_id: 1,
          content_row: 0,
          content_col: 5,
          content_height: 24,
          content_width: 80,
          is_active: true,
          cursor_line: 10,
          line_number_style: :hybrid,
          line_number_width: 4,
          sign_col_width: 1,
          entries: [
            %GutterEntry{buf_line: 8, display_type: :normal, sign_type: :git_added},
            %GutterEntry{buf_line: 9, display_type: :fold_start, sign_type: :none},
            %GutterEntry{buf_line: 10, display_type: :wrap_continuation, sign_type: :diag_error}
          ]
        }
      }

      cmd =
        Enum.find(WindowEncoder.encode(model), fn <<opcode::8, _rest::binary>> ->
          opcode == Opcodes.gui_gutter()
        end)

      decoded = round_trip(harness, cmd, "gui_gutter")

      assert decoded["type"] == "gui_gutter"
      assert decoded["window_id"] == 1
      assert decoded["content_col"] == 5
      assert decoded["content_height"] == 24
      assert decoded["content_width"] == 80
      assert decoded["is_active"] == true
      assert decoded["cursor_line"] == 10
      assert decoded["line_number_style"] == 0
      assert decoded["line_number_width"] == 4
      assert decoded["sign_col_width"] == 1
      assert Enum.count(decoded["entries"]) == 3

      [e1, e2, e3] = decoded["entries"]
      assert e1["buf_line"] == 8
      assert e1["display_type"] == 0
      assert e1["sign_type"] == 1
      assert e2["display_type"] == 1
      assert e2["fold_end_line"] == nil
      assert e3["display_type"] == 3
      assert e3["sign_type"] == 4
    end

    test "adapter resident gutter replace, retain, and clear round-trip through Swift", %{
      harness: harness
    } do
      alias Minga.RenderModel.Window.Gutter.ResidentRows
      alias Minga.RenderModel.Window.GutterEntry

      model =
        resident_window(300, 7, [
          %GutterEntry{buf_line: 120, display_type: :normal, sign_type: :diag_error}
        ])

      {commands, caches} = GUI.encode_windows([model], Caches.new())
      replaced = round_trip(harness, find_command(commands, Opcodes.gui_gutter()), "gui_gutter")

      assert replaced["content_epoch"] == 7
      assert replaced["line_count"] == 300
      assert replaced["retain_overrides"] == false
      assert [%{"buf_line" => 120, "sign_type" => 4}] = replaced["entries"]

      caches = Caches.acknowledge_pending_window_deltas(caches)
      moved = %{model | gutter: %{model.gutter | cursor_line: 50}}
      {commands, caches} = GUI.encode_windows([moved], caches)
      retained = round_trip(harness, find_command(commands, Opcodes.gui_gutter()), "gui_gutter")

      assert retained["content_epoch"] == 7
      assert retained["line_count"] == 300
      assert retained["retain_overrides"] == true
      assert retained["entries"] == []

      cleared = %{
        moved
        | gutter: %{
            moved.gutter
            | entries: %ResidentRows{content_epoch: 7, line_count: 300, overrides: []}
          }
      }

      {commands, _caches} = GUI.encode_windows([cleared], caches)
      empty = round_trip(harness, find_command(commands, Opcodes.gui_gutter()), "gui_gutter")

      assert empty["content_epoch"] == 7
      assert empty["line_count"] == 300
      assert empty["retain_overrides"] == false
      assert empty["entries"] == []

      :ok
    end

    test "adapter resident gutter chunks all sparse overrides through Swift", %{harness: harness} do
      alias Minga.RenderModel.Window.GutterEntry

      overrides =
        for line <- 0..6_999,
            do: %GutterEntry{buf_line: line, display_type: :normal, sign_type: :git_added}

      {commands, _caches} =
        GUI.encode_windows([resident_window(7_000, 9, overrides)], Caches.new())

      decoded = round_trip(harness, find_command(commands, Opcodes.gui_gutter()), "gui_gutter")

      assert decoded["content_epoch"] == 9
      assert decoded["line_count"] == 7_000
      assert decoded["retain_overrides"] == false
      assert Enum.map(decoded["entries"], & &1["buf_line"]) == Enum.to_list(0..6_999)
    end
  end

  describe "gui_completion visible" do
    test "round-trips visible completion with items", %{harness: harness} do
      comp = %Minga.Editing.Completion{
        items: [],
        filtered: [
          %{
            label: "def",
            kind: :keyword,
            insert_text: "def",
            filter_text: "def",
            detail: "keyword",
            documentation: "",
            sort_text: "def",
            text_edit: nil,
            additional_text_edits: [],
            deprecated: false,
            preselect: false,
            data: nil,
            commit_characters: []
          },
          %{
            label: "defmodule",
            kind: :keyword,
            insert_text: "defmodule",
            filter_text: "defmodule",
            detail: "keyword",
            documentation: "",
            sort_text: "defmodule",
            text_edit: nil,
            additional_text_edits: [],
            deprecated: false,
            preselect: false,
            data: nil,
            commit_characters: []
          }
        ],
        selected: 0,
        trigger_position: {5, 0},
        max_visible: 10
      }

      {visible_items, selected_offset} = Minga.Editing.Completion.visible_items(comp)

      model = %Completion{
        visible?: true,
        generation: 42,
        cursor_row: 5,
        cursor_col: 0,
        selected_offset: selected_offset,
        selected_item_id: "def-id",
        documentation: "Defines a function.",
        total_count: 12,
        matched_count: 2,
        incomplete?: true,
        items:
          Enum.with_index(visible_items, fn item, index ->
            %Completion.Item{
              id: if(index == 0, do: "def-id", else: "defmodule-id"),
              source: "elixir-ls",
              kind: item.kind,
              label: item.label,
              detail: item.detail || "",
              match_ranges: [%{start: 0, length: 3}]
            }
          end)
      }

      cmd = CompletionEncoder.encode_command(model)
      decoded = round_trip(harness, cmd, "gui_completion")

      assert decoded["type"] == "gui_completion"
      assert decoded["visible"] == true
      assert decoded["anchor_row"] == 5
      assert decoded["anchor_col"] == 0
      assert decoded["selected_index"] == 0
      assert decoded["selected_item_id"] == "def-id"
      assert Enum.count(decoded["items"]) == 2
      first = hd(decoded["items"])
      assert first["label"] == "def"
      assert first["id"] == "def-id"
      assert first["source"] == "elixir-ls"
      assert first["match_ranges"] == [%{"start" => 0, "length" => 3}]
      assert decoded["documentation"] == "Defines a function."
      assert decoded["total_count"] == 12
      assert decoded["matched_count"] == 2
      assert decoded["incomplete"] == true
      assert decoded["generation"] == 42
    end
  end

  describe "gui_menu_bar" do
    test "round-trips the whole default leader keymap, with the Search, Code and Git groups", %{
      harness: harness
    } do
      alias Minga.Frontend.Adapter.GUI.MenuBarEncoder
      alias Minga.RenderModel.UI.ConfigState

      items =
        MingaEditor.RenderModel.UI.LeaderMenuBuilder.build(Minga.Keymap.Defaults.leader_trie())

      assert length(items) > 50

      {cmd, _caches} =
        MenuBarEncoder.encode(%ConfigState{options: [], leader_menu: items}, Caches.new())

      decoded = round_trip(harness, cmd, "gui_menu_bar")

      assert decoded["type"] == "gui_menu_bar"
      assert length(decoded["items"]) == length(items)

      groups =
        for %{"kind" => 1, "path" => path, "label" => label} <- decoded["items"],
            into: %{},
            do: {path, label}

      assert groups["s"] == "Search"
      assert groups["c"] == "Code"

      assert %{"command" => "save", "platform_key" => "⌘S"} =
               Enum.find(decoded["items"], &(&1["path"] == "f s"))
    end
  end

  describe "gui_which_key visible" do
    test "round-trips the panel: path, breadcrumb, count and tone, hints and entries", %{
      harness: harness
    } do
      model = %Minga.RenderModel.UI.WhichKey{
        visible: true,
        path: "SPC a",
        breadcrumb: [
          %{key: "SPC", label: "", path: "SPC"},
          %{key: "a", label: "Minga", path: "SPC a"}
        ],
        count: %{text: "· 1 needs you", tone: :needs_you},
        hints: [%{key: "⌫", label: "back"}, %{key: "esc", label: "close"}],
        entries: [
          %{
            key: "s",
            codepoint: ?s,
            modifiers: 0,
            label: "Stop",
            kind: :command,
            section: "Tasks",
            count: %{text: "", tone: :muted},
            platform_key: "⌘."
          },
          %{
            key: "q",
            codepoint: ?q,
            modifiers: 0,
            label: "Queue ›",
            kind: :group,
            section: "Conversation",
            count: %{text: "· 2 errors", tone: :error},
            platform_key: ""
          }
        ]
      }

      {cmd, _caches} = WhichKeyEncoder.encode(model, Caches.new())
      decoded = round_trip(harness, cmd, "gui_which_key")

      assert decoded["type"] == "gui_which_key"
      assert decoded["visible"] == true
      assert decoded["path"] == "SPC a"
      assert decoded["count"] == "· 1 needs you"
      assert decoded["count_tone"] == 1

      assert decoded["breadcrumb"] == [
               %{"key" => "SPC", "label" => "", "path" => "SPC"},
               %{"key" => "a", "label" => "Minga", "path" => "SPC a"}
             ]

      assert decoded["hints"] == [
               %{"key" => "⌫", "label" => "back"},
               %{"key" => "esc", "label" => "close"}
             ]

      assert decoded["entries"] == [
               %{
                 "kind" => 0,
                 "key" => "s",
                 "codepoint" => ?s,
                 "modifiers" => 0,
                 "label" => "Stop",
                 "section" => "Tasks",
                 "count" => "",
                 "count_tone" => 0,
                 "platform_key" => "⌘."
               },
               %{
                 "kind" => 1,
                 "key" => "q",
                 "codepoint" => ?q,
                 "modifiers" => 0,
                 "label" => "Queue ›",
                 "section" => "Conversation",
                 "count" => "· 2 errors",
                 "count_tone" => 2,
                 "platform_key" => ""
               }
             ]
    end
  end

  describe "gui_picker visible" do
    test "round-trips visible picker with items", %{harness: harness} do
      # The production PickerBuilder normalizes a filtered legacy picker into
      # this wire-shaped RenderModel.UI.Picker (flags packed: marked => bit 1 =>
      # 2; query "edi" re-derives match_positions [0, 1, 2] against "editor.ex").
      # This mirrors what the old ProtocolGUI.encode_gui_picker oracle received.
      model = %PickerModel{
        visible?: true,
        title: "Find File",
        query: "edi",
        query_generation: 7,
        acknowledged_query_edit_seq: 11,
        selected_index: 0,
        filtered_count: 1,
        total_count: 2,
        marked_count: 1,
        has_preview?: false,
        items: [
          %{
            icon_color: 0x51AFEF,
            flags: 2,
            label: "editor.ex",
            description: "lib",
            annotation: "",
            match_positions: [0, 1, 2],
            activation_id: 23,
            status: "",
            status_tone: :none,
            group: ""
          },
          %{
            icon_color: 0,
            flags: 8,
            label: "Claude Opus 4",
            description: "Claude Max · 5h limit resets 3:59 PM",
            annotation: "★ favorite",
            match_positions: [],
            activation_id: 24,
            status: "Limit reached",
            status_tone: :error,
            group: "Claude (subscription)"
          }
        ],
        action_menu: nil,
        mode_prefix: ">",
        load_status: :ready,
        movement_keys: [
          %{codepoint: ?j, modifiers: 0x02, movement: :next},
          %{codepoint: 57_352, modifiers: 0, movement: :previous}
        ]
      }

      cmd = PickerEncoder.encode_command(model)
      # Split the bundled picker and preview because each harness call expects one response.
      picker_size = byte_size(cmd) - 2
      preview_opcode = Opcodes.gui_picker_preview()
      assert <<picker::binary-size(^picker_size), ^preview_opcode, 0>> = cmd

      decoded = round_trip(harness, picker, "gui_picker")
      preview = round_trip(harness, <<preview_opcode, 0>>, "gui_picker_preview")

      assert preview["visible"] == false

      assert decoded["type"] == "gui_picker"
      assert decoded["visible"] == true
      assert decoded["title"] == "Find File"
      assert decoded["query"] == "edi"
      assert decoded["query_generation"] == 7
      assert decoded["acknowledged_query_edit_seq"] == 11
      assert decoded["mode_prefix"] == ">"
      assert decoded["filtered_count"] == 1
      assert decoded["total_count"] == 2
      assert decoded["marked_count"] == 1
      assert Enum.count(decoded["items"]) == 2

      [item, model_row] = decoded["items"]
      assert item["label"] == "editor.ex"
      assert item["description"] == "lib"
      assert item["match_positions"] == [0, 1, 2]
      assert item["flags"] == 2
      assert item["status"] == ""
      assert item["status_tone"] == 0
      assert item["group"] == ""

      assert model_row["label"] == "Claude Opus 4"
      assert model_row["flags"] == 8
      assert model_row["annotation"] == "★ favorite"
      assert model_row["status"] == "Limit reached"
      # status_tone error is 3 (none 0, ready 1, warn 2, error 3, checking 4, neutral 5).
      assert model_row["status_tone"] == 3
      assert model_row["group"] == "Claude (subscription)"
      refute Map.has_key?(decoded, "empty")
      assert decoded["list_keys"] == false

      # Movement keys reach the frontend as the exact key press identity and a row delta.
      assert decoded["movement_keys"] == [
               %{"codepoint" => ?j, "modifiers" => 2, "delta" => 1},
               %{"codepoint" => 57_352, "modifiers" => 0, "delta" => -1}
             ]
    end

    test "round-trips the empty section of a picker that offers next steps", %{harness: harness} do
      model = %PickerModel{
        visible?: true,
        title: "Switch project",
        filtered_count: 1,
        items: [
          %{
            icon_color: 0,
            flags: 0,
            label: "Add a folder",
            description: "",
            annotation: "SPC p a",
            match_positions: [],
            activation_id: 5,
            status: "",
            status_tone: :none,
            group: ""
          }
        ],
        empty: %EmptyList{title: "No projects yet.", why: "Minga remembers folders you open."},
        list_keys?: true,
        enter_selects?: true,
        hints: [{"j k", "move"}, {"↩", "run"}]
      }

      cmd = PickerEncoder.encode_command(model)
      picker_size = byte_size(cmd) - 2
      assert <<picker::binary-size(^picker_size), _preview::binary>> = cmd

      decoded = round_trip(harness, picker, "gui_picker")

      assert decoded["empty"] == %{
               "glyph" => "",
               "title" => "No projects yet.",
               "why" => "Minga remembers folders you open.",
               "selected" => 0,
               "actions" => []
             }

      assert decoded["list_keys"] == true

      assert decoded["hints"] == [
               %{"keys" => "j k", "word" => "move"},
               %{"keys" => "↩", "word" => "run"}
             ]

      assert [%{"label" => "Add a folder", "annotation" => "SPC p a"}] = decoded["items"]
    end
  end

  describe "gui_picker_preview visible" do
    test "round-trips visible preview with styled lines", %{harness: harness} do
      # Line 1: 2 segments
      seg1 = <<0x51, 0xAF, 0xEF, 0x01, 4::16, "def "::binary>>
      seg2 = <<0xEC, 0xBE, 0x7B, 0x00, 5::16, "hello"::binary>>
      # Line 2: 1 segment
      seg3 = <<0xBB, 0xC2, 0xCF, 0x00, 3::16, ":ok"::binary>>

      cmd =
        <<0x7D, 1::8, 2::16, 2::8, seg1::binary, seg2::binary, 1::8, seg3::binary>>

      decoded = round_trip(harness, cmd, "gui_picker_preview")

      assert decoded["type"] == "gui_picker_preview"
      assert decoded["visible"] == true
      assert Enum.count(decoded["lines"]) == 2

      [[s1, s2], [s3]] = decoded["lines"]
      assert s1["text"] == "def "
      assert s1["bold"] == true
      assert s1["fg_color"] == 0x51AFEF
      assert s2["text"] == "hello"
      assert s2["bold"] == false
      assert s3["text"] == ":ok"
    end
  end

  describe "gui_bottom_panel visible" do
    test "round-trips visible bottom panel with tabs and entries", %{harness: harness} do
      # Tab: type=0 (messages), name="Messages"
      tab = <<0::8, 8::8, "Messages"::binary>>

      # Content: stream_instance(4) + entry_count(2) + entries...
      # Entry: id(4) + level(1) + subsystem(1) + timestamp(4) + path_len(2) + path + text_len(2) + text
      path = "lib/editor.ex"
      text = "File opened"

      entry =
        <<42::32, 1::8, 0::8, 3661::32, byte_size(path)::16, path::binary, byte_size(text)::16,
          text::binary>>

      cmd =
        <<0x7C, 1::8, 0::8, 30::8, 0::8, 1::8, tab::binary, 7::32, 1::16, entry::binary>>

      decoded = round_trip(harness, cmd, "gui_bottom_panel")

      assert decoded["type"] == "gui_bottom_panel"
      assert decoded["visible"] == true
      assert decoded["active_tab_index"] == 0
      assert decoded["height_percent"] == 30
      assert Enum.count(decoded["tabs"]) == 1
      assert hd(decoded["tabs"])["name"] == "Messages"
      assert Enum.count(decoded["entries"]) == 1

      entry_decoded = hd(decoded["entries"])
      assert entry_decoded["id"] == 42
      assert entry_decoded["level"] == 1
      assert entry_decoded["text"] == "File opened"
    end
  end

  describe "empty lists in panels" do
    test "an empty folder round-trips its next steps after its rows", %{harness: harness} do
      empty = %EmptyList{
        glyph: "",
        title: "notes/ is empty.",
        why: "Make the first file or folder here.",
        selected: 1,
        actions: [
          %EmptyList.Action{id: "tree_new_file", key: "a", label: "New file"},
          %EmptyList.Action{id: "tree_new_folder", key: "A", label: "New folder"}
        ]
      }

      command =
        FileTreeEncoder.encode_command(%FileTree{
          generation: 3,
          root_path: "/project/notes",
          tree_width: 30,
          status: :empty,
          focused?: true,
          rows: [],
          empty: empty
        })

      decoded = round_trip(harness, command, "gui_file_tree")

      assert decoded["tree_state"] == 2

      assert decoded["empty"] == %{
               "glyph" => "",
               "title" => "notes/ is empty.",
               "why" => "Make the first file or folder here.",
               "selected" => 1,
               "actions" => [
                 %{"id" => "tree_new_file", "key" => "a", "label" => "New file"},
                 %{"id" => "tree_new_folder", "key" => "A", "label" => "New folder"}
               ]
             }
    end

    test "a clean tree round-trips its next steps, and a tree with changes carries none", %{
      harness: harness
    } do
      alias Minga.Frontend.Adapter.GUI.GitStatusEncoder
      alias Minga.RenderModel.UI.GitStatus
      alias MingaEditor.GitStatus.CleanTree

      clean = %GitStatus{
        repo_state: :normal,
        syncing: false,
        panel_id: 9,
        commit_target_id: 4,
        branch: "main",
        ahead: 2,
        empty: CleanTree.empty_list(%{branch: "main", ahead: 2, behind: 0}, 0)
      }

      decoded = round_trip(harness, GitStatusEncoder.encode_command(clean), "gui_git_status")

      assert %{
               "title" => "Nothing to commit on main.",
               "why" => "2 commits to push.",
               "selected" => 0,
               "actions" => [%{"id" => "git_status_push", "key" => "P"} | _]
             } = decoded["empty"]

      plain =
        round_trip(
          harness,
          GitStatusEncoder.encode_command(%{clean | empty: nil}),
          "gui_git_status"
        )

      refute Map.has_key?(plain, "empty")
    end
  end

  describe "gui_file_tree visible" do
    test "round-trips semantic visible file tree with entries", %{harness: harness} do
      root = "/project"

      rows = [
        %Row{
          id: "/project/lib",
          path: "/project/lib",
          name: "lib",
          icon: "󱉇",
          icon_color: 0x42A5F5,
          flags: %Flags{
            directory?: true,
            expanded?: true
          },
          depth: 0,
          guides: []
        },
        %Row{
          id: "/project/lib/editor.ex",
          path: "/project/lib/editor.ex",
          name: "editor.ex",
          icon: "",
          icon_color: 0x9B59B6,
          flags: %Flags{
            active?: true,
            dirty?: true,
            last_child?: true
          },
          git_status: :modified,
          depth: 1,
          guides: [true],
          editing: %Editing{type: :rename, text: "editor_renamed.ex", token: 0x01020304}
        }
      ]

      command =
        FileTreeEncoder.encode_command(%FileTree{
          generation: 17,
          root_path: root,
          tree_width: 30,
          status: :ready,
          focused?: true,
          selected_id: "/project/lib",
          rows: rows
        })

      decoded = round_trip(harness, command, "gui_file_tree")

      assert decoded["type"] == "gui_file_tree"
      assert decoded["version"] == 4
      assert decoded["generation"] == 17
      assert decoded["tree_state"] == 3
      assert decoded["error_reason"] == ""
      assert Bitwise.band(decoded["tree_flags"], 0x01) != 0
      assert Bitwise.band(decoded["tree_flags"], 0x02) != 0
      assert decoded["selected_id"] == "/project/lib"
      assert decoded["tree_width"] == 30
      assert decoded["root_path"] == "/project"
      assert Enum.count(decoded["entries"]) == 2

      [e1, e2] = decoded["entries"]
      assert e1["id"] == "/project/lib"
      assert e1["path"] == "/project/lib"
      assert e1["name"] == "lib"
      assert e1["relative_path"] == "lib"
      assert e1["is_dir"] == true
      assert e1["is_expanded"] == true
      assert e1["is_selected"] == true
      assert e1["is_focused"] == true
      assert e1["depth"] == 0

      assert e2["id"] == "/project/lib/editor.ex"
      assert e2["name"] == "editor.ex"
      assert e2["relative_path"] == "lib/editor.ex"
      assert e2["is_dir"] == false
      assert e2["is_active"] == true
      assert e2["is_dirty"] == true
      assert e2["is_editing"] == true
      assert e2["editing_token"] == 0x01020304
      assert e2["depth"] == 1
      assert e2["git_status"] == 1
    end
  end

  describe "gui_cursorline" do
    test "round-trips visible and hidden cursorline states", %{harness: harness} do
      decoded =
        round_trip(
          harness,
          <<Opcodes.gui_cursorline(), 12::16, 0x2C, 0x32, 0x3C>>,
          "gui_cursorline"
        )

      assert decoded["type"] == "gui_cursorline"
      assert decoded["row"] == 12
      assert decoded["r"] == 0x2C
      assert decoded["g"] == 0x32
      assert decoded["b"] == 0x3C

      decoded =
        round_trip(harness, <<Opcodes.gui_cursorline(), 0xFFFF::16, 0, 0, 0>>, "gui_cursorline")

      assert decoded["type"] == "gui_cursorline"
      assert decoded["row"] == 0xFFFF
      assert decoded["r"] == 0
      assert decoded["g"] == 0
      assert decoded["b"] == 0
    end
  end

  describe "gui_window_content" do
    test "round-trips window content with rows, selection, and diagnostics", %{harness: harness} do
      alias Minga.RenderModel.Window
      alias Minga.RenderModel.Window.{DiagnosticRange, Row, Selection, Span}

      sw = %Window{
        window_id: 7,
        content_kind: :buffer,
        rect: {0, 0, 80, 20},
        full_refresh: true,
        cursor_row: 1,
        cursor_col: 3,
        cursor_shape: :beam,
        rows: [
          %Row{
            row_id: Row.stable_id(:normal, 0),
            row_type: :normal,
            buf_line: 0,
            text: "def foo do",
            content_hash: 12_345,
            spans: [
              %Span{start_col: 0, end_col: 3, fg: 0x51AFEF, bg: 0x282C34, attrs: 0x01}
            ]
          },
          %Row{
            row_id: Row.stable_id(:fold_start, 1),
            row_type: :fold_start,
            buf_line: 1,
            text: "  :ok",
            spans: [],
            content_hash: 99
          }
        ],
        selection: %Selection{type: :char, start_row: 0, start_col: 0, end_row: 0, end_col: 10},
        search_matches: [],
        diagnostic_ranges: [
          %DiagnosticRange{
            start_row: 0,
            start_col: 0,
            end_row: 0,
            end_col: 3,
            severity: :warning
          }
        ]
      }

      cmd = WindowEncoder.encode_window_content(sw)
      decoded = round_trip(harness, cmd, "gui_window_content")

      assert decoded["type"] == "gui_window_content"
      assert decoded["window_id"] == 7
      assert decoded["full_refresh"] == true
      assert decoded["cursor_row"] == 1
      assert decoded["cursor_col"] == 3
      assert decoded["cursor_shape"] == 1
      assert Enum.count(decoded["rows"]) == 2

      [r1, r2] = decoded["rows"]
      assert r1["text"] == "def foo do"
      assert r1["row_type"] == 0
      assert r1["row_id"] == Row.stable_id(:normal, 0)
      assert r1["buf_line"] == 0
      assert Enum.count(r1["spans"]) == 1
      assert hd(r1["spans"])["fg"] == 0x51AFEF
      assert r2["row_type"] == 1
      assert r2["row_id"] == Row.stable_id(:fold_start, 1)
      assert r2["text"] == "  :ok"

      assert decoded["selection"]["type"] == 1
      assert decoded["selection"]["start_row"] == 0
      assert decoded["selection"]["end_col"] == 10
      assert decoded["diagnostic_count"] == 1
    end

    test "round-trips the sequential resident row-store header", %{harness: harness} do
      alias Minga.RenderModel.Window
      alias Minga.RenderModel.Window.Row

      window = %Window{
        window_id: 7,
        content_kind: :buffer,
        rect: {0, 0, 80, 20},
        full_refresh: true,
        cursor_row: 0,
        cursor_col: 0,
        cursor_shape: :beam,
        content_epoch: 11,
        row_store_mode: {:resident, 2},
        rows: [
          %Row{
            row_id: 100,
            row_type: :normal,
            buf_line: 41,
            text: "first",
            spans: [],
            content_hash: 1
          },
          %Row{
            row_id: 101,
            row_type: :normal,
            buf_line: 42,
            text: "second",
            spans: [],
            content_hash: 2
          }
        ]
      }

      decoded =
        round_trip(harness, WindowEncoder.encode_window_content(window), "gui_window_content")

      assert decoded["window_id"] == 7
      assert decoded["full_refresh"] == true
      assert decoded["rows"] |> Enum.map(& &1["buf_line"]) == [0, 1]
      assert decoded["rows"] |> Enum.map(& &1["text"]) == ["first", "second"]
    end

    test "round-trips a large full row through the viewport delta", %{harness: harness} do
      assert_large_delta_row_round_trip(
        harness,
        &WindowEncoder.encode_viewport_delta/2,
        "gui_window_viewport_delta"
      )
    end

    test "round-trips a large full row through the rows delta", %{harness: harness} do
      assert_large_delta_row_round_trip(
        harness,
        fn window, hashes ->
          delta = Minga.RenderModel.Window.RowDelta.from_snapshots([], window.rows)
          WindowEncoder.encode_rows_delta(window, delta, hashes)
        end,
        "gui_window_rows_delta"
      )
    end

    test "round-trips rows delta with ref and full entries", %{harness: harness} do
      alias Minga.RenderModel.Window
      alias Minga.RenderModel.Window.Row
      alias Minga.RenderModel.Window.RowDelta
      alias Minga.RenderModel.Window.RowSplice

      retained = %Row{
        row_id: Row.stable_id(:normal, 0),
        row_type: :normal,
        buf_line: 0,
        text: "old",
        spans: [],
        content_hash: 11
      }

      replacement = %Row{
        row_id: Row.stable_id(:normal, 1),
        row_type: :normal,
        buf_line: 1,
        text: "new",
        spans: [],
        content_hash: 22
      }

      window = %Window{
        window_id: 7,
        content_kind: :buffer,
        rect: {0, 0, 80, 20},
        full_refresh: false,
        cursor_row: 1,
        cursor_col: 3,
        cursor_shape: :beam,
        content_epoch: 42,
        scroll_left: 2,
        rows: [retained, replacement]
      }

      {:ok, delta} =
        RowDelta.new(1, 2, [RowSplice.new(0, 1, [retained, replacement])])

      {cmd, true} =
        WindowEncoder.encode_rows_delta(
          window,
          delta,
          %{retained.row_id => retained.content_hash}
        )

      decoded = round_trip(harness, cmd, "gui_window_rows_delta")

      assert decoded["type"] == "gui_window_rows_delta"
      assert decoded["window_id"] == 7
      assert decoded["content_epoch"] == 42
      assert decoded["scroll_left"] == 2

      assert [%{"start_index" => 0, "delete_count" => 1, "insert_entries" => [ref, full]}] =
               decoded["row_splices"]

      assert ref["entry_type"] == "ref"
      assert ref["row_id"] == Row.stable_id(:normal, 0)
      assert full["entry_type"] == "full"
      assert full["text"] == "new"
    end
  end

  @spec assert_large_delta_row_round_trip(
          GenServer.server(),
          (Minga.RenderModel.Window.t(), map() -> {binary(), boolean()}),
          String.t()
        ) :: :ok
  defp assert_large_delta_row_round_trip(harness, encode_delta, expected_type) do
    alias Minga.RenderModel.Window
    alias Minga.RenderModel.Window.Row

    text = String.duplicate("x", 70_000)

    row = %Row{
      row_id: Row.stable_id(:normal, 0),
      row_type: :normal,
      buf_line: 0,
      text: text,
      spans: [],
      content_hash: 1
    }

    window = %Window{
      window_id: 7,
      content_kind: :buffer,
      rect: {0, 0, 80, 20},
      full_refresh: false,
      cursor_row: 0,
      cursor_col: 0,
      cursor_shape: :beam,
      content_epoch: 42,
      rows: [row]
    }

    {command, false} = encode_delta.(window, %{})
    section_id = if expected_type == "gui_window_rows_delta", do: 0x0B, else: 0x02
    rows_payload = section_payload(command, section_id)

    row_entry =
      case section_id do
        0x0B ->
          assert <<0::32, 1::32, 1::32, 0::32, 0::32, 1::32, entry::binary>> = rows_payload
          entry

        0x02 ->
          assert <<1::32, entry::binary>> = rows_payload
          entry
      end

    assert <<1::8, _row_type::8, _row_id::64, _buf_line::32, _content_hash::32, text_length::32,
             row_text::binary-size(text_length), 0::16>> = row_entry

    assert text_length == byte_size(text)
    assert text_length > 65_535
    assert byte_size(rows_payload) > 65_535
    assert row_text == text

    decoded = round_trip(harness, command, expected_type)
    assert decoded["type"] == expected_type

    if section_id == 0x0B do
      assert [%{"insert_entries" => [%{"entry_type" => "full", "text" => ^text}]}] =
               decoded["row_splices"]
    else
      assert [%{"entry_type" => "full", "text" => ^text}] = decoded["rows"]
    end

    :ok
  end

  @spec section_payload(binary(), non_neg_integer()) :: binary()
  defp section_payload(<<_opcode::8, _section_count::8, sections::binary>>, section_id) do
    find_section_payload(sections, section_id)
  end

  @spec find_section_payload(binary(), non_neg_integer()) :: binary()
  defp find_section_payload(
         <<section_id::8, length::32, payload::binary-size(length), _rest::binary>>,
         section_id
       ),
       do: payload

  defp find_section_payload(
         <<_id::8, length::32, _payload::binary-size(length), rest::binary>>,
         section_id
       ),
       do: find_section_payload(rest, section_id)

  @spec find_command([binary()], non_neg_integer()) :: binary()
  defp find_command(commands, opcode) do
    Enum.find(commands, fn
      <<^opcode, _rest::binary>> -> true
      _command -> false
    end)
  end

  @spec resident_window(non_neg_integer(), non_neg_integer(), [
          Minga.RenderModel.Window.GutterEntry.t()
        ]) :: Minga.RenderModel.Window.t()
  defp resident_window(line_count, content_epoch, overrides) do
    alias Minga.RenderModel.Window
    alias Minga.RenderModel.Window.Gutter
    alias Minga.RenderModel.Window.Gutter.ResidentRows

    %Window{
      window_id: 1,
      content_kind: :buffer,
      rect: {0, 0, 80, 20},
      rows: [],
      cursor_row: 0,
      cursor_col: 0,
      cursor_shape: :block,
      content_epoch: content_epoch,
      full_refresh: false,
      row_store_mode: {:resident, line_count},
      gutter: %Gutter{
        window_id: 1,
        content_row: 0,
        content_col: 0,
        content_height: 20,
        content_width: 80,
        is_active: true,
        cursor_line: 0,
        line_number_style: :absolute,
        line_number_width: 4,
        sign_col_width: 1,
        entries: %ResidentRows{
          content_epoch: content_epoch,
          line_count: line_count,
          overrides: overrides
        }
      }
    }
  end
end
