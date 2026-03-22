defmodule Minga.Tool.Installer.Stub do
  @moduledoc """
  Stub installer for tests. Configurable per-test via ETS.

  ## Usage in tests

      setup do
        Minga.Tool.Installer.Stub.reset()
        :ok
      end

      test "install succeeds" do
        Stub.set_install_result({:ok, "1.0.0"})
        # ... test code that triggers install ...
      end

      test "install fails" do
        Stub.set_install_result({:error, "simulated failure"})
        # ... test code that triggers install ...
      end
  """

  @behaviour Minga.Tool.Installer

  alias Minga.Tool.Recipe

  @table __MODULE__

  # ── Setup ───────────────────────────────────────────────────────────────────

  @doc """
  Creates the ETS table if it doesn't exist. Call once from test_helper.exs
  so the table is owned by the long-lived test coordinator process and
  survives across individual test processes.
  """
  @spec ensure_table() :: :ok
  def ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  end

  @doc "Resets the stub to default (successful) behavior. Table must already exist."
  @spec reset() :: :ok
  def reset do
    :ets.insert(@table, {:install_result, {:ok, "1.0.0-stub"}})
    :ets.insert(@table, {:uninstall_result, :ok})
    :ets.insert(@table, {:installed_version, {:ok, "1.0.0-stub"}})
    :ets.insert(@table, {:latest_version, {:ok, "2.0.0-stub"}})
    :ets.insert(@table, {:install_delay_ms, 0})
    :ets.insert(@table, {:installs, []})
    :ets.insert(@table, {:uninstalls, []})
    :ok
  end

  @doc "Sets the result that `install/3` will return."
  @spec set_install_result({:ok, String.t()} | {:error, term()}) :: :ok
  def set_install_result(result) do
    :ets.insert(@table, {:install_result, result})
    :ok
  end

  @doc "Sets the result that `uninstall/2` will return."
  @spec set_uninstall_result(:ok | {:error, term()}) :: :ok
  def set_uninstall_result(result) do
    :ets.insert(@table, {:uninstall_result, result})
    :ok
  end

  @doc "Sets the result that `installed_version/2` will return."
  @spec set_installed_version({:ok, String.t()} | nil) :: :ok
  def set_installed_version(result) do
    :ets.insert(@table, {:installed_version, result})
    :ok
  end

  @doc "Sets the result that `latest_version/1` will return."
  @spec set_latest_version({:ok, String.t()} | {:error, term()}) :: :ok
  def set_latest_version(result) do
    :ets.insert(@table, {:latest_version, result})
    :ok
  end

  @doc "Sets a delay in milliseconds before install completes."
  @spec set_install_delay(non_neg_integer()) :: :ok
  def set_install_delay(ms) when is_integer(ms) and ms >= 0 do
    :ets.insert(@table, {:install_delay_ms, ms})
    :ok
  end

  @doc "Returns the list of tools that were installed (name atoms)."
  @spec installs() :: [atom()]
  def installs do
    case :ets.lookup(@table, :installs) do
      [{:installs, list}] -> list
      [] -> []
    end
  end

  @doc "Returns the list of tools that were uninstalled (name atoms)."
  @spec uninstalls() :: [atom()]
  def uninstalls do
    case :ets.lookup(@table, :uninstalls) do
      [{:uninstalls, list}] -> list
      [] -> []
    end
  end

  # ── Behaviour callbacks ────────────────────────────────────────────────────

  @impl true
  @spec install(Recipe.t(), String.t(), Minga.Tool.Installer.progress_callback()) ::
          {:ok, String.t()} | {:error, term()}
  def install(%Recipe{name: name} = _recipe, dest_dir, progress) do
    # Record the install attempt
    current = installs()
    :ets.insert(@table, {:installs, current ++ [name]})

    # Create the directory structure so Manager can create symlinks
    bin_dir = Path.join(dest_dir, "bin")
    File.mkdir_p!(bin_dir)

    progress.(:installing, "Stub installing #{name}...")

    # Simulate delay if configured (test stub only, not production code)
    delay = get_value(:install_delay_ms, 0)
    # credo:disable-for-next-line Minga.Credo.NoProcessSleepCheck
    if delay > 0, do: Process.sleep(delay)

    progress.(:verifying, "Stub verifying #{name}...")

    get_value(:install_result, {:ok, "1.0.0-stub"})
  end

  @impl true
  @spec uninstall(Recipe.t(), String.t()) :: :ok | {:error, term()}
  def uninstall(%Recipe{name: name} = _recipe, _dest_dir) do
    current = uninstalls()
    :ets.insert(@table, {:uninstalls, current ++ [name]})

    get_value(:uninstall_result, :ok)
  end

  @impl true
  @spec installed_version(Recipe.t(), String.t()) :: {:ok, String.t()} | nil
  def installed_version(_recipe, _dest_dir) do
    get_value(:installed_version, {:ok, "1.0.0-stub"})
  end

  @impl true
  @spec latest_version(Recipe.t()) :: {:ok, String.t()} | {:error, term()}
  def latest_version(_recipe) do
    get_value(:latest_version, {:ok, "2.0.0-stub"})
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec get_value(atom(), term()) :: term()
  defp get_value(key, default) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> default
    end
  end
end
