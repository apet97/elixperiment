defmodule PumbleAutomation.Pumble.Signature do
  @moduledoc """
  The Pumble callback signature scheme, as a pure function of its inputs.

  Evidence `H-7`, `H-9`, and `H-10` in `docs/evidence/pumble_source_matrix.md`
  fix the scheme from the SDK source:

      signature = HMAC-SHA256(signing_secret, "<timestamp>:<raw_body>")

  rendered as lowercase hexadecimal with no prefix, scheme, or version tag. The
  `timestamp` is the value of the `x-pumble-request-timestamp` header, treated as
  an opaque string: its unit is `PR-03` and nothing here depends on it. Because
  the timestamp is inside the signed string, it cannot be altered on its own.

  ## Constant time, and what that costs

  `valid?/4` compares with `Plug.Crypto.secure_compare/2`, which runs in time
  independent of how many leading bytes match. The Node SDK compares with `!==`
  (`H-18`); that divergence is deliberate.

  A signature of the wrong length or with a non-hexadecimal character is rejected
  before any comparison. That check is not constant time and does not need to be:
  it reveals only the length and alphabet of the value the caller supplied, which
  the caller already knows. Every *well-formed* signature takes the same path.

  ## No secret handling here

  This module never reads configuration. It is given a secret, and the decision
  of where the secret comes from — and the refusal to run without one — belongs
  to `PumbleAutomationWeb.Plugs.VerifyPumbleSignature`.
  """

  @digest_bytes 32
  @hex_length @digest_bytes * 2

  @doc """
  Computes the signature Pumble would send for these bytes.

  Returns lowercase hexadecimal. Used to build fixtures and to verify; a caller
  authenticating a request should use `valid?/4` rather than comparing the
  result of this function itself.
  """
  @spec compute(binary(), binary(), binary()) :: String.t()
  def compute(secret, timestamp, raw_body)
      when is_binary(secret) and is_binary(timestamp) and is_binary(raw_body) do
    secret
    |> mac(timestamp, raw_body)
    |> Base.encode16(case: :lower)
  end

  @doc """
  True when `signature` is the signature of `raw_body` at `timestamp`.

  Answers `false` — never raises — for a missing, wrong-length, non-hexadecimal,
  or non-binary input, so a caller has one failure to handle and cannot tell the
  cases apart from the return value.
  """
  @spec valid?(binary() | nil, binary() | nil, binary() | nil, binary() | nil) :: boolean()
  def valid?(secret, timestamp, raw_body, signature)
      when is_binary(secret) and is_binary(timestamp) and is_binary(raw_body) and
             is_binary(signature) do
    case decode(signature) do
      {:ok, supplied} -> Plug.Crypto.secure_compare(supplied, mac(secret, timestamp, raw_body))
      :error -> false
    end
  end

  def valid?(_secret, _timestamp, _raw_body, _signature), do: false

  @doc "The length of a well-formed signature, in hexadecimal characters."
  @spec hex_length() :: pos_integer()
  def hex_length, do: @hex_length

  defp mac(secret, timestamp, raw_body) do
    :crypto.mac(:hmac, :sha256, secret, [timestamp, ":", raw_body])
  end

  # Length first: `Base.decode16/2` accepts any even-length hexadecimal string,
  # so without this a 2 character signature would decode happily and then be
  # compared against a 32 byte digest.
  defp decode(signature) when byte_size(signature) == @hex_length do
    signature
    |> String.downcase()
    |> Base.decode16(case: :lower)
  end

  defp decode(_signature), do: :error
end
