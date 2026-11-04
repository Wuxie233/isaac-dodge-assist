using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Text;

// Keeps every line of the game's log.txt, which Isaac rewrites on each
// launch. Lines go to one gzip file per run (runs\<start>_<seed>.log.gz), or
// to the launch file (launches\<start>.log.gz) outside a run. The sensor marks
// runs with "IAD RUN begin|pause|end" lines. A live segment is an
// uncompressed .part, appended as one gzip member when it closes, so a crash
// loses nothing and `gzip -dc` reads all members back in order. Archive state
// (launch, offset, current run) survives a Host restart, so no line is stored
// twice. Independent of the live IAD1 reader, which may skip backlog.
internal sealed class RunArchive
{
    public const int MaxBytesPerPoll = 1 << 20;
    const string Header = "file\tseed\tstarted\tstatus\treason\tnote";
    readonly string runs, launches, statePath, indexPath;
    readonly string launchId;
    readonly Func<DateTime> now;
    readonly List<string[]> index = new List<string[]>();
    long offset;
    string run, launchFile;
    readonly byte[] buffer = new byte[MaxBytesPerPoll];
    // Nothing is written until the state loaded; a failed start is retried.
    bool ready;
    // index.tsv is rewritten after the lines are stored, never in between:
    // a locked index (pull_logs reading it) must not make a poll store the
    // same lines twice.
    bool indexDirty;
    public string Status { get; private set; }

    public RunArchive(string root, string launchId, Func<DateTime> now)
    {
        this.launchId = launchId;
        this.now = now;
        runs = Path.Combine(root, "runs");
        launches = Path.Combine(root, "launches");
        statePath = Path.Combine(root, "archive-state.txt");
        indexPath = Path.Combine(runs, "index.tsv");
        Start();
    }

    void Start()
    {
        try
        {
            index.Clear();
            Directory.CreateDirectory(runs);
            Directory.CreateDirectory(launches);
            LoadIndex();
            string savedLaunch = null, savedRun = null, savedLaunchFile = null;
            long savedOffset = 0;
            if (File.Exists(statePath))
                foreach (string line in File.ReadAllLines(statePath))
                {
                    int eq = line.IndexOf('=');
                    if (eq < 0) continue;
                    string key = line.Substring(0, eq), value = line.Substring(eq + 1);
                    if (key == "launch") savedLaunch = value;
                    else if (key == "offset") long.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out savedOffset);
                    else if (key == "run") savedRun = value.Length > 0 ? value : null;
                    else if (key == "launchFile") savedLaunchFile = value.Length > 0 ? value : null;
                }
            // A Host restart inside the same launch keeps writing the open
            // segments; anything else left over is from an earlier launch.
            if (savedLaunch == launchId && savedLaunchFile != null)
            {
                offset = savedOffset;
                run = savedRun;
                launchFile = savedLaunchFile;
            }
            else
            {
                if (savedRun != null) SetStatus(savedRun, "paused", null);
                NewLaunch();
            }
            foreach (string dir in new[] { runs, launches })
                foreach (string part in Directory.GetFiles(dir, "*.part"))
                {
                    string gz = part.Substring(0, part.Length - ".part".Length);
                    if (Path.GetFileName(gz) != run && Path.GetFileName(gz) != launchFile) Compress(gz);
                }
            indexDirty = true;
            SaveState();
            ready = true;
            SaveIndexIfDirty();
        }
        catch (Exception e) { Status = "存档失败：" + e.Message; }
    }

    void NewLaunch()
    {
        offset = 0;
        run = null;
        launchFile = Unique(launches, now().ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture), ".log.gz");
    }

    // Reads complete new lines from log.txt (at most MaxBytesPerPoll) and
    // stores them. Never throws: a failure is reported in Status and the same
    // bytes are tried again on the next poll.
    public void Poll(string logPath)
    {
        if (!ready) { Start(); if (!ready) return; }
        try
        {
            using (var log = new FileStream(logPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                if (log.Length < offset)
                {
                    // log.txt was rewritten: a new launch under the same Host.
                    CloseSegments();
                    if (run != null) SetStatus(run, "paused", null);
                    NewLaunch();
                    indexDirty = true;
                    SaveState();
                }
                if (log.Length == offset) { SaveIndexIfDirty(); return; }
                log.Seek(offset, SeekOrigin.Begin);
                int count = 0, read;
                while (count < buffer.Length && (read = log.Read(buffer, count, buffer.Length - count)) > 0) count += read;
                int start = 0;
                for (int i = 0; i < count; i++)
                {
                    if (buffer[i] != (byte)'\n') continue;
                    Store(start, i + 1);
                    start = i + 1;
                }
                if (start == 0) return;
                Flush();
                offset += start;
                SaveState();
                Status = "存档中：" + (run ?? "菜单");
            }
            SaveIndexIfDirty();
        }
        catch (Exception e) { Status = "存档失败：" + e.Message; }
    }

    void SaveIndexIfDirty()
    {
        if (!indexDirty) return;
        try { SaveIndex(); indexDirty = false; }
        catch (Exception e) { Status = "索引稍后重写：" + e.Message; }
    }

    // Host exit: every live segment becomes a gzip member. The run stays
    // open, so a Host restart in the same launch continues it.
    public void Close()
    {
        if (!ready) return;
        try
        {
            Flush();
            CloseSegments();
            SaveState();
            SaveIndexIfDirty();
        }
        catch (Exception e) { Status = "存档失败：" + e.Message; }
    }

    FileStream runPart, launchPart;
    string runPartName;

    void Store(int start, int end)
    {
        string line = Encoding.UTF8.GetString(buffer, start, end - start);
        int marker = line.IndexOf("IAD RUN ", StringComparison.Ordinal);
        if (marker < 0) { Write(start, end); return; }
        string[] words = line.Substring(marker + "IAD RUN ".Length).Trim().Split(' ');
        string kind = words[0];
        var fields = new Dictionary<string, string>();
        for (int i = 1; i < words.Length; i++)
        {
            int eq = words[i].IndexOf('=');
            if (eq > 0) fields[words[i].Substring(0, eq)] = words[i].Substring(eq + 1);
        }
        if (kind == "begin")
        {
            string seed, continued;
            fields.TryGetValue("seed", out seed);
            fields.TryGetValue("continued", out continued);
            seed = Clean(seed);
            if (run != null)
            {
                CloseRun();
                SetStatus(run, "ended", "abandoned");
                run = null;
            }
            string found = null;
            if (continued == "true")
                for (int i = index.Count - 1; i >= 0 && found == null; i--)
                    // A run left open by a crash was abandoned by the next
                    // new run, but its save can still be continued.
                    if (index[i][1] == seed && (index[i][3] != "ended" || index[i][4] == "abandoned")) found = index[i][0];
            if (found != null)
            {
                run = found;
                SetStatus(run, "open", null);
            }
            else
            {
                run = Unique(runs, now().ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture) + "_" + seed, ".log.gz");
                index.Add(new[] { run, seed, now().ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture), "open", "", continued == "true" ? "continued" : "" });
            }
            indexDirty = true;
            Write(start, end);
        }
        else if ((kind == "pause" || kind == "end") && run != null)
        {
            Write(start, end);
            CloseRun();
            string reason = null;
            if (kind == "end") fields.TryGetValue("reason", out reason);
            SetStatus(run, kind == "end" ? "ended" : "paused", kind == "end" ? (reason ?? "unknown") : null);
            run = null;
            indexDirty = true;
        }
        else Write(start, end);
    }

    void Write(int start, int end)
    {
        FileStream part;
        if (run != null)
        {
            if (runPart == null || runPartName != run)
            {
                CloseRun();
                runPart = OpenPart(runs, run);
                runPartName = run;
            }
            part = runPart;
        }
        else
        {
            if (launchPart == null) launchPart = OpenPart(launches, launchFile);
            part = launchPart;
        }
        part.Write(buffer, start, end - start);
    }

    static FileStream OpenPart(string dir, string file)
    {
        return new FileStream(Path.Combine(dir, file + ".part"), FileMode.Append, FileAccess.Write, FileShare.Read);
    }

    void Flush()
    {
        if (runPart != null) runPart.Flush(true);
        if (launchPart != null) launchPart.Flush(true);
    }

    void CloseRun()
    {
        if (runPart == null) return;
        runPart.Dispose();
        runPart = null;
        Compress(Path.Combine(runs, runPartName));
        runPartName = null;
    }

    void CloseSegments()
    {
        CloseRun();
        if (launchPart != null)
        {
            launchPart.Dispose();
            launchPart = null;
            Compress(Path.Combine(launches, launchFile));
        }
    }

    // Appends <gz>.part to <gz> as one more gzip member, then drops the part.
    // The new file is built beside the old one and swapped in, so a Host
    // killed mid-way leaves the old .gz whole and the .part to redo.
    static void Compress(string gz)
    {
        string part = gz + ".part", temp = gz + ".tmp";
        if (!File.Exists(part)) return;
        if (new FileInfo(part).Length > 0)
        {
            using (var target = new FileStream(temp, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                if (File.Exists(gz)) using (var old = File.OpenRead(gz)) old.CopyTo(target);
                using (var source = File.OpenRead(part))
                using (var zip = new GZipStream(target, CompressionMode.Compress, true)) source.CopyTo(zip);
                target.Flush(true);
            }
            if (File.Exists(gz)) File.Replace(temp, gz, null);
            else File.Move(temp, gz);
        }
        File.Delete(part);
    }

    static string Clean(string seed)
    {
        var b = new StringBuilder();
        if (seed != null) foreach (char c in seed) if ((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) b.Append(c);
        return b.Length > 0 ? b.ToString() : "unknown";
    }

    static string Unique(string dir, string stem, string suffix)
    {
        string name = stem + suffix;
        for (int i = 2; File.Exists(Path.Combine(dir, name)) || File.Exists(Path.Combine(dir, name + ".part")); i++)
            name = stem + "-" + i + suffix;
        return name;
    }

    void SetStatus(string file, string status, string reason)
    {
        foreach (string[] row in index)
            if (row[0] == file)
            {
                row[3] = status;
                row[4] = reason ?? "";
            }
    }

    void LoadIndex()
    {
        if (!File.Exists(indexPath)) return;
        string[] lines = File.ReadAllLines(indexPath);
        for (int i = 1; i < lines.Length; i++)
        {
            string[] f = lines[i].Split('\t');
            if (f.Length < 6) Array.Resize(ref f, 6);
            for (int j = 0; j < f.Length; j++) if (f[j] == null) f[j] = "";
            if (f[0].Length > 0) index.Add(f);
        }
    }

    void SaveIndex()
    {
        var b = new StringBuilder(Header + "\n");
        foreach (string[] row in index) b.Append(string.Join("\t", row)).Append('\n');
        Replace(indexPath, b.ToString());
    }

    void SaveState()
    {
        Replace(statePath, "launch=" + launchId + "\noffset=" + offset.ToString(CultureInfo.InvariantCulture) +
            "\nrun=" + (run ?? "") + "\nlaunchFile=" + (launchFile ?? "") + "\n");
    }

    static void Replace(string path, string text)
    {
        string temp = path + ".tmp";
        File.WriteAllText(temp, text, new UTF8Encoding(false));
        if (File.Exists(path)) File.Replace(temp, path, null);
        else File.Move(temp, path);
    }
}
