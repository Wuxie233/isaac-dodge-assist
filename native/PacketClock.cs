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

