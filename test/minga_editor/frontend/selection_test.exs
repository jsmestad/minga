defmodule MingaEditor.Frontend.SelectionTest do
  # Mutates the MINGA_FRONTEND env var and :minga app env, both global.
  use ExUnit.Case, async: false

  alias MingaEditor.Frontend.Selection

  setup do
    previous_env = System.get_env("MINGA_FRONTEND")
    previous_app = Application.get_env(:minga, :tui_impl)

    on_exit(fn ->
      restore_env("MINGA_FRONTEND", previous_env)
      restore_app_env(:tui_impl, previous_app)
    end)

    System.delete_env("MINGA_FRONTEND")
    Application.delete_env(:minga, :tui_impl)
    :ok
  end

  describe "tui_impl/0 default" do
    test "defaults to Go when nothing is configured" do
      assert Selection.tui_impl() == :go
    end
  end

  describe "MINGA_FRONTEND escape hatch" do
    test "zig selects the legacy Zig renderer" do
      System.put_env("MINGA_FRONTEND", "zig")
      assert Selection.tui_impl() == :zig
    end

    test "go selects the Go renderer explicitly" do
      System.put_env("MINGA_FRONTEND", "go")
      assert Selection.tui_impl() == :go
    end

    test "an unknown value raises instead of silently falling back" do
      System.put_env("MINGA_FRONTEND", "wgpu")

      assert_raise ArgumentError, ~r/MINGA_FRONTEND=wgpu is not a valid terminal frontend/, fn ->
        Selection.tui_impl()
      end
    end

    test "the env var wins over the application env" do
      Application.put_env(:minga, :tui_impl, :zig)
      System.put_env("MINGA_FRONTEND", "go")
      assert Selection.tui_impl() == :go
    end
  end

  describe "application env override (tests)" do
    test "accepts an atom" do
      Application.put_env(:minga, :tui_impl, :zig)
      assert Selection.tui_impl() == :zig
    end

    test "accepts a string" do
      Application.put_env(:minga, :tui_impl, "go")
      assert Selection.tui_impl() == :go
    end

    test "rejects an unknown atom" do
      Application.put_env(:minga, :tui_impl, :nope)

      assert_raise ArgumentError, fn -> Selection.tui_impl() end
    end
  end

  describe "renderer_binary_name/1" do
    test "maps implementations to their shipped binary names" do
      assert Selection.renderer_binary_name(:go) == "minga-renderer-go"
      assert Selection.renderer_binary_name(:zig) == "minga-renderer"
    end
  end

  defp restore_env(_name, nil), do: :ok
  defp restore_env(name, value), do: System.put_env(name, value)

  defp restore_app_env(_key, nil), do: Application.delete_env(:minga, :tui_impl)
  defp restore_app_env(key, value), do: Application.put_env(:minga, key, value)
end
