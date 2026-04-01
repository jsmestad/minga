defmodule Minga.Extension.Updater do
  @moduledoc """
  Orchestrates extension update checks, application, and rollback.

  The update lifecycle has two phases:

  1. **Check** (background Task): fetch remote changes for all extensions,
     build a list of available updates, and send it to the Editor to
     enter confirmation mode.

  2. **Apply** (after user confirms): for each accepted update, fast-forward
     git repos or reinstall hex packages, recompile, and rollback on failure.

  All check functions run in a background `Task` so they don't block the
  editor. Results are communicated back via `MingaEditor.cast/1`.
  """

  alias Minga.Extension.Git, as: ExtGit
  alias Minga.Extension.Hex, as: ExtHex
  alias Minga.Extension.Registry, as: ExtRegistry
  alias Minga.Extension.Supervisor, as: ExtSupervisor
  alias Minga.Mode.ExtensionConfirmState

  @typedoc "Result of a single extension update attempt."
  @type update_result ::
          {:updated, atom(), String.t(), String.t()}
          | {:up_to_date, atom()}
          | {:rolled_back, atom(), String.t()}
          | {:error, atom(), String.t()}

  # ── Public API: Check phase ────────────────────────────────────────────────

  @doc """
  Checks for updates on all extensions and sends results to the Editor
  for confirmation. Designed to run in a background Task.

  Fetches remote changes for git extensions and checks version info for
  hex extensions, then sends an `:extension_updates_available` message
  to the Editor with the update list.
  """
  @spec check_all() :: :ok
  def check_all do
    entries = ExtRegistry.all()
    updates = gather_updates(entries)

    case updates do
      [] ->
        MingaEditor.log_to_messages("All extensions are up to date.")

      _ ->
        MingaEditor.cast({:extension_updates_available, updates})
    end

    :ok
  end

  @doc """
  Checks for updates on a single extension by name and sends results
  to the Editor for confirmation. Designed to run in a background Task.
  """
  @spec check_single(atom()) :: :ok
  def check_single(name) do
    case ExtRegistry.get(name) do
      {:ok, entry} ->
        updates = gather_updates([{name, entry}])

        case updates do
          [] ->
            MingaEditor.log_to_messages("#{name}: already up to date.")

          _ ->
            MingaEditor.cast({:extension_updates_available, updates})
        end

      :error ->
        MingaEditor.log_to_messages("Extension #{name} not found in registry.")
    end

    :ok
  end

  # ── Public API: Apply phase ────────────────────────────────────────────────

  @doc """
  Applies the accepted updates from the confirmation dialog.

  Takes the confirmation state and applies updates for each accepted index.
  Runs in a background Task. Results are posted to *Messages*.
  """
  @spec apply_accepted(ExtensionConfirmState.t()) :: :ok
  def apply_accepted(%ExtensionConfirmState{updates: updates, accepted: accepted}) do
    accepted_set = MapSet.new(accepted)

    results =
      updates
      |> Enum.with_index()
      |> Enum.map(fn {update, idx} ->
        if MapSet.member?(accepted_set, idx) do
          apply_single_update(update)
        else
          {:up_to_date, update.name}
        end
      end)
      |> Enum.reject(&match?({:up_to_date, _}, &1))

    report_results(results)
  end

  @doc """
  Gets the git log details for an extension (for the `d` key in confirmation).

  Returns a formatted string of recent commit messages.
  """
  @spec details(atom()) :: String.t()
  def details(name) do
    dest = ExtGit.extension_path(name)

    if File.dir?(Path.join(dest, ".git")) do
      case System.cmd("git", ["log", "--oneline", "HEAD..FETCH_HEAD", "--max-count=20"],
             cd: dest,
             stderr_to_stdout: true
           ) do
        {output, 0} when output != "" ->
          "Recent commits for #{name}:\n#{output}"

        _ ->
          "No commit details available for #{name}."
      end
    else
      "#{name} is not a git extension."
    end
  end

  # ── Private: Gathering updates ─────────────────────────────────────────────

  @spec gather_updates([{atom(), Minga.Extension.Entry.t()}]) ::
          [ExtensionConfirmState.update_entry()]
  defp gather_updates(entries) do
    entries
    |> Enum.map(&check_entry/1)
    |> Enum.reject(&is_nil/1)
  end

  @spec check_entry({atom(), Minga.Extension.Entry.t()}) ::
          ExtensionConfirmState.update_entry() | nil
  defp check_entry({name, %{source_type: :git} = entry}) do
    case ExtGit.fetch_updates(name, entry.git) do
      {:ok, info} ->
        %{
          name: name,
          source_type: :git,
          old_ref: info.old_ref,
          new_ref: info.new_ref,
          commit_count: info.commit_count,
          branch: info.branch,
          pinned: entry.git.ref != nil
        }

      :up_to_date ->
        nil

      {:error, reason} ->
        Minga.Log.warning(:config, "#{name}: #{reason}")
        nil
    end
  end

  defp check_entry({_name, %{source_type: :hex}}) do
    # Hex updates are handled via Mix.install force reinstall.
    # We can't easily diff versions without querying the Hex API,
    # which is out of scope for v1. Users run :ExtUpdateAll to
    # force-reinstall all hex deps.
    nil
  end

  defp check_entry({_name, %{source_type: :path}}) do
    # Path extensions are user-managed
    nil
  end

  # ── Private: Applying updates ──────────────────────────────────────────────

  @spec apply_single_update(ExtensionConfirmState.update_entry()) :: update_result()
  defp apply_single_update(%{pinned: true, name: name}) do
    {:up_to_date, name}
  end

  defp apply_single_update(%{source_type: :git, name: name}) do
    case ExtRegistry.get(name) do
      {:ok, entry} ->
        apply_git_update(name, entry)

      :error ->
        {:error, name, "not found in registry"}
    end
  end

  defp apply_single_update(%{source_type: :hex, name: name}) do
    case ExtHex.reinstall_all() do
      :ok -> {:updated, name, "", "latest"}
      {:error, reason} -> {:error, name, reason}
    end
  end

  @spec apply_git_update(atom(), Minga.Extension.Entry.t()) :: update_result()
  defp apply_git_update(name, entry) do
    with {:ok, old_ref} <- ExtGit.current_ref(name),
         :ok <- ExtGit.apply_update(name),
         :ok <- recompile_extension(name, entry) do
      {:ok, new_ref} = ExtGit.current_ref(name)
      {:updated, name, old_ref, new_ref}
    else
      {:error, :compile_failed, reason} ->
        handle_compile_failure(name, reason)

      {:error, reason} when is_binary(reason) ->
        {:error, name, reason}
    end
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

  # ── Private: Reporting ─────────────────────────────────────────────────────

  @spec report_results([update_result()]) :: :ok
  defp report_results([]) do
    MingaEditor.log_to_messages("No updates applied.")
  end

  defp report_results(results) do
    lines = Enum.map(results, &format_result/1)
    msg = Enum.join(["Extension update results:" | lines], "\n")
    MingaEditor.log_to_messages(msg)
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
