defmodule Minga.RenderModel.UI.AgentChatTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.AgentChat
  alias Minga.RenderModel.UI.AgentChat.PromptCompletion

  describe "%AgentChat{}" do
    test "defaults to a hidden, empty conversation" do
      model = %AgentChat{}

      refute model.visible?
      assert model.status == :idle
      assert model.model_name == ""
      assert model.thinking_level == ""
      assert model.prompt == ""
      assert model.prompt_line_count == 1
      assert model.prompt_visible_rows == 1
      assert model.prompt_completion == nil
      refute model.help_visible?
      assert model.help_groups == []
      assert model.resident_messages == []
    end

    test "carries semantic conversation fields, not an encoded binary" do
      refute Map.has_key?(%AgentChat{}, :encoded)
      refute Map.has_key?(%AgentChat{}, :fingerprint)
    end

    test "holds visible chrome and resident transcript metadata" do
      model = %AgentChat{
        visible?: true,
        status: :thinking,
        model_name: "claude",
        thinking_level: "high",
        prompt: "hello",
        prompt_line_count: 2,
        prompt_cursor_line: 1,
        prompt_cursor_col: 3,
        prompt_vim_mode: :insert,
        prompt_visible_rows: 4,
        resident_messages: [{1, {:user, "hi"}}, {2, {:assistant, "yo"}}],
        resident_truncated?: true,
        transcript_epoch: 9
      }

      assert model.visible?
      assert model.status == :thinking
      assert model.prompt_vim_mode == :insert
      assert Enum.count(model.resident_messages) == 2
      assert model.resident_truncated?
      assert model.transcript_epoch == 9
    end

    test "selects a contiguous newest resident suffix" do
      messages = [{1, {:user, "one"}}, {2, {:user, "two"}}, {3, {:user, "three"}}]
      sizes = %{1 => 10, 2 => 20, 3 => 30}

      assert {[{2, {:user, "two"}}, {3, {:user, "three"}}], true} =
               AgentChat.resident_suffix(messages, 50, fn {id, _body} -> Map.fetch!(sizes, id) end)
    end

    test "retains an oversized newest message without shortening it" do
      messages = [{1, {:user, "older"}}, {2, {:user, "newest"}}]

      assert {[{2, {:user, "newest"}}], true} =
               AgentChat.resident_suffix(messages, 10, fn _message -> 20 end)

      assert {[{2, {:user, "newest"}}], false} =
               AgentChat.resident_suffix([{2, {:user, "newest"}}], 10, fn _message -> 20 end)
    end

    test "holds a prompt completion popup" do
      completion = %PromptCompletion{
        type: :slash,
        candidates: [{"/help", "Show help"}],
        selected: 0,
        anchor_line: 1,
        anchor_col: 2
      }

      model = %AgentChat{visible?: true, prompt_completion: completion}
      assert model.prompt_completion.type == :slash
    end

    test "holds help groups" do
      model = %AgentChat{
        visible?: true,
        help_visible?: true,
        help_groups: [{"Navigation", [{"j", "down"}]}]
      }

      assert [{"Navigation", [{"j", "down"}]}] = model.help_groups
    end
  end
end
