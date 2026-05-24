defmodule MingaDired.Commands do
  @moduledoc """
  Commands for Oil.nvim-style directory buffers.

  The directory listing is an editable buffer. Saving diffs current
  content against the original listing and applies file operations
  (renames, deletes, creates). Navigation keys open files or enter
  directories.
  """

  use MingaEditor.Commands.Provider

  alias Minga.Buffer
  alias MingaDired.Core, as: Dired
  alias MingaEditor.Commands
  alias MingaEditor.State, as: EditorState
  alias MingaDired.State, as: DiredState

  @type state :: EditorState.t()

  command(:dired_open, "Open directory (Dired)", requires_buffer: false)
  command(:dired_open_entry, "Open file / enter directory", requires_buffer: false)
  command(:dired_parent, "Go to parent directory", requires_buffer: false)
  command(:dired_close, "Close directory buffer", requires_buffer: false)
  command(:dired_toggle_hidden, "Toggle hidden files", requires_buffer: false)
  command(:dired_cycle_sort, "Cycle sort order", requires_buffer: false)
  command(:dired_toggle_details, "Toggle detail columns", requires_buffer: false)
  command(:dired_open_external, "Open with system application", requires_buffer: false)
  command(:dired_refresh, "Refresh directory listing", requires_buffer: false)
  command(:dired_apply_changes, "Apply directory changes", requires_buffer: false)
  command(:dired_confirm_apply, "Confirm and apply changes", requires_buffer: false)
  command(:dired_cancel_apply, "Cancel pending changes", requires_buffer: false)

  # ── Command dispatch ─────────────────────────────────────────────────────

  @spec execute(state(), atom()) :: state()

  def execute(state, :dired_open) do
    {path, state} = pop_requested_path(state)
    dir = path || current_directory(state)
    open_directory(state, dir)
  end

  def execute(state, :dired_open_entry) do
    dired_state = EditorState.get_feature_state(state, :dired)

    with %DiredState{active?: true, dired: dired, buffer: buf} <- dired_state,
         {cursor_line, _col} <- Buffer.cursor(buf),
         %{} = entry <- Dired.entry_at_line(dired, cursor_line) do
      if entry.dir? do
        navigate_to_directory(state, entry.path)
      else
        open_file(state, entry.path)
      end
    else
      _ -> EditorState.set_status(state, "No entry at cursor")
    end
  end

  def execute(state, :dired_parent) do
    dired_state = EditorState.get_feature_state(state, :dired)

    case dired_state do
      %DiredState{active?: true, dired: %Dired{directory: dir}} ->
        parent = Dired.parent_directory(dir)

        if parent != dir do
          navigate_to_directory(state, parent)
        else
          state
        end

      _ ->
        EditorState.set_status(state, "No active Dired buffer")
    end
  end

  def execute(state, :dired_close) do
    close_dired(state)
  end

  def execute(state, :dired_toggle_hidden) do
    with_dired_update(state, fn dired ->
      Dired.with_show_hidden(dired, !dired.show_hidden)
    end)
  end

  def execute(state, :dired_cycle_sort) do
    with_dired_update(state, fn dired ->
      Dired.with_sort_by(dired, Dired.next_sort_key(dired.sort_by))
    end)
  end

  def execute(state, :dired_toggle_details) do
    with_dired_update(state, fn dired ->
      Dired.with_show_details(dired, !dired.show_details)
    end)
  end

  def execute(state, :dired_open_external) do
    dired_state = EditorState.get_feature_state(state, :dired)

    with %DiredState{active?: true, dired: dired, buffer: buf} <- dired_state,
         {cursor_line, _col} <- Buffer.cursor(buf),
         %{} = entry <- Dired.entry_at_line(dired, cursor_line) do
      spawn_external_open(entry.path)
      EditorState.set_status(state, "Opened #{entry.name}")
    else
      _ -> EditorState.set_status(state, "No entry at cursor")
    end
  end

  def execute(state, :dired_refresh) do
    with_dired_update(state, fn dired ->
      Dired.refresh(dired)
    end)
  end

  def execute(state, :dired_apply_changes) do
    dired_state = EditorState.get_feature_state(state, :dired)

    case dired_state do
      %DiredState{
        active?: true,
        dired: %Dired{directory: dir},
        buffer: buf,
        original_entries: original
      } ->
        ops = compute_pending_ops(buf, original, dir)
        maybe_enter_confirmation(state, ops)

      _ ->
        EditorState.set_status(state, "No active Dired buffer")
    end
  end

  def execute(state, :dired_confirm_apply) do
    dired_state = EditorState.get_feature_state(state, :dired)

    case dired_state do
      %DiredState{active?: true, dired: %Dired{}, pending_ops: ops} when ops != [] ->
        state = clear_confirming(state)
        {successes, errors} = apply_operations(ops)
        state = refresh_dired_buffer(state)
        report_apply_result(state, successes, errors)

      _ ->
        EditorState.set_status(state, "No active Dired buffer")
    end
  end

  def execute(state, :dired_cancel_apply) do
    state = clear_confirming(state)
    EditorState.set_status(state, "Cancelled")
  end

  # ── Opening ──────────────────────────────────────────────────────────────

  @doc "Opens a directory at the given path in a Dired buffer."
  @spec open_directory(state(), String.t()) :: state()
  def open_directory(state, dir) do
    with {:ok, dired} <- Dired.read_directory(dir),
         {:ok, pid} <- start_dired_buffer(state, dired) do
      dired_state = DiredState.activate(%DiredState{}, dired, pid)

      state
      |> Commands.add_buffer(pid)
      |> EditorState.set_feature_state(:dired, dired_state)
      |> EditorState.set_keymap_scope(:dired)
      |> EditorState.set_status("Dired: #{dired.directory}")
    else
      {:error, reason} ->
        EditorState.set_status(state, "Cannot open directory: #{inspect(reason)}")
    end
  end

  @spec start_dired_buffer(state(), Dired.t()) :: {:ok, pid()} | {:error, term()}
  defp start_dired_buffer(state, %Dired{} = dired) do
    listing = Dired.format_listing(dired)

    DynamicSupervisor.start_child(
      Minga.Buffer.Supervisor,
      {Minga.Buffer,
       content: listing,
       buffer_type: :nofile,
       buffer_name: "*Dired: #{dired.directory}*",
       read_only: false,
       unlisted: true,
       filetype: :dired,
       options_server: EditorState.options_server(state)}
    )
  end

  # ── Requested path ──────────────────────────────────────────────────────

  @spec pop_requested_path(state()) :: {String.t() | nil, state()}
  defp pop_requested_path(state) do
    case EditorState.get_feature_state(state, :dired_requested_path) do
      nil -> {nil, state}
      path -> {path, EditorState.set_feature_state(state, :dired_requested_path, nil)}
    end
  end

  # ── Navigation ───────────────────────────────────────────────────────────

  @spec navigate_to_directory(state(), String.t()) :: state()
  defp navigate_to_directory(state, dir) do
    dired_state = EditorState.get_feature_state(state, :dired)

    case dired_state do
      %DiredState{active?: true, dired: old_dired, buffer: buf} ->
        case Dired.read_directory(dir,
               show_hidden: old_dired.show_hidden,
               sort_by: old_dired.sort_by,
               show_details: old_dired.show_details
             ) do
          {:ok, new_dired} ->
            listing = Dired.format_listing(new_dired)
            Buffer.replace_generated_content(buf, listing)
            Buffer.move_to(buf, {0, 0})
            updated_dired_state = DiredState.update_dired(dired_state, new_dired)

            state
            |> EditorState.set_feature_state(:dired, updated_dired_state)
            |> EditorState.set_status("Dired: #{new_dired.directory}")

          {:error, reason} ->
            EditorState.set_status(state, "Cannot open directory: #{inspect(reason)}")
        end

      _ ->
        state
    end
  end

  @spec open_file(state(), String.t()) :: state()
  defp open_file(state, file_path) do
    state = close_dired(state)

    case Commands.start_buffer(file_path, EditorState.options_server(state)) do
      {:ok, pid} -> Commands.add_buffer(state, pid)
      {:error, _} -> EditorState.set_status(state, "Cannot open: #{file_path}")
    end
  end

  # ── Close ────────────────────────────────────────────────────────────────

  @spec close_dired(state()) :: state()
  defp close_dired(state) do
    dired_state = EditorState.get_feature_state(state, :dired)

    case dired_state do
      %DiredState{active?: true, buffer: buf} when is_pid(buf) ->
        state =
          state
          |> EditorState.update_feature_state(:dired, %DiredState{}, &DiredState.deactivate/1)
          |> EditorState.set_keymap_scope(:editor)

        Commands.execute(state, :kill_buffer)

      _ ->
        EditorState.set_keymap_scope(state, :editor)
    end
  end

  # ── Update helpers ───────────────────────────────────────────────────────

  @spec with_dired_update(state(), (Dired.t() -> {:ok, Dired.t()} | {:error, term()})) :: state()
  defp with_dired_update(state, update_fn) do
    dired_state = EditorState.get_feature_state(state, :dired)

    case dired_state do
      %DiredState{active?: true, dired: %Dired{} = dired, buffer: buf} ->
        case update_fn.(dired) do
          {:ok, new_dired} ->
            listing = Dired.format_listing(new_dired)
            Buffer.replace_generated_content(buf, listing)
            Buffer.move_to(buf, {0, 0})
            updated_dired_state = DiredState.update_dired(dired_state, new_dired)

            state
            |> EditorState.set_feature_state(:dired, updated_dired_state)
            |> EditorState.set_status(status_for_dired(new_dired))

          {:error, reason} ->
            EditorState.set_status(state, "Dired error: #{inspect(reason)}")
        end

      _ ->
        EditorState.set_status(state, "No active Dired buffer")
    end
  end

  @spec refresh_dired_buffer(state()) :: state()
  defp refresh_dired_buffer(state) do
    with_dired_update(state, fn dired -> Dired.refresh(dired) end)
  end

  @spec clear_confirming(state()) :: state()
  defp clear_confirming(state) do
    dired_state = EditorState.get_feature_state(state, :dired)

    case dired_state do
      %DiredState{} ->
        new_dired = DiredState.exit_confirmation(dired_state)
        EditorState.set_feature_state(state, :dired, new_dired)

      _ ->
        state
    end
  end

  @spec compute_pending_ops(pid(), [Dired.entry()], String.t()) :: [Dired.operation()]
  defp compute_pending_ops(buf, original_entries, directory) do
    content = Buffer.content(buf)
    current_names = Dired.parse_listing(content)
    Dired.diff_operations(original_entries, current_names, directory)
  end

  @spec maybe_enter_confirmation(state(), [Dired.operation()]) :: state()
  defp maybe_enter_confirmation(state, []),
    do: EditorState.set_status(state, "No changes to apply")

  defp maybe_enter_confirmation(state, ops) do
    summary = format_operations_summary(ops)

    state
    |> EditorState.update_feature_state(
      :dired,
      %DiredState{},
      &DiredState.enter_confirmation(&1, ops)
    )
    |> EditorState.set_status("#{summary} — apply? (y/n)")
  end

  @spec spawn_external_open(String.t()) :: {:ok, pid()}
  defp spawn_external_open(path) do
    open_cmd = if :os.type() == {:unix, :darwin}, do: "open", else: "xdg-open"

    Task.start(fn ->
      {output, code} = System.cmd(open_cmd, [path], stderr_to_stdout: true)

      if code != 0 do
        Minga.Log.warning(:editor, "#{open_cmd} exited #{code}: #{String.trim(output)}")
      end
    end)
  end

  @spec report_apply_result(state(), non_neg_integer(), [{Dired.operation(), term()}]) :: state()
  defp report_apply_result(state, successes, []) do
    EditorState.set_status(state, "Applied #{successes} operation(s)")
  end

  defp report_apply_result(state, successes, errors) do
    error_details = Enum.map_join(errors, "; ", &format_error/1)
    Minga.Log.error(:editor, "Dired errors: #{error_details}")

    {first_op, first_reason} = hd(errors)
    hint = "#{format_op_name(first_op)}: #{inspect(first_reason)}"
    EditorState.set_status(state, "Applied #{successes}, #{length(errors)} error(s) — #{hint}")
  end

  @spec format_error({Dired.operation(), term()}) :: String.t()
  defp format_error({{:rename, old, new}, reason}),
    do: "rename #{Path.basename(old)} -> #{Path.basename(new)}: #{inspect(reason)}"

  defp format_error({{:delete, path}, reason}),
    do: "delete #{Path.basename(path)}: #{inspect(reason)}"

  defp format_error({{:create, path}, reason}),
    do: "create #{Path.basename(path)}: #{inspect(reason)}"

  defp format_error({{:mkdir, path}, reason}),
    do: "mkdir #{Path.basename(path)}: #{inspect(reason)}"

  @spec format_op_name(Dired.operation()) :: String.t()
  defp format_op_name({:rename, old, _new}), do: "rename #{Path.basename(old)}"
  defp format_op_name({:delete, path}), do: "delete #{Path.basename(path)}"
  defp format_op_name({:create, path}), do: "create #{Path.basename(path)}"
  defp format_op_name({:mkdir, path}), do: "mkdir #{Path.basename(path)}"

  # ── File operations ──────────────────────────────────────────────────────

  @spec apply_operations([Dired.operation()]) ::
          {non_neg_integer(), [{Dired.operation(), term()}]}
  defp apply_operations(ops) do
    Enum.reduce(ops, {0, []}, fn op, {ok_count, errors} ->
      case apply_single_operation(op) do
        :ok -> {ok_count + 1, errors}
        {:error, reason} -> {ok_count, [{op, reason} | errors]}
      end
    end)
  end

  @spec apply_single_operation(Dired.operation()) :: :ok | {:error, term()}
  defp apply_single_operation({:rename, old_path, new_path}) do
    parent = Path.dirname(new_path)

    case ensure_directory(parent) do
      :ok -> File.rename(old_path, new_path)
      error -> error
    end
  end

  defp apply_single_operation({:delete, path}) do
    case File.rm_rf(path) do
      {:ok, _} -> :ok
      {:error, reason, _} -> {:error, reason}
    end
  end

  defp apply_single_operation({:create, path}) do
    parent = Path.dirname(path)

    case ensure_directory(parent) do
      :ok -> File.touch(path)
      error -> error
    end
  end

  defp apply_single_operation({:mkdir, path}) do
    File.mkdir_p(path)
  end

  @spec ensure_directory(String.t()) :: :ok | {:error, term()}
  defp ensure_directory(path) do
    if File.dir?(path), do: :ok, else: File.mkdir_p(path)
  end

  # ── Status helpers ───────────────────────────────────────────────────────

  @spec current_directory(state()) :: String.t()
  defp current_directory(state) do
    buf = state.workspace.buffers.active

    if buf do
      case Buffer.file_path(buf) do
        path when is_binary(path) -> Path.dirname(path)
        _ -> File.cwd!()
      end
    else
      File.cwd!()
    end
  end

  @spec status_for_dired(Dired.t()) :: String.t()
  defp status_for_dired(%Dired{directory: dir, sort_by: sort, show_hidden: hidden}) do
    sort_label = "sort:#{sort}"
    hidden_label = if hidden, do: "hidden:on", else: "hidden:off"
    "Dired: #{dir} [#{sort_label} #{hidden_label}]"
  end

  @spec format_operations_summary([Dired.operation()]) :: String.t()
  defp format_operations_summary(ops) do
    counts =
      Enum.frequencies_by(ops, fn
        {:rename, _, _} -> :rename
        {:delete, _} -> :delete
        {:create, _} -> :create
        {:mkdir, _} -> :mkdir
      end)

    parts =
      Enum.flat_map(
        [{:rename, "rename"}, {:delete, "delete"}, {:create, "create"}, {:mkdir, "mkdir"}],
        fn {key, label} ->
          case Map.get(counts, key) do
            nil -> []
            n -> ["#{n} #{label}"]
          end
        end
      )

    Enum.join(parts, ", ")
  end
end
