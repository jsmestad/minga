defmodule MingaEditor.Journeys.AgentOpenTest do
  @moduledoc """
  Exercises real key dispatch through the committed semantic Agent chat frame.

  The test provider and shared warm model catalog do not exercise the first-open freeze in #3610. The shipping-app journey in #3644 owns that check.
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.Config.Options
  alias MingaEditor.Frontend.Capabilities

  @moduletag :tmp_dir
  @capabilities %Capabilities{frontend_type: :native_gui, semantic_ui: true}

  setup %{tmp_dir: dir} do
    path = Path.join(dir, "journey.txt")
    contents = "A file open before Agent starts"
    File.write!(path, contents)
    options = start_supervised!({Options, name: nil})

    ctx =
      start_editor(contents,
        file_path: path,
        shell: :traditional,
        capabilities: @capabilities,
        options_server: options,
        agent_provider_module: Minga.Test.StubProvider
      )

    %{editor_ctx: ctx}
  end

  test "SPC a a opens an empty composer from an editor with only a file", %{editor_ctx: ctx} do
    refute match?(%{visible?: true}, agent_chat(ctx))

    send_keys_async(ctx, "<SPC>aa")

    assert %{visible?: true, prompt: "", prompt_vim_mode: 0} = agent_chat(ctx)
  end

  test "SPC a n opens a focused Insert composer", %{editor_ctx: ctx} do
    send_keys_async(ctx, "<SPC>an")

    assert %{visible?: true, prompt: "", prompt_vim_mode: 1, input_focused?: true} =
             agent_chat(ctx)
  end

  test "keys immediately following SPC a n appear in the new composer", %{editor_ctx: ctx} do
    send_keys_async(ctx, "<SPC>anmy draft")

    assert %{visible?: true, prompt: "my draft"} = agent_chat(ctx)
  end

  test "toggling to the file and back keeps the same draft", %{editor_ctx: ctx} do
    send_keys_async(ctx, "<SPC>aaiunfinished<Esc>")
    assert %{visible?: true, prompt: "unfinished"} = agent_chat(ctx)

    send_keys_async(ctx, "<SPC>aa")
    refute match?(%{visible?: true}, agent_chat(ctx))

    send_keys_async(ctx, "<SPC>aa")
    assert %{visible?: true, prompt: "unfinished"} = agent_chat(ctx)
  end

  test "Next agent tab from the file reopens the existing draft", %{editor_ctx: ctx} do
    send_keys_async(ctx, "<SPC>anexisting<Esc>")
    assert %{visible?: true, prompt: "existing"} = agent_chat(ctx)

    send_keys_async(ctx, "<SPC>aa")
    refute match?(%{visible?: true}, agent_chat(ctx))

    send_keys_async(ctx, "<SPC>\ta")
    assert %{visible?: true, prompt: "existing"} = agent_chat(ctx)
  end
end
