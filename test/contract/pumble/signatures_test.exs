defmodule PumbleAutomation.Contract.Pumble.SignaturesTest do
  @moduledoc """
  Stored signature fixtures against the HMAC-SHA256 scheme (H-7, H-9).
  """

  use ExUnit.Case, async: true

  alias PumbleAutomation.Pumble.Signature
  alias PumbleAutomation.PumbleFake

  test "the valid fixture is accepted and the invalid fixture is refused" do
    for entry <- Enum.filter(PumbleFake.catalog()["fixtures"], &(&1["kind"] == "signature")) do
      fixture = PumbleFake.fixture(entry["path"])
      valid? = entry["expected"]["verify"] == "accepted"

      assert Signature.valid?(
               fixture["signing_secret"],
               fixture["timestamp"],
               fixture["body"],
               fixture["signature"]
             ) == valid?

      if valid? do
        assert Signature.compute(
                 fixture["signing_secret"],
                 fixture["timestamp"],
                 fixture["body"]
               ) == fixture["signature"]
      end
    end
  end
end
