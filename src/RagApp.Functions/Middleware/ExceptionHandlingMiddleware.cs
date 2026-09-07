using Microsoft.AspNetCore.Http;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Middleware;
using Microsoft.Extensions.Logging;

namespace RagApp.Functions.Middleware;

/// <summary>
/// Catches unhandled exceptions from HTTP-triggered functions and returns them as a JSON
/// 500 body instead of an empty response. Without this, exceptions thrown during DI
/// resolution (e.g. a missing config value building a client) crash the invocation before
/// any function-level try/catch runs, and the caller sees a bare 500 with no indication why.
/// Non-HTTP triggers have no HttpContext to write to, so they fall through to the host's
/// normal failure/retry handling.
/// </summary>
public class ExceptionHandlingMiddleware : IFunctionsWorkerMiddleware
{
    private readonly ILogger<ExceptionHandlingMiddleware> _logger;

    public ExceptionHandlingMiddleware(ILogger<ExceptionHandlingMiddleware> logger)
    {
        _logger = logger;
    }

    public async Task Invoke(FunctionContext context, FunctionExecutionDelegate next)
    {
        try
        {
            await next(context);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Unhandled exception in {FunctionName}", context.FunctionDefinition.Name);

            var httpContext = context.GetHttpContext();
            if (httpContext is null || httpContext.Response.HasStarted)
            {
                throw;
            }

            httpContext.Response.StatusCode = 500;
            httpContext.Response.ContentType = "application/json";
            await httpContext.Response.WriteAsJsonAsync(new { error = ex.Message });
        }
    }
}
