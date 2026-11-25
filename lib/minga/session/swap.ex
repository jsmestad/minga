defmodule Minga.Session.Swap do
  @moduledoc """
  Swap file management for crash recovery.

  Dirty buffers periodically write their content to swap files at
  `~/.local/share/minga/swap/`. If Minga crashes, orphaned swap files
  are detected on next startup and the user is offered recovery.

  Swap files use a SHA-256 hash of the absolute file path plus the OS PID
  as the filename: `{hash}.{os_pid}.swap`. Including the OS PID in the
  filename prevents silent overwrites when multiple Minga instances edit
  the same file.

  ## File format (binary)

  The swap file uses a binary length-prefixed format to avoid content
  collision. A text delimiter like `\\n---\\n` would break on files
  containing that exact string.

      <<magic::14 bytes, header_len::32-big, header::header_len bytes, content::rest>>

  Where `magic` is `"MINGA_SWAP_V1\\n"` (14 bytes including newline),
  `header_len` is a 4-byte big-endian integer, `header` is a UTF-8
  encoded string with key=value lines, and `content` is the raw buffer
  content (arbitrary bytes, preserved exactly).

  ## Header fields

      path=/absolute/path/to/file.ex
      os_pid=12345
      mtime=1711234567
      run_started=1711230000

  ## Who owns a swap file

  A swap file belongs to one run of the editor, and recovery must leave it alone while that run is alive. An OS process id alone does not identify a run: after a reboot a new run, or any other program, gets the id of a run that crashed. So the owner is the process id together with the moment that run's VM started (`run_started`, seconds since the epoch):

  - a swap with this VM's process id is this run's only when it also carries this VM's start time, which needs no OS call;
  - a swap with another process id is owned by a live run only when the OS reports a running process with that id that started at the recorded moment (`ps` gives the elapsed time, and a few seconds of difference are allowed);
  - a process the OS reports as a zombie has exited and owns nothing.

  A swap written before `run_started` existed has only the process id, so it is owned when some other process with that id runs, and never by this VM.
  """

  @behaviour Minga.Session.Swap.Backend

  alias Minga.Session.Swap.Prepared

  @magic "MINGA_SWAP_V1\n"
  @temporary_name_regex ~r/\A[0-9a-v]{52}\.(\d+)\.swap\.\d+\.\d+\.tmp\z/

  @typedoc "Metadata parsed from a swap file header."
  @type metadata :: %{
          path: String.t(),
          os_pid: integer(),
          mtime: integer(),
          run_started: integer() | nil,
          swap_path: String.t()
        }

  @typedoc "What the OS says about a process id: gone (or a zombie), or running since a moment that is `nil` when it cannot be read."
  @type process_state :: :gone | {:running, started :: integer() | nil}

  # The VM's start as Erlang records it and the process start that `ps` gives differ by well under a second.
  # Process ids are not reused within seconds of the same start time, so a few seconds of slack cannot match a stranger.
  @start_tolerance_s 5

  @doc "Returns the swap directory path."
  @spec swap_dir(keyword()) :: String.t()
  def swap_dir(opts \\ []) do
    Keyword.get_lazy(opts, :swap_dir, fn ->
      Path.join(System.get_env("XDG_DATA_HOME") || Path.expand("~/.local/share"), "minga/swap")
    end)
  end

  @doc """
  Returns the swap file path for a given source file path.

  Includes the OS PID in the filename so multiple Minga instances
  editing the same file each get their own swap file.
  """
  @spec swap_path(String.t(), keyword()) :: String.t()
  def swap_path(file_path, opts \\ []) when is_binary(file_path) do
    dir = swap_dir(opts)
    hash = :crypto.hash(:sha256, file_path) |> Base.hex_encode32(case: :lower, padding: false)
    os_pid = Keyword.get(opts, :os_pid, os_pid())
    Path.join(dir, "#{hash}.#{os_pid}.swap")
  end

  @doc """
  Writes a swap file for the given source file path and buffer content.

  Creates the swap directory if it doesn't exist. The write is atomic:
  content is written to a temporary file, then renamed to avoid partial
  writes on crash.
  """
  @spec write(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def write(file_path, content, opts \\ [])
      when is_binary(file_path) and is_binary(content) do
    case prepare(file_path, content, opts) do
      {:ok, prepared} -> publish(prepared)
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Writes a complete swap to a uniquely named temporary file.

  The returned value is not visible to recovery until `publish/1` atomically
  promotes it. Each preparation uses its own temporary target, so obsolete
  generations cannot overwrite one another before publication.
  """
  @impl Minga.Session.Swap.Backend
  @spec prepare(String.t(), binary(), keyword()) :: {:ok, Prepared.t()} | {:error, term()}
  def prepare(file_path, content, opts \\ [])
      when is_binary(file_path) and is_binary(content) do
    dir = swap_dir(opts)
    os_pid_val = Keyword.get(opts, :os_pid, os_pid())
    target = swap_path(file_path, opts)
    tmp = temporary_path(target, Keyword.get(opts, :generation))

    header =
      "path=#{file_path}\nos_pid=#{os_pid_val}\nmtime=#{System.os_time(:second)}" <>
        run_started_field(opts)

    header_len = byte_size(header)
    data = <<@magic, header_len::32-big, header::binary, content::binary>>

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp, data) do
      {:ok, %Prepared{temporary_path: tmp, target_path: target}}
    else
      error ->
        File.rm(tmp)
        error
    end
  end

  @doc "Atomically publishes a fully prepared swap file."
  @impl Minga.Session.Swap.Backend
  @spec publish(Prepared.t()) :: :ok | {:error, term()}
  def publish(%Prepared{temporary_path: tmp, target_path: target} = prepared) do
    case File.rename(tmp, target) do
      :ok ->
        :ok

      {:error, reason} ->
        publish_error(reason, discard(prepared))
    end
  end

  @doc "Discards an obsolete prepared swap file."
  @impl Minga.Session.Swap.Backend
  @spec discard(Prepared.t()) :: :ok | {:error, term()}
  def discard(%Prepared{temporary_path: tmp}) do
    remove_file(tmp)
  end

  @doc "Deletes the swap file for the given source file path, if it exists."
  @impl Minga.Session.Swap.Backend
  @spec delete(String.t(), keyword()) :: :ok | {:error, term()}
  def delete(file_path, opts \\ []) when is_binary(file_path) do
    target = swap_path(file_path, opts)

    case temporary_paths(target) do
      {:ok, temporary_paths} -> remove_files([target | temporary_paths])
      {:error, _reason} = error -> error
    end
  end

  @doc "Returns the owner OS PID encoded in a recognized generation temporary filename."
  @spec temporary_owner_pid(String.t()) :: {:ok, pos_integer()} | :error
  def temporary_owner_pid(path) when is_binary(path) do
    case Regex.run(@temporary_name_regex, Path.basename(path), capture: :all_but_first) do
      [pid_string] -> parse_positive_pid(pid_string)
      nil -> :error
    end
  end

  @doc """
  Reads and parses a swap file, returning the metadata and buffer content.

  Returns `{:ok, metadata, content}` or `{:error, reason}`.
  """
  @spec read(String.t()) :: {:ok, metadata(), binary()} | {:error, term()}
  def read(swap_path) when is_binary(swap_path) do
    case File.read(swap_path) do
      {:ok, data} -> parse_swap_file(data, swap_path)
      error -> error
    end
  end

  @doc """
  Checks whether a process with the given OS process id is running. A zombie counts as gone.

  This says nothing about which program it is. To decide whether a swap file's owner is alive, use `owner_alive?/2`.
  """
  @spec pid_alive?(integer()) :: boolean()
  def pid_alive?(os_pid) when is_integer(os_pid), do: process_state(os_pid) != :gone

  @doc """
  The moment this VM started, in seconds since the epoch. Together with the OS process id it identifies this run.

  The value is computed once and kept, so it stays the same for the life of the VM.
  """
  @spec run_started() :: integer()
  def run_started do
    case :persistent_term.get({__MODULE__, :run_started}, nil) do
      nil ->
        started =
          System.convert_time_unit(
            :erlang.system_info(:start_time) + :erlang.time_offset(),
            :native,
            :second
          )

        :persistent_term.put({__MODULE__, :run_started}, started)
        started

      started ->
        started
    end
  end

  @doc """
  Decides whether the run that wrote a swap file is still alive, from the owner recorded in its header.

  See "Who owns a swap file" in the module documentation. `probe` asks the OS about a process id; tests pass their own so that no OS process is spawned.
  """
  @spec owner_alive?(metadata(), (integer() -> process_state())) :: boolean()
  def owner_alive?(%{os_pid: owner_pid, run_started: recorded}, probe \\ &process_state/1)
      when is_integer(owner_pid) and is_function(probe, 1) do
    if owner_pid == os_pid() do
      recorded == run_started()
    else
      same_run?(probe.(owner_pid), recorded)
    end
  end

  @spec same_run?(process_state(), integer() | nil) :: boolean()
  defp same_run?(:gone, _recorded), do: false

  # Without both moments the process id is all there is to go by.
  # A live process then keeps the swap: never take a live run's text.
  defp same_run?({:running, nil}, _recorded), do: true
  defp same_run?({:running, _started}, nil), do: true
  defp same_run?({:running, started}, recorded), do: abs(started - recorded) <= @start_tolerance_s

  @doc "Asks the OS whether a process id is running and since when. Spawns `ps`, so tests of other code pass a stand-in."
  @spec process_state(integer()) :: process_state()
  def process_state(os_pid) when is_integer(os_pid) do
    case System.cmd("ps", ["-p", Integer.to_string(os_pid), "-o", "stat=", "-o", "etime="],
           stderr_to_stdout: true,
           env: [{"LC_ALL", "C"}]
         ) do
      {output, 0} -> parse_process_state(output, System.os_time(:second))
      {_output, _status} -> :gone
    end
  end

  @doc """
  Reads one `ps -o stat= -o etime=` line: the process state letters and the elapsed time as `[[days-]hours:]minutes:seconds`.

  `now` is in seconds since the epoch. An empty line means the process is gone, and so does a state that starts with `Z`: a zombie has exited and only waits for its parent.
  """
  @spec parse_process_state(String.t(), integer()) :: process_state()
  def parse_process_state(output, now) when is_binary(output) and is_integer(now) do
    case String.split(output) do
      [] -> :gone
      ["Z" <> _state | _elapsed] -> :gone
      [_state, elapsed | _rest] -> {:running, started(elapsed, now)}
      [_state] -> {:running, nil}
    end
  end

  @spec started(String.t(), integer()) :: integer() | nil
  defp started(elapsed, now) do
    {days, clock} =
      case String.split(elapsed, "-", parts: 2) do
        [days, clock] -> {days, clock}
        [clock] -> {"0", clock}
      end

    with {days, ""} <- Integer.parse(days),
         {:ok, seconds} <- clock_seconds(String.split(clock, ":")) do
      now - (days * 86_400 + seconds)
    else
      _unreadable -> nil
    end
  end

  @spec clock_seconds([String.t()]) :: {:ok, non_neg_integer()} | :error
  defp clock_seconds(parts) when length(parts) in 2..3 do
    parts
    |> Enum.reduce_while({:ok, 0}, fn part, {:ok, total} ->
      case Integer.parse(part) do
        {value, ""} -> {:cont, {:ok, total * 60 + value}}
        _not_a_number -> {:halt, :error}
      end
    end)
  end

  defp clock_seconds(_parts), do: :error

  @doc "Returns the current OS process ID as an integer."
  @spec os_pid() :: integer()
  def os_pid do
    System.pid() |> String.to_integer()
  end

  # ── Private ─────────────────────────────────────────────────────────────

  # A swap written as this run records when the run started. One written on behalf of another process id
  # (tests, tools) records a start only when it is given one.
  @spec run_started_field(keyword()) :: String.t()
  defp run_started_field(opts) do
    started =
      if Keyword.has_key?(opts, :os_pid),
        do: Keyword.get(opts, :run_started),
        else: Keyword.get(opts, :run_started, run_started())

    if is_integer(started), do: "\nrun_started=#{started}", else: ""
  end

  @spec temporary_path(String.t(), term()) :: String.t()
  defp temporary_path(target, generation) do
    generation = if is_integer(generation), do: generation, else: 0
    unique = System.unique_integer([:positive, :monotonic])
    "#{target}.#{generation}.#{unique}.tmp"
  end

  @spec publish_error(term(), :ok | {:error, term()}) :: {:error, term()}
  defp publish_error(reason, :ok), do: {:error, reason}

  defp publish_error(reason, {:error, discard_reason}) do
    {:error, {:publish_failed, reason, {:discard_failed, discard_reason}}}
  end

  @spec temporary_paths(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  defp temporary_paths(target) do
    directory = Path.dirname(target)
    target_name = Path.basename(target)
    regex = Regex.compile!("\\A#{Regex.escape(target_name)}\\.\\d+\\.\\d+\\.tmp\\z")

    case File.ls(directory) do
      {:ok, names} ->
        paths =
          names
          |> Enum.filter(&Regex.match?(regex, &1))
          |> Enum.map(&Path.join(directory, &1))

        {:ok, paths}

      {:error, :enoent} ->
        {:ok, []}

      {:error, _reason} = error ->
        error
    end
  end

  @spec remove_files([String.t()]) :: :ok | {:error, term()}
  defp remove_files(paths) do
    Enum.reduce(paths, :ok, fn path, result ->
      case {result, remove_file(path)} do
        {:ok, next_result} -> next_result
        {{:error, _reason} = error, _next_result} -> error
      end
    end)
  end

  @spec remove_file(String.t()) :: :ok | {:error, term()}
  defp remove_file(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @spec parse_positive_pid(String.t()) :: {:ok, pos_integer()} | :error
  defp parse_positive_pid(pid_string) do
    case Integer.parse(pid_string) do
      {pid, ""} when pid > 0 -> {:ok, pid}
      _ -> :error
    end
  end

  @spec parse_swap_file(binary(), String.t()) ::
          {:ok, metadata(), binary()} | {:error, :invalid_format}
  defp parse_swap_file(
         <<@magic, header_len::32-big, header::binary-size(header_len), content::binary>>,
         swap_path
       ) do
    case parse_header(header) do
      {:ok, meta} -> {:ok, Map.put(meta, :swap_path, swap_path), content}
      error -> error
    end
  end

  defp parse_swap_file(_, _), do: {:error, :invalid_format}

  @spec parse_header(binary()) :: {:ok, map()} | {:error, :invalid_format}
  defp parse_header(header) do
    fields =
      header
      |> String.split("\n")
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, "=", parts: 2) do
          [key, value] -> Map.put(acc, key, value)
          _ -> acc
        end
      end)

    with {:ok, path} <- Map.fetch(fields, "path"),
         {:ok, pid_str} <- Map.fetch(fields, "os_pid"),
         {:ok, mtime_str} <- Map.fetch(fields, "mtime"),
         {os_pid, ""} <- Integer.parse(pid_str),
         {mtime, ""} <- Integer.parse(mtime_str) do
      {:ok,
       %{
         path: path,
         os_pid: os_pid,
         mtime: mtime,
         run_started: run_started(fields["run_started"])
       }}
    else
      _ -> {:error, :invalid_format}
    end
  end

  # Swap files from before the field existed have none.
  @spec run_started(String.t() | nil) :: integer() | nil
  defp run_started(nil), do: nil

  defp run_started(text) do
    case Integer.parse(text) do
      {started, ""} -> started
      _not_a_number -> nil
    end
  end
end
