defmodule Minga.Dired do
  @moduledoc """
  Pure data structure and functions for Oil.nvim-style directory buffers.

  A Dired listing is an editable buffer where each line is a filename.
  Saving the buffer diffs current content against the original entry list
  and applies the resulting file operations (renames, deletes, creates).

  Layer 0: pure functions, no process dependencies.
  """

  alias __MODULE__

  @type sort_key :: :name | :size | :date | :extension

  @type entry :: %{
          path: String.t(),
          name: String.t(),
          dir?: boolean(),
          symlink?: boolean(),
          target: String.t() | nil,
          executable?: boolean(),
          size: non_neg_integer(),
          mtime: NaiveDateTime.t() | nil,
          mode: non_neg_integer()
        }

  @type operation ::
          {:rename, String.t(), String.t()}
          | {:delete, String.t()}
          | {:create, String.t()}
          | {:mkdir, String.t()}

  @type t :: %Dired{
          directory: String.t(),
          entries: [entry()],
          show_hidden: boolean(),
          sort_by: sort_key(),
          show_details: boolean()
        }

  defstruct directory: "",
            entries: [],
            show_hidden: false,
            sort_by: :name,
            show_details: false

  # ── Reading ──────────────────────────────────────────────────────────────

  @spec read_directory(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def read_directory(path, opts \\ []) do
    show_hidden = Keyword.get(opts, :show_hidden, false)
    sort_by = Keyword.get(opts, :sort_by, :name)
    show_details = Keyword.get(opts, :show_details, false)

    case File.ls(path) do
      {:ok, names} ->
        entries =
          names
          |> Enum.map(&build_entry(path, &1))
          |> filter_hidden(show_hidden)
          |> sort_entries(sort_by)

        {:ok,
         %Dired{
           directory: Path.expand(path),
           entries: entries,
           show_hidden: show_hidden,
           sort_by: sort_by,
           show_details: show_details
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec build_entry(String.t(), String.t()) :: entry()
  defp build_entry(dir, name) do
    full_path = Path.join(dir, name)
    {stat, symlink?, target} = stat_entry(full_path)
    entry_from_stat(full_path, name, stat, symlink?, target)
  end

  @spec stat_entry(String.t()) :: {File.Stat.t() | nil, boolean(), String.t() | nil}
  defp stat_entry(path) do
    case File.lstat(path) do
      {:ok, %{type: :symlink} = lstat} ->
        target =
          case File.read_link(path),
            do: (
              {:ok, t} -> t
              _ -> nil
            )

        real_stat =
          case File.stat(path),
            do: (
              {:ok, s} -> s
              _ -> lstat
            )

        {real_stat, true, target}

      {:ok, stat} ->
        {stat, false, nil}

      {:error, _} ->
        {nil, false, nil}
    end
  end

  @spec entry_from_stat(String.t(), String.t(), File.Stat.t() | nil, boolean(), String.t() | nil) ::
          entry()
  defp entry_from_stat(full_path, name, nil, symlink?, target) do
    %{
      path: full_path,
      name: name,
      dir?: false,
      symlink?: symlink?,
      target: target,
      executable?: false,
      size: 0,
      mtime: nil,
      mode: 0
    }
  end

  defp entry_from_stat(full_path, name, stat, symlink?, target) do
    dir? = stat.type == :directory
    executable? = Bitwise.band(stat.mode, 0o111) != 0 and not dir?
    mtime = if stat.mtime, do: NaiveDateTime.from_erl!(stat.mtime), else: nil

    %{
      path: full_path,
      name: name,
      dir?: dir?,
      symlink?: symlink?,
      target: target,
      executable?: executable?,
      size: stat.size,
      mtime: mtime,
      mode: stat.mode
    }
  end

  # ── Formatting ───────────────────────────────────────────────────────────

  @spec format_entry(entry(), boolean()) :: String.t()
  def format_entry(entry, show_details \\ false)

  def format_entry(entry, false) do
    format_name(entry)
  end

  def format_entry(entry, true) do
    perms = format_permissions(entry.mode, entry.dir?, entry.symlink?)
    size = format_size(entry.size)
    date = format_date(entry.mtime)
    "#{perms} #{size} #{date} #{format_name(entry)}"
  end

  @spec format_name(entry()) :: String.t()
  defp format_name(%{dir?: true, name: name}), do: name <> "/"
  defp format_name(%{symlink?: true, name: name, target: target}), do: "#{name}@ -> #{target}"
  defp format_name(%{executable?: true, name: name}), do: name <> "*"
  defp format_name(%{name: name}), do: name

  @spec format_listing(t()) :: String.t()
  def format_listing(%Dired{entries: entries, show_details: show_details}) do
    Enum.map_join(entries, "\n", &format_entry(&1, show_details))
  end

  @spec format_permissions(non_neg_integer(), boolean(), boolean()) :: String.t()
  defp format_permissions(mode, dir?, symlink?) do
    type_char = cond_type_char(dir?, symlink?)

    owner = permission_triplet(Bitwise.bsr(mode, 6))
    group = permission_triplet(Bitwise.bsr(mode, 3))
    other = permission_triplet(mode)

    "#{type_char}#{owner}#{group}#{other}"
  end

  @spec cond_type_char(boolean(), boolean()) :: String.t()
  defp cond_type_char(true, _), do: "d"
  defp cond_type_char(_, true), do: "l"
  defp cond_type_char(_, _), do: "-"

  @spec permission_triplet(non_neg_integer()) :: String.t()
  defp permission_triplet(bits) do
    r = if Bitwise.band(bits, 4) != 0, do: "r", else: "-"
    w = if Bitwise.band(bits, 2) != 0, do: "w", else: "-"
    x = if Bitwise.band(bits, 1) != 0, do: "x", else: "-"
    "#{r}#{w}#{x}"
  end

  @spec format_size(non_neg_integer()) :: String.t()
  defp format_size(size) when size < 1024, do: String.pad_leading("#{size}", 7)
  defp format_size(size) when size < 1024 * 1024, do: String.pad_leading("#{div(size, 1024)}K", 7)

  defp format_size(size) when size < 1024 * 1024 * 1024,
    do: String.pad_leading("#{div(size, 1024 * 1024)}M", 7)

  defp format_size(size),
    do: String.pad_leading("#{div(size, 1024 * 1024 * 1024)}G", 7)

  @spec format_date(NaiveDateTime.t() | nil) :: String.t()
  defp format_date(nil), do: "--- -- --:--"

  defp format_date(dt) do
    month = Enum.at(~w[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec], dt.month - 1)
    day = String.pad_leading("#{dt.day}", 2)

    time =
      "#{String.pad_leading("#{dt.hour}", 2, "0")}:#{String.pad_leading("#{dt.minute}", 2, "0")}"

    "#{month} #{day} #{time}"
  end

  # ── Parsing (buffer text → names) ────────────────────────────────────────

  @spec parse_listing(String.t()) :: [String.t()]
  def parse_listing(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.map(&parse_line/1)
    |> Enum.reject(&is_nil/1)
  end

  @spec parse_line(String.t()) :: String.t() | nil
  defp parse_line(line) do
    trimmed = String.trim(line)

    if trimmed == "" do
      nil
    else
      trimmed
      |> strip_detail_prefix()
      |> strip_indicators()
    end
  end

  @spec strip_detail_prefix(String.t()) :: String.t()
  defp strip_detail_prefix(line) do
    case Regex.run(~r/^[dl-][rwx-]{9}\s+\S+\s+\w+\s+\d+\s+\d+:\d+\s+(.+)$/, line) do
      [_, name] -> name
      _ -> line
    end
  end

  @spec strip_indicators(String.t()) :: String.t()
  defp strip_indicators(name) do
    name
    |> strip_symlink_target()
    |> strip_trailing_indicator()
  end

  @spec strip_symlink_target(String.t()) :: String.t()
  defp strip_symlink_target(name) do
    case String.split(name, "@ -> ", parts: 2) do
      [base, _target] -> base
      _ -> name
    end
  end

  @spec strip_trailing_indicator(String.t()) :: String.t()
  defp strip_trailing_indicator(name) do
    String.trim_trailing(name, "/")
    |> String.trim_trailing("*")
  end

  # ── Diffing ──────────────────────────────────────────────────────────────

  @spec diff_operations([entry()], [String.t()]) :: [operation()]
  def diff_operations(original_entries, current_names) do
    original_names = Enum.map(original_entries, & &1.name)
    original_set = MapSet.new(original_names)
    current_set = MapSet.new(current_names)

    max_len = max(length(original_names), length(current_names))

    original_padded = original_names ++ List.duplicate(nil, max_len - length(original_names))
    current_padded = current_names ++ List.duplicate(nil, max_len - length(current_names))

    {renames, remaining_deletes, remaining_creates} =
      original_padded
      |> Enum.zip(current_padded)
      |> Enum.reduce({[], [], []}, fn {orig, curr}, {rn, del, cre} ->
        handle_diff_pair(orig, curr, original_set, current_set, rn, del, cre)
      end)

    rename_ops = Enum.reverse(renames)

    renamed_old = MapSet.new(rename_ops, fn {:rename, old, _} -> old end)
    renamed_new = MapSet.new(rename_ops, fn {:rename, _, new} -> new end)

    delete_ops =
      remaining_deletes
      |> Enum.reverse()
      |> Enum.reject(&MapSet.member?(renamed_old, &1))
      |> Enum.map(fn name ->
        entry = Enum.find(original_entries, &(&1.name == name))
        {:delete, entry.path}
      end)

    create_ops =
      remaining_creates
      |> Enum.reverse()
      |> Enum.reject(&MapSet.member?(renamed_new, &1))
      |> Enum.uniq()
      |> Enum.map(fn name ->
        if String.ends_with?(name, "/") do
          {:mkdir, name}
        else
          {:create, name}
        end
      end)

    rename_ops ++ delete_ops ++ create_ops
  end

  @spec handle_diff_pair(
          String.t() | nil,
          String.t() | nil,
          MapSet.t(),
          MapSet.t(),
          [operation()],
          [String.t()],
          [String.t()]
        ) :: {[operation()], [String.t()], [String.t()]}
  defp handle_diff_pair(same, same, _orig_set, _curr_set, rn, del, cre) when is_binary(same) do
    {rn, del, cre}
  end

  defp handle_diff_pair(nil, curr, _orig_set, _curr_set, rn, del, cre) when is_binary(curr) do
    {rn, del, [curr | cre]}
  end

  defp handle_diff_pair(orig, nil, _orig_set, _curr_set, rn, del, cre) when is_binary(orig) do
    {rn, [orig | del], cre}
  end

  defp handle_diff_pair(orig, curr, orig_set, curr_set, rn, del, cre) do
    orig_gone = not MapSet.member?(curr_set, orig)
    curr_new = not MapSet.member?(orig_set, curr)

    if orig_gone and curr_new do
      {[{:rename, orig, curr} | rn], del, cre}
    else
      del = if orig_gone, do: [orig | del], else: del
      cre = if curr_new, do: [curr | cre], else: cre
      {rn, del, cre}
    end
  end

  # ── Sorting & filtering ─────────────────────────────────────────────────

  @spec sort_entries([entry()], sort_key()) :: [entry()]
  defp sort_entries(entries, sort_by) do
    {dirs, files} = Enum.split_with(entries, & &1.dir?)
    Enum.sort_by(dirs, &sort_key(&1, sort_by)) ++ Enum.sort_by(files, &sort_key(&1, sort_by))
  end

  @spec sort_key(entry(), sort_key()) :: term()
  defp sort_key(entry, :name), do: String.downcase(entry.name)
  defp sort_key(entry, :size), do: entry.size
  defp sort_key(entry, :date), do: entry.mtime || ~N[1970-01-01 00:00:00]

  defp sort_key(entry, :extension) do
    ext = Path.extname(entry.name)
    {String.downcase(ext), String.downcase(entry.name)}
  end

  @spec filter_hidden([entry()], boolean()) :: [entry()]
  defp filter_hidden(entries, true), do: entries

  defp filter_hidden(entries, false) do
    Enum.reject(entries, &String.starts_with?(&1.name, "."))
  end

  # ── Navigation helpers ───────────────────────────────────────────────────

  @spec parent_directory(String.t()) :: String.t()
  def parent_directory(path), do: Path.dirname(path)

  @spec entry_at_line(t(), non_neg_integer()) :: entry() | nil
  def entry_at_line(%Dired{entries: entries}, line) do
    Enum.at(entries, line)
  end

  @spec refresh(t()) :: {:ok, t()} | {:error, term()}
  def refresh(%Dired{} = dired) do
    read_directory(dired.directory,
      show_hidden: dired.show_hidden,
      sort_by: dired.sort_by,
      show_details: dired.show_details
    )
  end

  @spec with_show_hidden(t(), boolean()) :: {:ok, t()} | {:error, term()}
  def with_show_hidden(%Dired{} = dired, show_hidden) do
    read_directory(dired.directory,
      show_hidden: show_hidden,
      sort_by: dired.sort_by,
      show_details: dired.show_details
    )
  end

  @spec with_sort_by(t(), sort_key()) :: {:ok, t()} | {:error, term()}
  def with_sort_by(%Dired{} = dired, sort_by) do
    read_directory(dired.directory,
      show_hidden: dired.show_hidden,
      sort_by: sort_by,
      show_details: dired.show_details
    )
  end

  @spec with_show_details(t(), boolean()) :: {:ok, t()} | {:error, term()}
  def with_show_details(%Dired{} = dired, show_details) do
    read_directory(dired.directory,
      show_hidden: dired.show_hidden,
      sort_by: dired.sort_by,
      show_details: show_details
    )
  end

  @spec next_sort_key(sort_key()) :: sort_key()
  def next_sort_key(:name), do: :size
  def next_sort_key(:size), do: :date
  def next_sort_key(:date), do: :extension
  def next_sort_key(:extension), do: :name
end
