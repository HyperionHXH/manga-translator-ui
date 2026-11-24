// Manga Studio Windows launcher.
//
// This is a deliberately thin GUI-subsystem launcher. It owns no UI and no
// long-lived service of its own: it resolves the bundled runtime, starts one
// pythonw.exe child for desktop_qt_ui\main.py, waits for that child, and exits
// with the child's exit code. The lifecycle contract intentionally matches the
// original Win-Start.bat flow:
//   * working directory is the distribution root (the EXE's folder);
//   * PYTHONUTF8=1 is set and PortableGit\cmd is prepended to PATH when present;
//   * exactly one foreground application process is started;
//   * a named mutex scoped to this distribution root prevents a second instance
//     from sharing the same config/result tree;
//   * no Job Object, restart loop, or detached daemon is added;
//   * the application keeps ownership of its config writes and shutdown.
//
// The launcher adds two things: the single-instance guard described above, and
// diagnostics that capture stdout/stderr so a pythonw startup failure is
// visible instead of silent. A message box reports a non-zero exit or an
// uncaught Python startup traceback.
//
// C# 5 / .NET Framework 4.x only. Build with the Windows Framework csc.exe;
// no WinForms, no NuGet packages, no external Python.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

namespace MangaStudio.Windows
{
    internal static class Launcher
    {
        private const string ProductName = "Manga Studio";
        private const int BadArgumentsExitCode = 2;

        private const uint MB_SETFOREGROUND = 0x00010000;
        private const uint MB_TOPMOST = 0x00040000;

        private static readonly object OutputGate = new object();
        private static readonly StringBuilder RecentOutput = new StringBuilder();
        private static StreamWriter _log;
        private static string _logPath = string.Empty;
        private static bool _sawFatalText;
        private static Mutex _instanceMutex;

        private enum MessageIcon : uint
        {
            Error = 0x00000010,
            Information = 0x00000040
        }

        [DllImport("user32.dll", EntryPoint = "MessageBoxW", CharSet = CharSet.Unicode, ExactSpelling = true)]
        private static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);

        [STAThread]
        private static int Main(string[] args)
        {
            try
            {
                return Run(args);
            }
            catch (Exception ex)
            {
                WriteLog("launcher", "fatal launcher error: " + ex);
                FlushLog();
                ShowMessage(
                    ProductName + " could not start",
                    ProductName + " could not start its bundled runtime." +
                    Environment.NewLine + Environment.NewLine +
                    ex.Message +
                    Environment.NewLine + Environment.NewLine +
                    "Launcher log: " + DisplayLogPath(),
                    MessageIcon.Error);
                return 1;
            }
        }

        private static int Run(string[] args)
        {
            List<string> forwarded = new List<string>();

            for (int i = 0; i < args.Length; i++)
            {
                string argument = args[i];

                if (argument == "--studio-help" || argument == "-?" || argument == "/?")
                {
                    ShowMessage(ProductName + " launcher", UsageText(), MessageIcon.Information);
                    return 0;
                }

                if (argument == "--studio-version")
                {
                    ShowVersion();
                    return 0;
                }

                if (argument.StartsWith("--studio-", StringComparison.OrdinalIgnoreCase))
                {
                    ShowMessage(
                        ProductName + " launcher",
                        "Unknown launcher option: " + argument +
                        Environment.NewLine + Environment.NewLine + UsageText(),
                        MessageIcon.Error);
                    return BadArgumentsExitCode;
                }

                if (IsMaintenanceOption(argument))
                {
                    ShowMessage(
                        ProductName + " launcher",
                        "The maintenance option " + argument + " is not valid for the desktop launcher." +
                        Environment.NewLine + Environment.NewLine +
                        "Start the desktop application normally. Maintenance is a separate console workflow.",
                        MessageIcon.Error);
                    return BadArgumentsExitCode;
                }

                if (argument.IndexOf('\0') >= 0 || argument.IndexOf('\r') >= 0 || argument.IndexOf('\n') >= 0)
                {
                    ShowMessage(
                        ProductName + " launcher",
                        "Arguments containing NUL, carriage return, or newline characters are not supported.",
                        MessageIcon.Error);
                    return BadArgumentsExitCode;
                }

                if (IsReservedApplicationArgument(argument))
                {
                    forwarded.Add(argument);
                    continue;
                }

                ShowMessage(
                    ProductName + " launcher",
                    "This build does not accept file paths or arbitrary command-line arguments." +
                    Environment.NewLine + Environment.NewLine +
                    "Launch MangaStudio.exe without arguments." +
                    Environment.NewLine +
                    "Use --studio-help for launcher options or --studio-version for version information.",
                    MessageIcon.Error);
                return BadArgumentsExitCode;
            }

            if (IntPtr.Size != 8)
            {
                ShowMessage(
                    ProductName + " cannot start",
                    "This distribution requires 64-bit Windows." + Environment.NewLine + Environment.NewLine +
                    "The bundled Python runtime is x64 and cannot run inside a 32-bit launcher process.",
                    MessageIcon.Error);
                return 1;
            }

            string root = ResolveApplicationRoot();
            OpenLog(root);
            WriteLog("launcher", ProductName + " launcher");
            WriteLog("launcher", "root=" + root);
            WriteLog("launcher", "os=" + Environment.OSVersion.VersionString + " (x64=" + Environment.Is64BitOperatingSystem.ToString() + ")");
            WriteLog("launcher", "launcher version=" + LauncherVersion());

            bool alreadyRunning;
            _instanceMutex = TryAcquireSingleInstance(root, out alreadyRunning);
            if (alreadyRunning)
            {
                WriteLog("launcher", "another instance already owns this distribution");
                ShowMessage(
                    ProductName + " is already running",
                    ProductName + " is already running from this folder." +
                    Environment.NewLine + Environment.NewLine +
                    "Only one instance can use this distribution's config and result files." +
                    Environment.NewLine +
                    "Close the running application, then start MangaStudio.exe again.",
                    MessageIcon.Information);
                return 0;
            }
            if (_instanceMutex == null)
            {
                WriteLog("launcher", "single-instance mutex was unavailable; continuing without the guard");
            }

            string pythonw = Path.Combine(root, "packaging", "python", "pythonw.exe");
            string python = Path.Combine(root, "packaging", "python", "python.exe");
            string mainPy = Path.Combine(root, "desktop_qt_ui", "main.py");

            if (!File.Exists(pythonw))
            {
                return FailMissingRuntime(
                    "The bundled Python launcher is missing:" + Environment.NewLine + pythonw,
                    root);
            }

            if (!File.Exists(python))
            {
                return FailMissingRuntime(
                    "The bundled Python runtime is incomplete (python.exe is missing):" + Environment.NewLine + python,
                    root);
            }

            if (!File.Exists(mainPy))
            {
                return FailMissingRuntime(
                    "The desktop entry point is missing:" + Environment.NewLine + mainPy,
                    root);
            }

            string commandLine;
            try
            {
                commandLine = BuildCommandLine(mainPy, forwarded);
            }
            catch (ArgumentException ex)
            {
                ShowMessage(ProductName + " launcher", ex.Message, MessageIcon.Error);
                return BadArgumentsExitCode;
            }

            ProcessStartInfo startInfo = new ProcessStartInfo();
            startInfo.FileName = pythonw;
            startInfo.Arguments = commandLine;
            startInfo.WorkingDirectory = root;
            startInfo.UseShellExecute = false;
            startInfo.CreateNoWindow = true;
            startInfo.RedirectStandardOutput = true;
            startInfo.RedirectStandardError = true;
            startInfo.StandardOutputEncoding = new UTF8Encoding(false);
            startInfo.StandardErrorEncoding = new UTF8Encoding(false);
            startInfo.EnvironmentVariables["PYTHONUTF8"] = "1";
            startInfo.EnvironmentVariables["PYTHONIOENCODING"] = "utf-8";
            startInfo.EnvironmentVariables["PYTHONUNBUFFERED"] = "1";

            string portableGitDir = Path.Combine(root, "PortableGit", "cmd");
            if (File.Exists(Path.Combine(portableGitDir, "git.exe")))
            {
                string currentPath = startInfo.EnvironmentVariables["PATH"];
                if (currentPath == null)
                {
                    currentPath = string.Empty;
                }
                startInfo.EnvironmentVariables["PATH"] = portableGitDir + ";" + currentPath;
                WriteLog("launcher", "portable git=" + Path.Combine(portableGitDir, "git.exe"));
            }

            WriteLog("launcher", "pythonw=" + pythonw);
            WriteLog("launcher", "entrypoint=" + mainPy);
            WriteLog("launcher", "command line=" + commandLine);

            int exitCode;
            using (Process process = new Process())
            {
                process.StartInfo = startInfo;
                process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs eventArgs)
                {
                    if (eventArgs.Data != null)
                    {
                        WriteLog("stdout", eventArgs.Data);
                    }
                };
                process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs eventArgs)
                {
                    if (eventArgs.Data != null)
                    {
                        WriteLog("stderr", eventArgs.Data);
                    }
                };

                try
                {
                    if (!process.Start())
                    {
                        throw new InvalidOperationException("Process.Start returned false.");
                    }
                }
                catch (Exception ex)
                {
                    WriteLog("launcher", "could not start pythonw: " + ex);
                    FlushLog();
                    ShowMessage(
                        ProductName + " could not start",
                        "Windows could not start the bundled Python runtime." +
                        Environment.NewLine + Environment.NewLine +
                        "Runtime: " + pythonw +
                        Environment.NewLine +
                        "Error: " + ex.Message +
                        Environment.NewLine + Environment.NewLine +
                        "Launcher log: " + DisplayLogPath(),
                        MessageIcon.Error);
                    return 1;
                }

                process.BeginOutputReadLine();
                process.BeginErrorReadLine();
                WriteLog("launcher", "started pid=" + process.Id.ToString(CultureInfo.InvariantCulture));

                process.WaitForExit();
                exitCode = process.ExitCode;
            }

            bool sawFatalText;
            lock (OutputGate)
            {
                sawFatalText = _sawFatalText;
            }

            WriteLog("launcher", "exit code=" + exitCode.ToString(CultureInfo.InvariantCulture) + " (" + FormatExitCode(exitCode) + ")");
            FlushLog();

            if (exitCode != 0 || sawFatalText)
            {
                ShowMessage(
                    ProductName + " exited with an error",
                    BuildFailureMessage(exitCode),
                    MessageIcon.Error);
            }

            return exitCode;
        }

        private static bool IsReservedApplicationArgument(string argument)
        {
            // No desktop application flags are reserved in this build. Add exact,
            // documented switches here when the desktop application gains them.
            // File paths, secrets, and free-form arguments are never forwarded
            // by default.
            return false;
        }

        private static Mutex TryAcquireSingleInstance(string root, out bool alreadyRunning)
        {
            alreadyRunning = false;
            try
            {
                string name = "Local\\MangaStudio.Desktop." + DistributionIdentity(root);
                bool createdNew;
                Mutex mutex = new Mutex(true, name, out createdNew);
                if (!createdNew)
                {
                    mutex.Dispose();
                    alreadyRunning = true;
                    return null;
                }
                WriteLog("launcher", "single-instance mutex=" + name);
                return mutex;
            }
            catch (Exception ex)
            {
                WriteLog("launcher", "could not create single-instance mutex: " + ex.Message);
                return null;
            }
        }

        private static string DistributionIdentity(string root)
        {
            string normalized = Path.GetFullPath(root)
                .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
                .ToLowerInvariant();
            using (SHA256 sha256 = SHA256.Create())
            {
                byte[] hash = sha256.ComputeHash(Encoding.UTF8.GetBytes(normalized));
                StringBuilder identity = new StringBuilder(16);
                for (int i = 0; i < 8; i++)
                {
                    identity.Append(hash[i].ToString("x2", CultureInfo.InvariantCulture));
                }
                return identity.ToString();
            }
        }

        private static bool IsMaintenanceOption(string argument)
        {
            return string.Equals(argument, "--maintenance", StringComparison.OrdinalIgnoreCase)
                || string.Equals(argument, "--auto-update", StringComparison.OrdinalIgnoreCase)
                || string.Equals(argument, "--resume-install", StringComparison.OrdinalIgnoreCase)
                || string.Equals(argument, "--resume-update", StringComparison.OrdinalIgnoreCase);
        }

        private static int FailMissingRuntime(string detail, string root)
        {
            WriteLog("launcher", detail);
            FlushLog();
            ShowMessage(
                ProductName + " cannot start",
                "The distribution is incomplete." +
                Environment.NewLine + Environment.NewLine +
                detail +
                Environment.NewLine + Environment.NewLine +
                "Expected layout: MangaStudio.exe next to desktop_qt_ui\\ and packaging\\python\\." +
                Environment.NewLine +
                "Re-extract the complete archive. Do not move MangaStudio.exe out of its folder." +
                Environment.NewLine + Environment.NewLine +
                "Distribution root: " + root +
                Environment.NewLine +
                "Launcher log: " + DisplayLogPath(),
                MessageIcon.Error);
            return 1;
        }

        private static string ResolveApplicationRoot()
        {
            string executable = Assembly.GetExecutingAssembly().Location;
            if (string.IsNullOrEmpty(executable))
            {
                executable = Process.GetCurrentProcess().MainModule.FileName;
            }

            string directory = Path.GetDirectoryName(Path.GetFullPath(executable));
            if (string.IsNullOrEmpty(directory))
            {
                throw new InvalidOperationException("Cannot resolve the launcher directory.");
            }

            return directory;
        }

        private static void OpenLog(string root)
        {
            string fileName = "launcher_" +
                DateTime.Now.ToString("yyyyMMdd_HHmmss", CultureInfo.InvariantCulture) +
                "_" + Process.GetCurrentProcess().Id.ToString(CultureInfo.InvariantCulture) +
                ".log";
            string resultDirectory = Path.Combine(root, "result");
            string candidate = Path.Combine(resultDirectory, fileName);

            try
            {
                Directory.CreateDirectory(resultDirectory);
                FileStream stream = new FileStream(candidate, FileMode.CreateNew, FileAccess.Write, FileShare.Read);
                _log = new StreamWriter(stream, new UTF8Encoding(false));
                _log.AutoFlush = true;
                _logPath = candidate;
            }
            catch
            {
                try
                {
                    string fallback = Path.Combine(Path.GetTempPath(), "MangaStudio-launcher.log");
                    FileStream stream = new FileStream(fallback, FileMode.Create, FileAccess.Write, FileShare.Read);
                    _log = new StreamWriter(stream, new UTF8Encoding(false));
                    _log.AutoFlush = true;
                    _logPath = fallback;
                }
                catch
                {
                    _log = null;
                    _logPath = candidate;
                }
            }
        }

        private static void WriteLog(string channel, string message)
        {
            lock (OutputGate)
            {
                if (_log != null)
                {
                    try
                    {
                        _log.WriteLine(
                            DateTime.Now.ToString("HH:mm:ss.fff", CultureInfo.InvariantCulture) +
                            " [" + channel + "] " + message);
                    }
                    catch
                    {
                        // Diagnostics must never interfere with the application.
                    }
                }

                if (RecentOutput.Length > 0)
                {
                    RecentOutput.Append('\n');
                }
                RecentOutput.Append(message);
                if (RecentOutput.Length > 24000)
                {
                    RecentOutput.Remove(0, RecentOutput.Length - 24000);
                }

                if (message.IndexOf("Traceback (most recent call last)", StringComparison.Ordinal) >= 0 ||
                    message.IndexOf("Fatal Python error", StringComparison.Ordinal) >= 0 ||
                    message.IndexOf("Could not find the Qt platform plugin", StringComparison.Ordinal) >= 0 ||
                    message.IndexOf("no Qt platform plugin could be initialized", StringComparison.Ordinal) >= 0)
                {
                    _sawFatalText = true;
                }
            }
        }

        private static void FlushLog()
        {
            lock (OutputGate)
            {
                if (_log != null)
                {
                    try
                    {
                        _log.Flush();
                    }
                    catch
                    {
                    }
                }
            }
        }

        private static string DisplayLogPath()
        {
            if (string.IsNullOrEmpty(_logPath))
            {
                return "(launcher log unavailable)";
            }
            if (_log == null)
            {
                return _logPath + " (could not be created)";
            }
            return _logPath;
        }

        private static string BuildFailureMessage(int exitCode)
        {
            StringBuilder message = new StringBuilder();
            message.AppendLine(ProductName + " exited with an error.");
            message.AppendLine();
            message.AppendLine("Exit code: " + exitCode.ToString(CultureInfo.InvariantCulture) +
                " (" + FormatExitCode(exitCode) + ")");
            message.AppendLine("Launcher log: " + DisplayLogPath());
            message.AppendLine();
            message.AppendLine("Recent output:");
            message.AppendLine(RecentOutputTail(3500));
            message.AppendLine();
            message.AppendLine("If this happened during startup, read the launcher log and the newest result\\log_*.txt file.");
            message.AppendLine("If files are missing, re-extract the complete distribution archive.");
            return message.ToString();
        }

        private static string RecentOutputTail(int maximumCharacters)
        {
            lock (OutputGate)
            {
                if (RecentOutput.Length == 0)
                {
                    return "(no output was captured)";
                }
                if (RecentOutput.Length <= maximumCharacters)
                {
                    return RecentOutput.ToString();
                }
                return "..." + RecentOutput.ToString(RecentOutput.Length - maximumCharacters, maximumCharacters);
            }
        }

        private static string FormatExitCode(int exitCode)
        {
            uint unsigned = unchecked((uint)exitCode);
            return "0x" + unsigned.ToString("X8", CultureInfo.InvariantCulture);
        }

        private static string LauncherVersion()
        {
            Version version = Assembly.GetExecutingAssembly().GetName().Version;
            return version == null ? "unknown" : version.ToString();
        }

        private static string ApplicationVersion(string root)
        {
            try
            {
                string path = Path.Combine(root, "packaging", "VERSION");
                if (File.Exists(path))
                {
                    string version = File.ReadAllText(path).Trim();
                    if (version.Length > 0)
                    {
                        return version;
                    }
                }
            }
            catch
            {
            }
            return "unknown";
        }

        private static void ShowVersion()
        {
            string root = ResolveApplicationRoot();
            ShowMessage(
                ProductName + " launcher",
                ProductName + " " + ApplicationVersion(root) + Environment.NewLine +
                "Launcher " + LauncherVersion() + Environment.NewLine +
                "Runtime: " + Path.Combine(root, "packaging", "python", "pythonw.exe") + Environment.NewLine +
                "Entry point: " + Path.Combine(root, "desktop_qt_ui", "main.py"),
                MessageIcon.Information);
        }

        private static string UsageText()
        {
            return
                "Usage:" + Environment.NewLine +
                "  MangaStudio.exe" + Environment.NewLine +
                "  MangaStudio.exe --studio-help" + Environment.NewLine +
                "  MangaStudio.exe --studio-version" + Environment.NewLine +
                Environment.NewLine +
                "The launcher starts desktop_qt_ui\\main.py with the bundled" + Environment.NewLine +
                "packaging\\python\\pythonw.exe. No system Python or .bat file is used." + Environment.NewLine +
                Environment.NewLine +
                "This build accepts no file paths or arbitrary application arguments." + Environment.NewLine +
                "Only reserved launcher flags are accepted; maintenance/installer switches" + Environment.NewLine +
                "are rejected. One instance can run from a distribution folder at a time." + Environment.NewLine +
                "Do not move MangaStudio.exe out of its distribution folder.";
        }

        // Quotes one argument using the same backslash/quote rules as the
        // Windows CRT and Python's subprocess.list2cmdline. Every argument is
        // passed to CreateProcess as data, never through cmd.exe.
        private static string QuoteArgument(string argument)
        {
            if (argument == null)
            {
                throw new ArgumentNullException("argument");
            }

            bool needsQuotes = argument.Length == 0;
            if (!needsQuotes)
            {
                for (int i = 0; i < argument.Length; i++)
                {
                    char c = argument[i];
                    if (c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '"')
                    {
                        needsQuotes = true;
                        break;
                    }
                }
            }

            if (!needsQuotes)
            {
                return argument;
            }

            StringBuilder quoted = new StringBuilder(argument.Length + 8);
            quoted.Append('"');
            int backslashes = 0;
            for (int i = 0; i < argument.Length; i++)
            {
                char c = argument[i];
                if (c == '\\')
                {
                    backslashes++;
                    continue;
                }
                if (c == '"')
                {
                    quoted.Append('\\', (backslashes * 2) + 1);
                    quoted.Append('"');
                    backslashes = 0;
                    continue;
                }
                if (backslashes > 0)
                {
                    quoted.Append('\\', backslashes);
                    backslashes = 0;
                }
                quoted.Append(c);
            }
            if (backslashes > 0)
            {
                quoted.Append('\\', backslashes * 2);
            }
            quoted.Append('"');
            return quoted.ToString();
        }

        private static string BuildCommandLine(string mainPy, List<string> arguments)
        {
            StringBuilder commandLine = new StringBuilder();
            commandLine.Append(QuoteArgument(mainPy));
            for (int i = 0; i < arguments.Count; i++)
            {
                commandLine.Append(' ');
                commandLine.Append(QuoteArgument(arguments[i]));
            }

            if (commandLine.Length > 30000)
            {
                throw new ArgumentException("The command line is too long (Windows limit is 32767 characters).");
            }

            return commandLine.ToString();
        }

        private static void ShowMessage(string caption, string text, MessageIcon icon)
        {
            uint flags = (uint)icon | MB_SETFOREGROUND | MB_TOPMOST;
            MessageBoxW(IntPtr.Zero, LimitMessage(text), caption, flags);
        }

        private static string LimitMessage(string text)
        {
            const int maximum = 60000;
            if (text == null)
            {
                return string.Empty;
            }
            if (text.Length <= maximum)
            {
                return text;
            }
            return text.Substring(0, maximum) + Environment.NewLine + "(message truncated)";
        }
    }
}
