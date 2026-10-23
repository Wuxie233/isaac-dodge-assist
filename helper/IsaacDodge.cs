using System;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

internal static class Program
{
    [STAThread] static void Main(string[] args)
    {
        bool created;
        using (var singleton = new Mutex(true, "Local\\IsaacDodgeAssist", out created))
        {
            if (!created) { MessageBox.Show("躲弹辅助已经在运行。", "Isaac Dodge"); return; }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            string path = args.Length > 0 ? args[0] : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
                "My Games", "Binding of Isaac Repentance+", "log.txt");
            try { Application.Run(new DodgeWindow(path)); }
            catch (Exception e) { MessageBox.Show(e.Message, "躲弹辅助启动失败"); }
        }
    }
}

// Sender and receiver clocks may have different origins. Calibrate only from
// new log records, then reject backlog by its excess delay on a monotonic clock.
internal sealed class PacketClock
{
    bool started;
    uint previousStamp;
    long previousSequence, sourceElapsed, firstArrival, minimumOffset;
    int samples;
    internal long Delay { get; private set; }
    internal void Reset() { started = false; samples = 0; Delay = 0; }
    internal bool Accept(uint stamp, long sequence, long arrival)
    {
        if (started && sequence == previousSequence) return false;
        int delta = unchecked((int)(stamp - previousStamp));
        if (!started || sequence < previousSequence || delta < 0)
        {
            started = true; previousStamp = stamp; previousSequence = sequence;
            sourceElapsed = 0; firstArrival = minimumOffset = arrival; samples = 1;
            Delay = 0; return false;
        }
        previousStamp = stamp; previousSequence = sequence; sourceElapsed += delta;
        long offset = arrival - sourceElapsed;
        minimumOffset = Math.Min(minimumOffset, offset);
        Delay = offset - minimumOffset;
        samples++;
        return samples >= 3 && arrival - firstArrival >= 120 && Delay <= 100;
    }
}

internal sealed class DodgeWindow : Form
{
    readonly Label status = new Label(), detail = new Label();
    readonly CheckBox enabled = new CheckBox();
    readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
    readonly Stopwatch clock = Stopwatch.StartNew();
    readonly PacketClock packetClock = new PacketClock();
    readonly string logPath;
    readonly bool[] physical = new bool[4], effective = new bool[4];
    // Key order: A, D, W, S. Candidate order must match main.lua.
    readonly int[] keys = {0x41, 0x44, 0x57, 0x53};
    readonly int[] masks = {0, 1, 2, 4, 8, 5, 6, 9, 10};
    readonly int[] dx = {0,-1,1,0,0,-1,1,-1,1}, dy = {0,0,0,-1,1,-1,-1,1,1};
    Native.HookProc hookProc;
    IntPtr hook;
    FileStream log;
    string pending = "";
    double[] risks = new double[9];
    long received = -10000, packets, interventions, lastUi;
    long logOpenedAt;
    bool sensorActive, overriding, wasForeground, disposed, suspended;
    int chosen = -1, slot = -1, horizon = 150, blocked;
    string note = "等待游戏中的模组数据";

    public DodgeWindow(string path)
    {
        logPath = path;
        Text = "以撒紧急躲弹 0.1.1"; ClientSize = new Size(540, 245);
        FormBorderStyle = FormBorderStyle.FixedSingle; MaximizeBox = false;
        Font = new Font("Microsoft YaHei UI", 10);
        enabled.Text = "启用本机键盘辅助"; enabled.Checked = true; enabled.SetBounds(20,18,480,28);
        status.SetBounds(20,55,500,40); status.Font = new Font(Font.FontFamily, 14, FontStyle.Bold);
        detail.SetBounds(20,100,500,62);
        var help = new Label { Text = "游戏内：F6 开关 · F7 选择角色 · F8 调整提前量\n按住左 Alt 暂停 · WASD 移动 · 关闭此窗口退出", AutoSize = false };
        help.SetBounds(20,175,500,60);
        Controls.AddRange(new Control[] {enabled,status,detail,help});
        enabled.CheckedChanged += delegate { if (!enabled.Checked) SafeRelease(IsGameForeground()); };
        for (int i = 0; i < 4; i++) physical[i] = effective[i] = Native.Down(keys[i]);
        hookProc = Keyboard;
        hook = Native.SetWindowsHookEx(13, hookProc, Native.GetModuleHandle(null), 0);
        if (hook == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "无法启用键盘输入协调");
        Native.timeBeginPeriod(1);
        timer.Interval = 8; timer.Tick += delegate { Tick(); }; timer.Start();
        FormClosing += delegate { Shutdown(); };
        UpdateLabels();
    }

    uint foregroundPid;
    long foregroundChecked = -1000;
    bool foregroundIsGame;

    bool IsGameForeground()
    {
        IntPtr hwnd = Native.GetForegroundWindow(); uint pid;
        Native.GetWindowThreadProcessId(hwnd, out pid);
        if (pid == 0) return false;
        // HWND/PID are checked on every call. ProcessName on .NET Framework
        // enumerates process information; do not repeat that at input-poll rate.
        long now = clock.ElapsedMilliseconds;
        if (pid == foregroundPid && now - foregroundChecked < 250) return foregroundIsGame;
        foregroundPid = pid; foregroundChecked = now; foregroundIsGame = false;
        try { using (var p = Process.GetProcessById((int)pid)) foregroundIsGame = p.ProcessName.Equals("isaac-ng", StringComparison.OrdinalIgnoreCase); }
        catch (ArgumentException) { }
        catch (System.ComponentModel.Win32Exception) { }
        return foregroundIsGame;
    }

    IntPtr Keyboard(int code, IntPtr message, IntPtr data)
    {
        if (code >= 0)
        {
            var key = (Native.KeyboardData)Marshal.PtrToStructure(data, typeof(Native.KeyboardData));
            // Never mistake our own SendInput events (or other injected events) for physical intent.
            if ((key.flags & 0x10) == 0)
            {
                bool down = message.ToInt32() == 0x100 || message.ToInt32() == 0x104;
                bool game = IsGameForeground();
                if (down && game && (key.vkCode == 0x75 || key.vkCode == 0x76 || key.vkCode == 0x1B || key.vkCode == 0xC0))
                {
                    // F6/F7/menu/console: stop immediately, before the next sensor packet.
                    sensorActive = false; received = -10000;
                    SafeRelease(true);
                }
                if (key.vkCode == 0xA4 || key.vkCode == 0x12)
                {
                    suspended = down;
                    if (down) SafeRelease(game);
                }
                for (int i = 0; i < 4; i++) if (key.vkCode == keys[i])
                {
                    physical[i] = down;
                    if (overriding && game) return new IntPtr(1);
                    effective[i] = down;
                }
            }
        }
        return Native.CallNextHookEx(hook, code, message, data);
    }

    void ReadLog()
    {
        try
        {
            if (log == null)
            {
                log = new FileStream(logPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                log.Seek(0, SeekOrigin.End); // Never replay records from an earlier run.
                pending = ""; sensorActive = false; received = -10000;
                logOpenedAt = clock.ElapsedMilliseconds; packetClock.Reset();
                note = "日志已连接；等待新的游戏数据";
                return;
            }
            long length = log.Length;
            if (length < log.Position)
            {
                log.Dispose(); log = null; sensorActive = false; received = -10000;
                pending = ""; return;
            }
            long available = length - log.Position;
            if (available > 65536)
            {
                log.Seek(0, SeekOrigin.End); pending = ""; received = -10000; sensorActive = false; packetClock.Reset();
                note = "跳过积压数据；等待实时记录"; return;
            }
            if (available == 0)
            {
                // A game restart can replace the pathname while our old handle remains valid.
                if (clock.ElapsedMilliseconds - Math.Max(received, logOpenedAt) > 1000)
                { log.Dispose(); log = null; sensorActive = false; }
                return;
            }
            byte[] bytes = new byte[(int)available];
            int n = log.Read(bytes, 0, bytes.Length);
            pending += Encoding.UTF8.GetString(bytes,0,n);
            int newline;
            while ((newline = pending.IndexOf('\n')) >= 0)
            {
                string line = pending.Substring(0,newline).TrimEnd('\r');
                pending = pending.Substring(newline+1);
                int marker = line.IndexOf("IAD1|", StringComparison.Ordinal);
                if (marker >= 0) Parse(line.Substring(marker));
            }
            if (pending.Length > 16384) pending = "";
        }
        catch (IOException e) { Disconnect("日志等待中：" + e.Message); }
        catch (UnauthorizedAccessException e) { Disconnect("日志无法读取：" + e.Message); }
    }
    void Disconnect(string reason)
    {
        if (log != null) log.Dispose(); log = null;
        sensorActive = false; received = -10000; note = reason;
    }
    void Parse(string line)
    {
        string[] fields = line.Split('|');
        if (fields.Length != 8) return;
        double stamp; long sequence; int player, ms, blockedPaths;
        if (!Int64.TryParse(fields[1], out sequence) || !Double.TryParse(fields[2], NumberStyles.Float, CultureInfo.InvariantCulture, out stamp) ||
            !Int32.TryParse(fields[4], out player) || !Int32.TryParse(fields[5], out ms) || !Int32.TryParse(fields[7], out blockedPaths)) return;
        string[] values = fields[6].Split(',');
        if (values.Length != 9) return;
        var scores = new double[9];
        for (int i=0;i<9;i++) if (!Double.TryParse(values[i], NumberStyles.Float, CultureInfo.InvariantCulture, out scores[i]) ||
            Double.IsNaN(scores[i]) || Double.IsInfinity(scores[i])) return;
        long now = clock.ElapsedMilliseconds;
        if (Double.IsNaN(stamp) || Double.IsInfinity(stamp) || stamp < 0 || stamp > Int64.MaxValue) return;
        if (!packetClock.Accept(unchecked((uint)(long)stamp), sequence, now))
        {
            sensorActive = false;
            note = packetClock.Delay > 100 ? "实时数据积压超过 100ms；暂停接管" : "正在校准实时数据时钟";
            return;
        }
        risks = scores; blocked = blockedPaths; sensorActive = fields[3] == "1";
        slot = player; horizon = ms; received = now; packets++;
        note = sensorActive ? "正在监测" : "模组关闭、暂停、未绑定或角色不受支持";
    }
    int ManualDirection()
    {
        int x = (physical[1]?1:0) - (physical[0]?1:0);
        int y = (physical[3]?1:0) - (physical[2]?1:0);
        for (int i=0;i<9;i++) if (dx[i]==x && dy[i]==y) return i;
        return 0;
    }
    void Tick()
    {
        try
        {
            ReadLog();
            bool game = IsGameForeground();
            if (!game && wasForeground) Release(false);
            if (game && !wasForeground)
                for (int i=0;i<4;i++) physical[i] = effective[i] = Native.Down(keys[i]);
            wasForeground = game;
            bool ready = game && enabled.Checked && !suspended && !Native.Down(0xA4) && sensorActive && clock.ElapsedMilliseconds-received <= 120;
            if (!ready) Release(game);
            else
            {
                int manual = ManualDirection();
                // Only bullets trigger intervention; blocked paths are excluded independently.
                if (risks[manual] <= 0) Release(true);
                else
                {
                    int best = manual; double value = risks[manual];
                    for (int i=0;i<9;i++)
                    {
                        if ((blocked & (1 << i)) != 0) continue;
                        double candidate = risks[i] + (Math.Abs(dx[i]-dx[manual])+Math.Abs(dy[i]-dy[manual]))*3;
                        if (i == chosen) candidate -= 2;
                        if (candidate < value) { value = candidate; best = i; }
                    }
                    if (best == manual || risks[best] >= risks[manual]) Release(true);
                    else Apply(best);
                }
            }
            if (clock.ElapsedMilliseconds-lastUi >= 150) { UpdateLabels(); lastUi=clock.ElapsedMilliseconds; }
        }
        catch (Exception e)
        {
            enabled.Checked = false; sensorActive = false; SafeRelease(IsGameForeground());
            note = "已停止：" + e.Message; UpdateLabels();
        }
    }
    void Apply(int direction)
    {
        if (!overriding) interventions++;
        overriding = true; chosen = direction;
        for (int i=0;i<4;i++) SetKey(i, (masks[direction] & (1<<i)) != 0);
    }
    void Release(bool restorePhysical)
    {
        if (!overriding) return;
        overriding = false; chosen = -1;
        System.ComponentModel.Win32Exception error = null;
        for (int i=0;i<4;i++)
        {
            try { SetKey(i, restorePhysical && physical[i]); }
            catch (System.ComponentModel.Win32Exception e) { error = e; }
        }
        if (error != null) throw error;
    }
    void SafeRelease(bool restorePhysical)
    {
        try { Release(restorePhysical); }
        catch (System.ComponentModel.Win32Exception e) { note = "输入释放失败：" + e.Message; }
    }
    void SetKey(int index, bool down)
    {
        if (effective[index] == down) return;
        var input = new Native.Input(); input.type = 1;
        input.payload.keyboard.scan = (ushort)Native.MapVirtualKey((uint)keys[index],0);
        input.payload.keyboard.flags = 0x8u | (down?0u:0x2u);
        input.payload.keyboard.extra = new UIntPtr(0x49414431u);
        if (Native.SendInput(1,new Native.Input[] {input},Marshal.SizeOf(typeof(Native.Input))) != 1)
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "SendInput 失败；请确认游戏与辅助程序权限一致");
        effective[index] = down;
    }
    void UpdateLabels()
    {
        bool fresh = clock.ElapsedMilliseconds-received <= 120;
        status.Text = !enabled.Checked ? "辅助已关闭" : !wasForeground ? "后台暂停（切回游戏自动恢复）" : suspended ? "临时暂停" :
            !fresh ? "等待模组实时数据" : overriding ? "正在紧急躲避" : sensorActive ? "监测中" : "未接管输入";
        status.ForeColor = overriding ? Color.DarkOrange : Color.DarkSlateBlue;
        detail.Text = String.Format("{0}\n角色 P{1} · 提前 {2}ms · 收到 {3} 帧 · 干预 {4} 次", note, slot+1,horizon,packets,interventions);
    }
    void Shutdown()
    {
        if (disposed) return; disposed = true; timer.Stop();
        try { SafeRelease(IsGameForeground()); }
        finally
        {
            if (hook != IntPtr.Zero) Native.UnhookWindowsHookEx(hook);
            if (log != null) log.Dispose(); Native.timeEndPeriod(1);
        }
    }
    protected override void Dispose(bool disposing) { if (disposing) Shutdown(); base.Dispose(disposing); }
}

internal static class Native
{
    internal delegate IntPtr HookProc(int code, IntPtr message, IntPtr data);
    [StructLayout(LayoutKind.Sequential)] internal struct KeyboardData { internal uint vkCode, scanCode, flags, time; internal UIntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] internal struct KeyInput { internal ushort vk,scan; internal uint flags,time; internal UIntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] internal struct MouseInput { internal int x,y; internal uint data,flags,time; internal UIntPtr extra; }
    [StructLayout(LayoutKind.Explicit)] internal struct Payload { [FieldOffset(0)] internal KeyInput keyboard; [FieldOffset(0)] internal MouseInput mouse; }
    [StructLayout(LayoutKind.Sequential)] internal struct Input { internal uint type; internal Payload payload; }
    [DllImport("user32.dll", SetLastError=true)] internal static extern IntPtr SetWindowsHookEx(int id, HookProc proc, IntPtr module, uint thread);
    [DllImport("user32.dll")] internal static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] internal static extern IntPtr CallNextHookEx(IntPtr hook,int code,IntPtr message,IntPtr data);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] internal static extern IntPtr GetModuleHandle(string name);
    [DllImport("kernel32.dll")] internal static extern uint GetTickCount();
    [DllImport("user32.dll")] internal static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] internal static extern uint GetWindowThreadProcessId(IntPtr window,out uint process);
    [DllImport("user32.dll")] internal static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] internal static extern uint MapVirtualKey(uint code,uint type);
    [DllImport("user32.dll", SetLastError=true)] internal static extern uint SendInput(uint count,Input[] inputs,int size);
    [DllImport("winmm.dll")] internal static extern uint timeBeginPeriod(uint period);
    [DllImport("winmm.dll")] internal static extern uint timeEndPeriod(uint period);
    internal static bool Down(int key) { return (GetAsyncKeyState(key) & 0x8000) != 0; }
}
