defmodule MingaAgent.OAuth.ManualCLI do
  @moduledoc """
  Runs the headless OAuth paste-back flow from a terminal.

  This path does not start the editor. It prints the authorize URL, reads one pasted redirect value from stdin, and completes the token exchange on the server.
  """

  alias MingaAgent.OAuth.Flow

  @type input_fun :: (String.t() -> String.t() | nil)
  @type output_fun :: (String.t() -> term())
  @type begin_fun :: (-> {:ok, String.t(), String.t()} | {:error, String.t()})
  @type complete_fun :: (String.t(), String.t() -> {:ok, :openai} | {:error, String.t()})

  @doc "Runs the manual OAuth CLI flow."
  @spec run(keyword()) :: :ok | {:error, String.t()}
  def run(opts \\ []) do
    input_fun = Keyword.get(opts, :input_fun, &IO.gets/1)
    output_fun = Keyword.get(opts, :output_fun, &IO.puts/1)
    begin_fun = Keyword.get(opts, :begin_fun, &Flow.begin_manual/0)
    complete_fun = Keyword.get(opts, :complete_fun, &Flow.complete_manual/2)

    with {:ok, url, ref} <- begin_fun.(),
         {:ok, pasted} <- prompt_for_redirect(input_fun, output_fun, url, ref),
         {:ok, :openai} <- complete_fun.(ref, pasted) do
      output_fun.("ChatGPT subscription connected. Tokens were written to the server oauth.json.")
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec prompt_for_redirect(input_fun(), output_fun(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp prompt_for_redirect(input_fun, output_fun, url, ref) do
    output_fun.("Open this URL in your browser to sign in:")
    output_fun.(url)
    output_fun.("Flow ref: #{ref}")

    output_fun.(
      "After approving, paste the full redirect URL, bare code, or code#state value below."
    )

    input_fun.("Paste redirect value: ")
    |> normalize_input()
  end

  @spec normalize_input(String.t() | nil) :: {:ok, String.t()} | {:error, String.t()}
  defp normalize_input(nil),
    do: {:error, "No redirect value was provided. Run minga login --manual to try again."}

  defp normalize_input(value) when is_binary(value) do
    value
    |> String.trim()
    |> normalize_trimmed_input()
  end

  @spec normalize_trimmed_input(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp normalize_trimmed_input(""),
    do: {:error, "No redirect value was provided. Run minga login --manual to try again."}

  defp normalize_trimmed_input(value), do: {:ok, value}
end
