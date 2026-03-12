defmodule Minga.Credo.NoDirectLoggerCheck do
  @moduledoc """
  Forbids direct `Logger` calls in application code. Use `Minga.Log` instead.

  ## Why this exists

  Minga has per-subsystem log level filtering through `Minga.Log`. Each
  subsystem (`:render`, `:lsp`, `:agent`, `:editor`) has its own config
  option so users can turn debug output on/off per subsystem without
  drowning in noise from everywhere else.

  Direct `Logger.debug/info/warning/error` calls bypass this filtering.
  A `Logger.debug("render took 24µs")` shows up even when the user has
  set `:log_level_render` to `:warning`. This defeats the purpose of the
  subsystem-aware logging system.

  ## What to do instead

      # Bad: bypasses subsystem filtering
      Logger.debug("[render] content stage: 24µs")
      Logger.warning("LSP server crashed: \#{inspect(reason)}")

      # Good: respects per-subsystem log level config
      Minga.Log.debug(:render, "[render:content] 24µs")
      Minga.Log.warning(:lsp, "LSP server crashed: \#{inspect(reason)}")

  ## Exceptions

  This check ignores:
  - `Minga.Log` itself (it wraps Logger internally)
  - Test files (tests can log however they want)
  - `mix/` compiler tasks (run outside the application)

  See AGENTS.md § "Logging and the *Messages* Buffer" for subsystem docs.
  """

  use Credo.Check,
    id: "EX9003",
    base_priority: :normal,
    category: :design,
    explanations: [
      check: """
      Use `Minga.Log.debug(:subsystem, msg)` instead of `Logger.debug(msg)`.

      `Minga.Log` routes through per-subsystem log levels so users can
      control debug output per subsystem. Direct Logger calls bypass
      this filtering.
      """
    ]

  @logger_functions [:debug, :info, :notice, :warning, :error]

  @impl Credo.Check
  def run(%SourceFile{} = source_file, params) do
    if skip_file?(source_file) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)

      source_file
      |> Credo.Code.prewalk(&find_direct_logger(&1, &2, issue_meta))
      |> List.flatten()
    end
  end

  # Match Logger.debug(...), Logger.info(...), etc.
  defp find_direct_logger(
         {{:., _, [{:__aliases__, _, [:Logger]}, func]}, meta, _args} = ast,
         issues,
         issue_meta
       )
       when func in @logger_functions do
    issue =
      format_issue(issue_meta,
        message:
          "Use Minga.Log.#{func}(:subsystem, msg) instead of Logger.#{func}(). Direct Logger calls bypass per-subsystem log level filtering.",
        trigger: "Logger.#{func}",
        line_no: meta[:line]
      )

    {ast, [issue | issues]}
  end

  defp find_direct_logger(ast, issues, _issue_meta), do: {ast, issues}

  defp skip_file?(%SourceFile{} = source_file) do
    filename = Path.expand(source_file.filename)

    String.contains?(filename, "/test/") or
      String.contains?(filename, "/mix/") or
      String.ends_with?(filename, "/log.ex")
  end
end
