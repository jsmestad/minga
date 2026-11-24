defmodule MingaEditor.Extension.PickerTest do
  # Registers the test picker source in the shared extension lease table.
  use ExUnit.Case, async: false

  alias Minga.Extension.CallbackInvoker
  alias Minga.Extension.CodeLease
  alias Minga.RenderModel.UI.Picker, as: PickerModel
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Request
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Extension.EditorAPI
  alias MingaEditor.Extension.Picker
  alias MingaEditor.Extension.Picker.Item
  alias MingaEditor.Extension.SourceFinalizer
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.PickerUI
  alias MingaEditor.RenderModel.UI.PickerBuilder
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.UI.Picker.FetchEffect

  @owner {:extension, :test_public_picker}
  @ctrl MingaEditor.Input.mod_ctrl()
  @down 57_353

  defmodule TestSource do
    @behaviour MingaEditor.Extension.Picker.Source

    alias MingaEditor.Extension.Picker.Source

    @spec open(EditorAPI.state(), map()) :: EditorAPI.state()
    def open(state, args), do: Picker.open(state, __MODULE__, args)

    @impl true
    @spec title() :: String.t()
    def title, do: "Extension picker"

    @impl true
    @spec candidates(map(), Source.page_request()) ::
            {:ok, [Item.t()], Source.next_page()} | {:error, String.t()}
    def candidates(args, page) do
      send(args.test_pid, {:candidates, args, page, self()})

      case {args.mode, page} do
        {:paged, :start} ->
          {:ok, [%Item{id: :first, label: "First"}],
           {:more, {:offset, 50}, %Item{id: :more, label: "Load more"}}}

        {:paged, {:continue, {:offset, 50}}} ->
          receive do
            :next_page -> {:ok, [%Item{id: :second, label: "Second"}], :done}
          end

        {:empty, :start} ->
          {:ok, [], :done}

        {:error, :start} ->
          {:error, "Repository is offline"}

        {{_preview_kind, path}, :start} ->
          {:ok, [%Item{id: path, label: "Absolute path"}], :done}

        {_mode, :start} ->
          {:ok, [%Item{id: :first, label: "First"}, %Item{id: :second, label: "Second"}], :done}
      end
    end

    @impl true
    @spec fallback(String.t(), map()) :: Item.t() | nil
    def fallback(query, %{mode: :fallback}),
      do: %Item{id: {:create, query}, label: "Create #{query}"}

    def fallback(_query, _args), do: nil

    @impl true
    @spec live_file_preview?() :: boolean()
    def live_file_preview?, do: true

    @impl true
    @spec preview(Item.t(), map()) :: Source.preview()
    def preview(item, args) do
      send(args.test_pid, {:preview, args, item.id, self()})

      case args.mode do
        {:file, path} ->
          {:file, path}

        :blocked_preview ->
          receive do
            {:finish_preview, result} -> result
          end

        _no_preview ->
          :none
      end
    end

    @impl true
    @spec actions(Item.t(), map()) :: [Source.action_entry()]
    def actions(%Item{id: :first}, %{mode: :invalid_actions}),
      do: [{"Broken", :broken} | :not_a_list]

    def actions(%Item{id: :first}, args) do
      send(args.test_pid, {:offered_actions, args, :first})
      [{"Keep", :keep}]
    end

    def actions(%Item{}, _args), do: []

    @impl true
    @spec on_select(EditorAPI.state(), Item.t(), map()) :: EditorAPI.state()
    def on_select(state, item, args) do
      send(args.test_pid, {:selected, item, args, state.shell_runtime.state.modal})
      state
    end

    @impl true
    @spec on_action(EditorAPI.state(), term(), Item.t(), map()) :: EditorAPI.state()
    def on_action(state, id, item, args) do
      send(args.test_pid, {:action, id, item, args, state.shell_runtime.state.modal})
      state
    end
  end

  setup do
    :ok = CodeLease.activate_source(@owner, [TestSource])

    on_exit(fn ->
      {:ok, token} = CodeLease.quiesce_source(@owner)
      ref = make_ref()
      :ok = CodeLease.notify_when_drained(@owner, self(), ref)
      assert_receive {CodeLease, :drained, @owner, ^ref}
      :ok = CodeLease.complete_unload(token)
    end)

    tasks = start_supervised!(Task.Supervisor)
    scheduler = start_supervised!({EffectScheduler, task_supervisor: tasks})
    :ok = EffectScheduler.attach(scheduler, self())
    %{state: TestHelpers.base_state(effect_scheduler: scheduler, port_manager: nil)}
  end

  test "selection and act menu callbacks receive the captured args after close", %{
    state: state
  } do
    args = args(:ordinary)
    state = open(state, args)
    assert_receive {:candidates, ^args, :start, worker}
    refute worker == self()
    state = apply_result(state, :picker_fetch)
    model = picker_model(state)
    assert [%{label: "First"}, second] = model.items

    selected = PickerUI.activate_item(state, model.activation_generation, second.activation_id)
    assert_receive {:selected, %Item{id: :second}, ^args, :none}
    assert selected.shell_runtime.state.modal == :none

    state = selected |> open(args) |> apply_result(:picker_fetch)
    menu = PickerUI.handle_key(state, ?., @ctrl)
    assert_receive {:offered_actions, ^args, :first}
    assert %{actions: ["Keep"], activation_ids: [action_id]} = picker_model(menu).action_menu
    model = picker_model(menu)

    # A native query edit can change the highlight while the menu retains the captured item.
    menu = PickerUI.replace_query(menu, model.query_generation, 1, "Second")
    assert picker_model(menu).acknowledged_query_edit_seq == 1
    acted = PickerUI.activate_action(menu, model.activation_generation, action_id)
    assert_receive {:action, :keep, %Item{id: :first}, ^args, :none}
    assert acted.shell_runtime.state.modal == :none
  end

  test "activating a continuation keeps committed rows until the final page lands", %{
    state: state
  } do
    args = args(:paged)
    state = state |> open(args) |> apply_result(:picker_fetch)
    assert_receive {:candidates, ^args, :start, _worker}
    state = PickerUI.handle_key(state, @down, 0)
    model = picker_model(state)
    assert [%{label: "First"} = first, %{label: "Load more"} = more] = model.items
    assert model.selected_item_id == more.activation_id
    refute_received {:candidates, _, {:continue, _}, _}
    refute_received {:preview, _, :more, _}

    loading = PickerUI.activate_item(state, model.activation_generation, more.activation_id)
    assert_receive {:candidates, ^args, {:continue, {:offset, 50}}, worker}
    assert %PickerModel{items: [^first, ^more], load_status: :loading} = picker_model(loading)
    assert PickerUI.handle_key(loading, 13, 0) == loading
    send(worker, :next_page)

    ready = apply_result(loading, :picker_fetch)

    assert %PickerModel{items: [^first, %{label: "Second"}], load_status: :ready} =
             picker_model(ready)

    assert PickerUI.handle_key(ready, 13, 0).shell_runtime.state.modal == :none
    assert_receive {:selected, %Item{id: :second}, ^args, :none}
    refute_received {:candidates, _, {:continue, _}, _}
  end

  test "a late worker preview cannot replace another item's accepted styled preview", %{
    state: state
  } do
    args = args(:blocked_preview)
    state = state |> open(args) |> apply_result(:picker_fetch)
    assert_receive {:preview, ^args, :first, first_worker}
    refute first_worker == self()
    assert %PickerModel{has_preview?: true, preview_lines: nil} = picker_model(state)
    send(first_worker, {:finish_preview, {:lines, [[{"late", :default, false}]]}})
    stale = take_result(state, :picker_preview)

    state = PickerUI.handle_key(state, @down, 0)
    assert_receive {:preview, ^args, :second, second_worker}
    assert picker_model(state).preview_lines == nil
    send(second_worker, {:finish_preview, {:lines, [[{"new", 0x123456, true}]]}})
    ready = apply_result(state, :picker_preview)
    assert picker_model(ready).preview_lines == [[{"new", 0x123456, true}]]

    assert {^ready, %Outcome{value: {:stale, :picker_preview_superseded}}} =
             FetchEffect.apply(ready, stale)

    refute_received {:selected, _item, _args, _modal}
  end

  @tag :tmp_dir
  test "file preview restores the origin on cancel; none never guesses a path", %{
    state: state,
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "preview.txt")
    File.write!(path, "captured file preview")
    origin = state.workspace.buffers.active

    state =
      state
      |> open(args({:file, path}))
      |> apply_result(:picker_fetch)
      |> apply_result(:picker_preview)

    previewed = state.workspace.buffers.active
    refute previewed == origin
    assert Minga.Buffer.file_path(previewed) == path

    # The accepted pane content survives the file disappearing before render.
    File.rm!(path)
    assert [[{"captured file preview", _fg, false}]] = picker_model(state).preview_lines
    refute_received {:selected, _item, _args, _modal}

    canceled = PickerUI.handle_key(state, 27, 0)
    assert canceled.workspace.buffers.active == origin
    assert canceled.shell_runtime.state.modal == :none

    File.write!(path, "should not be inferred")

    state =
      canceled
      |> open(args({:none, path}))
      |> apply_result(:picker_fetch)
      |> apply_result(:picker_preview)

    assert picker_model(state).preview_lines == nil
    assert state.workspace.buffers.active == origin
  end

  test "a fallback is selectable after the initial fetch and disappears when candidates match", %{
    state: state
  } do
    args = args(:fallback)
    state = open(state, args)
    model = picker_model(state)
    state = PickerUI.replace_query(state, model.query_generation, 1, "new")
    state = apply_result(state, :picker_fetch)
    model = picker_model(state)
    assert [%{label: "Create new", activation_id: id}] = model.items

    picked = PickerUI.activate_item(state, model.activation_generation, id)
    assert_receive {:selected, %Item{id: {:create, "new"}}, ^args, :none}

    state = picked |> open(args) |> apply_result(:picker_fetch)
    state = PickerUI.handle_key(state, ?z, 0)
    assert [%{label: "Create z"}] = picker_model(state).items
    state = state |> PickerUI.handle_key(127, 0) |> PickerUI.handle_key(?f, 0)
    assert [%{label: "First"}] = picker_model(state).items
  end

  test "empty candidates and candidate errors are distinct", %{state: state} do
    empty = state |> open(args(:empty)) |> apply_result(:picker_fetch)
    assert %PickerModel{items: [], load_status: :ready} = picker_model(empty)

    failed = empty |> open(args(:error)) |> apply_result(:picker_fetch)

    assert %PickerModel{items: [], load_status: {:error, "Repository is offline"}} =
             picker_model(failed)
  end

  test "malformed action lists do not interrupt picker input", %{state: state} do
    state = state |> open(args(:invalid_actions)) |> apply_result(:picker_fetch)
    assert state == PickerUI.handle_key(state, ?o, @ctrl)
    assert picker_model(state).action_menu == nil
  end

  test "unload cancels its own work and picker only", %{state: state} do
    args = args(:blocked_preview)
    state = state |> open(args) |> apply_result(:picker_fetch)
    assert_receive {:preview, ^args, :first, worker}
    monitor = Process.monitor(worker)
    assert {:ok, ^state} = SourceFinalizer.finalize(state, {:extension, :unrelated_picker})
    assert {:ok, _token} = CodeLease.quiesce_source(@owner)
    assert {:ok, unloaded} = SourceFinalizer.finalize(state, @owner)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}
    assert unloaded.shell_runtime.state.modal == :none
    refute EffectScheduler.active_source?(state.effect_scheduler, @owner)

    model = picker_model(state)

    stale_click =
      PickerUI.activate_item(unloaded, model.activation_generation, model.selected_item_id)

    assert stale_click.shell_runtime.state.modal == :none
    refute_received {:selected, _item, _args, _modal}
  end

  @spec args(term()) :: map()
  defp args(mode),
    do: %{test_pid: self(), repo: "/original/repo", path: "lib/original.ex", mode: mode}

  @spec open(EditorState.t(), map()) :: EditorState.t()
  defp open(state, args) do
    assert {:ok, %EditorState{} = state} =
             CallbackInvoker.invoke(@owner, TestSource, :open, [state, args], :command)

    state
  end

  @spec picker_model(EditorState.t()) :: PickerModel.t()
  defp picker_model(state), do: state |> Context.from_editor_state() |> PickerBuilder.build()

  @spec take_result(EditorState.t(), atom()) :: Outcome.t()
  defp take_result(state, lane) do
    scheduler = state.effect_scheduler

    assert_receive {:effect_result, ^scheduler,
                    %Outcome{request: %Request{resource: {^lane, TestSource}}} = outcome}

    outcome
  end

  @spec apply_result(EditorState.t(), atom()) :: EditorState.t()
  defp apply_result(state, lane) do
    outcome = take_result(state, lane)
    assert :ok = EffectScheduler.claim(state.effect_scheduler, outcome)
    {new_state, finished} = FetchEffect.apply(state, outcome)
    assert :ok = EffectScheduler.finalize(state.effect_scheduler, finished)
    new_state
  end
end
