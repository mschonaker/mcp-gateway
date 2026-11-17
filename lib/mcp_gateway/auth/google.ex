defmodule McpGateway.Auth.Google do
  @moduledoc false

  @auth_url "https://accounts.google.com/o/oauth2/v2/auth"
  @token_url "https://oauth2.googleapis.com/token"
  @jwks_url "https://www.googleapis.com/oauth2/v3/certs"
  @issuer "https://accounts.google.com"

  def authorize_url(state) do
    params =
      URI.encode_query(%{
        client_id: McpGateway.Config.google_client_id(),
        redirect_uri: redirect_uri(),
        response_type: "code",
        scope: "openid email profile",
        state: state,
        prompt: "select_account"
      })

    @auth_url <> "?" <> params
  end

  def exchange_code(code) do
    body = %{
      code: code,
      client_id: McpGateway.Config.google_client_id(),
      client_secret: McpGateway.Config.google_client_secret(),
      redirect_uri: redirect_uri(),
      grant_type: "authorization_code"
    }

    with {:ok, %{status: 200, body: resp}} <- Req.post(@token_url, form: body, finch: McpGateway.Finch),
         %{"id_token" => id_token} <- resp,
         {:ok, claims} <- verify_id_token(id_token) do
      {:ok, claims}
    else
      {:ok, %{status: status, body: body}} -> {:error, {:token_exchange_failed, status, body}}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  def redirect_uri, do: McpGateway.Config.base_url() <> "/auth/google/callback"

  defp verify_id_token(id_token) do
    with {:ok, %{status: 200, body: %{"keys" => keys}}} <- Req.get(@jwks_url, finch: McpGateway.Finch),
         {:ok, claims} <- verify_with_keys(id_token, keys),
         :ok <- validate_claims(claims) do
      {:ok, claims}
    else
      {:ok, %{status: status}} -> {:error, {:jwks_fetch_failed, status}}
      err -> err
    end
  end

  defp verify_with_keys(id_token, keys) do
    Enum.find_value(keys, {:error, :invalid_signature}, fn key ->
      try do
        jwk = JOSE.JWK.from_map(key)
        case JOSE.JWT.verify(jwk, id_token) do
          {true, %JOSE.JWT{fields: fields}, _jws} -> {:ok, fields}
          _ -> nil
        end
      rescue
        _ -> nil
      end
    end)
  end

  defp validate_claims(%{"iss" => iss, "aud" => aud, "exp" => exp, "email" => email} = claims)
       when iss in [@issuer, "accounts.google.com"] and is_binary(email) do
    now = System.system_time(:second)
    client_id = McpGateway.Config.google_client_id()

    cond do
      aud != client_id -> {:error, :invalid_audience}
      exp <= now -> {:error, :token_expired}
      claims["email_verified"] == false -> {:error, :email_not_verified}
      true -> :ok
    end
  end

  defp validate_claims(_), do: {:error, :invalid_claims}
end
