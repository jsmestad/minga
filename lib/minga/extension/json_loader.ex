defmodule Minga.Extension.JsonLoader do
  @moduledoc """
  Loads a plugin bundle from a `plugin.json` manifest and generates an in-memory extension module.

  The loader reads a JSON file from a plugin directory, substitutes `${MINGA_PLUGIN_ROOT}` placeholders with the actual directory path, and creates a runtime module that uses `Minga.Extension.Agent` with the declared components (hooks, skills, MCP servers, slash commands).

  The generated module name is deterministic: `Minga.Extension.Plugin.<CamelizedName>` where the name comes from the JSON's `"name"` field (or the directory basename as fallback).
  """

  alias Minga.Extension.CodeLease

  @placeholder "${MINGA_PLUGIN_ROOT}"

  @doc """
  Loads a plugin bundle from the given directory.

  Reads `plugin.json`, substitutes `${MINGA_PLUGIN_ROOT}` with `plugin_dir` in all string values, and creates an in-memory extension module with `use Minga.Extension.Agent`.

  Returns `{:ok, module}` on success or `{:error, reason}` on failure.
  """
  @spec load(String.t()) :: {:ok, module()} | {:error, String.t()}
  @spec load(String.t(), atom() | nil) :: {:ok, module()} | {:error, String.t()}
  def load(plugin_dir, extension_name \\ nil) do
    json_path = Path.join(plugin_dir, "plugin.json")

    with {:ok, raw} <- read_file(json_path),
         {:ok, parsed} <- decode_json(raw),
         manifest = substitute_root(parsed, plugin_dir),
         {:ok, module_name} <- build_module_name(manifest, plugin_dir, extension_name),
         {:ok, _module} <- create_module(module_name, manifest, plugin_dir, extension_name) do
      {:ok, module_name}
    end
  end

  @spec read_file(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, "failed to read #{path}: #{inspect(reason)}"}
    end
  end

  @spec decode_json(String.t()) :: {:ok, map()} | {:error, String.t()}
  defp decode_json(raw) do
    case JSON.decode(raw) do
      {:ok, parsed} when is_map(parsed) -> {:ok, parsed}
      {:ok, _other} -> {:error, "plugin.json must be a JSON object"}
      {:error, err} -> {:error, "malformed JSON: #{inspect(err)}"}
    end
  end

  @spec build_module_name(map(), String.t(), atom() | nil) ::
          {:ok, module()} | {:error, String.t()}
  defp build_module_name(_manifest, _plugin_dir, extension_name)
       when is_atom(extension_name) and not is_nil(extension_name) do
    module =
      extension_name
      |> Atom.to_string()
      |> String.replace("-", "_")
      |> Macro.camelize()
      |> then(&Module.concat(Minga.Extension.Plugin, &1))

    {:ok, module}
  end

  defp build_module_name(manifest, plugin_dir, nil) do
    plugin_name = manifest["name"] || Path.basename(plugin_dir)
    # Macro.camelize treats underscores as word separators but not hyphens,
    # so normalize hyphens first to get "hello-world" -> "HelloWorld".
    camelized = plugin_name |> String.replace("-", "_") |> Macro.camelize()
    module = Module.concat(Minga.Extension.Plugin, camelized)
    {:ok, module}
  end

  @spec substitute_root(term(), String.t()) :: term()
  defp substitute_root(value, plugin_dir) when is_binary(value) do
    String.replace(value, @placeholder, plugin_dir)
  end

  defp substitute_root(value, plugin_dir) when is_map(value) do
    Map.new(value, fn {k, v} -> {k, substitute_root(v, plugin_dir)} end)
  end

  defp substitute_root(value, plugin_dir) when is_list(value) do
    Enum.map(value, &substitute_root(&1, plugin_dir))
  end

  defp substitute_root(value, _plugin_dir), do: value

  @spec create_module(module(), map(), String.t(), atom() | nil) ::
          {:ok, module()} | {:error, String.t()}
  defp create_module(module_name, manifest, plugin_dir, extension_name) do
    with {:ok, hooks} <- build_hook_declarations(manifest),
         {:ok, skills} <- build_skill_declarations(manifest),
         {:ok, mcp_servers} <- build_mcp_server_declarations(manifest),
         {:ok, slash_commands} <- build_slash_command_declarations(manifest) do
      name = extension_name || module_name
      description = manifest["description"] || "Plugin from #{Path.basename(plugin_dir)}"
      version = manifest["version"] || "0.1.0"

      contents =
        quote do
          use Minga.Extension.Agent

          unquote_splicing(hooks)
          unquote_splicing(skills)
          unquote_splicing(mcp_servers)
          unquote_splicing(slash_commands)

          @impl true
          def name, do: unquote(name)

          @impl true
          def description, do: unquote(description)

          @impl true
          def version, do: unquote(version)

          @impl true
          def init(_config), do: {:ok, %{}}
        end

      with :ok <- purge_if_loaded(module_name) do
        Module.create(module_name, contents, Macro.Env.location(__ENV__))
        {:ok, module_name}
      end
    end
  end

  @spec purge_if_loaded(module()) :: :ok | {:error, String.t()}
  defp purge_if_loaded(module) do
    if :code.is_loaded(module) do
      case CodeLease.purge_module(nil, module) do
        :ok ->
          :ok

        {:error, reason} ->
          {:error, "plugin module #{inspect(module)} is leased: #{inspect(reason)}"}
      end
    else
      :ok
    end
  end

  # --- Hook declarations ---

  @spec build_hook_declarations(map()) :: {:ok, [Macro.t()]} | {:error, String.t()}
  defp build_hook_declarations(%{"hooks" => hooks}) when is_list(hooks) do
    hooks
    |> Enum.reduce_while({:ok, []}, fn hook, {:ok, acc} ->
      case build_single_hook(hook) do
        {:ok, ast} -> {:cont, {:ok, [ast | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, asts} -> {:ok, Enum.reverse(asts)}
      {:error, _} = err -> err
    end
  end

  defp build_hook_declarations(_manifest), do: {:ok, []}

  @spec build_single_hook(map()) :: {:ok, Macro.t()} | {:error, String.t()}
  defp build_single_hook(%{"event" => event_str} = hook) do
    case normalize_hook_event(event_str) do
      {:ok, event} ->
        opts = hook_opts_from_map(hook)
        {:ok, quote(do: hook(unquote(event), unquote(opts)))}

      {:error, _} = err ->
        err
    end
  end

  defp build_single_hook(_hook), do: {:error, "hook missing required \"event\" field"}

  @spec hook_opts_from_map(map()) :: keyword()
  defp hook_opts_from_map(hook) do
    opts = []
    opts = if hook["command"], do: [{:command, hook["command"]} | opts], else: opts
    opts = if hook["tool"], do: [{:tool, hook["tool"]} | opts], else: opts
    Enum.reverse(opts)
  end

  # --- Skill declarations ---

  @spec build_skill_declarations(map()) :: {:ok, [Macro.t()]}
  defp build_skill_declarations(%{"skills" => skills}) when is_list(skills) do
    asts = Enum.map(skills, fn path -> quote(do: skill(unquote(path))) end)
    {:ok, asts}
  end

  defp build_skill_declarations(_manifest), do: {:ok, []}

  # --- MCP server declarations ---

  @spec build_mcp_server_declarations(map()) :: {:ok, [Macro.t()]}
  defp build_mcp_server_declarations(%{"mcp_servers" => servers}) when is_list(servers) do
    asts = Enum.map(servers, &build_single_mcp_server/1)
    {:ok, asts}
  end

  defp build_mcp_server_declarations(_manifest), do: {:ok, []}

  @spec build_single_mcp_server(map()) :: Macro.t()
  defp build_single_mcp_server(%{"name" => name_str} = server) do
    opts = mcp_server_opts_from_map(server)
    quote(do: mcp_server(unquote(name_str), unquote(opts)))
  end

  @spec mcp_server_opts_from_map(map()) :: keyword()
  defp mcp_server_opts_from_map(server) do
    opts = []
    opts = if server["command"], do: [{:command, server["command"]} | opts], else: opts
    opts = if server["args"], do: [{:args, server["args"]} | opts], else: opts
    Enum.reverse(opts)
  end

  # --- Slash command declarations ---

  @spec build_slash_command_declarations(map()) :: {:ok, [Macro.t()]}
  defp build_slash_command_declarations(%{"slash_commands" => commands}) when is_list(commands) do
    asts = Enum.map(commands, &build_single_slash_command/1)
    {:ok, asts}
  end

  defp build_slash_command_declarations(_manifest), do: {:ok, []}

  @spec build_single_slash_command(map()) :: Macro.t()
  defp build_single_slash_command(%{"name" => name_str, "description" => desc} = cmd) do
    opts = slash_command_opts_from_map(cmd)
    quote(do: slash_command(unquote(name_str), unquote(desc), unquote(opts)))
  end

  @spec slash_command_opts_from_map(map()) :: keyword()
  defp slash_command_opts_from_map(cmd) do
    if cmd["command"], do: [command: cmd["command"]], else: []
  end

  # --- Hook event validation ---

  @known_hook_events %{
    "pre_tool_use" => :pre_tool_use,
    "post_tool_use" => :post_tool_use,
    "session_start" => :session_start,
    "session_end" => :session_end,
    "stop" => :stop,
    "user_prompt_submit" => :user_prompt_submit,
    "pre_compact" => :pre_compact,
    "notification" => :notification
  }

  @spec normalize_hook_event(String.t()) :: {:ok, atom()} | {:error, String.t()}
  defp normalize_hook_event(str) do
    case Map.fetch(@known_hook_events, str) do
      {:ok, event} ->
        {:ok, event}

      :error ->
        {:error,
         "unknown hook event: #{inspect(str)}. Valid events: #{Enum.join(Map.keys(@known_hook_events), ", ")}"}
    end
  end
end
