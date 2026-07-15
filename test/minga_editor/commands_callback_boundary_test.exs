defmodule MingaEditor.CommandsCallbackBoundaryTest do
  use ExUnit.Case, async: true

  alias Minga.Command
  alias Minga.Command.Registry
  alias Minga.Test.ExtensionCallbackProbe, as: Probe
  alias MingaEditor.Commands

  test "extension command invalid returns and failures preserve prior state" do
    state = base_state()
    source = {:extension, unique_name(:command_source)}

    invalid_name = unique_name(:invalid_extension_command)

    register_command(source, invalid_name, fn _state ->
      {:extension_callback, source, Probe, :return, {:ok, :invalid_command_state}}
    end)

    assert Commands.execute(state, invalid_name) == state

    failed_name = unique_name(:failed_extension_command)
    failure = {:callback_failed, source, Probe, :return, :throw, :failed}

    register_command(source, failed_name, fn _state ->
      {:extension_callback, source, Probe, :return, {:error, failure}}
    end)

    assert Commands.execute(state, failed_name) == state
  end

  test "core command invalid returns and failures propagate" do
    state = base_state()
    source = {:bundle, unique_name(:core_command_source)}
    invalid_name = unique_name(:invalid_core_command)

    register_command(source, invalid_name, fn _state -> :invalid_command_state end)

    assert_raise ArgumentError, ~r/registered core command returned invalid state/, fn ->
      Commands.execute(state, invalid_name)
    end

    raising_name = unique_name(:raising_core_command)
    register_command(source, raising_name, fn _state -> raise "core command failed" end)

    assert_raise RuntimeError, "core command failed", fn ->
      Commands.execute(state, raising_name)
    end
  end

  defp register_command(source, name, execute) do
    command = %Command{name: name, description: "Callback boundary probe", execute: execute}
    :ok = Registry.register_command(Registry, source, command)
    on_exit(fn -> Registry.unregister_source(source) end)
  end

  defp base_state do
    MingaEditor.RenderPipeline.TestHelpers.base_state(rendering: :disabled)
  end

  defp unique_name(prefix),
    do: String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")
end
