using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;

namespace ComfyDeployControl;

public partial class MainWindow : Window
{
    private readonly DispatcherTimer _watchTimer = new() { Interval = TimeSpan.FromSeconds(45) };
    private readonly HttpClient _http = new();
    private PipelineSettings _settings = new();
    private CancellationTokenSource? _logCts;
    private bool _busy;
    private string _lastNodeFingerprint = "";

    public MainWindow()
    {
        InitializeComponent();
        _watchTimer.Tick += WatchTimer_Tick;
    }

    private void Window_Loaded(object sender, RoutedEventArgs e)
    {
        _settings = PipelineSettings.Load();
        if (string.IsNullOrWhiteSpace(_settings.LocalRepoPath))
            _settings.LocalRepoPath = FindRepoRoot();

        ApplySettingsToUi();
        _ = RefreshNodesAsync();
        _ = RefreshBuildHistoryAsync();
    }

    private void Window_Closing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        _watchTimer.Stop();
        _logCts?.Cancel();
    }

    private void ApplySettingsToUi()
    {
        GitHubOwnerBox.Text = _settings.GitHubOwner;
        GitHubRepoBox.Text = _settings.GitHubRepo;
        RepoPathBox.Text = _settings.LocalRepoPath;
        DockerUsernameBox.Text = _settings.DockerUsername;
        DockerTokenBox.Password = _settings.DockerToken;
        DockerNamespaceBox.Text = _settings.DockerNamespace;
        DockerRepoBox.Text = _settings.DockerRepo;
        ModalAppBox.Text = _settings.ModalAppName;
        ModalVolumeBox.Text = _settings.ModalVolumeName;
        KeepTagsBox.Text = _settings.KeepDockerTags.ToString();
        AutoWatchBox.IsChecked = _settings.AutoWatch;
        PruneTagsBox.IsChecked = _settings.PruneDockerTags;

        foreach (ComboBoxItem item in GpuBox.Items)
        {
            if (string.Equals(item.Content?.ToString(), _settings.ModalGpu, StringComparison.OrdinalIgnoreCase))
            {
                GpuBox.SelectedItem = item;
                break;
            }
        }

        if (GpuBox.SelectedItem is null)
            GpuBox.SelectedIndex = 0;

        UpdateCards();
        UpdateWatcher();
    }

    private void PullSettingsFromUi()
    {
        _settings.GitHubOwner = GitHubOwnerBox.Text.Trim();
        _settings.GitHubRepo = GitHubRepoBox.Text.Trim();
        _settings.LocalRepoPath = RepoPathBox.Text.Trim();
        _settings.DockerUsername = DockerUsernameBox.Text.Trim();
        _settings.DockerToken = DockerTokenBox.Password;
        _settings.DockerNamespace = DockerNamespaceBox.Text.Trim();
        _settings.DockerRepo = DockerRepoBox.Text.Trim();
        _settings.ModalAppName = ModalAppBox.Text.Trim();
        _settings.ModalVolumeName = ModalVolumeBox.Text.Trim();
        _settings.ModalGpu = (GpuBox.SelectedItem as ComboBoxItem)?.Content?.ToString() ?? "A10";
        _settings.AutoWatch = AutoWatchBox.IsChecked == true;
        _settings.PruneDockerTags = PruneTagsBox.IsChecked == true;
        _settings.KeepDockerTags = int.TryParse(KeepTagsBox.Text.Trim(), out var keep) ? Math.Max(0, keep) : 3;
        UpdateCards();
    }

    private async void SaveSettings_Click(object sender, RoutedEventArgs e)
    {
        PullSettingsFromUi();
        _settings.Save();
        await LogAsync("Settings saved.");
    }

    private async void CheckAccess_Click(object sender, RoutedEventArgs e)
    {
        await RunGuardedAsync("Checking CLI access", async token =>
        {
            await RunAsync("gh", "auth status", _settings.LocalRepoPath, LogLine, token);
            await RunAsync("modal", "profile current", _settings.LocalRepoPath, LogLine, token);
            await RunAsync("git", "status --short --branch", _settings.LocalRepoPath, LogLine, token);
        });
    }

    private async void ConfigureSecrets_Click(object sender, RoutedEventArgs e)
    {
        await RunGuardedAsync("Configuring GitHub secrets", async token =>
        {
            PullSettingsFromUi();
            _settings.Save();
            var repo = RepoSpecifier;
            await RunAsync("gh", $"secret set DOCKERHUB_USERNAME --repo {repo} -b {Q(_settings.DockerUsername)}", _settings.LocalRepoPath, LogLine, token);
            await RunAsync("gh", $"secret set DOCKERHUB_TOKEN --repo {repo} -b {Q(_settings.DockerToken)}", _settings.LocalRepoPath, LogLine, token);
            await LogAsync("GitHub Actions secrets are configured.");
        });
    }

    private async void RunPipeline_Click(object sender, RoutedEventArgs e)
    {
        await RunPipelineAsync(forceBuild: false);
    }

    private async void ForceBuild_Click(object sender, RoutedEventArgs e)
    {
        await RunPipelineAsync(forceBuild: true);
    }

    private async void Deploy_Click(object sender, RoutedEventArgs e)
    {
        await RunGuardedAsync("Deploying Modal app", DeployModalAsync);
    }

    private async void StopApp_Click(object sender, RoutedEventArgs e)
    {
        await RunGuardedAsync("Stopping Modal app", token => RunAsync("modal", $"app stop {_settings.ModalAppName} --yes", _settings.LocalRepoPath, LogLine, token));
    }

    private async void RefreshBuilds_Click(object sender, RoutedEventArgs e)
    {
        await RefreshBuildHistoryAsync();
    }

    private async void StartAppLogs_Click(object sender, RoutedEventArgs e)
    {
        await StartLogStreamAsync(ModalLogBox, $"app logs {_settings.ModalAppName} -f --timestamps");
    }

    private async void StartComfyLogs_Click(object sender, RoutedEventArgs e)
    {
        await StartLogStreamAsync(ComfyLogBox, $"app logs {_settings.ModalAppName} -f --timestamps --source stderr");
    }

    private void StopLogs_Click(object sender, RoutedEventArgs e)
    {
        _logCts?.Cancel();
        _logCts = null;
        SetStatus("Logs stopped");
    }

    private void OpenComfy_Click(object sender, RoutedEventArgs e)
    {
        _ = OpenModalUrlAsync("comfyui", "");
    }

    private void OpenJupyter_Click(object sender, RoutedEventArgs e)
    {
        _ = OpenModalUrlAsync("jupyter", "/lab?token=modal-comfyui");
    }

    private void AutoWatch_Changed(object sender, RoutedEventArgs e)
    {
        PullSettingsFromUi();
        _settings.Save();
        UpdateWatcher();
    }

    private async void WatchTimer_Tick(object? sender, EventArgs e)
    {
        if (_busy || AutoWatchBox.IsChecked != true)
            return;

        try
        {
            var nodes = await ListModalNodesAsync(CancellationToken.None);
            var fingerprint = string.Join("|", nodes.OrderBy(x => x, StringComparer.OrdinalIgnoreCase));
            if (!string.IsNullOrEmpty(_lastNodeFingerprint) && fingerprint != _lastNodeFingerprint)
            {
                await LogAsync("Custom node change detected. Starting rebuild pipeline.");
                await RunPipelineAsync(forceBuild: false);
            }
            _lastNodeFingerprint = fingerprint;
        }
        catch (Exception ex)
        {
            await LogAsync("Watcher error: " + ex.Message);
        }
    }

    private async Task RunPipelineAsync(bool forceBuild)
    {
        await RunGuardedAsync(forceBuild ? "Building current repo" : "Syncing nodes and rebuilding", async token =>
        {
            PullSettingsFromUi();
            _settings.Save();

            if (!forceBuild)
                await SyncNodesFromModalAsync(token);

            await CommitAndPushIfChangedAsync(token);
            var runId = await StartFreshBuildAsync(token);
            await WaitForBuildAsync(runId, token);

            if (_settings.PruneDockerTags)
                await PruneDockerHubTagsAsync(token);

            await DeployModalAsync(token);
            await RefreshNodesAsync();
            await RefreshBuildHistoryAsync();
        });
    }

    private async Task SyncNodesFromModalAsync(CancellationToken token)
    {
        var nodes = await ListModalNodesAsync(token);
        NodeList.ItemsSource = nodes;
        NodeCountText.Text = nodes.Count.ToString();
        _lastNodeFingerprint = string.Join("|", nodes.OrderBy(x => x, StringComparer.OrdinalIgnoreCase));

        var runtimeDir = Path.Combine(_settings.LocalRepoPath, "custom_nodes_runtime");
        if (Directory.Exists(runtimeDir))
            Directory.Delete(runtimeDir, recursive: true);
        Directory.CreateDirectory(runtimeDir);

        await File.WriteAllTextAsync(Path.Combine(runtimeDir, "README.md"),
            "# App-managed custom nodes\n\nThis directory is refreshed by ComfyDeployControl from the Modal volume.\n", token);
        await File.WriteAllTextAsync(Path.Combine(runtimeDir, ".gitkeep"), "", token);

        foreach (var node in nodes)
        {
            token.ThrowIfCancellationRequested();
            await LogAsync($"Downloading custom node: {node}");
            var remotePath = $"/ComfyUI/custom_nodes/{node}";
            await RunAsync("modal", $"volume get {_settings.ModalVolumeName} {Q(remotePath)} {Q(runtimeDir)} --force", _settings.LocalRepoPath, LogLine, token);
        }

        CleanDownloadedNodes(runtimeDir);

        var manifest = new
        {
            syncedAtUtc = DateTimeOffset.UtcNow,
            volume = _settings.ModalVolumeName,
            nodes
        };
        await File.WriteAllTextAsync(
            Path.Combine(runtimeDir, "manifest.json"),
            JsonSerializer.Serialize(manifest, JsonOptions),
            token);
    }

    private async Task<List<string>> ListModalNodesAsync(CancellationToken token)
    {
        var lines = new List<string>();
        await RunAsync("modal", $"volume ls {_settings.ModalVolumeName} /ComfyUI/custom_nodes", _settings.LocalRepoPath, lines.Add, token, quiet: true);

        var skip = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "__pycache__",
            ".disabled",
            "example_node.py.example",
            "comfyui-manager",
            "ComfyUI-Civitai-Downloader"
        };

        return lines
            .Select(line => line.Trim())
            .Where(line => line.StartsWith("ComfyUI/custom_nodes/", StringComparison.OrdinalIgnoreCase))
            .Select(line => line["ComfyUI/custom_nodes/".Length..].Split('/', '\\')[0])
            .Where(name => !string.IsNullOrWhiteSpace(name) && !skip.Contains(name))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(name => name, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    private static void CleanDownloadedNodes(string runtimeDir)
    {
        foreach (var dir in Directory.EnumerateDirectories(runtimeDir, "__pycache__", SearchOption.AllDirectories).ToList())
            Directory.Delete(dir, recursive: true);
        foreach (var dir in Directory.EnumerateDirectories(runtimeDir, ".git", SearchOption.AllDirectories).ToList())
            Directory.Delete(dir, recursive: true);
        foreach (var dir in Directory.EnumerateDirectories(runtimeDir, ".ipynb_checkpoints", SearchOption.AllDirectories).ToList())
            Directory.Delete(dir, recursive: true);
        foreach (var file in Directory.EnumerateFiles(runtimeDir, "*.pyc", SearchOption.AllDirectories).ToList())
            File.Delete(file);
    }

    private async Task CommitAndPushIfChangedAsync(CancellationToken token)
    {
        await RunAsync("git", "add Dockerfile .dockerignore .gitignore custom_nodes_runtime desktop", _settings.LocalRepoPath, LogLine, token);
        var diffCode = await RunAsync("git", "diff --cached --quiet", _settings.LocalRepoPath, _ => { }, token, quiet: true, allowFailure: true);
        if (diffCode == 0)
        {
            await LogAsync("No repository changes to commit.");
            return;
        }

        await RunAsync("git", "commit -m \"Sync Modal custom nodes for image build\"", _settings.LocalRepoPath, LogLine, token);
        await RunAsync("git", "push origin main", _settings.LocalRepoPath, LogLine, token);
    }

    private async Task<long> StartFreshBuildAsync(CancellationToken token)
    {
        BuildStatusText.Text = "Canceling stale runs";
        var runningJson = new StringBuilder();
        await RunAsync("gh", $"run list --repo {RepoSpecifier} --workflow {Q("Build Docker image")} --limit 20 --json databaseId,status", _settings.LocalRepoPath, line => runningJson.AppendLine(line), token, quiet: true);

        foreach (var id in ParseRunningBuildIds(runningJson.ToString()))
        {
            await LogAsync($"Canceling stale build: {id}");
            await RunAsync("gh", $"run cancel {id} --repo {RepoSpecifier}", _settings.LocalRepoPath, LogLine, token, allowFailure: true);
        }

        BuildStatusText.Text = "Queued";
        await RunAsync("gh", $"workflow run {Q("Build Docker image")} --repo {RepoSpecifier} --ref main", _settings.LocalRepoPath, LogLine, token);
        await Task.Delay(TimeSpan.FromSeconds(6), token);

        var latest = await LatestBuildRunAsync(token);
        await LogAsync($"Tracking build run {latest.id}: {latest.url}");
        return latest.id;
    }

    private async Task WaitForBuildAsync(long runId, CancellationToken token)
    {
        BuildStatusText.Text = "Building";
        while (true)
        {
            token.ThrowIfCancellationRequested();
            var json = new StringBuilder();
            await RunAsync("gh", $"run view {runId} --repo {RepoSpecifier} --json status,conclusion,url", _settings.LocalRepoPath, line => json.AppendLine(line), token, quiet: true);
            using var doc = JsonDocument.Parse(json.ToString());
            var root = doc.RootElement;
            var status = root.GetProperty("status").GetString() ?? "";
            var conclusion = root.TryGetProperty("conclusion", out var c) ? c.GetString() ?? "" : "";
            BuildStatusText.Text = string.IsNullOrEmpty(conclusion) ? status : conclusion;
            await LogAsync($"Build {runId}: {status} {conclusion}".Trim());

            if (status == "completed")
            {
                if (conclusion != "success")
                    throw new InvalidOperationException($"Build {runId} finished with {conclusion}.");
                return;
            }

            await Task.Delay(TimeSpan.FromSeconds(20), token);
        }
    }

    private async Task<(long id, string url)> LatestBuildRunAsync(CancellationToken token)
    {
        var json = new StringBuilder();
        await RunAsync("gh", $"run list --repo {RepoSpecifier} --workflow {Q("Build Docker image")} --limit 1 --json databaseId,url", _settings.LocalRepoPath, line => json.AppendLine(line), token, quiet: true);
        using var doc = JsonDocument.Parse(json.ToString());
        var run = doc.RootElement[0];
        return (run.GetProperty("databaseId").GetInt64(), run.GetProperty("url").GetString() ?? "");
    }

    private async Task DeployModalAsync(CancellationToken token)
    {
        BuildStatusText.Text = "Deploying";
        var env = new Dictionary<string, string> { ["MODAL_GPU"] = _settings.ModalGpu, ["NO_COLOR"] = "1" };
        await RunAsync("modal", "deploy modal_app.py", _settings.LocalRepoPath, LogLine, token, env);
        BuildStatusText.Text = "Deployed";
    }

    private async Task PruneDockerHubTagsAsync(CancellationToken token)
    {
        if (string.IsNullOrWhiteSpace(_settings.DockerUsername) || string.IsNullOrWhiteSpace(_settings.DockerToken))
        {
            await LogAsync("DockerHub pruning skipped: missing username/token.");
            return;
        }

        await LogAsync("Pruning old DockerHub sha tags.");
        var authBody = JsonSerializer.Serialize(new { username = _settings.DockerUsername, password = _settings.DockerToken });
        using var authResp = await _http.PostAsync("https://hub.docker.com/v2/users/login/", new StringContent(authBody, Encoding.UTF8, "application/json"), token);
        authResp.EnsureSuccessStatusCode();
        using var authDoc = JsonDocument.Parse(await authResp.Content.ReadAsStringAsync(token));
        var jwt = authDoc.RootElement.GetProperty("token").GetString();

        using var request = new HttpRequestMessage(HttpMethod.Get, $"https://hub.docker.com/v2/repositories/{_settings.DockerNamespace}/{_settings.DockerRepo}/tags?page_size=100");
        request.Headers.Authorization = new AuthenticationHeaderValue("JWT", jwt);
        using var tagsResp = await _http.SendAsync(request, token);
        tagsResp.EnsureSuccessStatusCode();

        using var tagsDoc = JsonDocument.Parse(await tagsResp.Content.ReadAsStringAsync(token));
        var shaTags = tagsDoc.RootElement.GetProperty("results")
            .EnumerateArray()
            .Select(x => new
            {
                Name = x.GetProperty("name").GetString() ?? "",
                Updated = DateTimeOffset.TryParse(x.GetProperty("last_updated").GetString(), out var dt) ? dt : DateTimeOffset.MinValue
            })
            .Where(x => x.Name.StartsWith("sha-", StringComparison.OrdinalIgnoreCase))
            .OrderByDescending(x => x.Updated)
            .Skip(_settings.KeepDockerTags)
            .ToList();

        foreach (var tag in shaTags)
        {
            using var del = new HttpRequestMessage(HttpMethod.Delete, $"https://hub.docker.com/v2/repositories/{_settings.DockerNamespace}/{_settings.DockerRepo}/tags/{tag.Name}/");
            del.Headers.Authorization = new AuthenticationHeaderValue("JWT", jwt);
            using var delResp = await _http.SendAsync(del, token);
            await LogAsync(delResp.IsSuccessStatusCode ? $"Deleted DockerHub tag {tag.Name}" : $"Could not delete {tag.Name}: {(int)delResp.StatusCode}");
        }
    }

    private async Task RefreshNodesAsync()
    {
        try
        {
            var nodes = await ListModalNodesAsync(CancellationToken.None);
            NodeList.ItemsSource = nodes;
            NodeCountText.Text = nodes.Count.ToString();
            _lastNodeFingerprint = string.Join("|", nodes);
        }
        catch (Exception ex)
        {
            await LogAsync("Could not refresh nodes: " + ex.Message);
        }
    }

    private async Task RefreshBuildHistoryAsync()
    {
        var buffer = new StringBuilder();
        var code = await RunAsync("gh", $"run list --repo {RepoSpecifier} --workflow {Q("Build Docker image")} --limit 8 --json databaseId,status,conclusion,displayTitle,url", _settings.LocalRepoPath, line => buffer.AppendLine(line), CancellationToken.None, quiet: true, allowFailure: true);
        BuildHistoryBox.Text = code == 0 ? PrettyJson(buffer.ToString()) : buffer.ToString();
    }

    private async Task StartLogStreamAsync(TextBox target, string modalArgs)
    {
        _logCts?.Cancel();
        _logCts = new CancellationTokenSource();
        target.Clear();
        SetStatus("Streaming logs");

        try
        {
            await RunAsync("modal", modalArgs, _settings.LocalRepoPath, line => Append(target, line), _logCts.Token, allowFailure: true);
        }
        catch (OperationCanceledException)
        {
            Append(target, "Log stream stopped.");
        }
    }

    private async Task OpenModalUrlAsync(string label, string suffix)
    {
        var workspace = new StringBuilder();
        var script = "$env:PYTHONIOENCODING='utf-8'; $env:PYTHONUTF8='1'; " +
                     "$profiles = modal profile list --json | ConvertFrom-Json; " +
                     "$active = $profiles | Where-Object { $_.active } | Select-Object -First 1; " +
                     "if (-not $active) { throw 'No active Modal profile found.' }; $active.workspace";
        var code = await RunAsync("powershell", $"-NoProfile -ExecutionPolicy Bypass -Command {Q(script)}", _settings.LocalRepoPath, line => workspace.AppendLine(line), CancellationToken.None, quiet: true, allowFailure: true);
        if (code != 0)
        {
            await LogAsync("Could not determine Modal workspace.");
            return;
        }

        var url = $"https://{workspace.ToString().Trim()}--{label}.modal.run{suffix}";
        Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
    }

    private async Task RunGuardedAsync(string status, Func<CancellationToken, Task> action)
    {
        if (_busy)
        {
            await LogAsync("Another operation is already running.");
            return;
        }

        PullSettingsFromUi();
        _busy = true;
        SetStatus(status);
        try
        {
            await action(CancellationToken.None);
            SetStatus("Ready");
        }
        catch (Exception ex)
        {
            SetStatus("Error");
            await LogAsync("ERROR: " + ex.Message);
        }
        finally
        {
            _busy = false;
        }
    }

    private async Task<int> RunAsync(
        string fileName,
        string arguments,
        string workingDirectory,
        Action<string> onLine,
        CancellationToken token,
        IDictionary<string, string>? env = null,
        bool quiet = false,
        bool allowFailure = false)
    {
        if (!quiet)
            await LogAsync($"> {fileName} {arguments}");

        var psi = new ProcessStartInfo(fileName, arguments)
        {
            WorkingDirectory = string.IsNullOrWhiteSpace(workingDirectory) ? Environment.CurrentDirectory : workingDirectory,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };
        psi.Environment["PYTHONIOENCODING"] = "utf-8";
        psi.Environment["PYTHONUTF8"] = "1";
        if (env is not null)
        {
            foreach (var pair in env)
                psi.Environment[pair.Key] = pair.Value;
        }

        using var process = new Process { StartInfo = psi, EnableRaisingEvents = true };
        process.Start();

        var stdout = PumpAsync(process.StandardOutput, onLine, token);
        var stderr = PumpAsync(process.StandardError, onLine, token);

        try
        {
            await process.WaitForExitAsync(token);
        }
        catch (OperationCanceledException)
        {
            if (!process.HasExited)
                process.Kill(entireProcessTree: true);
            throw;
        }
        await Task.WhenAll(stdout, stderr);

        if (process.ExitCode != 0 && !allowFailure)
            throw new InvalidOperationException($"{fileName} exited with code {process.ExitCode}.");

        return process.ExitCode;
    }

    private static async Task PumpAsync(StreamReader reader, Action<string> onLine, CancellationToken token)
    {
        while (!reader.EndOfStream)
        {
            token.ThrowIfCancellationRequested();
            var line = await reader.ReadLineAsync(token);
            if (line is not null)
                onLine(line);
        }
    }

    private static IEnumerable<long> ParseRunningBuildIds(string json)
    {
        using var doc = JsonDocument.Parse(json);
        foreach (var run in doc.RootElement.EnumerateArray())
        {
            var status = run.GetProperty("status").GetString();
            if (status is "queued" or "in_progress" or "waiting" or "pending" or "requested")
                yield return run.GetProperty("databaseId").GetInt64();
        }
    }

    private void UpdateWatcher()
    {
        if (AutoWatchBox.IsChecked == true)
        {
            _watchTimer.Start();
            WatcherText.Text = "On";
        }
        else
        {
            _watchTimer.Stop();
            WatcherText.Text = "Off";
        }
    }

    private void UpdateCards()
    {
        ImageText.Text = $"{_settings.DockerNamespace}/{_settings.DockerRepo}:latest";
    }

    private void SetStatus(string value)
    {
        Dispatcher.Invoke(() => StatusText.Text = value);
    }

    private void LogLine(string line)
    {
        Append(PipelineLogBox, line);
    }

    private Task LogAsync(string line)
    {
        LogLine(line);
        return Task.CompletedTask;
    }

    private void Append(TextBox box, string line)
    {
        Dispatcher.Invoke(() =>
        {
            box.AppendText(line + Environment.NewLine);
            box.ScrollToEnd();
        });
    }

    private string RepoSpecifier => $"{_settings.GitHubOwner}/{_settings.GitHubRepo}";

    private static string Q(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }

    private static string PrettyJson(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            return JsonSerializer.Serialize(doc.RootElement, JsonOptions);
        }
        catch
        {
            return json;
        }
    }

    private static string FindRepoRoot()
    {
        var dir = new DirectoryInfo(Environment.CurrentDirectory);
        while (dir is not null)
        {
            if (File.Exists(Path.Combine(dir.FullName, "Dockerfile")) && Directory.Exists(Path.Combine(dir.FullName, ".git")))
                return dir.FullName;
            dir = dir.Parent;
        }

        return Environment.CurrentDirectory;
    }

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };
}

public sealed class PipelineSettings
{
    public string GitHubOwner { get; set; } = "AnqiPudding";
    public string GitHubRepo { get; set; } = "container";
    public string LocalRepoPath { get; set; } = "";
    public string DockerUsername { get; set; } = "";
    public string DockerToken { get; set; } = "";
    public string DockerNamespace { get; set; } = "anqipudding";
    public string DockerRepo { get; set; } = "modal_comfyui";
    public string ModalAppName { get; set; } = "modal-comfyui";
    public string ModalVolumeName { get; set; } = "modal-comfyui-data";
    public string ModalGpu { get; set; } = "L40S";
    public bool AutoWatch { get; set; }
    public bool PruneDockerTags { get; set; }
    public int KeepDockerTags { get; set; } = 3;

    public static PipelineSettings Load()
    {
        try
        {
            if (File.Exists(SettingsPath))
            {
                var loaded = JsonSerializer.Deserialize<PipelineSettings>(File.ReadAllText(SettingsPath));
                if (loaded is not null)
                    return loaded;
            }
        }
        catch
        {
            // Corrupt settings should not stop the control app from opening.
        }

        return new PipelineSettings();
    }

    public void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(SettingsPath)!);
        File.WriteAllText(SettingsPath, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
    }

    private static string SettingsPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ComfyDeployControl", "settings.json");
}
