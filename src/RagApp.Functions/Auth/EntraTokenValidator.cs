using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Options;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Protocols;
using Microsoft.IdentityModel.Protocols.OpenIdConnect;
using Microsoft.IdentityModel.Tokens;
using RagApp.Functions.Models;

namespace RagApp.Functions.Auth;

public interface ITokenValidator
{
    /// <summary>Validates the Bearer token on the request and returns the user context, or null when invalid.</summary>
    Task<UserContext?> ValidateAsync(HttpRequest request, CancellationToken cancellationToken = default);
}

/// <summary>
/// Validates Entra ID JWT bearer tokens. Accepts tokens acquired directly by users
/// as well as tokens obtained by partner agents via the OAuth2 on-behalf-of flow —
/// in both cases the token carries the end user's oid/groups claims, which drive
/// PostgreSQL row-level security.
/// </summary>
public class EntraTokenValidator : ITokenValidator
{
    private readonly AuthOptions _options;
    private readonly ConfigurationManager<OpenIdConnectConfiguration> _configManager;
    private readonly JsonWebTokenHandler _handler = new();

    public EntraTokenValidator(IOptions<AuthOptions> options)
    {
        _options = options.Value;
        var metadataAddress =
            $"https://login.microsoftonline.com/{_options.TenantId}/v2.0/.well-known/openid-configuration";
        _configManager = new ConfigurationManager<OpenIdConnectConfiguration>(
            metadataAddress, new OpenIdConnectConfigurationRetriever());
    }

    public async Task<UserContext?> ValidateAsync(HttpRequest request, CancellationToken cancellationToken = default)
    {
        var authHeader = request.Headers.Authorization.ToString();
        if (string.IsNullOrEmpty(authHeader) || !authHeader.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }

        var token = authHeader["Bearer ".Length..].Trim();
        var oidcConfig = await _configManager.GetConfigurationAsync(cancellationToken);

        var parameters = new TokenValidationParameters
        {
            ValidIssuers =
            [
                $"https://login.microsoftonline.com/{_options.TenantId}/v2.0",
                $"https://sts.windows.net/{_options.TenantId}/"
            ],
            ValidAudiences =
            [
                _options.ClientId,
                $"api://{_options.ClientId}"
            ],
            IssuerSigningKeys = oidcConfig.SigningKeys,
            ValidateIssuer = true,
            ValidateAudience = true,
            ValidateLifetime = true
        };

        var result = await _handler.ValidateTokenAsync(token, parameters);
        if (!result.IsValid)
        {
            return null;
        }

        var claims = result.ClaimsIdentity.Claims.ToList();
        var oid = claims.FirstOrDefault(c =>
            c.Type is "oid" or "http://schemas.microsoft.com/identity/claims/objectidentifier")?.Value;
        if (string.IsNullOrEmpty(oid))
        {
            return null;
        }

        var groups = claims.Where(c => c.Type == "groups").Select(c => c.Value).ToList();
        var name = claims.FirstOrDefault(c => c.Type is "name" or "preferred_username")?.Value;
        return new UserContext(oid, groups, name);
    }
}
