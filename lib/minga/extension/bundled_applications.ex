defmodule Minga.Extension.BundledApplications do
  @moduledoc """
  Explicit mapping from bundled source identities to trusted OTP applications.

  A mapping is active only when the named application's metadata is available
  on the current code path. Artifact admission may then adopt modules listed by
  that application while still claiming and loading any ordinary compiler
  outputs as one atomic source set.
  """

  @applications %{
    minga_adversarial: :minga_adversarial,
    minga_git_porcelain: :minga_git_porcelain,
    minga_knowledge_graph: :minga_knowledge_graph
  }

  @doc "Returns the verified OTP application for a bundled source, if present."
  @spec trusted_application(atom()) :: atom() | nil
  def trusted_application(source_name) when is_atom(source_name) do
    @applications
    |> Map.get(source_name)
    |> load_application_metadata()
  end

  @spec load_application_metadata(atom() | nil) :: atom() | nil
  defp load_application_metadata(nil), do: nil

  defp load_application_metadata(application) do
    case Application.load(application) do
      :ok -> verified_application(application)
      {:error, {:already_loaded, ^application}} -> verified_application(application)
      {:error, _reason} -> nil
    end
  end

  @spec verified_application(atom()) :: atom() | nil
  defp verified_application(application) do
    case :application.get_key(application, :modules) do
      {:ok, modules} when is_list(modules) -> application
      :undefined -> nil
    end
  end
end
