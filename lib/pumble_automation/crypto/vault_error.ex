defmodule PumbleAutomation.Crypto.VaultError do
  @moduledoc """
  Raised when a credential column cannot be sealed or opened.

  `PumbleAutomation.Crypto.EncryptedBinary` runs inside Ecto's load and dump
  path, where the only two answers available are a value or `:error`. An
  `:error` there becomes an `Ecto.ChangeError` that says a binary could not be
  loaded, which tells an operator nothing about the real cause.

  So the type raises this instead. The `:error` field carries the typed
  `PumbleAutomation.Error` the vault produced, so a caller that rescues can
  still classify the failure and a log line still names the code.

  Nothing about the value is included, here or in the message.
  """

  alias PumbleAutomation.Error

  @type t :: %__MODULE__{error: Error.t()}

  defexception [:error]

  @impl true
  def message(%__MODULE__{error: %Error{} = error}) do
    "#{error.code}: #{error.message}"
  end
end
