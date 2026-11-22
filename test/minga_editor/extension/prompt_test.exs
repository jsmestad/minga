defmodule MingaEditor.Extension.PromptTest do
  use Minga.Test.EditorCase, async: false, rendering: :disabled

  alias Minga.Extension.CallbackInvoker
  alias Minga.Extension.CodeLease
  alias Minga.Extension.InvocationContext
  alias MingaEditor.Extension.EditorAPI
  alias MingaEditor.Extension.Prompt
  alias MingaEditor.Extension.SourceFinalizer
  alias MingaEditor.Handlers.GuiActionHandler
  alias MingaEditor.MinibufferData
  alias MingaEditor.PromptUI
  alias MingaEditor.RenderModel.UI.MinibufferBuilder
  alias MingaEditor.Target

  @source {:extension, :public_prompt_test}
  @other_source {:extension, :public_prompt_other_test}

  defmodule Opener do
    @spec open(
            EditorAPI.state(),
            :text | :confirm,
            module(),
            term(),
            [Prompt.text_option()]
          ) :: Prompt.result()
    def open(state, :text, handler, args, opts), do: Prompt.text(state, handler, args, opts)
    def open(state, :confirm, handler, args, opts), do: Prompt.confirm(state, handler, args, opts)
  end

  defmodule Handler do
    @behaviour Prompt.Handler

    @type args :: {pid(), term()}

    @impl true
    @spec on_submit(EditorAPI.state(), String.t(), args()) :: EditorAPI.state()
    def on_submit(state, text, {test, _target} = args) do
      send(test, {:submitted, text, args, state.shell_runtime.state.modal, source()})
      state
    end

    @impl true
    @spec on_cancel(EditorAPI.state(), args()) :: EditorAPI.state()
    def on_cancel(state, {test, _target} = args) do
      send(test, {:text_canceled, args, state.shell_runtime.state.modal, source()})
      state
    end

    @impl true
    @spec on_confirm(EditorAPI.state(), Prompt.decision(), args()) :: EditorAPI.state()
    def on_confirm(state, decision, {test, _target} = args) do
      send(test, {:decided, decision, args, state.shell_runtime.state.modal, source()})
      state
    end

    @spec source() :: InvocationContext.source()
    defp source do
      {:ok, source} = InvocationContext.current_source()
      source
    end
  end

  defmodule OtherHandler do
    @behaviour Prompt.Handler

    @impl true
    @spec on_confirm(EditorAPI.state(), Prompt.decision(), Handler.args()) :: EditorAPI.state()
    def on_confirm(state, decision, args), do: Handler.on_confirm(state, decision, args)
  end

  setup do
    :ok = CodeLease.activate_source(@source, [Opener, Handler])
    :ok = CodeLease.activate_source(@other_source, [Opener, OtherHandler])

    on_exit(fn ->
      for source <- [@source, @other_source], CodeLease.source_status(source) == :active do
        {:ok, token} = CodeLease.quiesce_source(source)
        :ok = CodeLease.complete_unload(token)
      end
    end)

    :ok
  end

  test "text uses default, cursor editing and paste, then submits exact args after dismissal" do
    ctx = start_editor("unrelated buffer contents")
    args = {self(), {:repo, "/captured/repository", [:amend, make_ref()]}}

    opened =
      present(ctx, @source, :text, Handler, args,
        label: "Amend message: ",
        default: "AC",
        admission: :if_idle
      )

    assert {"Amend message: ", "AC", 2} = PromptUI.render_data(opened)
    assert {:prompt, %{owner: @source}} = opened.shell_runtime.state.modal
    send_key_sync(ctx, 57_350)
    typed = send_key_sync(ctx, ?b)
    assert {"Amend message: ", "AbC", 2} = PromptUI.render_data(typed)

    send(ctx.editor, {:minga_input, {:paste_event, "é"}})
    assert {"Amend message: ", "AbéC", 3} = PromptUI.render_data(editor_state(ctx))

    closed = send_key_sync(ctx, 13)
    assert closed.shell_runtime.state.modal == :none
    assert_received {:submitted, "AbéC", ^args, :none, @source}
    refute_received {:text_canceled, _, _, _}
  end

  test "idle admission neither replaces nor cancels an existing modal" do
    ctx = start_editor("scratch")
    args = {self(), :existing_prompt}
    opened = present(ctx, @source, :text, Handler, args, label: "Existing: ", default: "draft")
    modal = opened.shell_runtime.state.modal

    assert {:error, :modal_busy} =
             invoke(opened, @source, :text, Handler, {self(), :new_prompt},
               label: "Replace: ",
               admission: :if_idle
             )

    assert editor_state(ctx).shell_runtime.state.modal == modal
    closed = send_key_sync(ctx, 27)
    assert closed.shell_runtime.state.modal == :none
    assert_received {:text_canceled, ^args, :none, @source}
    refute_received {:text_canceled, _, _, _}
  end

  test "Yes/No choices use the existing semantic surface and n/Escape cancel after dismissal" do
    ctx = start_editor("scratch")
    args = {self(), {:branch, "feature"}}

    for key <- [?n, 27] do
      opened = present(ctx, @source, :confirm, Handler, args, label: "Delete branch?")
      offered = opened |> MinibufferData.from_state() |> MinibufferBuilder.build()
      assert offered.prompt == "Delete branch?"
      assert offered.cursor_pos == nil
      assert Enum.map(offered.candidates, & &1.id) == ["Yes", "No"]

      send(ctx.editor, {:minga_input, {:paste_event, "y"}})
      unchanged = send_key_sync(ctx, 13)
      assert unchanged.shell_runtime.state.modal == opened.shell_runtime.state.modal
      refute_received {:decided, _, _, _, _}

      closed = send_key_sync(ctx, key)
      assert closed.shell_runtime.state.modal == :none
      assert_received {:decided, :canceled, ^args, :none, @source}
      refute_received {:text_canceled, _, _, _}
    end

    opened = present(ctx, @source, :confirm, Handler, args, label: "Delete branch?")
    action = target(opened, "Yes")
    closed = GuiActionHandler.dispatch(opened, action)
    assert closed.shell_runtime.state.modal == :none
    assert_received {:decided, :accepted, ^args, :none, @source}
  end

  test "finalization preserves another owner's prompt and stale activations cannot cross unload" do
    ctx = start_editor("scratch")
    original = present(ctx, @source, :confirm, Handler, {self(), :original}, label: "Continue?")
    stale = target(original, "Yes")

    assert :ok = SourceFinalizer.unregister_source(@other_source, ctx.editor)
    assert editor_state(ctx).shell_runtime.state.modal == original.shell_runtime.state.modal

    assert {:ok, token} = CodeLease.quiesce_source(@source)

    try do
      denied = GuiActionHandler.dispatch(original, stale)
      assert denied.shell_runtime.state.modal == :none
      refute_received {:decided, _, _, _, _}

      assert :ok = SourceFinalizer.unregister_source(@source, ctx.editor)
      assert editor_state(ctx).shell_runtime.state.modal == :none
      refute_received {:decided, _, _, _, _}
    after
      :ok = CodeLease.complete_unload(token)
    end

    args = {self(), :replacement}
    replacement = present(ctx, @other_source, :confirm, OtherHandler, args, label: "Continue?")
    assert Target.resolve(replacement, stale) == {:error, :stale_generation}

    assert GuiActionHandler.dispatch(replacement, stale).shell_runtime.state.modal ==
             replacement.shell_runtime.state.modal

    refute_received {:decided, _, _, _, _}
    assert send_key_sync(ctx, ?y).shell_runtime.state.modal == :none
    assert_received {:decided, :accepted, ^args, :none, @other_source}
  end

  test "only a live extension invocation may open a prompt with an owned handler" do
    state = editor_state(start_editor("scratch"))

    assert {:error, :not_extension_callback} = Prompt.confirm(state, Handler, nil, label: "No")

    assert {:error, :source_unavailable} =
             invoke(state, @other_source, :confirm, Handler, nil, label: "Not owned")

    assert {:error, :invalid_handler} =
             invoke(state, @other_source, :text, OtherHandler, nil, label: "No on_submit")
  end

  defp invoke(state, source, kind, handler, args, opts) do
    {:ok, result} =
      CallbackInvoker.invoke(
        source,
        Opener,
        :open,
        [state, kind, handler, args, opts],
        :test_prompt
      )

    result
  end

  defp present(ctx, source, kind, handler, args, opts) do
    :sys.replace_state(ctx.editor, fn state ->
      {:ok, opened} = invoke(state, source, kind, handler, args, opts)
      opened
    end)
  end

  defp target(state, id) do
    %Target{
      surface: :command_completion,
      intent: :accept,
      generation: MinibufferData.from_state(state).generation,
      item_id: id
    }
  end
end
