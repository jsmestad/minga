defmodule Minga.Config.LoaderTest do
  # Not async because we manipulate XDG_CONFIG_HOME and the global Options server
  use ExUnit.Case, async: false

  alias Minga.Config.Loader
  alias Minga.Config.Options

  setup do
    # Ensure the global Options server is running (config file eval needs it)
    case Options.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> Options.reset()
    end

    :ok
  end

  describe "config_path/1" do
    test "returns the resolved config path" do
      name = :"loader_path_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Agent.start_link(fn -> %{config_path: "/tmp/test.exs", load_error: nil} end, name: name)

      assert Loader.config_path(pid) == "/tmp/test.exs"
    end
  end

  describe "loading valid config" do
    test "applies set options from config file" do
      {_dir, cleanup} =
        make_config_dir("""
        use Minga.Config

        set :tab_width, 4
        set :line_numbers, :relative
        """)

      on_exit(cleanup)

      name = :"loader_valid_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name)

      assert Loader.load_error(pid) == nil
      assert Options.get(:tab_width) == 4
      assert Options.get(:line_numbers) == :relative
    end
  end

  describe "loading config with syntax error" do
    test "captures syntax error and stores it" do
      {_dir, cleanup} =
        make_config_dir("""
        this is not valid elixir %%%
        """)

      on_exit(cleanup)

      name = :"loader_syntax_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name)

      error = Loader.load_error(pid)
      assert is_binary(error)
      assert error =~ "syntax" or error =~ "error" or error =~ "Error"
    end
  end

  describe "loading config with runtime error" do
    test "captures runtime error from invalid option value" do
      {_dir, cleanup} =
        make_config_dir("""
        use Minga.Config

        set :tab_width, -1
        """)

      on_exit(cleanup)

      name = :"loader_runtime_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name)

      error = Loader.load_error(pid)
      assert is_binary(error)
      assert error =~ "positive integer" or error =~ "error" or error =~ "Error"
    end
  end

  describe "missing config file" do
    test "no error when config file does not exist" do
      empty_dir =
        Path.join(System.tmp_dir!(), "minga_empty_#{System.unique_integer([:positive])}")

      File.mkdir_p!(empty_dir)
      System.put_env("XDG_CONFIG_HOME", empty_dir)

      on_exit(fn ->
        System.delete_env("XDG_CONFIG_HOME")
        File.rm_rf!(empty_dir)
      end)

      name = :"loader_missing_#{System.unique_integer([:positive])}"
      {:ok, pid} = Loader.start_link(name: name)

      assert Loader.load_error(pid) == nil
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  # Creates a temporary directory structure that mimics XDG_CONFIG_HOME with
  # a minga/config.exs file. Returns `{minga_dir, cleanup_fn}`.
  @spec make_config_dir(String.t()) :: {String.t(), (-> :ok)}
  defp make_config_dir(config_content) do
    base = Path.join(System.tmp_dir!(), "minga_cfg_#{System.unique_integer([:positive])}")
    minga_dir = Path.join(base, "minga")
    File.mkdir_p!(minga_dir)
    File.write!(Path.join(minga_dir, "config.exs"), config_content)
    System.put_env("XDG_CONFIG_HOME", base)

    cleanup = fn ->
      System.delete_env("XDG_CONFIG_HOME")
      File.rm_rf!(base)

      try do
        Options.reset()
      catch
        :exit, _ -> :ok
      end
    end

    {minga_dir, cleanup}
  end
end
