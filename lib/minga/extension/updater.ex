defmodule Minga.Extension.Updater do
  @moduledoc """
  Orchestrates extension update checks and next-generation source staging.

  The update lifecycle has two phases:

  1. **Check** (background Task): fetch remote changes for all extensions,
     build a list of available updates, and send it to the Editor to
     enter confirmation mode.

  2. **Apply** (after user confirms): stage accepted source updates for the
     next BEAM VM generation. Running extension code is never recompiled or
     replaced in this process.

  All check functions run in a background `Task` so they don't block the
  editor. Results are communicated back via `Events` broadcasts.
  """

  alias Minga.Extension.Git, as: ExtGit
  alias Minga.Extension.Registry, as: ExtRegistry
  alias Minga.Mode.ExtensionConfirmState
  alias Minga.Events

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
        Events.broadcast(:log_message, %Events.LogMessageEvent{
          text: "All extensions are up to date.",
          level: :info
        })

      _ ->
        Events.broadcast(
          :extension_updates_available,
          %Minga.Extension.UpdatesAvailableEvent{updates: updates}
        )
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
            Events.broadcast(:log_message, %Events.LogMessageEvent{
              text: "#{name}: already up to date.",
              level: :info
            })

          _ ->
            Events.broadcast(
              :extension_updates_available,
              %Minga.Extension.UpdatesAvailableEvent{updates: updates}
            )
        end

      :error ->
        Events.broadcast(:log_message, %Events.LogMessageEvent{
          text: "Extension #{name} not found in registry.",
          level: :info
        })
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
    {:error, name, "Hex dependency updates require a fresh Minga process"}
  end

  @spec apply_git_update(atom(), Minga.Extension.Entry.t()) :: update_result()
  defp apply_git_update(name, _entry) do
    with {:ok, old_ref} <- ExtGit.current_ref(name),
         :ok <- ExtGit.apply_update(name),
         {:ok, new_ref} <- ExtGit.current_ref(name) do
      Events.broadcast(
        :extension_restart_required,
        %Events.ExtensionRestartRequiredEvent{
          extension: name,
          reason: :updated,
          old_ref: old_ref,
          new_ref: new_ref
        }
      )

      {:updated, name, old_ref, new_ref}
    else
      {:error, reason} when is_binary(reason) -> {:error, name, reason}
    end
  end

  # ── Private: Reporting ─────────────────────────────────────────────────────

  @spec report_results([update_result()]) :: :ok
  defp report_results([]) do
    Events.broadcast(:log_message, %Events.LogMessageEvent{
      text: "No updates applied.",
      level: :info
    })
  end

  defp report_results(results) do
    lines = Enum.map(results, &format_result/1)
    msg = Enum.join(["Extension update results:" | lines], "\n")
    Events.broadcast(:log_message, %Events.LogMessageEvent{text: msg, level: :info})
  end

  @spec format_result(update_result()) :: String.t()
  defp format_result({:updated, name, old_ref, new_ref}) do
    "  #{name}: staged #{old_ref} -> #{new_ref}; restart Minga to activate"
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
