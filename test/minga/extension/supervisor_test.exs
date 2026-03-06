defmodule Minga.Extension.SupervisorTest do
  use ExUnit.Case, async: true

  alias Minga.Extension.Registry, as: ExtRegistry
  alias Minga.Extension.Supervisor, as: ExtSupervisor

  setup do
    reg_name = :"ext_reg_#{System.unique_integer([:positive])}"
    sup_name = :"ext_sup_#{System.unique_integer([:positive])}"

    {:ok, _} = ExtRegistry.start_link(name: reg_name)
    {:ok, _} = ExtSupervisor.start_link(name: sup_name)

    {:ok, registry: reg_name, supervisor: sup_name}
  end

  describe "start_extension/4" do
    test "starts a valid extension from a local path", ctx do
      {path, cleanup} =
        make_extension("ValidExt", """
        defmodule Minga.TestExtensions.ValidExt do
          use Minga.Extension

          @impl true
          def name, do: :valid_ext

          @impl true
          def description, do: "A test extension"

          @impl true
          def version, do: "1.0.0"

          @impl true
          def init(_config), do: {:ok, %{}}
        end
        """)

      on_exit(fn ->
        cleanup.()
        :code.purge(Minga.TestExtensions.ValidExt)
        :code.delete(Minga.TestExtensions.ValidExt)
      end)

      :ok = ExtRegistry.register(ctx.registry, :valid_ext, path, [])
      {:ok, entry} = ExtRegistry.get(ctx.registry, :valid_ext)

      assert {:ok, pid} =
               ExtSupervisor.start_extension(ctx.supervisor, ctx.registry, :valid_ext, entry)

      assert Process.alive?(pid)

      {:ok, updated} = ExtRegistry.get(ctx.registry, :valid_ext)
      assert updated.status == :running
      assert updated.pid == pid
      assert updated.module == Minga.TestExtensions.ValidExt
    end

    test "records load_error for nonexistent path", ctx do
      :ok =
        ExtRegistry.register(
          ctx.registry,
          :missing,
          "/tmp/does_not_exist_#{System.unique_integer([:positive])}",
          []
        )

      {:ok, entry} = ExtRegistry.get(ctx.registry, :missing)

      assert {:error, _reason} =
               ExtSupervisor.start_extension(ctx.supervisor, ctx.registry, :missing, entry)

      {:ok, updated} = ExtRegistry.get(ctx.registry, :missing)
      assert updated.status == :load_error
    end

    test "records load_error for extension with no .ex files", ctx do
      dir = Path.join(System.tmp_dir!(), "empty_ext_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      :ok = ExtRegistry.register(ctx.registry, :empty, dir, [])
      {:ok, entry} = ExtRegistry.get(ctx.registry, :empty)

      assert {:error, _reason} =
               ExtSupervisor.start_extension(ctx.supervisor, ctx.registry, :empty, entry)

      {:ok, updated} = ExtRegistry.get(ctx.registry, :empty)
      assert updated.status == :load_error
    end

    test "records load_error when init returns error", ctx do
      {path, cleanup} =
        make_extension("FailInit", """
        defmodule Minga.TestExtensions.FailInit do
          use Minga.Extension

          @impl true
          def name, do: :fail_init

          @impl true
          def description, do: "Fails to init"

          @impl true
          def version, do: "0.1.0"

          @impl true
          def init(_config), do: {:error, :something_wrong}
        end
        """)

      on_exit(fn ->
        cleanup.()
        :code.purge(Minga.TestExtensions.FailInit)
        :code.delete(Minga.TestExtensions.FailInit)
      end)

      :ok = ExtRegistry.register(ctx.registry, :fail_init, path, [])
      {:ok, entry} = ExtRegistry.get(ctx.registry, :fail_init)

      assert {:error, _} =
               ExtSupervisor.start_extension(ctx.supervisor, ctx.registry, :fail_init, entry)

      {:ok, updated} = ExtRegistry.get(ctx.registry, :fail_init)
      assert updated.status == :load_error
    end

    test "passes config to init/1", ctx do
      {path, cleanup} =
        make_extension("ConfigExt", """
        defmodule Minga.TestExtensions.ConfigExt do
          use Minga.Extension

          @impl true
          def name, do: :config_ext

          @impl true
          def description, do: "Reads config"

          @impl true
          def version, do: "0.1.0"

          @impl true
          def init(config) do
            if Keyword.get(config, :greeting) == "hello" do
              {:ok, %{}}
            else
              {:error, :bad_config}
            end
          end
        end
        """)

      on_exit(fn ->
        cleanup.()
        :code.purge(Minga.TestExtensions.ConfigExt)
        :code.delete(Minga.TestExtensions.ConfigExt)
      end)

      :ok = ExtRegistry.register(ctx.registry, :config_ext, path, greeting: "hello")
      {:ok, entry} = ExtRegistry.get(ctx.registry, :config_ext)

      assert {:ok, _pid} =
               ExtSupervisor.start_extension(ctx.supervisor, ctx.registry, :config_ext, entry)

      {:ok, updated} = ExtRegistry.get(ctx.registry, :config_ext)
      assert updated.status == :running
    end
  end

  describe "stop_extension/4" do
    test "stops a running extension and purges the module", ctx do
      {path, cleanup} =
        make_extension("StopMe", """
        defmodule Minga.TestExtensions.StopMe do
          use Minga.Extension

          @impl true
          def name, do: :stop_me

          @impl true
          def description, do: "Will be stopped"

          @impl true
          def version, do: "0.1.0"

          @impl true
          def init(_config), do: {:ok, %{}}
        end
        """)

      on_exit(fn ->
        cleanup.()
        :code.purge(Minga.TestExtensions.StopMe)
        :code.delete(Minga.TestExtensions.StopMe)
      end)

      :ok = ExtRegistry.register(ctx.registry, :stop_me, path, [])
      {:ok, entry} = ExtRegistry.get(ctx.registry, :stop_me)
      {:ok, pid} = ExtSupervisor.start_extension(ctx.supervisor, ctx.registry, :stop_me, entry)
      assert Process.alive?(pid)

      {:ok, running_entry} = ExtRegistry.get(ctx.registry, :stop_me)
      :ok = ExtSupervisor.stop_extension(ctx.supervisor, ctx.registry, :stop_me, running_entry)

      refute Process.alive?(pid)

      {:ok, stopped} = ExtRegistry.get(ctx.registry, :stop_me)
      assert stopped.status == :stopped
      assert stopped.pid == nil
      assert stopped.module == nil
    end
  end

  describe "start_all/2 and stop_all/2" do
    test "starts and stops all registered extensions", ctx do
      {path_a, cleanup_a} =
        make_extension("ExtA", """
        defmodule Minga.TestExtensions.ExtA do
          use Minga.Extension

          @impl true
          def name, do: :ext_a

          @impl true
          def description, do: "Extension A"

          @impl true
          def version, do: "1.0.0"

          @impl true
          def init(_config), do: {:ok, %{}}
        end
        """)

      {path_b, cleanup_b} =
        make_extension("ExtB", """
        defmodule Minga.TestExtensions.ExtB do
          use Minga.Extension

          @impl true
          def name, do: :ext_b

          @impl true
          def description, do: "Extension B"

          @impl true
          def version, do: "2.0.0"

          @impl true
          def init(_config), do: {:ok, %{}}
        end
        """)

      on_exit(fn ->
        cleanup_a.()
        cleanup_b.()

        for mod <- [Minga.TestExtensions.ExtA, Minga.TestExtensions.ExtB] do
          :code.purge(mod)
          :code.delete(mod)
        end
      end)

      :ok = ExtRegistry.register(ctx.registry, :ext_a, path_a, [])
      :ok = ExtRegistry.register(ctx.registry, :ext_b, path_b, [])

      :ok = ExtSupervisor.start_all(ctx.supervisor, ctx.registry)

      {:ok, a} = ExtRegistry.get(ctx.registry, :ext_a)
      {:ok, b} = ExtRegistry.get(ctx.registry, :ext_b)
      assert a.status == :running
      assert b.status == :running
      assert Process.alive?(a.pid)
      assert Process.alive?(b.pid)

      :ok = ExtSupervisor.stop_all(ctx.supervisor, ctx.registry)

      {:ok, a_stopped} = ExtRegistry.get(ctx.registry, :ext_a)
      {:ok, b_stopped} = ExtRegistry.get(ctx.registry, :ext_b)
      assert a_stopped.status == :stopped
      assert b_stopped.status == :stopped
    end
  end

  describe "list_extensions/1" do
    test "returns name, version, and status for each extension", ctx do
      {path, cleanup} =
        make_extension("Listed", """
        defmodule Minga.TestExtensions.Listed do
          use Minga.Extension

          @impl true
          def name, do: :listed

          @impl true
          def description, do: "Listable"

          @impl true
          def version, do: "3.2.1"

          @impl true
          def init(_config), do: {:ok, %{}}
        end
        """)

      on_exit(fn ->
        cleanup.()
        :code.purge(Minga.TestExtensions.Listed)
        :code.delete(Minga.TestExtensions.Listed)
      end)

      :ok = ExtRegistry.register(ctx.registry, :listed, path, [])
      :ok = ExtSupervisor.start_all(ctx.supervisor, ctx.registry)

      extensions = ExtSupervisor.list_extensions(ctx.registry)
      assert [{:listed, "3.2.1", :running}] = extensions
    end
  end

  describe "crash isolation" do
    test "a crashing extension does not take down the supervisor", ctx do
      {path, cleanup} =
        make_extension("Crasher", """
        defmodule Minga.TestExtensions.Crasher do
          use Minga.Extension

          @impl true
          def name, do: :crasher

          @impl true
          def description, do: "Will crash"

          @impl true
          def version, do: "0.0.1"

          @impl true
          def init(_config), do: {:ok, %{}}

          @impl true
          def child_spec(_config) do
            %{
              id: __MODULE__,
              start: {Agent, :start_link, [fn -> :ok end]},
              restart: :temporary,
              type: :worker
            }
          end
        end
        """)

      on_exit(fn ->
        cleanup.()
        :code.purge(Minga.TestExtensions.Crasher)
        :code.delete(Minga.TestExtensions.Crasher)
      end)

      :ok = ExtRegistry.register(ctx.registry, :crasher, path, [])
      {:ok, entry} = ExtRegistry.get(ctx.registry, :crasher)
      {:ok, pid} = ExtSupervisor.start_extension(ctx.supervisor, ctx.registry, :crasher, entry)

      # Kill the extension process and wait for the supervisor to handle it
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      # Supervisor is still alive
      assert Process.alive?(Process.whereis(ctx.supervisor))
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  @spec make_extension(String.t(), String.t()) :: {String.t(), (-> :ok)}
  defp make_extension(dir_name, source) do
    dir =
      Path.join(System.tmp_dir!(), "minga_ext_#{dir_name}_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "extension.ex"), source)

    cleanup = fn -> File.rm_rf!(dir) end
    {dir, cleanup}
  end
end
