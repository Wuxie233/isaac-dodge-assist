using System;
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

// One IAD2 word may precede exactly one IAD1 packet with the same sequence.
// Any stream discontinuity, malformed packet or rejected packet clears it so
// a new sensor session cannot inherit a stale combat decision.
internal sealed class CombatPairing
{
    long sequence = -1;
    uint word;
    internal void Reset() { sequence = -1; word = 0; }
    internal void Receive(long seq, uint value) { sequence = seq; word = value; }
    internal bool ReceiveLine(string line)
    {
        string[] f = line.Split('|');
        long seq;
        uint value;
        if (f.Length == 3 && long.TryParse(f[1], out seq) && uint.TryParse(f[2], out value))
        {
            Receive(seq, value);
            return true;
        }
        Reset();
        return false;
    }
    internal uint Take(long seq)
    {
        uint result = sequence == seq ? word : 0;
        Reset();
        return result;
    }
}

// Paired IAD3 metadata payload for one matching IAD1 sequence.
internal struct NativeMeta
{
    internal bool Present;
    internal uint BoundSeed;
    internal uint Flags;
    internal int QueueDelay;
}

// One IAD3 word may precede IAD2/IAD1 packets with the same sequence.
// Format: IAD3|<seq>|<boundSeed>|<flags>|<queueDelay>
internal sealed class NativeMetaPairing
{
    long sequence = -1;
    NativeMeta pending;

    internal void Reset()
    {
        sequence = -1;
        pending = default(NativeMeta);
    }

    internal void Receive(long seq, uint seed, uint fl, int qd)
    {
        sequence = seq;
        pending.Present = true;
        pending.BoundSeed = seed;
        pending.Flags = fl;
        pending.QueueDelay = qd;
    }

    internal bool ReceiveLine(string line)
    {
        string[] f = line.Split('|');
        long seq;
        uint seed, fl;
        int qd;
        if (f.Length == 5 &&
            long.TryParse(f[1], out seq) &&
            uint.TryParse(f[2], out seed) &&
            uint.TryParse(f[3], out fl) &&
            int.TryParse(f[4], out qd))
        {
            Receive(seq, seed, fl, qd);
            return true;
        }
        Reset();
        return false;
    }

    internal NativeMeta Take(long seq)
    {
        NativeMeta result = sequence == seq ? pending : default(NativeMeta);
        Reset();
        return result;
    }
}
