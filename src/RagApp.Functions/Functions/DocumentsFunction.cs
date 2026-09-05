using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;
using RagApp.Functions.Auth;
using RagApp.Functions.Services;

namespace RagApp.Functions.Functions;

public class DocumentsFunction
{
    private readonly ITokenValidator _tokenValidator;
    private readonly DocumentIngestionService _ingestionService;
    private readonly PgVectorStore _store;
    private readonly ILogger<DocumentsFunction> _logger;

    public DocumentsFunction(
        ITokenValidator tokenValidator,
        DocumentIngestionService ingestionService,
        PgVectorStore store,
        ILogger<DocumentsFunction> logger)
    {
        _tokenValidator = tokenValidator;
        _ingestionService = ingestionService;
        _store = store;
        _logger = logger;
    }

    /// <summary>
    /// Uploads a document (multipart/form-data, field "file"). Optional form field
    /// "groupIds" is a comma-separated list of Entra group object ids to share with.
    /// </summary>
    [Function("UploadDocument")]
    public async Task<IActionResult> Upload(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "documents")] HttpRequest request,
        CancellationToken ct)
    {
        var user = await _tokenValidator.ValidateAsync(request, ct);
        if (user is null)
        {
            return new UnauthorizedResult();
        }

        if (!request.HasFormContentType)
        {
            return new BadRequestObjectResult(new { error = "Expected multipart/form-data with a 'file' field." });
        }

        var form = await request.ReadFormAsync(ct);
        var file = form.Files.GetFile("file") ?? form.Files.FirstOrDefault();
        if (file is null || file.Length == 0)
        {
            return new BadRequestObjectResult(new { error = "No file provided." });
        }

        var groupIds = (form["groupIds"].ToString() ?? string.Empty)
            .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

        try
        {
            await using var stream = file.OpenReadStream();
            var result = await _ingestionService.IngestAsync(
                user, file.FileName, file.ContentType, stream, groupIds, ct);
            return new OkObjectResult(result);
        }
        catch (InvalidOperationException ex)
        {
            _logger.LogWarning(ex, "Ingestion rejected for {Filename}", file.FileName);
            return new UnprocessableEntityObjectResult(new { error = ex.Message });
        }
    }

    [Function("ListDocuments")]
    public async Task<IActionResult> List(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "documents")] HttpRequest request,
        CancellationToken ct)
    {
        var user = await _tokenValidator.ValidateAsync(request, ct);
        if (user is null)
        {
            return new UnauthorizedResult();
        }

        var documents = await _store.ListDocumentsAsync(user, ct);
        return new OkObjectResult(documents);
    }
}
