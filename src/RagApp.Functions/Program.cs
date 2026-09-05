using Azure.AI.DocumentIntelligence;
using Azure.AI.OpenAI;
using Azure.Core;
using Azure.Identity;
using Azure.Storage.Blobs;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Options;
using RagApp.Functions.Auth;
using RagApp.Functions.Models;
using RagApp.Functions.Services;

var builder = FunctionsApplication.CreateBuilder(args);
builder.ConfigureFunctionsWebApplication();

TokenCredential credential = new DefaultAzureCredential();

// Centralized configuration: Azure App Configuration with Key Vault references.
var appConfigEndpoint = builder.Configuration["AppConfig:Endpoint"];
if (!string.IsNullOrEmpty(appConfigEndpoint))
{
    builder.Configuration.AddAzureAppConfiguration(options =>
    {
        options.Connect(new Uri(appConfigEndpoint), credential)
            .Select("Rag:*")
            .ConfigureKeyVault(kv => kv.SetCredential(credential));
    });
}

builder.Services.Configure<RagOptions>(builder.Configuration.GetSection(RagOptions.SectionName));
builder.Services.Configure<AuthOptions>(builder.Configuration.GetSection(AuthOptions.SectionName));

builder.Services.AddSingleton(credential);
builder.Services.AddSingleton(sp =>
{
    var options = sp.GetRequiredService<IOptions<RagOptions>>().Value;
    return new AzureOpenAIClient(new Uri(options.OpenAiEndpoint), credential);
});
builder.Services.AddSingleton(sp =>
{
    var options = sp.GetRequiredService<IOptions<RagOptions>>().Value;
    return new DocumentIntelligenceClient(new Uri(options.DocumentIntelligenceEndpoint), credential);
});
builder.Services.AddSingleton(sp =>
{
    var options = sp.GetRequiredService<IOptions<RagOptions>>().Value;
    return new BlobServiceClient(new Uri(options.BlobEndpoint), credential);
});

builder.Services.AddSingleton<ITokenValidator, EntraTokenValidator>();
builder.Services.AddSingleton<PgVectorStore>();
builder.Services.AddSingleton<ChunkingService>();
builder.Services.AddSingleton<EmbeddingService>();
builder.Services.AddSingleton<DocumentIngestionService>();
builder.Services.AddSingleton<RagAgentService>();

builder.Services
    .AddApplicationInsightsTelemetryWorkerService()
    .ConfigureFunctionsApplicationInsights();

builder.Build().Run();
