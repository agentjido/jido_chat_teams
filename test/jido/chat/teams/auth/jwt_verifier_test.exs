defmodule Jido.Chat.Teams.Auth.JwtVerifierTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.Teams.Auth.JwtVerifier
  alias Jido.Chat.WebhookRequest

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
    request = request(token(ctx.private_key, valid_claims()))

    assert {:ok, claims} =
             JwtVerifier.verify_with_claims(request,
               app_id: @app_id,
               jwks: ctx.jwks,
               now: @now
             )

    assert claims["aud"] == @app_id
    assert claims["serviceurl"] == @service_url
  end

  test "rejects a wrong audience", ctx do
    claims = Map.put(valid_claims(), "aud", "another-app")

    assert {:error, :invalid_audience} =
             JwtVerifier.verify(request(token(ctx.private_key, claims)),
               app_id: @app_id,
               jwks: ctx.jwks,
               now: @now
             )
  end

  test "rejects a service URL mismatch", ctx do
    claims = Map.put(valid_claims(), "serviceurl", "https://smba.trafficmanager.net/emea/")

    assert {:error, :service_url_mismatch} =
             JwtVerifier.verify(request(token(ctx.private_key, claims)),
               app_id: @app_id,
               jwks: ctx.jwks,
               now: @now
             )
  end

  test "rejects an expired token", ctx do
    claims = Map.put(valid_claims(), "exp", @now - 301)

    assert {:error, :expired_token} =
             JwtVerifier.verify(request(token(ctx.private_key, claims)),
               app_id: @app_id,
               jwks: ctx.jwks,
               now: @now
             )
  end

  test "rejects a request with no authorization header", ctx do
    request = WebhookRequest.new(%{payload: %{"serviceUrl" => @service_url}})

    assert {:error, :missing_authorization} =
             JwtVerifier.verify(request, app_id: @app_id, jwks: ctx.jwks, now: @now)
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

  defp request(token) do
    WebhookRequest.new(%{
      adapter_name: :teams,
      headers: %{"authorization" => "Bearer #{token}"},
      payload: %{"serviceUrl" => @service_url}
    })
  end
end
