using System.IO;
using System.Windows;
using System.Windows.Threading;

namespace ComfyDeployControl;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        DispatcherUnhandledException += OnDispatcherUnhandledException;
        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
            WriteCrashLog(args.ExceptionObject as Exception ?? new Exception(args.ExceptionObject?.ToString()));
        TaskScheduler.UnobservedTaskException += (_, args) =>
        {
            WriteCrashLog(args.Exception);
            args.SetObserved();
        };
    }

    private static void OnDispatcherUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        WriteCrashLog(e.Exception);
        MessageBox.Show(
            "Comfy Deploy Control hit an error, but it was captured instead of closing.\n\n" +
            e.Exception.Message + "\n\nDetails were written to:\n" + CrashLogPath,
            "Comfy Deploy Control",
            MessageBoxButton.OK,
            MessageBoxImage.Warning);
        e.Handled = true;
    }

    public static void WriteCrashLog(Exception? exception)
    {
        if (exception is null)
            return;

        Directory.CreateDirectory(Path.GetDirectoryName(CrashLogPath)!);
        File.AppendAllText(CrashLogPath, $"[{DateTimeOffset.Now:O}]\n{exception}\n\n");
    }

    public static string CrashLogPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ComfyDeployControl", "crash.log");
}
