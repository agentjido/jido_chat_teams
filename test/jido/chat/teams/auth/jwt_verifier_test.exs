defmodule Jido.Chat.Teams.Auth.JwtVerifierTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.Teams.Auth.JwtVerifier

  @app_id "00000000-0000-0000-0000-000000000001"
  @service_url "https://smba.trafficmanager.net/amer/"
  @now 1_787_137_200

  setup do
    private_key = JOSE.JWK.generate_key({:rsa, 2048})
    {_key_info, public_key} = JOSE.JWK.to_public_map(private_key)
    public_key = Map.merge(public_key, %{"kid" => "test-key", "alg" => "RS256", "use" => "sig"})

    {:ok, private_key: private_key, jwks: [public_key]}
  end

  test "accepts a valid Bot Connector token", ctx do
    token = token(ctx.private_key, valid_claims())

    assert {:ok, claims} =
             JwtVerifier.verify_with_claims(
               payload(),
               %{"authorization" => "Bearer #{token}"},
               %{app_id: @app_id, app_password: "private"},
               jwks: ctx.jwks,
               now: @now
             )

    assert claims["aud"] == @app_id
  end

  test "rejects a wrong audience, service URL, and expired token", ctx do
    cases = [
      {Map.put(valid_claims(), "aud", "another-app"), :invalid_audience},
      {Map.put(valid_claims(), "serviceurl", "https://smba.trafficmanager.net/emea/"),
       :service_url_mismatch},
      {Map.put(valid_claims(), "exp", @now - 301), :expired_token}
    ]

    for {claims, reason} <- cases do
      token = token(ctx.private_key, claims)

      assert {:error, ^reason} =
               JwtVerifier.verify(
                 payload(),
                 [{"Authorization", "Bearer #{token}"}],
                 %{"app_id" => @app_id},
                 jwks: ctx.jwks,
                 now: @now
               )
    end
  end

  test "rejects missing authorization and missing explicit app identity", ctx do
    assert {:error, :missing_authorization} =
             JwtVerifier.verify(payload(), %{}, %{app_id: @app_id}, jwks: ctx.jwks, now: @now)

    token = token(ctx.private_key, valid_claims())

    assert {:error, {:missing_credential, :app_id}} =
             JwtVerifier.verify(payload(), %{"authorization" => "Bearer #{token}"}, %{},
               jwks: ctx.jwks,
               now: @now
             )
  end

  defp valid_claims do
    %{
      "iss" => "https://api.botframework.com",
      "aud" => @app_id,
      "exp" => @now + 600,
      "nbf" => @now - 10,
      "serviceurl" => @service_url
    }
  end

  defp token(private_key, claims) do
    private_key
    |> JOSE.JWT.sign(%{"alg" => "RS256", "kid" => "test-key"}, claims)
    |> JOSE.JWS.compact()
    |> elem(1)
  end

  defp payload, do: %{"serviceUrl" => @service_url}
end
