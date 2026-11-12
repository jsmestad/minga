defmodule Minga.Config.OptionsVersionTest do
  use ExUnit.Case, async: true

  alias Minga.Config.Options

  @policy [:agent_tool_permissions, :agent_tool_approval, :agent_destructive_tools]

  setup do
    events = :"option_versions_events_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :duplicate, name: events})
    server = start_supervised!({Options, name: nil, events_registry: events})
    %{server: server, events: events}
  end

  test "ordinary readers project values while authority readers retain every publication", %{
    server: server
  } do
    assert {:ok, values, stamp} = Options.read_versioned(server, @policy)
    assert values == Map.take(Options.all(server), @policy)
    assert :ok = Options.validate_version(server, stamp)

    for name <- @policy do
      assert {:ok, _values, before} = Options.read_versioned(server, @policy)
      value = Options.get(server, name)
      assert {:ok, ^value} = Options.set(server, name, value)
      assert {:error, :options_changed} = Options.validate_version(server, before)
      assert Options.get(server, name) == value
    end
  end

  test "allow deny allow cannot reuse an earlier permission stamp", %{server: server} do
    allowed = %{"write_file" => :allow}
    assert {:ok, ^allowed} = Options.set(server, :agent_tool_permissions, allowed)
    assert {:ok, _values, before} = Options.read_versioned(server, @policy)
    assert {:ok, _} = Options.set(server, :agent_tool_permissions, %{"write_file" => :deny})
    assert {:ok, ^allowed} = Options.set(server, :agent_tool_permissions, allowed)
    assert {:error, :options_changed} = Options.validate_version(server, before)
  end

  test "unchecked publications and reseeding also invalidate equal values", %{server: server} do
    assert {:ok, values, before} = Options.read_versioned(server, @policy)
    assert :ok = Options.set_unchecked(server, :agent_tool_approval, values.agent_tool_approval)
    assert {:error, :options_changed} = Options.validate_version(server, before)
    assert {:ok, _values, before_reset} = Options.read_versioned(server, @policy)
    assert :ok = Options.reset(server)
    assert {:error, :options_changed} = Options.validate_version(server, before_reset)
  end

  test "missing authority never borrows ordinary read defaults", %{server: server} do
    assert {:ok, _values, stamp} = Options.read_versioned(server, @policy)
    table = GenServer.call(server, :table_name)
    :ets.delete(table, :agent_tool_approval)
    assert Options.get(server, :agent_tool_approval) == Options.default(:agent_tool_approval)
    assert {:error, :options_unavailable} = Options.read_versioned(server, @policy)
    assert {:error, :options_unavailable} = Options.validate_version(server, stamp)
  end

  test "a replacement owner cannot validate the former table incarnation", %{
    server: server,
    events: events
  } do
    assert {:ok, _values, stamp} = Options.read_versioned(server, @policy)
    assert :ok = stop_supervised(Options)
    replacement = start_supervised!({Options, name: nil, events_registry: events})
    assert {:error, :options_changed} = Options.validate_version(replacement, stamp)
  end
end
