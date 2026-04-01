defmodule MingaEditor.Input.SignatureHelpTest do
  use ExUnit.Case, async: true

  alias MingaEditor.SignatureHelp, as: SigHelp
  alias MingaEditor.Input.SignatureHelp, as: SigHelpInput

  import MingaEditor.RenderPipeline.TestHelpers

  @ctrl 4
  @escape 27

  @sample_response %{
    "signatures" => [
      %{"label" => "foo(a, b)", "parameters" => [%{"label" => "a"}, %{"label" => "b"}]},
      %{"label" => "foo(x)", "parameters" => [%{"label" => "x"}]}
    ],
    "activeSignature" => 0,
    "activeParameter" => 0
  }

  defp state_with_sig_help do
    state = base_state()
    sh = SigHelp.from_response(@sample_response, 10, 20)
    MingaEditor.State.update_shell_state(state, &%{&1 | signature_help: sh})
  end

  describe "handle_key/3 with no signature help" do
    test "passes through" do
      state = base_state()
      assert {:passthrough, ^state} = SigHelpInput.handle_key(state, ?a, 0)
    end
  end

  describe "handle_key/3 with signature help visible" do
    test "C-j cycles to next signature" do
      state = state_with_sig_help()
      assert {:handled, new_state} = SigHelpInput.handle_key(state, ?j, @ctrl)
      assert new_state.shell_state.signature_help.active_signature == 1
    end

    test "C-k cycles to previous signature" do
      state = state_with_sig_help()
      # Go to signature 1 first
      {:handled, state} = SigHelpInput.handle_key(state, ?j, @ctrl)
      assert {:handled, new_state} = SigHelpInput.handle_key(state, ?k, @ctrl)
      assert new_state.shell_state.signature_help.active_signature == 0
    end

    test "Escape dismisses" do
      state = state_with_sig_help()
      assert {:handled, new_state} = SigHelpInput.handle_key(state, @escape, 0)
      assert new_state.shell_state.signature_help == nil
    end

    test "regular keys pass through (signature stays visible)" do
      state = state_with_sig_help()
      assert {:passthrough, new_state} = SigHelpInput.handle_key(state, ?a, 0)
      assert new_state.shell_state.signature_help != nil
    end
  end
end
