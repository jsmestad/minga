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
      run_started=Tue Nov 24 20:27:02 2026

  ## Who owns a swap file

  A swap file belongs to one run of the editor, and recovery must leave it alone while that run is alive. An OS process id alone does not identify a run: after a reboot a new run, or any other program, gets the id of a run that crashed. So the owner is a `Minga.Session.Instance`: the process id together with the start time the OS reports for that process, recorded as `run_started`:

  - a swap with this VM's process id is this run's only when it also carries this run's start time, which needs no OS call;
  - a swap with another process id is owned by a live run only when the OS reports a running process with that id and exactly that start time;
  - a process the OS reports as a zombie has exited and owns nothing.

  A swap written before `run_started` existed has only the process id, so it is owned while some other process with that id runs, and never by this VM.
  """

  @behaviour Minga.Session.Swap.Backend

  alias Minga.Session.Instance
  alias Minga.Session.Swap.Prepared

  @magic "MINGA_SWAP_V1\n"
  @review_magic "MINGA_SWAP_V2\n"
  @temporary_name_regex ~r/\A[0-9a-v]{52}\.(\d+)(?:\.held-[0-9a-f]{32})?\.swap\.\d+\.\d+\.tmp\z/

  @typedoc "The review snapshot associated with the exact last saved content."
  @type saved_review :: {<<_::256>>, binary()}

  @typedoc "One swap generation's review history. A clean record has no unsaved text."
  @type review :: %{
          kind: :dirty | :clean,
          dirty: binary() | nil,
          saved: saved_review() | nil
        }

  @typedoc "Incarnation, generation and written time in microseconds."
  @type revision :: {pos_integer(), pos_integer(), pos_integer()}

  @type disk_base :: <<_::256>> | :missing | :invalid

  @typedoc "Metadata parsed from a swap file header."
  @type metadata :: %{
          required(:path) => String.t(),
          required(:os_pid) => integer(),
          required(:mtime) => integer(),
          required(:run_started) => String.t() | nil,
          required(:swap_path) => String.t(),
          optional(:kind) => :clean | :dirty,
          optional(:revision) => revision() | {:invalid, <<_::256>>},
          optional(:disk_base) => disk_base(),
          optional(:review) => review() | :invalid,
          optional(:held?) => true
        }

  @typedoc "The exact publication retained until a recovery request is adopted."
  @type identity :: %{
          required(:path) => String.t(),
          required(:os_pid) => integer(),
          required(:run_started) => String.t() | nil,
          required(:swap_path) => String.t(),
          required(:revision) => identity_revision()
        }

  @typep identity_revision :: revision() | {:invalid | :legacy, <<_::256>>}

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
    hash = path_key(file_path)
    os_pid = Keyword.get(opts, :os_pid, os_pid())
    Path.join(dir, "#{hash}.#{os_pid}.swap")
  end

  @doc "Moves an unadopted review publication out of the writable slot without changing its bytes."
  @spec hold(String.t()) :: {:ok, String.t()} | {:error, File.posix()}
  def hold(swap_path) do
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    held = String.replace_suffix(swap_path, ".swap", ".held-#{token}.swap")
    with :ok <- File.rename(swap_path, held), do: {:ok, held}
  end

  @doc "Lists published swap generations whose filename identifies this source path."
  @spec paths_for_file(String.t(), keyword()) :: [String.t()]
  def paths_for_file(file_path, opts \\ []) when is_binary(file_path) do
    dir = swap_dir(opts)
    prefix = path_key(file_path) <> "."

    case File.ls(dir) do
      {:ok, names} ->
        for name <- names,
            String.starts_with?(name, prefix),
            String.ends_with?(name, ".swap"),
            do: Path.join(dir, name)

      {:error, _reason} ->
        []
    end
  end

  @spec path_key(String.t()) :: String.t()
  defp path_key(path),
    do: :crypto.hash(:sha256, path) |> Base.hex_encode32(case: :lower, padding: false)

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
    prepare_at(swap_path(file_path, opts), file_path, content, opts)
  end

  @spec prepare_at(String.t(), String.t(), binary(), keyword()) ::
          {:ok, Prepared.t()} | {:error, term()}
  defp prepare_at(target, file_path, content, opts) do
    os_pid_val = Keyword.get(opts, :os_pid, os_pid())
    dir = Path.dirname(target)
    tmp = temporary_path(target, Keyword.get(opts, :generation))

    header =
      "path=#{file_path}\nos_pid=#{os_pid_val}\nmtime=#{System.os_time(:second)}" <>
        run_started_field(opts)

    with {:ok, data} <- encode_swap(header, content, opts),
         :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp, data) do
      {:ok, %Prepared{temporary_path: tmp, target_path: target}}
    else
      error ->
        File.rm(tmp)
        error
    end
  end

  @doc "Prepares a saved-only replacement in the exact dirty record's slot."
  @spec prepare_saved_only(metadata(), saved_review()) :: {:ok, Prepared.t()} | {:error, term()}
  def prepare_saved_only(%{revision: {incarnation, generation, written}} = source, saved) do
    opts = [
      os_pid: source.os_pid,
      run_started: source.run_started,
      incarnation: incarnation,
      generation: generation + 1,
      review: %{kind: :clean, dirty: nil, saved: saved}
    ]

    opts = if source[:held?], do: Keyword.put(opts, :written, written), else: opts
    prepare_at(source.swap_path, source.path, "", opts)
  end

  @spec encode_swap(binary(), binary(), keyword()) :: {:ok, iodata()} | {:error, :invalid_review}
  defp encode_swap(header, content, opts) do
    case Keyword.get(opts, :review) do
      nil ->
        {:ok, [<<@magic, byte_size(header)::32>>, header, content]}

      review ->
        encode_review_swap(
          append_disk_base(header, Keyword.get(opts, :disk_base)),
          content,
          review,
          Keyword.get(opts, :incarnation),
          Keyword.get(opts, :generation),
          Keyword.get_lazy(opts, :written, fn -> System.os_time(:microsecond) end)
        )
    end
  end

  @spec append_disk_base(binary(), disk_base() | nil) :: binary()
  defp append_disk_base(header, <<_::256>> = digest),
    do: header <> "\ndisk_base=" <> Base.encode16(digest)

  defp append_disk_base(header, :missing), do: header <> "\ndisk_base=missing"
  defp append_disk_base(header, nil), do: header

  @spec encode_review_swap(binary(), binary(), review(), term(), term(), pos_integer()) ::
          {:ok, iodata()} | {:error, :invalid_review}
  defp encode_review_swap(header, content, review, incarnation, generation, written)
       when is_integer(incarnation) and incarnation > 0 and incarnation < 0x10000000000000000 and
              is_integer(generation) and generation > 0 and generation < 0x10000000000000000 do
    with {:ok, kind} <- review_kind(review, content),
         {:ok, review_frame} <- encode_review(review) do
      framing =
        <<@review_magic, byte_size(header)::32, byte_size(content)::64, incarnation::64,
          generation::64, written::signed-64, kind::8>>

      {:ok, [framing, header, content, review_frame, :crypto.hash(:sha256, review_frame)]}
    end
  end

  defp encode_review_swap(_header, _content, _review, _incarnation, _generation, _written),
    do: {:error, :invalid_review}

  @spec review_kind(review(), binary()) :: {:ok, 0 | 1} | {:error, :invalid_review}
  defp review_kind(%{kind: :dirty}, _content), do: {:ok, 1}
  defp review_kind(%{kind: :clean, saved: {_, _}, dirty: nil}, ""), do: {:ok, 0}
  defp review_kind(_review, _content), do: {:error, :invalid_review}

  @spec encode_review(review()) :: {:ok, iodata()} | {:error, :invalid_review}
  defp encode_review(%{dirty: dirty, saved: saved}) when is_binary(dirty) or is_nil(dirty) do
    dirty = dirty || ""

    case saved do
      nil ->
        {:ok, [<<byte_size(dirty)::64>>, dirty, <<0>>]}

      {<<_::256>> = digest, snapshot} when is_binary(snapshot) and byte_size(snapshot) > 0 ->
        {:ok, [<<byte_size(dirty)::64>>, dirty, <<1>>, digest, snapshot]}

      _invalid ->
        {:error, :invalid_review}
    end
  end

  defp encode_review(_review), do: {:error, :invalid_review}

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

  @doc "Checks the exact publication identity after a recovery read."
  @spec current?(identity() | metadata()) :: boolean()
  def current?(%{path: path, swap_path: swap, os_pid: owner, run_started: started, revision: rev}) do
    case read(swap) do
      {:ok, %{path: ^path, os_pid: ^owner, run_started: ^started} = meta, text} ->
        record_revision(meta, text) == rev

      _replaced ->
        false
    end
  end

  def current?(_legacy), do: false

  @doc "Returns the publication identity without retaining a copy of the review checkpoint."
  @spec identity(metadata(), binary()) :: identity()
  def identity(meta, text) do
    meta
    |> Map.take([:path, :os_pid, :run_started, :swap_path])
    |> Map.put(:revision, record_revision(meta, text))
  end

  @spec record_revision(metadata(), binary()) :: identity_revision()
  defp record_revision(%{revision: revision}, _text), do: revision
  defp record_revision(_legacy, text), do: {:legacy, :crypto.hash(:sha256, text)}

  @doc "Checks whether automatic recovery can use the loaded file as the swap's original base."
  @spec matches_disk_base?(metadata(), binary() | nil) :: boolean()
  def matches_disk_base?(%{revision: {:invalid, _}}, _digest), do: false
  def matches_disk_base?(%{disk_base: :missing}, nil), do: true
  def matches_disk_base?(%{disk_base: <<_::256>> = digest}, digest), do: true
  def matches_disk_base?(%{disk_base: _}, _digest), do: false
  def matches_disk_base?(_older_record, _digest), do: true

  @doc """
  Checks whether a process with the given OS process id is running. A zombie counts as gone.

  This says nothing about which program it is. To decide whether a swap file's owner is alive, use `owner_alive?/2`.
  """
  @spec pid_alive?(integer()) :: boolean()
  def pid_alive?(os_pid) when is_integer(os_pid) and os_pid > 0,
    do: Instance.start_time(os_pid) != :error

  def pid_alive?(os_pid) when is_integer(os_pid), do: false

  @doc """
  This run as an owner of swap files: its OS process id and the start time the OS reports for it.

  Reading the start time asks the OS once. `Minga.Application` does that at boot, and the value is kept for the life of the VM, so later calls cost nothing and spawn nothing.
  """
  @spec this_run() :: Instance.t()
  def this_run do
    case :persistent_term.get({__MODULE__, :this_run}, nil) do
      nil ->
        instance = Instance.current()
        :persistent_term.put({__MODULE__, :this_run}, instance)
        instance

      instance ->
        instance
    end
  end

  @doc """
  Decides whether the run that wrote a swap file is still alive, from the owner recorded in its header.

  See "Who owns a swap file" in the module documentation. `start_time` asks the OS when a process id started; tests pass their own so that no OS process is spawned.
  """
  @spec owner_alive?(metadata(), (pos_integer() -> {:ok, String.t()} | :error)) :: boolean()
  def owner_alive?(
        %{os_pid: owner_pid, run_started: recorded},
        start_time \\ &Instance.start_time/1
      )
      when is_integer(owner_pid) and is_function(start_time, 1) do
    %{os_pid: own_pid, started: own_started} = this_run()

    cond do
      owner_pid == own_pid -> recorded == own_started
      owner_pid <= 0 -> false
      true -> same_run?(start_time.(owner_pid), recorded)
    end
  end

  @spec same_run?({:ok, String.t()} | :error, String.t() | nil) :: boolean()
  defp same_run?(:error, _recorded), do: false
  # A swap from before the start time was recorded has only the process id to go by.
  # A live process then keeps the swap: never take a live run's text.
  defp same_run?({:ok, _started}, nil), do: true
  defp same_run?({:ok, started}, recorded), do: started == recorded

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
        else: Keyword.get_lazy(opts, :run_started, fn -> this_run().started end)

    if is_binary(started), do: "\nrun_started=#{started}", else: ""
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
          {:ok, metadata(), binary()} | {:error, :invalid_format | :invalid_review_record}
  defp parse_swap_file(
         <<@magic, header_len::32-big, header::binary-size(header_len), content::binary>>,
         swap_path
       ) do
    case parse_header(header) do
      {:ok, meta} -> {:ok, Map.put(meta, :swap_path, swap_path), content}
      error -> error
    end
  end

  defp parse_swap_file(
         <<@review_magic, header_len::32, content_len::64, incarnation::64, generation::64,
           written::signed-64, kind_code, header::binary-size(header_len),
           content::binary-size(content_len), frame::binary>> = file,
         swap_path
       )
       when kind_code == 1 or (kind_code == 0 and content_len == 0) do
    kind = if kind_code == 1, do: :dirty, else: :clean

    with {:ok, meta} <- parse_header(header),
         {:ok, held?} <- validate_review_path(meta, swap_path) do
      {revision, review} =
        if incarnation > 0 and generation > 0 and written > 0 do
          {{incarnation, generation, written}, parse_review(kind, frame)}
        else
          {{:invalid, :crypto.hash(:sha256, file)}, :invalid}
        end

      meta =
        Map.merge(meta, %{kind: kind, revision: revision, review: review, swap_path: swap_path})

      {:ok, if(held?, do: Map.put(meta, :held?, true), else: meta), content}
    else
      {:error, _reason} -> {:error, :invalid_review_record}
    end
  end

  defp parse_swap_file(<<@review_magic, _::binary>>, _path), do: {:error, :invalid_review_record}

  defp parse_swap_file(_, _), do: {:error, :invalid_format}

  @spec validate_review_path(map(), String.t()) ::
          {:ok, boolean()} | {:error, :invalid_review_record}
  defp validate_review_path(%{path: path, os_pid: os_pid}, swap) when os_pid > 0 do
    expected = Path.expand(swap_path(path, os_pid: os_pid, swap_dir: Path.dirname(swap)))
    swap = Path.expand(swap)
    prefix = String.replace_suffix(expected, ".swap", ".held-")
    size = byte_size(prefix)

    case swap do
      ^expected ->
        {:ok, false}

      <<^prefix::binary-size(^size), token::binary-size(32), ".swap">> ->
        case Base.decode16(token, case: :lower) do
          {:ok, _nonce} -> {:ok, true}
          :error -> {:error, :invalid_review_record}
        end

      _different ->
        {:error, :invalid_review_record}
    end
  end

  defp validate_review_path(_meta, _swap), do: {:error, :invalid_review_record}

  @spec parse_review(:clean | :dirty, binary()) :: review() | :invalid
  defp parse_review(kind, frame) when byte_size(frame) >= 32 do
    payload_size = byte_size(frame) - 32
    <<payload::binary-size(^payload_size), checksum::binary-32>> = frame

    if :crypto.hash(:sha256, payload) == checksum,
      do: parse_review_frame(kind, payload),
      else: :invalid
  end

  defp parse_review(_kind, _frame), do: :invalid

  @spec parse_review_frame(:clean | :dirty, binary()) :: review() | :invalid
  defp parse_review_frame(:dirty, <<len::64, dirty::binary-size(len), 0>>),
    do: %{kind: :dirty, dirty: present(dirty), saved: nil}

  defp parse_review_frame(
         kind,
         <<len::64, dirty::binary-size(len), 1, digest::binary-32, saved::binary>>
       )
       when byte_size(saved) > 0 and (kind == :dirty or len == 0),
       do: %{kind: kind, dirty: present(dirty), saved: {digest, saved}}

  defp parse_review_frame(_kind, _frame), do: :invalid

  @spec present(binary()) :: binary() | nil
  defp present(""), do: nil
  defp present(binary), do: binary

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
      meta = %{path: path, os_pid: os_pid, mtime: mtime, run_started: fields["run_started"]}

      case Map.fetch(fields, "disk_base") do
        {:ok, value} -> {:ok, Map.put(meta, :disk_base, parse_disk_base(value))}
        :error -> {:ok, meta}
      end
    else
      _ -> {:error, :invalid_format}
    end
  end

  @spec parse_disk_base(binary()) :: disk_base()
  defp parse_disk_base("missing"), do: :missing

  defp parse_disk_base(hex) do
    case Base.decode16(hex) do
      {:ok, <<_::256>> = digest} -> digest
      _invalid -> :invalid
    end
  end
end
