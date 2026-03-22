defmodule Minga.Port.Manager do
  @moduledoc """
  GenServer that manages the Zig renderer Port process.

  Spawns the Zig binary as an Erlang Port with `{:packet, 4}` framing.
  Incoming input events from Zig are decoded and forwarded to subscribers.
  Outgoing render commands are encoded and sent to the Port.

  Subscribers register via `subscribe/1` and receive messages as:

      {:minga_input, event}

  where `event` is a `Minga.Port.Protocol.input_event()`.
  """

  use GenServer

  @behaviour Minga.Port.Frontend

  alias Minga.Port.Protocol

  @typedoc "Renderer backend."
  @type backend :: :tui | :gui

  @typedoc "Options for starting the port manager."
  @type start_opt ::
          {:name, GenServer.name()}
          | {:renderer_path, String.t()}
          | {:backend, backend()}

  alias Minga.Port.Manager.State, as: PortState

  @typedoc "Internal state."
  @type state :: PortState.t()

  # ── Client API ──

  @doc "Starts the port manager."
  @impl Minga.Port.Frontend
  @spec start_link([start_opt()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Sends a list of encoded render command binaries to the Zig renderer."
  @impl Minga.Port.Frontend
  @spec send_commands(GenServer.server(), [binary()]) :: :ok
  def send_commands(server \\ __MODULE__, commands) when is_list(commands) do
    GenServer.cast(server, {:send_commands, commands})
  end

  @doc "Subscribes the calling process to receive input events."
  @impl Minga.Port.Frontend
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server \\ __MODULE__) do
    GenServer.call(server, {:subscribe, self()})
  end

  @doc "Returns the terminal size as `{width, height}`, or nil if not yet ready."
  @impl Minga.Port.Frontend
  @spec terminal_size(GenServer.server()) :: {pos_integer(), pos_integer()} | nil
  def terminal_size(server \\ __MODULE__) do
    GenServer.call(server, :terminal_size)
  end

  @doc "Returns whether the Zig renderer has sent its ready signal."
  @impl Minga.Port.Frontend
  @spec ready?(GenServer.server()) :: boolean()
  def ready?(server \\ __MODULE__) do
    GenServer.call(server, :ready?)
  end

  @doc "Returns the frontend's reported capabilities."
  @impl Minga.Port.Frontend
  @spec capabilities(GenServer.server()) :: Minga.Port.Capabilities.t()
  def capabilities(server \\ __MODULE__) do
    GenServer.call(server, :capabilities)
  end

  # ── Server Callbacks ──

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    # Port.Manager sends large binary render commands every frame.
    # Frequent full sweeps reclaim binary refs promptly.
    Process.flag(:fullsweep_after, 20)

    backend = Keyword.get(opts, :backend, :tui)
    renderer_path = Keyword.get(opts, :renderer_path, default_renderer_path(backend))

    state = %PortState{renderer_path: renderer_path}
    {:ok, start_port(state)}
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), state()) :: {:reply, term(), state()}
  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    subscribers = [pid | state.subscribers] |> Enum.uniq()
    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  def handle_call(:terminal_size, _from, state) do
    {:reply, state.terminal_size, state}
  end

  def handle_call(:ready?, _from, state) do
    {:reply, state.ready, state}
  end

  def handle_call(:capabilities, _from, state) do
    {:reply, state.capabilities, state}
  end

  @impl true
  @spec handle_cast(term(), state()) :: {:noreply, state()}
  def handle_cast({:send_commands, _commands}, %{port: nil} = state) do
    {:noreply, state}
  end

  def handle_cast({:send_commands, commands}, state) do
    batch = IO.iodata_to_binary(commands)
    Port.command(state.port, batch)
    {:noreply, state}
  end

  @impl true
  @spec handle_info(term(), state()) :: {:noreply, state()}
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    case Protocol.decode_event(data) do
      {:ok, {:ready, width, height, caps}} ->
        new_state = %{state | ready: true, terminal_size: {width, height}, capabilities: caps}
        broadcast(new_state.subscribers, {:minga_input, {:ready, width, height}})
        {:noreply, new_state}

      {:ok, {:ready, width, height}} ->
        new_state = %{state | ready: true, terminal_size: {width, height}}
        broadcast(new_state.subscribers, {:minga_input, {:ready, width, height}})
        {:noreply, new_state}

      {:ok, {:capabilities_updated, caps}} ->
        new_state = %{state | capabilities: caps}
        broadcast(new_state.subscribers, {:minga_input, {:capabilities_updated, caps}})
        {:noreply, new_state}

      {:ok, {:resize, width, height}} ->
        new_state = %{state | terminal_size: {width, height}}
        broadcast(new_state.subscribers, {:minga_input, {:resize, width, height}})
        {:noreply, new_state}

      {:ok, event} ->
        broadcast(state.subscribers, {:minga_input, event})
        {:noreply, state}

      {:error, reason} ->
        Minga.Log.warning(
          :port,
          "Failed to decode event: #{inspect(reason)}, data: #{inspect(data)}"
        )

        {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, 0}}, %{port: port} = state) do
    Minga.Log.info(:port, "Renderer: exited normally")
    maybe_stop_system(0)
    {:noreply, %{state | port: nil, ready: false}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Minga.Log.error(:port, "Renderer: crashed (exit #{status})")
    maybe_stop_system(1)
    {:noreply, %{state | port: nil, ready: false}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    subscribers = Enum.reject(state.subscribers, &(&1 == pid))
    {:noreply, %{state | subscribers: subscribers}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Private ──

  @spec start_port(state()) :: state()
  defp start_port(state) do
    if File.exists?(state.renderer_path) do
      env = tty_env()

      port =
        Port.open(
          {:spawn_executable, state.renderer_path},
          [:binary, :exit_status, {:packet, 4}, :use_stdio, {:env, env}]
        )

      %{state | port: port}
    else
      state
    end
  end

  # Detect the tty device path and pass it to the Zig renderer.
  #
  # When spawned as a BEAM Port, the child process loses access to /dev/tty
  # because Erlang's erl_child_setup calls setsid().  We detect the real tty
  # device path and pass it via the MINGA_TTY env var.
  #
  # Detection order:
  #   1. MINGA_TTY env var (set by bin/minga shell wrapper or user)
  #   2. `ps -o tty=` on the BEAM process (reads from kernel, not stdin)
  #   3. Empty (Zig renderer falls back to /dev/tty — may fail)
  @spec tty_env() :: [{charlist(), charlist()}]
  defp tty_env do
    tty_path = System.get_env("MINGA_TTY") || detect_tty()

    case tty_path do
      nil -> []
      path -> [{~c"MINGA_TTY", String.to_charlist(path)}]
    end
  end

  @spec detect_tty() :: String.t() | nil
  defp detect_tty do
    with {output, 0} <- System.cmd("ps", ["-o", "tty=", "-p", to_string(:os.getpid())]),
         tty_name = String.trim(output),
         true <- tty_name != "" and tty_name != "??" do
      tty_path_for(tty_name)
    else
      _ -> nil
    end
  end

  @doc """
  Builds a `/dev/` path from the tty name returned by `ps -o tty=`.

  The format varies by OS and version:
  - macOS long form: `"ttys008"` → `"/dev/ttys008"`
  - macOS short form: `"s003"` → `"/dev/ttys003"`
  - Linux: `"pts/3"` → `"/dev/pts/3"`

  Checks if `/dev/{name}` exists first (handles long form and Linux).
  Falls back to `/dev/tty{name}` for short forms.
  """
  @spec tty_path_for(String.t()) :: String.t()
  def tty_path_for(tty_name) do
    path = "/dev/#{tty_name}"

    if File.exists?(path) do
      path
    else
      "/dev/tty#{tty_name}"
    end
  end

  @spec broadcast([pid()], term()) :: :ok
  defp broadcast(subscribers, message) do
    Enum.each(subscribers, &send(&1, message))
  end

  @spec default_renderer_path(backend()) :: String.t()
  defp default_renderer_path(backend) do
    binary_name = renderer_binary_name(backend)

    # Priority 1: app bundle context (BEAM release embedded inside Minga.app).
    # Priority 2: priv/ directory (Burrito binary or standard release).
    # Priority 3: dev/test fallback in the source tree.
    case find_app_bundle_binary(binary_name, backend) do
      {:ok, path} ->
        path

      :not_in_bundle ->
        priv_path = Application.app_dir(:minga, "priv/#{binary_name}")
        if File.exists?(priv_path), do: priv_path, else: dev_fallback_path(backend)
    end
  end

  @spec dev_fallback_path(backend()) :: String.t()
  defp dev_fallback_path(:gui), do: find_xcode_build_product("Minga")

  defp dev_fallback_path(:tui) do
    Path.join([File.cwd!(), "zig", "zig-out", "bin", "minga-renderer"])
  end

  # When running from a BEAM release embedded inside a .app bundle,
  # resolve the frontend binary relative to the bundle root.
  #
  # The release root is at: Minga.app/Contents/Resources/release/
  # The GUI binary is at:   Minga.app/Contents/MacOS/Minga
  # The TUI binary is at:   Minga.app/Contents/Resources/release/lib/minga-*/priv/minga-renderer
  #                         (which Application.app_dir already resolves, so TUI returns :not_in_bundle)
  @spec find_app_bundle_binary(String.t(), backend()) :: {:ok, String.t()} | :not_in_bundle
  defp find_app_bundle_binary(binary_name, :gui) do
    case app_bundle_root() do
      {:ok, bundle_root} ->
        gui_path = Path.join([bundle_root, "Contents", "MacOS", binary_name])

        if File.exists?(gui_path) do
          {:ok, gui_path}
        else
          :not_in_bundle
        end

      :not_in_bundle ->
        :not_in_bundle
    end
  end

  defp find_app_bundle_binary(_binary_name, _tui), do: :not_in_bundle

  # Detect whether the BEAM is running inside a .app bundle by checking
  # the release root path. Returns the bundle root (e.g., "/path/to/Minga.app")
  # or :not_in_bundle.
  #
  # The release root is the directory containing bin/, lib/, releases/, erts-*.
  # In a bundle, this is at: Minga.app/Contents/Resources/release/
  # So the bundle root is 3 levels up from the release root.
  @spec app_bundle_root() :: {:ok, String.t()} | :not_in_bundle
  defp app_bundle_root do
    # :code.root_dir() returns the release root in an OTP release,
    # e.g., "/path/to/Minga.app/Contents/Resources/release"
    release_root = :code.root_dir() |> to_string()

    if String.contains?(release_root, ".app/Contents/Resources/release") do
      # Walk up: release/ -> Resources/ -> Contents/ -> Minga.app/
      bundle_root =
        release_root
        |> Path.join("..")
        |> Path.join("..")
        |> Path.join("..")
        |> Path.expand()

      {:ok, bundle_root}
    else
      :not_in_bundle
    end
  end

  # Only stop the BEAM when running as a real editor (not in tests).
  @spec maybe_stop_system(non_neg_integer()) :: :ok
  defp maybe_stop_system(code) do
    if Application.get_env(:minga, :start_editor) do
      System.stop(code)
    end

    :ok
  end

  @spec renderer_binary_name(backend()) :: String.t()
  defp renderer_binary_name(:tui), do: "minga-renderer"
  defp renderer_binary_name(:gui), do: "Minga"

  # Find the Xcode build product in DerivedData.
  # Uses `xcodebuild -showBuildSettings` to get the exact path.
  #
  # For `type: application` targets, the executable lives inside the .app
  # bundle at `Minga.app/Contents/MacOS/Minga`. We parse both
  # BUILT_PRODUCTS_DIR and FULL_PRODUCT_NAME to construct the correct path.
  @spec find_xcode_build_product(String.t()) :: String.t()
  defp find_xcode_build_product(product_name) do
    project_path = Path.join([File.cwd!(), "macos", "Minga.xcodeproj"])

    case System.cmd(
           "xcodebuild",
           [
             "-project",
             project_path,
             "-scheme",
             "Minga",
             "-configuration",
             "Debug",
             "-showBuildSettings"
           ],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        resolve_build_product_path(output, product_name)

      _ ->
        Path.join([File.cwd!(), "macos", "build", "Debug", product_name])
    end
  end

  @spec resolve_build_product_path(String.t(), String.t()) :: String.t()
  defp resolve_build_product_path(build_settings, product_name) do
    built_dir = parse_build_setting(build_settings, "BUILT_PRODUCTS_DIR")
    full_product = parse_build_setting(build_settings, "FULL_PRODUCT_NAME")

    case {built_dir, full_product} do
      {dir, app_name} when is_binary(dir) and is_binary(app_name) ->
        resolve_executable_in_product(dir, app_name, product_name)

      {dir, _} when is_binary(dir) ->
        Path.join(dir, product_name)

      _ ->
        Path.join([File.cwd!(), "macos", "build", "Debug", product_name])
    end
  end

  @spec resolve_executable_in_product(String.t(), String.t(), String.t()) :: String.t()
  defp resolve_executable_in_product(dir, app_name, product_name) do
    if String.ends_with?(app_name, ".app") do
      # Application target: binary is inside the .app bundle
      Path.join([dir, app_name, "Contents", "MacOS", product_name])
    else
      # Tool target (legacy): binary is directly in the build dir
      Path.join(dir, product_name)
    end
  end

  @spec parse_build_setting(String.t(), String.t()) :: String.t() | nil
  defp parse_build_setting(output, key) do
    # Anchor to whitespace so e.g. "BUILT_PRODUCTS_DIR" doesn't match
    # "PRECOMPS_INCLUDE_HEADERS_FROM_BUILT_PRODUCTS_DIR".
    case Regex.run(~r/\s+#{Regex.escape(key)} = (.+)/, output) do
      [_, value] -> String.trim(value)
      _ -> nil
    end
  end
end
