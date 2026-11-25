defmodule Minga.Session.BufferSwapDirTest do
  @moduledoc "Buffers write swap files only in a VM that runs an interactive editor."

  # Reads the application environment that decides whether this VM runs an interactive editor.
  use ExUnit.Case, async: false

  alias Minga.Session

  setup do
    for key <- [:buffer_swap_dir, :start_editor, :backend] do
      previous = Application.fetch_env(:minga, key)

      on_exit(fn ->
        case previous do
          # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
          {:ok, value} -> Application.put_env(:minga, key, value)
          # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
          :error -> Application.delete_env(:minga, key)
        end
      end)
    end

    # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
    Application.delete_env(:minga, :buffer_swap_dir)
    :ok
  end

  test "the test VM runs no interactive editor, so buffers write no swap files" do
    assert Session.buffer_swap_dir() == nil
  end

  test "an interactive editor turns swap files on for every backend but the headless one" do
    for {backend, expected} <- [tui: Session.swap_dir(), gui: Session.swap_dir(), headless: nil] do
      run_mode(true, backend)
      assert Session.buffer_swap_dir() == expected
    end
  end

  test "a runtime without an editor writes none, whatever its backend" do
    run_mode(false, :tui)
    assert Session.buffer_swap_dir() == nil
  end

  test "an explicit directory, or an explicit nil, overrides the decision" do
    run_mode(true, :tui)

    # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
    Application.put_env(:minga, :buffer_swap_dir, "/tmp/elsewhere")
    assert Session.buffer_swap_dir() == "/tmp/elsewhere"

    # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
    Application.put_env(:minga, :buffer_swap_dir, nil)
    assert Session.buffer_swap_dir() == nil
  end

  # `:start_editor` is read here only. Nothing in this test starts or stops an editor.
  defp run_mode(start_editor?, backend) do
    # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
    Application.put_env(:minga, :start_editor, start_editor?)
    # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
    Application.put_env(:minga, :backend, backend)
  end
end
