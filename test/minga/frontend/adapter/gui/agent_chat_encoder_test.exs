defmodule Minga.Frontend.Adapter.GUI.AgentChatEncoderTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Minga.Frontend.Adapter.GUI.AgentChatEncoder
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.RenderModel.UI.AgentChat
  alias Minga.RenderModel.UI.AgentChat.ApprovalView
  alias Minga.RenderModel.UI.AgentChat.MarkdownBlock
  alias Minga.RenderModel.UI.AgentChat.PromptCompletion
  alias Minga.RenderModel.UI.AgentChat.ToolCallView
  alias Minga.RenderModel.UI.AgentChat.Usage

  @op_gui_agent_chat Minga.Protocol.Opcodes.gui_agent_chat()

  defp encode(model) do
    {binary, _caches} = AgentChatEncoder.encode(model, Caches.new())
    binary
  end

  # Extracts a section payload by ID from the sectioned binary.
  defp section!(<<@op_gui_agent_chat, count::8, sections::binary>>, target_id) do
    find_section(sections, count, target_id)
  end

  defp find_section(
         <<target_id::8, len::16, payload::binary-size(len), _rest::binary>>,
         _remaining,
         target_id
       ),
       do: payload

  defp find_section(
         <<_id::8, len::16, _payload::binary-size(len), rest::binary>>,
         remaining,
         target_id
       )
       when remaining > 0,
       do: find_section(rest, remaining - 1, target_id)

  # Unwraps the framed v1 messages payload into a list of message bodies.
  defp messages!(binary) do
    <<0xFF::8, 1::8, count::16, frames::binary>> = section!(binary, 0x06)
    unwrap_frames(frames, count, [])
  end

  defp unwrap_frames(<<>>, 0, acc), do: Enum.reverse(acc)

  defp unwrap_frames(
         <<len::32, message::binary-size(len), rest::binary>>,
         remaining,
         acc
       )
       when remaining > 0,
       do: unwrap_frames(rest, remaining - 1, [message | acc])

  describe "cache behaviour" do
    test "encodes hidden agent chat as two bytes" do
      assert encode(%AgentChat{visible?: false}) == <<@op_gui_agent_chat, 0::8>>
    end

    test "returns nil on second call with the same model" do
      model = %AgentChat{visible?: true, model_name: "claude"}
      caches = Caches.new()

      {cmd1, caches} = AgentChatEncoder.encode(model, caches)
      assert cmd1 != nil

      {cmd2, _caches} = AgentChatEncoder.encode(model, caches)
      assert cmd2 == nil
    end

    test "re-encodes when the model changes" do
      hidden = %AgentChat{visible?: false}
      visible = %AgentChat{visible?: true, model_name: "claude"}

      caches = Caches.new()
      {_, caches} = AgentChatEncoder.encode(hidden, caches)
      {cmd, _caches} = AgentChatEncoder.encode(visible, caches)

      assert cmd != nil
      assert <<@op_gui_agent_chat, 8::8, _::binary>> = cmd
    end

    test "transitions from visible back to hidden" do
      visible = %AgentChat{visible?: true, model_name: "claude"}
      hidden = %AgentChat{visible?: false}

      caches = Caches.new()
      {_, caches} = AgentChatEncoder.encode(visible, caches)
      {cmd, _caches} = AgentChatEncoder.encode(hidden, caches)

      assert cmd == <<@op_gui_agent_chat, 0::8>>
    end
  end

  describe "header, model, prompt, thinking sections" do
    test "visible chat always emits 8 sections" do
      assert <<@op_gui_agent_chat, 8::8, _::binary>> = encode(%AgentChat{visible?: true})
    end

    test "header carries the status byte" do
      for {status, byte} <- [
            {:idle, 0},
            {:thinking, 1},
            {:tool_executing, 2},
            {:error, 3},
            {:bogus, 0}
          ] do
        binary = encode(%AgentChat{visible?: true, status: status})
        assert <<1::8, ^byte::8>> = section!(binary, 0x01)
      end
    end

    test "model section carries the model name" do
      binary = encode(%AgentChat{visible?: true, model_name: "claude 🚀"})
      assert <<len::16, name::binary-size(len)>> = section!(binary, 0x02)
      assert name == "claude 🚀"
    end

    test "prompt section carries text and cell-grid metadata" do
      binary =
        encode(%AgentChat{
          visible?: true,
          prompt: "café",
          prompt_line_count: 3,
          prompt_cursor_line: 1,
          prompt_cursor_col: 2,
          prompt_vim_mode: :insert,
          prompt_visible_rows: 5
        })

      assert <<len::16, prompt::binary-size(len), line_count::8, cursor_line::16, cursor_col::16,
               vim_mode::8, visible_rows::8>> = section!(binary, 0x03)

      assert prompt == "café"
      assert line_count == 3
      assert cursor_line == 1
      assert cursor_col == 2
      assert vim_mode == 1
      assert visible_rows == 5
    end

    test "vim mode byte mapping" do
      for {mode, byte} <- [
            {:normal, 0},
            {:insert, 1},
            {:visual, 2},
            {:visual_line, 2},
            {:command, 3},
            {:operator_pending, 4},
            {:search, 5},
            {:search_prompt, 5},
            {:replace, 6},
            {nil, 0},
            {:weird, 0}
          ] do
        binary = encode(%AgentChat{visible?: true, prompt_vim_mode: mode})

        <<_len::16, _prompt::binary-size(0), _lc::8, _cl::16, _cc::16, vim_mode::8, _vr::8>> =
          section!(binary, 0x03)

        assert vim_mode == byte
      end
    end

    test "thinking section carries the thinking level" do
      binary = encode(%AgentChat{visible?: true, thinking_level: "high"})
      assert <<4::16, "high">> = section!(binary, 0x08)
    end

    test "nil model and prompt encode as empty strings" do
      binary =
        encode(%AgentChat{visible?: true, model_name: nil, prompt: nil, thinking_level: nil})

      assert <<0::16>> = section!(binary, 0x02)
      assert <<0::16, _meta::binary>> = section!(binary, 0x03)
      assert <<0::16>> = section!(binary, 0x08)
    end
  end

  describe "message bodies" do
    test "user and assistant messages with stable IDs" do
      binary =
        encode(%AgentChat{
          visible?: true,
          messages: [{42, {:user, "hello"}}, {99, {:assistant, "hi"}}]
        })

      assert [m1, m2] = messages!(binary)
      assert <<42::32, 0x01::8, 5::32, "hello">> = m1
      assert <<99::32, 0x02::8, 2::32, "hi">> = m2
    end

    test "message count cap keeps the newest transcript messages" do
      messages =
        for id <- 1..105 do
          {id, {:assistant, "message #{id}"}}
        end

      binary = encode(%AgentChat{visible?: true, messages: messages})
      encoded_messages = messages!(binary)

      assert length(encoded_messages) == 100
      assert [first | _] = encoded_messages
      assert <<6::32, 0x02::8, _rest::binary>> = first
      assert last = List.last(encoded_messages)
      assert <<105::32, 0x02::8, _rest::binary>> = last
    end

    test "bare tuple messages encode with ID 0" do
      binary = encode(%AgentChat{visible?: true, messages: [{:user, "bare"}]})
      assert [m1] = messages!(binary)
      assert <<0::32, 0x01::8, 4::32, "bare">> = m1
    end

    test "user message with attachments drops the attachments on the wire" do
      binary = encode(%AgentChat{visible?: true, messages: [{1, {:user, "hi", [:a]}}]})
      assert [m1] = messages!(binary)
      assert <<1::32, 0x01::8, 2::32, "hi">> = m1
    end

    test "thinking message carries the collapsed flag" do
      binary =
        encode(%AgentChat{
          visible?: true,
          messages: [{1, {:thinking, "open", false}}, {2, {:thinking, "closed", true}}]
        })

      assert [m1, m2] = messages!(binary)
      assert <<1::32, 0x03::8, 0::8, 4::32, "open">> = m1
      assert <<2::32, 0x03::8, 1::8, 6::32, "closed">> = m2
    end

    test "system message level byte" do
      binary =
        encode(%AgentChat{
          visible?: true,
          messages: [{1, {:system, "info", :info}}, {2, {:system, "err", :error}}]
        })

      assert [m1, m2] = messages!(binary)
      assert <<1::32, 0x05::8, 0::8, 4::32, "info">> = m1
      assert <<2::32, 0x05::8, 1::8, 3::32, "err">> = m2
    end

    test "usage message encodes counts and microdollar cost" do
      usage = %Usage{
        input: 10,
        output: 5,
        cache_read: 3,
        cache_write: 2,
        cost: 0.0012
      }

      binary = encode(%AgentChat{visible?: true, messages: [{1, {:usage, usage}}]})

      assert [m1] = messages!(binary)
      assert <<1::32, 0x06::8, 10::32, 5::32, 3::32, 2::32, 1200::32>> = m1
    end

    test "tool_call message fields and auto-approved scope" do
      tc = %ToolCallView{
        name: "write_file",
        summary: "lib/x.ex",
        status: :running,
        is_error: false,
        collapsed: true,
        auto_approved_scope: :session,
        duration_ms: 0,
        result: "file contents"
      }

      binary = encode(%AgentChat{visible?: true, messages: [{1, {:tool_call, tc}}]})
      assert [m1] = messages!(binary)

      <<1::32, 0x04::8, 0::8, 0::8, 1::8, 0::32, name_len::16, name::binary-size(name_len),
        summary_len::16, summary::binary-size(summary_len), result_len::32,
        result::binary-size(result_len), auto_approved::8, preview_kind::8, preview_count::16>> =
        m1

      assert name == "write_file"
      assert summary == "lib/x.ex"
      assert result == "file contents"
      assert auto_approved == 1
      assert preview_kind == 0
      assert preview_count == 0
    end

    test "tool_call message carries preview lines after auto-approved scope" do
      tc = %ToolCallView{
        name: "edit_file",
        summary: "lib/x.ex",
        status: :complete,
        collapsed: true,
        preview_kind: :diff,
        preview_lines: ["file: lib/x.ex", "-old", "+new"]
      }

      binary = encode(%AgentChat{visible?: true, messages: [{1, {:tool_call, tc}}]})
      assert [m1] = messages!(binary)

      <<1::32, 0x04::8, _status::8, _error::8, _collapsed::8, _duration::32, name_len::16,
        _name::binary-size(name_len), summary_len::16, _summary::binary-size(summary_len),
        result_len::32, _result::binary-size(result_len), auto_approved::8, kind::8,
        line_count::16, l1_len::16, l1::binary-size(l1_len), l2_len::16, l2::binary-size(l2_len),
        l3_len::16, l3::binary-size(l3_len)>> = m1

      assert auto_approved == 0
      assert kind == 1
      assert line_count == 3
      assert l1 == "file: lib/x.ex"
      assert l2 == "-old"
      assert l3 == "+new"
    end

    test "tool_call status byte mapping" do
      for {status, byte} <- [{:running, 0}, {:complete, 1}, {:error, 2}] do
        tc = %ToolCallView{name: "x", summary: "", status: status, result: ""}
        binary = encode(%AgentChat{visible?: true, messages: [{1, {:tool_call, tc}}]})
        assert [<<1::32, 0x04::8, ^byte::8, _::binary>>] = messages!(binary)
      end
    end

    test "styled_assistant message with styled runs" do
      styled = [
        [{"def ", 0xFF0000, 0, 0x11}, {"hello", 0xBBC2CF, 0, 0}],
        [{"  :world", 0x98BE65, 0, 0}]
      ]

      binary = encode(%AgentChat{visible?: true, messages: [{1, {:styled_assistant, styled}}]})
      assert [m1] = messages!(binary)

      <<1::32, 0x07::8, 2::16, 2::16, t1_len::16, t1::binary-size(t1_len), fg1::24, _bg1::24,
        flags1::8, _rest::binary>> = m1

      assert t1 == "def "
      assert fg1 == 0xFF0000
      assert flags1 == 0x11
    end

    test "assistant_markdown message encodes semantic code block payload" do
      blocks = [
        MarkdownBlock.paragraph(10, [
          [{"Use ", 0xBBC2CF, 0, 0}, {"code", 0x98BE65, 0x21242B, 0x10}]
        ]),
        MarkdownBlock.code_block(11, "elixir", "Elixir", "lib/demo.ex", true, [
          [{"", 0x98BE65, 0x21242B, 0x10}],
          [{"def hello", 0x98BE65, 0x21242B, 0x10}]
        ])
      ]

      binary = encode(%AgentChat{visible?: true, messages: [{7, {:assistant_markdown, blocks}}]})
      assert [m1] = messages!(binary)

      <<7::32, 0x0A::8, 2::16, 10::32, 0x01::8, 0::8, 1::16, 2::16, use_len::16,
        use::binary-size(use_len), _use_fg::24, _use_bg::24, 0::8, code_len::16,
        code::binary-size(code_len), _code_fg::24, _code_bg::24, code_flags::8, 11::32, 0x07::8,
        0x01::8, lang_len::16, lang::binary-size(lang_len), label_len::16,
        label::binary-size(label_len), path_len::16, path::binary-size(path_len), 0x01::8, 2::16,
        1::16, empty_len::16, empty::binary-size(empty_len), _empty_fg::24, _empty_bg::24,
        empty_flags::8, 1::16, line_len::16, line::binary-size(line_len), _line_fg::24,
        _line_bg::24, line_flags::8>> = m1

      assert use == "Use "
      assert code == "code"
      assert code_flags == 0x10
      assert lang == "elixir"
      assert label == "Elixir"
      assert path == "lib/demo.ex"
      assert empty == ""
      assert empty_flags == 0x10
      assert line == "def hello"
      assert line_flags == 0x10
    end

    test "styled_tool_call message with sub-opcode 0x08" do
      tc = %ToolCallView{
        name: "bash",
        summary: "",
        status: :complete,
        is_error: false,
        collapsed: false,
        duration_ms: 1234,
        result: "ignored"
      }

      styled = [[{"hello", 0xFF0000, 0x000000, 0x01}]]

      binary =
        encode(%AgentChat{visible?: true, messages: [{1, {:styled_tool_call, tc, styled}}]})

      assert [m1] = messages!(binary)

      <<1::32, 0x08::8, status::8, error::8, collapsed::8, duration::32, name_len::16,
        name::binary-size(name_len), summary_len::16, _summary::binary-size(summary_len),
        line_count::16, run_count::16, text_len::16, text::binary-size(text_len), fg::24, bg::24,
        flags::8, auto_approved::8, preview_kind::8, preview_count::16>> = m1

      assert status == 1
      assert error == 0
      assert collapsed == 0
      assert duration == 1234
      assert name == "bash"
      assert line_count == 1
      assert run_count == 1
      assert text == "hello"
      assert fg == 0xFF0000
      assert bg == 0x000000
      assert flags == 0x01
      assert auto_approved == 0
      assert preview_kind == 0
      assert preview_count == 0
    end

    test "approval_tool_call message with explicit preview" do
      approval = %ApprovalView{
        name: "write_file",
        tool_call_id: "tc_1",
        summary: "demo.ex",
        preview_kind: :target,
        preview_lines: ["file: demo.ex", "1 edit(s)"]
      }

      binary =
        encode(%AgentChat{
          visible?: true,
          status: :thinking,
          messages: [{1, {:approval_tool_call, approval}}]
        })

      assert [m1] = messages!(binary)

      <<1::32, 0x09::8, 0::8, name_len::16, name::binary-size(name_len), summary_len::16,
        summary::binary-size(summary_len), id_len::16, id::binary-size(id_len), kind::8,
        line_count::16, l1_len::16, l1::binary-size(l1_len), l2_len::16, l2::binary-size(l2_len)>> =
        m1

      assert name == "write_file"
      assert summary == "demo.ex"
      assert id == "tc_1"
      assert kind == 3
      assert line_count == 2
      assert l1 == "file: demo.ex"
      assert l2 == "1 edit(s)"
    end
  end

  describe "styled link runs" do
    test "carries url metadata when the link flag is set" do
      styled = [[{"docs", 0x61AFEF, 0, 0x0C, "https://example.com/docs"}]]
      binary = encode(%AgentChat{visible?: true, messages: [{1, {:styled_assistant, styled}}]})
      assert [m1] = messages!(binary)

      <<1::32, 0x07::8, 1::16, 1::16, tlen::16, text::binary-size(tlen), fg::24, _bg::24,
        flags::8, ulen::16, url::binary-size(ulen)>> = m1

      assert text == "docs"
      assert fg == 0x61AFEF
      assert (flags &&& 0x08) != 0
      assert url == "https://example.com/docs"
    end

    test "masks the link flag when no url is present" do
      styled = [[{"not a link", 0xBBC2CF, 0, 0x08}]]
      binary = encode(%AgentChat{visible?: true, messages: [{1, {:styled_assistant, styled}}]})
      assert [m1] = messages!(binary)

      <<1::32, 0x07::8, 1::16, 1::16, tlen::16, _text::binary-size(tlen), _fg::24, _bg::24,
        flags::8>> = m1

      assert (flags &&& 0x08) == 0
    end

    test "downgrades overlong link urls instead of corrupting framing" do
      for url <- [String.duplicate("a", 65_535), String.duplicate("a", 65_536)] do
        styled = [[{"docs", 0x61AFEF, 0, 0x0C, url}]]
        binary = encode(%AgentChat{visible?: true, messages: [{1, {:styled_assistant, styled}}]})
        assert [m1] = messages!(binary)

        <<1::32, 0x07::8, 1::16, 1::16, tlen::16, text::binary-size(tlen), _fg::24, _bg::24,
          flags::8>> = m1

        assert text == "docs"
        assert (flags &&& 0x08) == 0
        assert (flags &&& 0x04) == 0
      end
    end
  end

  describe "payload limits and truncation" do
    test "truncates oversized plain chat text" do
      text = String.duplicate("x", 70_000)
      binary = encode(%AgentChat{visible?: true, messages: [{:assistant, text}]})

      assert byte_size(section!(binary, 0x06)) <= 65_535
      assert [m1] = messages!(binary)
      <<0::32, 0x02::8, len::32, encoded::binary-size(len)>> = m1
      assert byte_size(encoded) == 60_000
      assert String.ends_with?(encoded, "… [truncated]")
    end

    test "omits older messages instead of overflowing the section" do
      text = String.duplicate("x", 70_000)

      binary =
        encode(%AgentChat{
          visible?: true,
          messages: [{1, {:assistant, text}}, {2, {:assistant, text}}]
        })

      assert byte_size(section!(binary, 0x06)) <= 65_535

      assert [notice_msg, kept_msg] = messages!(binary)
      <<0::32, 0x05::8, 0::8, notice_len::32, notice::binary-size(notice_len)>> = notice_msg
      assert notice =~ "omitted"

      <<2::32, 0x02::8, _len::32, _text::binary>> = kept_msg
    end

    test "keeps long command approval summaries without the short cap" do
      command = String.duplicate("echo long ", 40)

      approval = %ApprovalView{
        name: "shell",
        tool_call_id: "tc-approval",
        summary: command,
        preview_kind: :command,
        preview_lines: ["$ #{command}"]
      }

      binary =
        encode(%AgentChat{
          visible?: true,
          status: :tool_executing,
          messages: [{1, {:approval_tool_call, approval}}]
        })

      assert [m1] = messages!(binary)

      <<1::32, 0x09::8, 0::8, name_len::16, _name::binary-size(name_len), summary_len::16,
        summary::binary-size(summary_len), _rest::binary>> = m1

      assert summary == command
    end

    test "keeps multibyte summaries within UTF-8 byte limits" do
      command = String.duplicate("🚀", 20_000)
      tc = %ToolCallView{name: "shell", summary: command, status: :running, result: ""}

      binary = encode(%AgentChat{visible?: true, messages: [{1, {:tool_call, tc}}]})
      assert [m1] = messages!(binary)

      <<1::32, 0x04::8, _status::8, _error::8, _collapsed::8, _duration::32, name_len::16,
        _name::binary-size(name_len), summary_len::16, summary::binary-size(summary_len),
        _rest::binary>> = m1

      assert summary_len <= 60_000
      assert String.valid?(summary)
      assert String.ends_with?(summary, "… [truncated]")
    end
  end

  describe "prompt completion section" do
    test "encodes slash candidates with names and descriptions" do
      candidates = for i <- 1..25, do: {"candidate-#{i}.", "desc #{i}"}

      binary =
        encode(%AgentChat{
          visible?: true,
          prompt_completion: %PromptCompletion{
            type: :slash,
            candidates: candidates,
            selected: 3,
            anchor_line: 1,
            anchor_col: 2
          }
        })

      <<1::8, type::8, selected::8, anchor_line::16, anchor_col::16, count::8, _rest::binary>> =
        section!(binary, 0x07)

      assert type == 1
      assert selected == 3
      assert anchor_line == 1
      assert anchor_col == 2
      assert count == 25
    end

    test "encodes bare-name mention candidates with empty descriptions" do
      binary =
        encode(%AgentChat{
          visible?: true,
          prompt_completion: %PromptCompletion{type: :mention, candidates: ["alpha", "beta"]}
        })

      <<1::8, 0::8, 0::8, 0::16, 0::16, 2::8, nlen::16, name::binary-size(nlen), 0::16,
        _rest::binary>> = section!(binary, 0x07)

      assert name == "alpha"
    end

    test "empty candidates encode as not visible" do
      binary =
        encode(%AgentChat{
          visible?: true,
          prompt_completion: %PromptCompletion{type: :mention, candidates: []}
        })

      assert section!(binary, 0x07) == <<0::8>>
    end

    test "nil completion encodes as not visible" do
      assert section!(encode(%AgentChat{visible?: true}), 0x07) == <<0::8>>
    end
  end

  describe "pending approval section" do
    test "always encodes as not visible" do
      assert section!(encode(%AgentChat{visible?: true}), 0x04) == <<0::8>>
    end
  end

  describe "help overlay section" do
    test "encodes help groups with titles and bindings" do
      groups = [
        {"Navigation", [{"j / k", "Scroll down / up"}, {"gg / G", "Top / bottom"}]},
        {"Copy", [{"y", "Copy code block"}]}
      ]

      binary = encode(%AgentChat{visible?: true, help_visible?: true, help_groups: groups})
      <<1::8, group_count::8, rest::binary>> = section!(binary, 0x05)
      assert group_count == 2

      <<nav_len::16, nav::binary-size(nav_len), nav_count::8, nav_rest::binary>> = rest
      assert nav == "Navigation"
      assert nav_count == 2

      <<k1_len::8, k1::binary-size(k1_len), d1_len::16, d1::binary-size(d1_len), _::binary>> =
        nav_rest

      assert k1 == "j / k"
      assert d1 == "Scroll down / up"
    end

    test "help_visible? false encodes as a single zero byte" do
      binary = encode(%AgentChat{visible?: true, help_visible?: false, help_groups: []})
      assert section!(binary, 0x05) == <<0x00>>
    end

    test "help_visible? true with no groups encodes as not visible" do
      binary = encode(%AgentChat{visible?: true, help_visible?: true, help_groups: []})
      assert section!(binary, 0x05) == <<0x00>>
    end
  end
end
