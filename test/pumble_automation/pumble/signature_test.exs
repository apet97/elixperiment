defmodule PumbleAutomation.Pumble.SignatureTest do
  @moduledoc """
  The signature scheme against its stored examples and its malformed inputs.

  The fixtures carry a fake secret and a fake body and are the only place the
  expected hexadecimal is written down, so a change to the scheme fails here
  first and loudly.
  """

  use ExUnit.Case, async: true

  alias PumbleAutomation.Pumble.Signature
  alias PumbleAutomation.PumbleFake

  setup do
    valid = PumbleFake.fixture("signatures/valid.json")
    invalid = PumbleFake.fixture("signatures/invalid.json")

    %{valid: valid, invalid: invalid}
  end

  describe "compute/3" do
    test "reproduces the stored signature", %{valid: valid} do
      assert Signature.compute(valid["signing_secret"], valid["timestamp"], valid["body"]) ==
               valid["signature"]
    end

    test "is lowercase hexadecimal of the digest length", %{valid: valid} do
      signature = Signature.compute(valid["signing_secret"], valid["timestamp"], valid["body"])

      assert String.length(signature) == Signature.hex_length()
      assert signature == String.downcase(signature)
      assert {:ok, digest} = Base.decode16(signature, case: :lower)
      assert byte_size(digest) == 32
    end

    test "signs the timestamp and the body together, not the body alone", %{valid: valid} do
      other =
        Signature.compute(valid["signing_secret"], valid["timestamp"] <> "0", valid["body"])

      refute other == valid["signature"]
    end

    test "an empty body still signs", %{valid: valid} do
      signature = Signature.compute(valid["signing_secret"], valid["timestamp"], "")

      assert String.length(signature) == Signature.hex_length()
      refute signature == valid["signature"]
    end
  end

  describe "valid?/4" do
    test "accepts the stored valid example", %{valid: valid} do
      assert Signature.valid?(
               valid["signing_secret"],
               valid["timestamp"],
               valid["body"],
               valid["signature"]
             )
    end

    test "accepts the same signature in uppercase", %{valid: valid} do
      assert Signature.valid?(
               valid["signing_secret"],
               valid["timestamp"],
               valid["body"],
               String.upcase(valid["signature"])
             )
    end

    test "refuses the stored invalid example, which is well formed", %{invalid: invalid} do
      assert String.length(invalid["signature"]) == Signature.hex_length()

      refute Signature.valid?(
               invalid["signing_secret"],
               invalid["timestamp"],
               invalid["body"],
               invalid["signature"]
             )
    end

    test "refuses a body changed only in whitespace", %{valid: valid} do
      spaced = String.replace(valid["body"], ",", ", ")

      assert Jason.decode!(spaced) == Jason.decode!(valid["body"])

      refute Signature.valid?(
               valid["signing_secret"],
               valid["timestamp"],
               spaced,
               valid["signature"]
             )
    end

    test "refuses a changed timestamp", %{valid: valid} do
      refute Signature.valid?(
               valid["signing_secret"],
               valid["timestamp"] <> "1",
               valid["body"],
               valid["signature"]
             )
    end

    test "refuses another secret", %{valid: valid} do
      refute Signature.valid?(
               "ANOTHER_FAKE_SECRET",
               valid["timestamp"],
               valid["body"],
               valid["signature"]
             )
    end

    test "refuses a malformed or wrong-length signature", %{valid: valid} do
      truncated = String.slice(valid["signature"], 0, 62)
      extended = valid["signature"] <> "ab"
      non_hex = String.replace_prefix(valid["signature"], "63", "zz")

      for candidate <- ["", "0", truncated, extended, non_hex] do
        refute Signature.valid?(
                 valid["signing_secret"],
                 valid["timestamp"],
                 valid["body"],
                 candidate
               ),
               "#{inspect(candidate)} must not verify"
      end
    end

    test "refuses when any input is missing", %{valid: valid} do
      refute Signature.valid?(nil, valid["timestamp"], valid["body"], valid["signature"])
      refute Signature.valid?(valid["signing_secret"], nil, valid["body"], valid["signature"])

      refute Signature.valid?(
               valid["signing_secret"],
               valid["timestamp"],
               nil,
               valid["signature"]
             )

      refute Signature.valid?(valid["signing_secret"], valid["timestamp"], valid["body"], nil)
    end
  end
end
