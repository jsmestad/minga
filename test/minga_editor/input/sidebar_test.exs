defmodule MingaEditor.Input.SidebarTest do
  @moduledoc "The generic sidebar handler claims keys only for a left sidebar that is on screen and focused."

  use ExUnit.Case, async: true

  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.Input.Sidebar, as: SidebarInput
  alias MingaEditor.RenderPipeline.TestHelpers

  @enter 13

  setup do
    table = Module.concat(__MODULE__, "Sidebar#{System.unique_integer([:positive])}")
    start_supervised!({Sidebar, name: table, notify: false})
    {:ok, table: table, state: TestHelpers.base_state(sidebar_registry: table)}
  end

  defp register(table, attrs) do
    base = %{id: "outline", display_name: "Outline", placement: :left}
    assert :ok = Sidebar.register(table, {:extension, :outline}, Map.merge(base, attrs))
  end

  test "a visible, focused left sidebar without its own handler takes the key", context do
    register(context.table, %{visible?: true, focused?: true})

    assert {:handled, _state} = SidebarInput.handle_key(context.state, @enter, 0)
    assert {:handled, _state} = SidebarInput.handle_paste(context.state, "text")
  end

  test "a sidebar that is not on screen takes no key, even if it is still marked focused",
       context do
    # Hiding a sidebar leaves its focus mark alone, so the handler must not go by the mark.
    register(context.table, %{visible?: true, focused?: true})
    assert :ok = Sidebar.set_visible(context.table, {:extension, :outline}, "outline", false)
    assert %{visible?: false, focused?: true} = Sidebar.get(context.table, "outline")

    assert {:passthrough, state} = SidebarInput.handle_key(context.state, @enter, 0)
    assert state == context.state
    assert {:passthrough, _state} = SidebarInput.handle_paste(context.state, "text")
  end

  test "a visible sidebar without focus takes no key", context do
    register(context.table, %{visible?: true, focused?: false})

    assert {:passthrough, _state} = SidebarInput.handle_key(context.state, @enter, 0)
  end

  test "a focused sidebar with its own input handler is left to that handler", context do
    register(context.table, %{visible?: true, focused?: true, input_handler: __MODULE__})

    assert {:passthrough, _state} = SidebarInput.handle_key(context.state, @enter, 0)
  end

  test "no sidebar at all takes no key", context do
    assert {:passthrough, _state} = SidebarInput.handle_key(context.state, @enter, 0)
  end
end
