using System;
using System.IO;
using System.IO.MemoryMappedFiles;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Windows.Forms;

internal static class NativeHost
{
    const string ExpectedHash="210cade2a1de98550cef52d012174108189d1a0d3926a22c3a1ec12fb3ae4831";
    static MemoryMappedViewAccessor view;
    static Mutex ipcLock;
    static int gamePid;
    static volatile bool enabled=true, running=true;
    // Reader thread and UI share view/log state under this lock.
    static readonly object sync=new object();
    // Isaac.GetTime() is QueryPerformanceCounter milliseconds (checked on the
    // installed build), so arrival delay is measured directly (0..5000ms).
    static readonly int[] delays=new int[512];
    static int delayCount,delayNext,rejected,sameClock,otherClock;
    static FileStream log;
    static long received=-10000,opened=-10000;
    static readonly Stopwatch clock=Stopwatch.StartNew();
    static readonly PacketClock calibration=new PacketClock();
    static string pending="",note="等待新传感器数据";
    static long packets;
    static uint sequence;
    // IAD2 (sensor 0.12+) precedes the IAD1 packet whose sequence it names.
    static readonly CombatPairing pairing=new CombatPairing();
    static uint lastCombat;
    static void ResetStream()
    {
        pending="";
        calibration.Reset();
        pairing.Reset();
    }
    static void Publish(bool active,double[] risk,int blocked,uint combat=0)
    {
        bool acquired=false;
        try {
            try { acquired=ipcLock.WaitOne(50); } catch(AbandonedMutexException){acquired=true;}
            if(!acquired)return;
            view.Write(0,0x32444149u);view.Write(4,1u);view.Write(8,(uint)gamePid);
            view.Write(12,unchecked((uint)Environment.TickCount));view.Write(16,active?1u:0u);
            view.Write(20,(uint)blocked);view.Write(24,++sequence);view.Write(28,active?combat:0u);
            if(risk!=null)for(int i=0;i<9;i++)view.Write(32+i*8,risk[i]);
        } finally {if(acquired)ipcLock.ReleaseMutex();}
    }
    static void ReadLog(string path)
    {
        if(log==null){log=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete);log.Seek(0,SeekOrigin.End);opened=clock.ElapsedMilliseconds;ResetStream();Publish(false,null,0);return;}
        if(log.Length<log.Position || clock.ElapsedMilliseconds-Math.Max(opened,received)>1000){if(log!=null)log.Dispose();log=null;ResetStream();Publish(false,null,0);return;}
        if(log.Length-log.Position>65536){log.Seek(0,SeekOrigin.End);ResetStream();Publish(false,null,0);note="跳过积压，重新校准";return;}
        byte[] bytes=new byte[8192];int count;
        while((count=log.Read(bytes,0,bytes.Length))>0) {
            pending+=Encoding.UTF8.GetString(bytes,0,count);
            int newline;
            while((newline=pending.IndexOf('\n'))>=0){string line=pending.Substring(0,newline).Trim();pending=pending.Substring(newline+1);int start=line.IndexOf("IAD1|");if(start>=0)Parse(line.Substring(start));else{start=line.IndexOf("IAD2|");if(start>=0)ParseCombat(line.Substring(start));}}
            if(pending.Length>16384){pending="";pairing.Reset();}
        }
    }
    static void ParseCombat(string line)
    {
        pairing.ReceiveLine(line);
    }
    static void Parse(string line)
    {
        string[] f=line.Split('|');long seq;double stamp;int blocked;
        if(f.Length!=8 || !long.TryParse(f[1],out seq) || !double.TryParse(f[2],NumberStyles.Float,CultureInfo.InvariantCulture,out stamp) || double.IsNaN(stamp) || double.IsInfinity(stamp) || stamp<0 || !int.TryParse(f[7],out blocked)){pairing.Reset();return;}
        string[] r=f[6].Split(',');if(r.Length!=9){pairing.Reset();return;}double[] risk=new double[9];
        for(int i=0;i<9;i++)if(!double.TryParse(r[i],NumberStyles.Float,CultureInfo.InvariantCulture,out risk[i]) || double.IsNaN(risk[i]) || double.IsInfinity(risk[i])){pairing.Reset();return;}
        long absolute=Stopwatch.GetTimestamp()*1000/Stopwatch.Frequency-(long)stamp;
        if(absolute>=0 && absolute<5000){sameClock++;delays[delayNext]=(int)absolute;delayNext=(delayNext+1)%delays.Length;if(delayCount<delays.Length)delayCount++;}
        else otherClock++;
        if(!calibration.Accept(unchecked((uint)(long)stamp),seq,clock.ElapsedMilliseconds)){rejected++;pairing.Reset();Publish(false,null,0);note="校准时钟或等待实时数据";return;}
        received=clock.ElapsedMilliseconds;packets++;
        uint combat=pairing.Take(seq);lastCombat=combat;
        Publish(enabled && f[3]=="1",risk,blocked,combat);note="传感器已连接，原生键盘输入入口";
    }
    static string DelaySummary()
    {
        if(delayCount==0)return sameClock==0 && otherClock>0 ? "日志延迟：时钟不同源，未测" : "日志延迟：无数据";
        int[] sorted=new int[delayCount];Array.Copy(delays,sorted,delayCount);Array.Sort(sorted);
        return String.Format("日志延迟 p50 {0}ms · p95 {1}ms · 最大 {2}ms",sorted[delayCount/2],sorted[delayCount*95/100],sorted[delayCount-1]);
    }
    static void ReaderLoop(object path)
    {
        // WinForms timers fire every ~31ms at a 16ms interval; poll at 1ms.
        timeBeginPeriod(1);
        try{
            while(running){
                lock(sync){
                    if(view==null)return;
                    try{
                        ReadLog((string)path);
                        if(clock.ElapsedMilliseconds-received>120){pairing.Reset();Publish(false,null,0);}
                    }catch(IOException){pairing.Reset();Publish(false,null,0);if(log!=null)log.Dispose();log=null;note="等待游戏日志";}
                }
                Thread.Sleep(1);
            }
        }catch(Exception e){lock(sync){note="读取线程停止："+e.Message;if(view!=null)Publish(false,null,0);}}
        finally{timeEndPeriod(1);}
    }
    static void WriteStats(string reason)
    {
        try{
            string file=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"IsaacDodgeAssist","native-0.4-stats.log");
            string line;
            lock(sync){
                line=String.Format(CultureInfo.InvariantCulture,"{0:o} reason={1} packets={2} rejected={3} sameClock={4} otherClock={5} jitterMs={6} polls={7} overrides={8} shots={10} {9}",
                    DateTime.Now,reason,packets,rejected,sameClock,otherClock,calibration.Delay,
                    view!=null?view.ReadInt32(108):-1,view!=null?view.ReadInt32(112):-1,DelaySummary(),view!=null?view.ReadInt32(120):-1);
            }
            File.AppendAllText(file,line+Environment.NewLine);
        }catch(Exception){}
    }
    [STAThread] static void Main()
    {
        bool created;
        using(var singleton=new Mutex(true,"Local\\IsaacDodgeAssist",out created)){
            if(!created){MessageBox.Show("请先关闭旧的模拟按键辅助程序，再启动原生版。");return;}
            try { Run(); } catch(Exception e){MessageBox.Show(e.Message,"原生躲避未启动");}
            finally {if(view!=null){Publish(false,null,0);view.Dispose();}if(log!=null)log.Dispose();if(ipcLock!=null)ipcLock.Dispose();}
        }
    }
    static void Run()
    {
        Process[] targets=Process.GetProcessesByName("isaac-ng");
        if(targets.Length!=1)throw new Exception("请先启动一个以撒游戏进程，再启动本程序。");
        using(Process game=targets[0]){
            gamePid=game.Id;
            string exe=game.MainModule.FileName;
            using(var sha=SHA256.Create())using(var file=File.OpenRead(exe)){
                string hash=BitConverter.ToString(sha.ComputeHash(file)).Replace("-","").ToLowerInvariant();
                if(hash!=ExpectedHash)throw new Exception("游戏版本不匹配，未安装 Hook。");
            }
            string dll=Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"IsaacDodgeNative.dll");
            if(!File.Exists(dll))throw new Exception("缺少 IsaacDodgeNative.dll");
            ipcLock=new Mutex(false,"Local\\IsaacDodgeNativeLock-"+gamePid);
            using(var mapping=MemoryMappedFile.CreateOrOpen("Local\\IsaacDodgeNative-"+gamePid,128)){
                view=mapping.CreateViewAccessor();Publish(false,null,0);
                bool loaded=false;
                foreach(ProcessModule module in game.Modules)if(module.ModuleName.Equals("IsaacDodgeNative.dll",StringComparison.OrdinalIgnoreCase)){
                    if(!Path.GetFullPath(module.FileName).Equals(Path.GetFullPath(dll),StringComparison.OrdinalIgnoreCase))
                        throw new Exception("游戏仍加载着旧版原生模块，请退出游戏后重新启动，再打开本程序。");
                    loaded=true;
                }
                if(!loaded)Inject(game,dll);
                Application.EnableVisualStyles();
                var form=new Form{Text="以撒原生输入躲避 0.4.2",Width=560,Height=270};
                var toggle=new CheckBox{Text="启用原生移动接管",Checked=true,Left=20,Top=20,Width=300};
                var label=new Label{Left=20,Top=60,Width=510,Height=160};
                toggle.CheckedChanged+=delegate{enabled=toggle.Checked;if(!enabled)lock(sync)Publish(false,null,0);};
                form.Controls.Add(toggle);form.Controls.Add(label);
                var timer=new System.Windows.Forms.Timer{Interval=16};
                string path=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),"My Games","Binding of Isaac Repentance+","log.txt");
                var reader=new Thread(ReaderLoop){IsBackground=true,Priority=ThreadPriority.AboveNormal,Name="IAD log reader"};
                long lastStats=clock.ElapsedMilliseconds;
                timer.Tick+=delegate{
                    try{
                        if(game.HasExited){form.Close();return;}
                        int status;string text;
                        lock(sync){
                            status=view.ReadInt32(104);
                            string[] modes={"关","自动瞄准","自动战斗","?"};
                            text=String.Format("{0}\nHook状态 {1} · 收到 {2} 帧 · 拒收 {3}\n{4}\n移动输入读取 {5} 次 · 返回替代输入 {6} 次 · 射击替代 {7} 次\n战斗模式（游戏内 F10）：{8}\n关闭窗口或按住左 Shift 释放接管；计数不代表角色实际位移。",
                                note,status,packets,rejected,DelaySummary(),view.ReadInt32(108),view.ReadInt32(112),view.ReadInt32(120),modes[lastCombat&3]);
                        }
                        label.Text=text;
                        if(status<0){enabled=false;toggle.Checked=false;lock(sync)note="Hook校验失败："+status;}
                        if(clock.ElapsedMilliseconds-lastStats>=30000){lastStats=clock.ElapsedMilliseconds;WriteStats("interval");}
                    }catch(Exception e){lock(sync)Publish(false,null,0);timer.Stop();label.Text="已停止："+e.Message;}
                };
                form.FormClosing+=delegate{timer.Stop();running=false;reader.Join(500);WriteStats("exit");lock(sync)Publish(false,null,0);};
                reader.Start(path);timer.Start();Application.Run(form);timer.Dispose();
                running=false;reader.Join(500);
                lock(sync){view.Dispose();view=null;}
            }
        }
    }
    static void Inject(Process game,string path)
    {
        // Resolve the module which actually owns LoadLibraryW (including forwarding).
        IntPtr load=GetProcAddress(GetModuleHandle("kernel32.dll"),"LoadLibraryW");
        ProcessModule owner=null;
        using(Process self=Process.GetCurrentProcess())foreach(ProcessModule m in self.Modules)
            if(load.ToInt64()>=m.BaseAddress.ToInt64() && load.ToInt64()<m.BaseAddress.ToInt64()+m.ModuleMemorySize){owner=m;break;}
        if(owner==null)throw new Exception("无法定位系统加载器");
        IntPtr remoteLoad=IntPtr.Zero;
        foreach(ProcessModule m in game.Modules)if(m.ModuleName.Equals(owner.ModuleName,StringComparison.OrdinalIgnoreCase))remoteLoad=new IntPtr(m.BaseAddress.ToInt64()+load.ToInt64()-owner.BaseAddress.ToInt64());
        if(remoteLoad==IntPtr.Zero)throw new Exception("目标进程系统模块不匹配");
        IntPtr process=OpenProcess(0x43A,false,game.Id);if(process==IntPtr.Zero)throw new System.ComponentModel.Win32Exception();
        IntPtr allocation=IntPtr.Zero,thread=IntPtr.Zero;bool completed=false,started=false;
        try{
            byte[] data=Encoding.Unicode.GetBytes(path+"\0");
            allocation=VirtualAllocEx(process,IntPtr.Zero,(UIntPtr)data.Length,0x3000,4);if(allocation==IntPtr.Zero)throw new System.ComponentModel.Win32Exception();
            UIntPtr written;if(!WriteProcessMemory(process,allocation,data,(UIntPtr)data.Length,out written) || written.ToUInt64()!=(ulong)data.Length)throw new System.ComponentModel.Win32Exception();
            thread=CreateRemoteThread(process,IntPtr.Zero,UIntPtr.Zero,remoteLoad,allocation,0,IntPtr.Zero);
            if(thread==IntPtr.Zero)throw new System.ComponentModel.Win32Exception();started=true;
            if(WaitForSingleObject(thread,5000)!=0)throw new Exception("加载结果未确定；没有重试，请重启游戏后再启动。");
            completed=true;uint result;if(!GetExitCodeThread(thread,out result) || result==0)throw new Exception("游戏未能加载原生模块");
        }finally{if(allocation!=IntPtr.Zero && (completed || !started))VirtualFreeEx(process,allocation,UIntPtr.Zero,0x8000);if(thread!=IntPtr.Zero)CloseHandle(thread);CloseHandle(process);}
    }
    [DllImport("winmm.dll")]static extern uint timeBeginPeriod(uint period);
    [DllImport("winmm.dll")]static extern uint timeEndPeriod(uint period);
    [DllImport("kernel32.dll",SetLastError=true)]static extern IntPtr OpenProcess(uint access,bool inherit,int pid);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode)]static extern IntPtr GetModuleHandle(string module);
    [DllImport("kernel32.dll",CharSet=CharSet.Ansi)]static extern IntPtr GetProcAddress(IntPtr module,string name);
    [DllImport("kernel32.dll",SetLastError=true)]static extern IntPtr VirtualAllocEx(IntPtr process,IntPtr address,UIntPtr size,uint type,uint protect);
    [DllImport("kernel32.dll",SetLastError=true)]static extern bool WriteProcessMemory(IntPtr process,IntPtr address,byte[] bytes,UIntPtr size,out UIntPtr written);
    [DllImport("kernel32.dll",SetLastError=true)]static extern IntPtr CreateRemoteThread(IntPtr process,IntPtr attrs,UIntPtr stack,IntPtr start,IntPtr arg,uint flags,IntPtr id);
    [DllImport("kernel32.dll")]static extern uint WaitForSingleObject(IntPtr handle,uint ms);
    [DllImport("kernel32.dll")]static extern bool GetExitCodeThread(IntPtr thread,out uint result);
    [DllImport("kernel32.dll")]static extern bool VirtualFreeEx(IntPtr process,IntPtr address,UIntPtr size,uint type);
    [DllImport("kernel32.dll")]static extern bool CloseHandle(IntPtr handle);
}
