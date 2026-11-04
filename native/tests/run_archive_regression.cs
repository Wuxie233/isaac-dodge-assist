using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;

// Run archive tests for NativeHost: every log.txt line lands exactly once in
// a per-run (or per-launch) gzip file, runs continue across launches by seed,
// and a restarted Host never stores a line twice. Run on Linux with
// native/tests/run_archive_regression.sh (needs dotnet and gzip).
internal static class RunArchiveRegression
{
    static string root, logPath;
    static DateTime time = new DateTime(2026, 11, 4, 20, 0, 0);
    static readonly List<string> written = new List<string>();

    static void Check(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
    }
    static DateTime Now() { return time; }
    static void Append(params string[] lines)
    {
        using (var s = new FileStream(logPath, FileMode.Append, FileAccess.Write, FileShare.ReadWrite))
            foreach (string line in lines)
            {
                byte[] b = Encoding.UTF8.GetBytes(line + "\r\n");
                s.Write(b, 0, b.Length);
                written.Add(line);
            }
    }
    static void Restart(params string[] lines)
    {
        // A new game launch rewrites log.txt from scratch.
        File.WriteAllText(logPath, "");
        Append(lines);
    }
    static string Lua(string text) { return "[INFO] - Lua Debug: " + text; }
    static void Drain(RunArchive a)
    {
        for (int i = 0; i < 64; i++) a.Poll(logPath);
        Check(a.Status == null || !a.Status.StartsWith("存档失败"), "archive failed: " + a.Status);
    }
    static string[] Gunzip(string path)
    {
        var info = new ProcessStartInfo("gzip", "-dc \"" + path + "\"");
        info.RedirectStandardOutput = true;
        info.UseShellExecute = false;
        using (var p = Process.Start(info))
        {
            string text = p.StandardOutput.ReadToEnd();
            p.WaitForExit();
            Check(p.ExitCode == 0, "gzip -dc failed on " + path);
            var lines = new List<string>(text.Split(new[] { "\r\n" }, StringSplitOptions.None));
            if (lines.Count > 0 && lines[lines.Count - 1] == "") lines.RemoveAt(lines.Count - 1);
            return lines.ToArray();
        }
    }
    static string[] Files(string sub, string pattern)
    {
        string dir = Path.Combine(root, sub);
        if (!Directory.Exists(dir)) return new string[0];
        string[] files = Directory.GetFiles(dir, pattern);
        Array.Sort(files, StringComparer.Ordinal);
        return files;
    }
    // Stored lines of a run: its gzip members plus the live .part, if any.
    static string[] Run(string seed)
    {
        foreach (string f in Files("runs", "*_" + seed + "*.log.gz"))
        {
            var lines = new List<string>(Gunzip(f));
            if (File.Exists(f + ".part"))
                foreach (string l in File.ReadAllText(f + ".part").Split(new[] { "\r\n" }, StringSplitOptions.RemoveEmptyEntries)) lines.Add(l);
            return lines.ToArray();
        }
        throw new Exception("no run file for " + seed);
    }
    static Dictionary<string, string[]> Index()
    {
        var rows = new Dictionary<string, string[]>();
        string[] lines = File.ReadAllLines(Path.Combine(root, "runs", "index.tsv"));
        Check(lines[0].StartsWith("file\tseed\tstarted\tstatus\treason"), "index header");
        for (int i = 1; i < lines.Length; i++)
        {
            string[] f = lines[i].Split('\t');
            rows[f[1] + "#" + f[0]] = f;
        }
        return rows;
    }
    static string[] Row(string seed)
    {
        string[] found = null;
        foreach (var kv in Index()) if (kv.Value[1] == seed) { Check(found == null, "one index row per run " + seed); found = kv.Value; }
        Check(found != null, "index row for " + seed);
        return found;
    }
    static bool Contains(string[] lines, string text)
    {
        foreach (string l in lines) if (l.Contains(text)) return true;
        return false;
    }
    static int Count(string[] lines, string text)
    {
        int n = 0;
        foreach (string l in lines) if (l == text) n++;
        return n;
    }

    public static int Main()
    {
        string top = Path.Combine(Path.GetTempPath(), "iad-archive-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(top);
        logPath = Path.Combine(top, "log.txt");
        string logs = Path.Combine(top, "Logs");
        root = logs;
        try
        {
            // Host starts late: the menu and the first run are already logged.
            Restart("[INFO] - Loading mods", Lua("IAD: sensor 0.17.0 loaded"));
            Append(Lua("IAD RUN begin continued=false player=7 seed=AAAA1111"), Lua("IAD HIT: one"));
            var a = new RunArchive(logs, "launch-1", Now);
            Drain(a);
            // A partial line stays out until its newline arrives.
            using (var s = new FileStream(logPath, FileMode.Append, FileAccess.Write, FileShare.ReadWrite))
            { byte[] b = Encoding.UTF8.GetBytes(Lua("IAD HIT: tw")); s.Write(b, 0, b.Length); }
            Drain(a);
            using (var s = new FileStream(logPath, FileMode.Append, FileAccess.Write, FileShare.ReadWrite))
            { byte[] b = Encoding.UTF8.GetBytes("o\r\n"); s.Write(b, 0, b.Length); }
            written.Add(Lua("IAD HIT: two"));
            Drain(a);
            Append(Lua("IAD RUN pause"), "[INFO] - Menu again");
            Drain(a);
            string[] run = Run("AAAA1111");
            Check(run.Length == 4 && run[0].Contains("IAD RUN begin") && run[2] == Lua("IAD HIT: two") && run[3].Contains("IAD RUN pause"),
                "run file holds begin..pause with the split line intact");
            Check(Row("AAAA1111")[3] == "paused", "pause marks the run paused");
            Check(Files("runs", "*.part").Length == 0, "paused run leaves no .part");

            // Continue the same run in the same launch: a second gzip member.
            time = time.AddMinutes(5);
            Append(Lua("IAD RUN begin continued=true player=7 seed=AAAA1111"), Lua("IAD HIT: three"));
            Drain(a);
            // A new run while one is open abandons the open one.
            Append(Lua("IAD RUN begin continued=false player=3 seed=BBBB2222"), Lua("IAD HIT: b1"));
            Drain(a);
            Check(Row("AAAA1111")[3] == "ended" && Row("AAAA1111")[4] == "abandoned", "new run abandons the open run");
            run = Run("AAAA1111");
            Check(run.Length == 6 && run[5] == Lua("IAD HIT: three"), "continued run appended as a new member");
            Check(Files("runs", "*AAAA1111*").Length == 1, "continuation reuses the run file");

            // Host restarts inside the same launch: nothing is stored twice.
            a.Close();
            a = new RunArchive(logs, "launch-1", Now);
            Append(Lua("IAD HIT: b2"));
            Drain(a);
            Append(Lua("IAD RUN end reason=death"), Lua("IAD RUN pause"), "[INFO] - back to menu");
            Drain(a);
            run = Run("BBBB2222");
            Check(run.Length == 4 && Count(run, Lua("IAD HIT: b1")) == 1 && run[2] == Lua("IAD HIT: b2") && run[3].Contains("reason=death"),
                "Host restart continues the run without duplicates");
            Check(Row("BBBB2222")[3] == "ended" && Row("BBBB2222")[4] == "death", "end records its reason");

            // Start a third run, then the game crashes: Host exits without
            // Close, and the next launch rewrites log.txt.
            Append(Lua("IAD RUN begin continued=false player=1 seed=CCCC3333"), Lua("IAD HIT: c1"));
            Drain(a);
            Check(Files("runs", "*.part").Length == 1, "live run is kept as an uncompressed .part");
            time = time.AddHours(1);
            Restart("[INFO] - Loading mods", Lua("IAD RUN begin continued=true player=1 seed=CCCC3333"), Lua("IAD HIT: c2"));
            a = new RunArchive(logs, "launch-2", Now);
            Drain(a);
            run = Run("CCCC3333");
            Check(run.Length == 4 && run[1] == Lua("IAD HIT: c1") && run[3] == Lua("IAD HIT: c2"),
                "crashed .part recovered and the run continued across launches");
            Check(Row("CCCC3333")[3] == "open", "continued run is open again");

            // Continue with no matching run: a new file noted as continued.
            Append(Lua("IAD RUN pause"), Lua("IAD RUN begin continued=true player=1 seed=DDDD4444"), Lua("IAD HIT: d1"));
            Drain(a);
            Check(Row("DDDD4444")[5] == "continued", "unmatched continue is noted");

            // log.txt rewritten while the same Host keeps running (new launch).
            time = time.AddHours(1);
            Restart("[INFO] - Loading mods again");
            Drain(a);
            Check(Row("DDDD4444")[3] == "paused", "run left open by a new launch is paused");

            // Catch-up larger than one poll's byte budget keeps every line.
            var bulk = new string[40000];
            for (int i = 0; i < bulk.Length; i++) bulk[i] = Lua("IAD1|" + i + "|0|1|0|0|0,0,0,0,0,0,0,0,0|0");
            Append(Lua("IAD RUN begin continued=false player=0 seed=EEEE5555"));
            Append(bulk);
            Drain(a);
            a.Close();
            Check(Run("EEEE5555").Length == bulk.Length + 1, "bulk catch-up kept every line");
            Check(Files("runs", "*.part").Length == 0 && Files("launches", "*.part").Length == 0, "Close compresses every .part");

            // An index that cannot be rewritten (here: its temp path is
            // taken) is retried later; the lines are not stored twice.
            a = new RunArchive(logs, "launch-2", Now);
            string blocker = Path.Combine(logs, "runs", "index.tsv.tmp");
            Directory.CreateDirectory(blocker);
            Append(Lua("IAD RUN begin continued=false player=0 seed=FFFF6666"), Lua("IAD HIT: f1"));
            Drain(a);
            Check(a.Status != null && a.Status.StartsWith("索引稍后重写"), "locked index not reported: " + a.Status);
            Directory.Delete(blocker);
            Append(Lua("IAD HIT: f2"), Lua("IAD RUN pause"));
            Drain(a);
            run = Run("FFFF6666");
            Check(run.Length == 4 && Count(run, Lua("IAD HIT: f1")) == 1 && run[2] == Lua("IAD HIT: f2"), "locked index duplicated lines");
            Check(Row("FFFF6666")[3] == "paused", "index caught up after the lock");
            // A run abandoned by a crash and a new run can still be continued.
            Append(Lua("IAD RUN begin continued=false player=0 seed=GGGG7777"), Lua("IAD HIT: g1"),
                Lua("IAD RUN begin continued=false player=0 seed=HHHH8888"), Lua("IAD RUN pause"),
                Lua("IAD RUN begin continued=true player=0 seed=GGGG7777"), Lua("IAD HIT: g2"), Lua("IAD RUN pause"));
            Drain(a);
            run = Run("GGGG7777");
            Check(Files("runs", "*GGGG7777*").Length == 1 && run[1] == Lua("IAD HIT: g1") && run[run.Length - 2] == Lua("IAD HIT: g2"),
                "abandoned run not continued");
            a.Close();

            // Every line written to log.txt is stored exactly once overall.
            var stored = new Dictionary<string, int>();
            foreach (string sub in new[] { "runs", "launches" })
                foreach (string f in Files(sub, "*.log.gz"))
                    foreach (string l in Gunzip(f)) { int n; stored.TryGetValue(l, out n); stored[l] = n + 1; }
            var expected = new Dictionary<string, int>();
            foreach (string l in written) { int n; expected.TryGetValue(l, out n); expected[l] = n + 1; }
            foreach (var kv in expected)
            {
                int n; stored.TryGetValue(kv.Key, out n);
                Check(n == kv.Value, "line stored " + n + "x, written " + kv.Value + "x: " + kv.Key);
            }
            foreach (var kv in stored) Check(expected.ContainsKey(kv.Key), "line stored but never written: " + kv.Key);
            Check(Files("launches", "*.log.gz").Length == 3, "one launch file per launch");
            Console.WriteLine("PASS run archive: late start, split lines, pause/continue members, abandon, Host restart, crash recovery, new launch, catch-up, locked index, abandoned continue, exactly-once");
            return 0;
        }
        finally
        {
            try { Directory.Delete(top, true); } catch (Exception) { }
        }
    }
}
