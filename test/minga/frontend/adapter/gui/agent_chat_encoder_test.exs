defmodule Minga.Frontend.Adapter.GUI.AgentChatEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.AgentChatEncoder
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.RenderModel.UI.AgentChat
  alias Minga.RenderModel.UI.AgentChat.PromptCompletion

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

  defp find_section(<<>>, _remaining, _target_id), do: nil

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

    test "resident transcript fields do not affect the chrome fingerprint" do
      base = %AgentChat{visible?: true, model_name: "claude"}
      {_, caches} = AgentChatEncoder.encode(base, Caches.new())

      ignored_mutations = [
        %{resident_messages: [{1, {:user, "hi"}}]},
        %{resident_truncated?: true},
        %{transcript_epoch: 99}
      ]

      for attrs <- ignored_mutations do
        assert {nil, ^caches} = AgentChatEncoder.encode(struct(base, attrs), caches)
      end

      assert {cmd, _} = AgentChatEncoder.encode(%{base | status: :thinking}, caches)
      assert <<@op_gui_agent_chat, 8::8, _::binary>> = cmd
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
    test "visible chat emits 8 sections and omits retired messages section 0x06" do
      binary = encode(%AgentChat{visible?: true, resident_messages: [{1, {:user, "hi"}}]})
      assert <<@op_gui_agent_chat, 8::8, _::binary>> = binary
      assert section!(binary, 0x06) == nil
    end

    test "input_focused section carries the composer focus flag (#2654)" do
      assert <<1::8>> = section!(encode(%AgentChat{visible?: true, input_focused: true}), 0x09)
      assert <<0::8>> = section!(encode(%AgentChat{visible?: true, input_focused: false}), 0x09)
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
