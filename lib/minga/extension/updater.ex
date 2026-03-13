defmodule Minga.Extension.Updater do
  @moduledoc """
  Orchestrates extension update checks, application, and rollback.

  This module coordinates the full update lifecycle:

  1. **Fetch** — check for new commits (git) or version changes (hex)
  2. **Apply** — fast-forward git repos or reinstall hex packages
  3. **Recompile** — reload extension code from the updated source
  4. **Rollback** — on compile failure, revert to the previous ref and
     reload the old code

  All functions are designed to be called from a background `Task` so
  they don't block the editor. Results are posted to `*Messages*` via
  `Minga.Editor.log_to_messages/1`.
  """

  alias Minga.Extension.Git, as: ExtGit
  alias Minga.Extension.Hex, as: ExtHex
  alias Minga.Extension.Registry, as: ExtRegistry
  alias Minga.Extension.Supervisor, as: ExtSupervisor

  @typedoc "Result of a single extension update attempt."
  @type update_result ::
          {:updated, atom(), String.t(), String.t()}
          | {:up_to_date, atom()}
          | {:rolled_back, atom(), String.t()}
          | {:error, atom(), String.t()}

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Checks for updates and applies them for all registered extensions.

  Git extensions are fetched and fast-forwarded individually. If
  recompilation fails after an update, the extension is rolled back to
  its previous ref. Hex extensions are reinstalled via Mix.install with
  `force: true`.

  Results are posted to *Messages*.
  """
  @spec update_all() :: :ok
  def update_all do
    entries = ExtRegistry.all()
    git_entries = Enum.filter(entries, fn {_, e} -> e.source_type == :git end)
    hex_entries = Enum.filter(entries, fn {_, e} -> e.source_type == :hex end)

    git_results = Enum.map(git_entries, fn {name, entry} -> update_git(name, entry) end)
    hex_result = update_hex(hex_entries)

    report_results(git_results, hex_result)
  end

  @doc """
  Checks for updates and applies them for a single extension by name.

  Results are posted to *Messages*.
  """
  @spec update_single(atom()) :: :ok
  def update_single(name) do
    case ExtRegistry.get(name) do
      {:ok, entry} ->
        result = do_update_single(name, entry)
        report_single_result(result)

      :error ->
        Minga.Editor.log_to_messages("Extension #{name} not found in registry.")
    end

    :ok
  end

  # ── Private: Git updates ────────────────────────────────────────────────────

  @spec do_update_single(atom(), Minga.Extension.Entry.t()) :: update_result()
  defp do_update_single(name, %{source_type: :git} = entry) do
    update_git(name, entry)
  end

  defp do_update_single(name, %{source_type: :hex}) do
    case ExtHex.reinstall_all() do
      :ok -> {:updated, name, "", "latest"}
      {:error, reason} -> {:error, name, reason}
    end
  end

  defp do_update_single(name, %{source_type: :path}) do
    {:up_to_date, name}
  end

  @spec update_git(atom(), Minga.Extension.Entry.t()) :: update_result()
  defp update_git(name, entry) do
    with {:ok, old_ref} <- ExtGit.current_ref(name),
         {:ok, _info} <- fetch_git(name, entry),
         :ok <- apply_git(name),
         :ok <- recompile_extension(name, entry) do
      {:ok, new_ref} = ExtGit.current_ref(name)
      {:updated, name, old_ref, new_ref}
    else
      :up_to_date ->
        {:up_to_date, name}

      {:error, :compile_failed, reason} ->
        handle_compile_failure(name, reason)

      {:error, reason} when is_binary(reason) ->
        {:error, name, reason}
    end
  end

  @spec fetch_git(atom(), Minga.Extension.Entry.t()) ::
          {:ok, ExtGit.update_info()} | :up_to_date | {:error, String.t()}
  defp fetch_git(name, entry) do
    ExtGit.fetch_updates(name, entry.git)
  end

  @spec apply_git(atom()) :: :ok | {:error, String.t()}
  defp apply_git(name) do
    ExtGit.apply_update(name)
  end

  @spec recompile_extension(atom(), Minga.Extension.Entry.t()) ::
          :ok | {:error, :compile_failed, String.t()}
  defp recompile_extension(name, entry) do
    path = entry.path || ExtGit.extension_path(name)

    # Stop the running extension first
    case ExtRegistry.get(name) do
      {:ok, %{pid: pid} = current_entry} when is_pid(pid) ->
        ExtSupervisor.stop_extension(ExtSupervisor, ExtRegistry, name, current_entry)

      _ ->
        :ok
    end

    # Recompile and restart
    updated_entry = %{entry | path: path}

    case ExtSupervisor.start_extension(ExtSupervisor, ExtRegistry, name, updated_entry) do
      {:ok, _pid} -> :ok
      {:error, reason} -> {:error, :compile_failed, inspect(reason)}
    end
  end

  @spec handle_compile_failure(atom(), String.t()) :: update_result()
  defp handle_compile_failure(name, reason) do
    Minga.Log.warning(
      :config,
      "Extension #{name} failed to compile after update, rolling back..."
    )

    case ExtGit.current_ref(name) do
      {:ok, bad_ref} ->
        # Try to find the previous ref from the reflog
        case rollback_to_previous(name) do
          :ok ->
            msg = "rolled back from #{bad_ref} due to compile failure: #{reason}"
            {:rolled_back, name, msg}

          {:error, rollback_reason} ->
            {:error, name, "compile failed (#{reason}) and rollback failed (#{rollback_reason})"}
        end

      {:error, _} ->
        {:error, name, "compile failed: #{reason}"}
    end
  end

  @spec rollback_to_previous(atom()) :: :ok | {:error, String.t()}
  defp rollback_to_previous(name) do
    dest = ExtGit.extension_path(name)

    # Use reflog to find the previous HEAD before the merge
    case System.cmd("git", ["rev-parse", "--short", "HEAD@{1}"],
           cd: dest,
           stderr_to_stdout: true
         ) do
      {ref, 0} ->
        ExtGit.rollback(name, String.trim(ref))

      {output, _} ->
        {:error, "could not find previous ref: #{String.trim(output)}"}
    end
  end

  # ── Private: Hex updates ───────────────────────────────────────────────────

  @spec update_hex([{atom(), Minga.Extension.Entry.t()}]) :: :ok | {:error, String.t()}
  defp update_hex([]), do: :ok

  defp update_hex(_hex_entries) do
    Minga.Log.info(:config, "Reinstalling hex extensions...")
    ExtHex.reinstall_all()
  end

  # ── Private: Reporting ─────────────────────────────────────────────────────

  @spec report_results([update_result()], :ok | {:error, String.t()}) :: :ok
  defp report_results(git_results, hex_result) do
    lines = Enum.map(git_results, &format_result/1)

    hex_line =
      case hex_result do
        :ok -> nil
        {:error, reason} -> "  hex: #{reason}"
      end

    all_lines = Enum.reject(lines ++ [hex_line], &is_nil/1)

    msg =
      case all_lines do
        [] -> "No extensions to update."
        _ -> Enum.join(["Extension update results:" | all_lines], "\n")
      end

    Minga.Editor.log_to_messages(msg)
  end

  @spec report_single_result(update_result()) :: :ok
  defp report_single_result(result) do
    msg = format_result(result)
    Minga.Editor.log_to_messages(msg)
  end

  @spec format_result(update_result()) :: String.t()
  defp format_result({:updated, name, old_ref, new_ref}) do
    "  #{name}: updated #{old_ref} -> #{new_ref}"
  end

  defp format_result({:up_to_date, name}) do
    "  #{name}: up to date"
  end

  defp format_result({:rolled_back, name, reason}) do
    "  #{name}: #{reason}"
  end

  defp format_result({:error, name, reason}) do
    "  #{name}: error: #{reason}"
  end
end
