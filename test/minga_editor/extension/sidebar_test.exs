defmodule MingaEditor.Extension.SidebarTest do
  use ExUnit.Case, async: true

  alias Minga.Extension.CodeLease
  alias Minga.Extension.InvocationContext
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.Extension.Sidebar.Snapshot
  alias MingaEditor.Test.SidebarActionProbe

  setup do
    table = Module.concat(__MODULE__, "Table#{System.unique_integer([:positive])}")
    start_supervised!({Sidebar, name: table})
    %{table: table}
  end

  test "registers visible sidebars ordered by priority", %{table: table} do
    assert :ok =
             Sidebar.register(table, {:extension, :alpha}, %{
               id: "outline",
               display_name: "Outline",
               priority: 20,
               preferred_width: 24,
               visible?: true,
               semantic_kind: "generic_tree",
               icon: "list.bullet"
             })

    assert :ok =
             Sidebar.register(table, {:extension, :beta}, %{
               id: "bookmarks",
               display_name: "Bookmarks",
               priority: 10,
               visible?: true
             })

    assert Enum.map(Sidebar.visible(table), & &1.id) == ["bookmarks", "outline"]
  end

  test "rejects reserved built-in sidebar ids from extension sources", %{table: table} do
    assert {:error, {:reserved_sidebar_id, "file_tree"}} =
             Sidebar.register(table, {:extension, :alpha}, %{
               id: "file_tree",
               display_name: "File Tree"
             })
  end

  test "rejects duplicate sidebar ids from different sources", %{table: table} do
    assert :ok =
             Sidebar.register(table, {:extension, :alpha}, %{
               id: "outline",
               display_name: "Outline"
             })

    assert {:error, {:duplicate_sidebar_id, "outline", {:extension, :alpha}}} =
             Sidebar.register(table, {:extension, :beta}, %{id: "outline", display_name: "Other"})
  end

  test "allows the owning source to replace and remove its sidebar", %{table: table} do
    source = {:extension, :alpha}
    assert :ok = Sidebar.register(table, source, %{id: "outline", display_name: "Outline"})

    assert :ok =
             Sidebar.register(table, source, %{
               id: "outline",
               display_name: "Symbols",
               visible?: true
             })

    assert %{display_name: "Symbols", visible?: true} = Sidebar.get(table, "outline")
    assert :ok = Sidebar.unregister(table, source, "outline")
    assert Sidebar.get(table, "outline") == nil
  end

  test "publishes snapshots without changing registration metadata", %{table: table} do
    source = {:extension, :alpha}
    rows = [%{id: "a", text: "alpha"}, %{id: "b", text: "beta", selected?: true}]

    assert :ok = Sidebar.register(table, source, %{id: "outline", display_name: "Outline"})
    assert :ok = Sidebar.publish_snapshot(table, source, "outline", rows: rows)

    assert %{display_name: "Outline", snapshot: %Snapshot{rows: ^rows, selected_id: "b"}} =
             Sidebar.get(table, "outline")
  end

  test "active_left prefers focused visible sidebars before priority fallback", %{table: table} do
    assert :ok =
             Sidebar.register(table, {:extension, :alpha}, %{
               id: "outline",
               display_name: "Outline",
               priority: 10,
               visible?: true,
               focused?: false
             })

    assert :ok =
             Sidebar.register(table, {:extension, :beta}, %{
               id: "bookmarks",
               display_name: "Bookmarks",
               priority: 20,
               visible?: true,
               focused?: true
             })

    assert %{id: "bookmarks"} = Sidebar.active_left(table)
  end

  test "focus_left makes one visible left sidebar active", %{table: table} do
    assert :ok =
             Sidebar.register(table, {:extension, :alpha}, %{
               id: "outline",
               display_name: "Outline",
               priority: 10,
               visible?: true,
               focused?: true
             })

    assert :ok =
             Sidebar.register(table, {:extension, :beta}, %{
               id: "bookmarks",
               display_name: "Bookmarks",
               priority: 20,
               visible?: true,
               focused?: false
             })

    assert :ok = Sidebar.focus_left(table, "bookmarks")

    refute Sidebar.get(table, "outline").focused?
    assert Sidebar.get(table, "bookmarks").focused?
    assert %{id: "bookmarks"} = Sidebar.active_left(table)
  end

  test "source cleanup removes only matching source sidebars", %{table: table} do
    assert :ok =
             Sidebar.register(table, {:extension, :alpha}, %{
               id: "outline",
               display_name: "Outline"
             })

    assert :ok =
             Sidebar.register(table, {:extension, :beta}, %{
               id: "bookmarks",
               display_name: "Bookmarks"
             })

    assert :ok = Sidebar.unregister_source(table, {:extension, :alpha})

    assert Sidebar.get(table, "outline") == nil
    assert %{id: "bookmarks"} = Sidebar.get(table, "bookmarks")
  end

  test "dispatches extension MFAs with the owning source installed", %{table: table} do
    source = activate_source(SidebarActionProbe)
    state = base_state()

    assert :ok =
             Sidebar.register(table, source, %{
               id: "outline",
               display_name: "Outline",
               action_handler: {SidebarActionProbe, :handle}
             })

    assert Sidebar.dispatch_action(table, state, "outline", "open", %{
             row: 1,
             test_pid: self()
           }) == state

    assert_receive {:sidebar_action_called, "open",
                    %{row: 1, sidebar_id: "outline", test_pid: test_pid}, {:ok, ^source}}

    assert test_pid == self()
    assert InvocationContext.current_source() == :none
  end

  test "extension action handlers require an MFA", %{table: table} do
    source = {:extension, :closure_rejected}
    handler = fn state, _action, _context -> state end

    assert {:error, {:extension_action_handler_requires_mfa, ^handler}} =
             Sidebar.register(table, source, %{
               id: "closure",
               display_name: "Closure",
               action_handler: handler
             })
  end

  test "extension invalid returns preserve state while core failures propagate", %{table: table} do
    source = activate_source(SidebarActionProbe)
    state = base_state()

    assert :ok =
             Sidebar.register(table, source, %{
               id: "invalid_extension",
               display_name: "Invalid extension",
               action_handler: {SidebarActionProbe, :invalid}
             })

    assert Sidebar.dispatch_action(table, state, "invalid_extension", "open", %{}) == state

    assert :ok =
             Sidebar.register(table, :config, %{
               id: "raising_core",
               display_name: "Raising core",
               action_handler: {SidebarActionProbe, :raise_error}
             })

    assert_raise RuntimeError, "sidebar callback failed", fn ->
      Sidebar.dispatch_action(table, state, "raising_core", "open", %{})
    end
  end

  test "built-in and config actions retain their exact source", %{table: table} do
    state = base_state()

    for source <- [:builtin, :config] do
      id = "#{source}_sidebar"
      test_pid = self()

      assert :ok =
               Sidebar.register(table, source, %{
                 id: id,
                 display_name: id,
                 action_handler: fn current_state, _action, _context ->
                   send(test_pid, {:core_sidebar_source, InvocationContext.current_source()})
                   current_state
                 end
               })

      assert Sidebar.dispatch_action(table, state, id, "open", %{}) == state
      assert_receive {:core_sidebar_source, {:ok, ^source}}
      assert InvocationContext.current_source() == :none
    end
  end

  defp activate_source(module) do
    source = {:extension, unique_name(:sidebar_source)}
    :ok = CodeLease.activate_source(source, [module])

    on_exit(fn ->
      case CodeLease.quiesce_source(source) do
        {:ok, token} -> CodeLease.complete_unload(token)
        {:error, _reason} -> :ok
      end
    end)

    source
  end

  defp base_state do
    MingaEditor.RenderPipeline.TestHelpers.base_state(rendering: :disabled)
  end

  defp unique_name(prefix),
    do: String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")
end
