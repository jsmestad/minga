defmodule MingaEditor.HugeFile do
  @moduledoc """
  Pre-read size gate for the file-open action path.

  Minga V1 refuses files above `:max_file_size` (default 10 MB) rather than
  degrading. The decision is made from a `File.stat/1` size check *before* any
  content is read, so the gap buffer, undo log, and tree-sitter parser never
  touch a huge file. When a file is refused, the caller receives an ordinary
  read-only in-memory buffer holding a text-only refusal message. That buffer is
  normal window content on every frontend: it opens as a tab, renders as static
  text, and closes/navigates like any other buffer, so there is no new opcode,
  no card lifecycle, and no external-editor launch machinery.

  This lives in Layer 2 (`MingaEditor.*`) because the gate belongs to the
  editor's open-file orchestration, not to the Layer 1 buffer service that agent
  tools and other callers use to read files directly.
  """

  alias Minga.Config.Options

  @typedoc "Result of the size check for a candidate path."
  @type check_result :: :ok | {:refuse, size :: non_neg_integer(), limit :: pos_integer()}

  @typedoc "A thunk that performs the real open when the size gate passes."
  @type open_fun :: (-> {:ok, pid()} | {:error, term()})

  @doc """
  Runs `open_fun` when `file_path` is at or under the configured limit, or
  returns a read-only refusal buffer when it is over the limit.

  The size check is a `File.stat/1` on the expanded path. Non-regular files
  (directories, sockets) and stat errors (missing file) fall through to
  `open_fun` so the normal open path keeps producing its usual result.
  """
  @spec guard(String.t(), Options.server(), open_fun()) :: {:ok, pid()} | {:error, term()}
  def guard(file_path, options_server, open_fun)
      when is_binary(file_path) and is_function(open_fun, 0) do
    case oversize(file_path, limit(options_server)) do
      {:refuse, size, max_bytes} -> refusal_buffer(file_path, size, max_bytes, options_server)
      :ok -> open_fun.()
    end
  end

  @doc "Configured maximum file size in bytes."
  @spec limit(Options.server()) :: pos_integer()
  def limit(options_server), do: Options.get(options_server, :max_file_size)

  @doc """
  Stats `file_path` and reports whether it exceeds `max_bytes`.

  Reads inode metadata only; the file's content is never opened. Returns
  `{:refuse, size, max_bytes}` only for a regular file strictly larger than the
  limit, and `:ok` for everything else (at/under limit, non-regular, or a stat
  error).
  """
  @spec oversize(String.t(), pos_integer()) :: check_result()
  def oversize(file_path, max_bytes)
      when is_binary(file_path) and is_integer(max_bytes) and max_bytes > 0 do
    case File.stat(Path.expand(file_path)) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > max_bytes ->
        {:refuse, size, max_bytes}

      _ ->
        :ok
    end
  end

  @doc """
  Builds the text-only refusal message shown in the surface.

  Contains exactly the message, the file path, and the open-in-another-editor
  suggestion, plus a one-line pointer to the config option. No actions.
  """
  @spec message(String.t(), non_neg_integer(), pos_integer()) :: String.t()
  def message(file_path, size, max_bytes) do
    """
    File too large for Minga V1

    #{Path.expand(file_path)}

    This file is #{human_size(size)}, above Minga's #{human_size(max_bytes)} limit.
    Minga does not open files this large. Open it in another editor to view or edit it.

    Raise the ceiling with the :max_file_size option (in bytes) if you need to.
    """
  end

  @spec refusal_buffer(String.t(), non_neg_integer(), pos_integer(), Options.server()) ::
          {:ok, pid()} | {:error, term()}
  defp refusal_buffer(file_path, size, max_bytes, options_server) do
    DynamicSupervisor.start_child(
      Minga.Buffer.Supervisor,
      {Minga.Buffer,
       content: message(file_path, size, max_bytes),
       buffer_name: Path.basename(file_path),
       buffer_type: :nofile,
       filetype: :text,
       options_server: options_server}
    )
  end

  @kib 1024
  @mib 1024 * 1024
  @gib 1024 * 1024 * 1024

  @spec human_size(non_neg_integer()) :: String.t()
  defp human_size(bytes) when bytes >= @gib, do: "#{format_unit(bytes, @gib)} GB"
  defp human_size(bytes) when bytes >= @mib, do: "#{format_unit(bytes, @mib)} MB"
  defp human_size(bytes) when bytes >= @kib, do: "#{format_unit(bytes, @kib)} KB"
  defp human_size(bytes), do: "#{bytes} B"

  @spec format_unit(non_neg_integer(), pos_integer()) :: String.t()
  defp format_unit(bytes, unit) do
    value = bytes / unit
    rounded = Float.round(value, 1)

    if rounded == Float.round(value, 0) do
      Integer.to_string(trunc(rounded))
    else
      :erlang.float_to_binary(rounded, decimals: 1)
    end
  end
end
