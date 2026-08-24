defmodule PumbleAutomation.Installations.ReturnPaths do
  @moduledoc """
  The closed set of places an OAuth round trip may return a browser to.

  An OAuth state stores a *key* from this table, never a path and never a URL.
  That is the whole open-redirect control, and it is structural rather than
  defensive: there is no string in the state row that a redirect could be built
  from, so no amount of reflection, encoding, or parser disagreement turns a
  callback parameter into a destination. A key that is not in the table is
  refused at the moment the state is created, so a bad key never reaches the
  redirect at all.

  The values are relative paths beginning with `/`. They cannot carry a scheme,
  a host, or a protocol-relative `//` prefix, which is checked here rather than
  assumed, so that a future entry cannot quietly become an absolute URL.

  ## Adding a destination

  Add the key and its path here, and nowhere else. The table is small on purpose:
  it grows one entry at a time as the application grows a screen worth returning
  to, and every entry is a path this router actually serves.
  """

  alias PumbleAutomation.Error

  @paths %{"home" => "/"}

  @default_key "home"

  @doc """
  Returns the path for `key`.

  `nil` means the caller expressed no preference and gets `default_key/0`.
  Anything else that is not a known key is an error, never a silent fallback: a
  caller that asked for a destination this application does not have is
  confused, and answering with a different one hides that.
  """
  @spec fetch(String.t() | nil) :: {:ok, String.t()} | {:error, Error.t()}
  def fetch(nil), do: fetch(@default_key)

  def fetch(key) when is_binary(key) do
    case Map.fetch(@paths, key) do
      {:ok, path} -> {:ok, path}
      :error -> {:error, unknown(key)}
    end
  end

  def fetch(_key), do: {:error, unknown(nil)}

  @doc """
  Returns whether `key` names a destination.

  Use this to validate a key before storing it; use `fetch/1` to turn a stored
  key into a path.
  """
  @spec known?(term()) :: boolean()
  def known?(key) when is_binary(key), do: Map.has_key?(@paths, key)
  def known?(_key), do: false

  @doc "The key used when a caller names no destination."
  @spec default_key() :: String.t()
  def default_key, do: @default_key

  @doc "The path used when a flow fails and there is no trustworthy destination."
  @spec failure_path() :: String.t()
  def failure_path, do: Map.fetch!(@paths, @default_key)

  @doc "Every destination key, for documentation and tests."
  @spec keys() :: [String.t()]
  def keys, do: Map.keys(@paths)

  @doc """
  Returns whether a path is local to this application.

  Exposed so that a test can hold every entry of the table to the same rule the
  table claims to enforce.
  """
  @spec local_path?(String.t()) :: boolean()
  def local_path?(path) when is_binary(path) do
    String.starts_with?(path, "/") and not String.starts_with?(path, "//") and
      not String.contains?(path, ":") and not String.contains?(path, "\\")
  end

  def local_path?(_path), do: false

  defp unknown(key) do
    Error.new(:validation, :unknown_return_path,
      message: "The requested destination is not available.",
      details: %{requested_key: key, known_keys: Map.keys(@paths)}
    )
  end
end
