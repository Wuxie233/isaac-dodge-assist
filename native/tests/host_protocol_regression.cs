using System;

// Pairing tests for NativeHost: an IAD2 word is valid for one matching IAD1
// packet and must never survive a reset, malformed line, wrong sequence or a
// new sensor session. Run with PacketClock.cs in the same compilation.
internal static class HostProtocolRegression
{
    static void Check(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
    }
    public static int Main()
    {
        var p = new CombatPairing();
        Check(p.ReceiveLine("IAD2|7|513"), "valid combat line");
        Check(p.Take(7) == 513, "matching word");
        Check(p.Take(7) == 0, "word consumed once");

        Check(p.ReceiveLine("IAD2|8|2"), "second line");
        Check(p.Take(9) == 0, "wrong sequence rejected");
        Check(p.Take(8) == 0, "wrong sequence cleared pending word");

        Check(p.ReceiveLine("IAD2|10|4"), "third line");
        p.Reset();
        Check(p.Take(10) == 0, "stream reset cleared pending word");

        Check(p.ReceiveLine("IAD2|11|8"), "fourth line");
        Check(!p.ReceiveLine("IAD2|broken"), "malformed line rejected");
        Check(p.Take(11) == 0, "malformed line cleared pending word");

        // Duplicate IAD2 before an IAD1: only the latest word may be paired.
        Check(p.ReceiveLine("IAD2|12|16"), "duplicate setup one");
        Check(p.ReceiveLine("IAD2|12|32"), "duplicate setup two");
        Check(p.Take(12) == 32, "latest duplicate word wins");

        var m = new NativeMetaPairing();
        uint seed, fl;
        int qd;
        Check(m.ReceiveLine("IAD3|20|305419896|3|4"), "valid meta line");
        Check(m.Take(20, out seed, out fl, out qd) && seed == 305419896u && fl == 3u && qd == 4, "matching meta");
        Check(!m.Take(20, out seed, out fl, out qd) && seed == 0u && fl == 0u && qd == 0, "meta consumed once");

        Check(m.ReceiveLine("IAD3|21|123456|1|2"), "second meta line");
        Check(!m.Take(22, out seed, out fl, out qd), "wrong sequence meta rejected");
        Check(!m.Take(21, out seed, out fl, out qd), "wrong sequence cleared pending meta");

        Check(m.ReceiveLine("IAD3|23|4294967295|15|0"), "max uint seed meta");
        Check(!m.ReceiveLine("IAD3|23|notanint|1|0"), "malformed meta rejected");
        Check(!m.Take(23, out seed, out fl, out qd), "malformed line cleared meta");

        Check(m.ReceiveLine("IAD3|24|999|5|3"), "reset meta setup");
        m.Reset();
        Check(!m.Take(24, out seed, out fl, out qd), "reset cleared meta");

        Console.WriteLine("PASS host IAD2 & IAD3 pairing: one-shot, wrong sequence, reset, malformed and duplicate");
        return 0;
    }
}
