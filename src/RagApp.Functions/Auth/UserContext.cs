namespace RagApp.Functions.Auth;

/// <summary>Identity of the calling end user, extracted from the validated Entra ID token.</summary>
public record UserContext(string ObjectId, IReadOnlyList<string> GroupIds, string? Name);
