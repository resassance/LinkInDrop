package dev.resassance.linkindrop;

public final class MediaOrder {
    private static long timestamp(long taken, long modified, long added) {
        if (taken > 0) return taken;
        return (modified > 0 ? modified : Math.max(0, added)) * 1000L;
    }

    public static int compare(long leftTaken, long leftModified, long leftAdded, long leftId,
                              long rightTaken, long rightModified, long rightAdded, long rightId) {
        int date = Long.compare(timestamp(rightTaken, rightModified, rightAdded), timestamp(leftTaken, leftModified, leftAdded));
        return date == 0 ? Long.compare(rightId, leftId) : date;
    }

    private MediaOrder() {}
}
