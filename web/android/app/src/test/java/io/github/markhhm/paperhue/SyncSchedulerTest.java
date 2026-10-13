package io.github.markhhm.paperhue;

import static org.junit.Assert.assertEquals;

import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.TimeZone;
import org.junit.Test;

public class SyncSchedulerTest {

    private static final TimeZone TAIPEI = TimeZone.getTimeZone("Asia/Taipei");
    private static final List<String> TIMES = Arrays.asList("08:00", "17:30");

    /** Epoch ms of 2026-10-{day} hh:mm:ss in Taipei (UTC+8). */
    private static long at(int day, int hour, int minute, int second) {
        return java.time.ZonedDateTime.of(2026, 10, day, hour, minute, second, 0, TAIPEI.toZoneId()).toInstant().toEpochMilli();
    }

    @Test
    public void runsAtTheNextChosenTimeAndNeverWithoutOne() {
        assertEquals(at(13, 8, 0, 0), SyncScheduler.nextRun(TIMES, at(13, 7, 59, 0), TAIPEI, 0));
        assertEquals(at(13, 17, 30, 0), SyncScheduler.nextRun(TIMES, at(13, 8, 0, 1), TAIPEI, 0));
        assertEquals(at(14, 8, 0, 0), SyncScheduler.nextRun(TIMES, at(13, 18, 0, 0), TAIPEI, 0));
        assertEquals(-1, SyncScheduler.nextRun(Collections.<String>emptyList(), at(13, 7, 0, 0), TAIPEI, at(13, 7, 15, 0)));
        // A retry that is due before the next chosen time comes first.
        assertEquals(at(13, 8, 15, 0), SyncScheduler.nextRun(TIMES, at(13, 8, 1, 0), TAIPEI, at(13, 8, 15, 0)));
    }

    @Test
    public void triesEveryQuarterHourForTwoHoursAfterTheChosenTime() {
        long eight = at(13, 8, 0, 0);
        assertEquals(eight, SyncScheduler.lastScheduled(TIMES, at(13, 8, 0, 3), TAIPEI));
        assertEquals(at(13, 8, 15, 0), SyncScheduler.retryAt(at(13, 8, 1, 10), eight));
        // A late alarm does not push the tries off the quarter hours.
        assertEquals(at(13, 10, 0, 0), SyncScheduler.retryAt(at(13, 9, 45, 2), eight));
        assertEquals(-1, SyncScheduler.retryAt(at(13, 10, 0, 1), eight));
        // Retries after midnight belong to the evening's time.
        assertEquals(at(12, 23, 30, 0), SyncScheduler.lastScheduled(Collections.singletonList("23:30"), at(13, 0, 15, 0), TAIPEI));
    }
}
