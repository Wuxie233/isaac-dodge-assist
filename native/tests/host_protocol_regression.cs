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

        Console.WriteLine("PASS host IAD2 pairing: one-shot, wrong sequence, reset, malformed and duplicate");
        return 0;
    }
}
